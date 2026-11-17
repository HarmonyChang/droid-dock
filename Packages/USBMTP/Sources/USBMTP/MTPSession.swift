import Foundation

/// 批量传输通道抽象，便于用假实现测试会话逻辑。
public protocol MTPTransport: Sendable {
    func send(_ data: Data) async throws
    /// 读取一次 Bulk-IN，返回本次收到的字节（可能是容器的一部分）。
    func receive(maxLength: Int) async throws -> Data
}

public struct MTPResult: Sendable {
    public let data: Data
    public let responseCode: UInt16
    public let responseParams: [UInt32]
}

/// 单设备 MTP 会话。actor 保证该设备事务串行（MTP 不支持并发事务）。
public actor MTPSession {
    private let transport: any MTPTransport
    private var nextTransactionID: UInt32 = 1
    private let readChunk = 64 * 1024
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any MTPTransport) { self.transport = transport }

    private func withTransactionLock<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        try Task.checkCancellation()
        isBusy = true
        defer {
            isBusy = false
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
        return try await work()
    }

    /// 执行一次事务：命令 → （可选）数据阶段 → 响应（设备到主机方向）。
    public func execute(_ op: UInt16, params: [UInt32] = []) async throws -> MTPResult {
        try await withTransactionLock {
            try await executeUnchecked(op, params: params)
        }
    }

    /// 执行带主机到设备数据阶段的事务：命令 → 数据容器 → 响应。
    public func executeWithData(_ op: UInt16, params: [UInt32] = [], payload: Data) async throws -> MTPResult {
        try await withTransactionLock {
            try await executeWithDataUnchecked(op, params: params, payload: payload)
        }
    }

    private func executeUnchecked(_ op: UInt16, params: [UInt32] = []) async throws -> MTPResult {
        let tid = nextTransactionID
        nextTransactionID &+= 1
        try await transport.send(MTPContainer.command(op, tid: tid, params: params).encoded())

        var data = Data()
        var buffer = Data()
        while true {
            let (container, remainder) = try await readContainerAndRemainder(initialBuffer: buffer)
            buffer = remainder
            switch container.type {
            case .data:
                data.append(container.payload)
            case .response:
                return MTPResult(data: data, responseCode: container.code, responseParams: try parseResponseParams(container.payload))
            default:
                throw MTPError.unexpectedContainer("事务 \(tid) 收到类型 \(container.type)")
            }
        }
    }

    private func executeWithDataUnchecked(_ op: UInt16, params: [UInt32] = [], payload: Data) async throws -> MTPResult {
        let tid = nextTransactionID
        nextTransactionID &+= 1
        try await transport.send(MTPContainer.command(op, tid: tid, params: params).encoded())
        try await transport.send(MTPContainer(type: .data, code: op, transactionID: tid, payload: payload).encoded())

        let (container, _) = try await readContainerAndRemainder()
        guard container.type == .response else {
            throw MTPError.unexpectedContainer("事务 \(tid) 预期响应容器，收到 \(container.type)")
        }
        return MTPResult(data: Data(), responseCode: container.code, responseParams: try parseResponseParams(container.payload))
    }

    private func parseResponseParams(_ payload: Data) throws -> [UInt32] {
        var r = ByteReader(payload)
        var rp: [UInt32] = []
        while r.remaining >= 4 { rp.append(try r.u32()) }
        return rp
    }

    private func receiveNonEmpty(into buffer: inout Data, minBytes: Int) async throws {
        var emptyCount = 0
        while buffer.count < minBytes {
            let chunk = try await transport.receive(maxLength: readChunk)
            if chunk.isEmpty {
                emptyCount += 1
                if emptyCount >= 8 {
                    throw MTPError.transport("连续收到空 USB 数据包")
                }
                continue
            }
            emptyCount = 0
            buffer.append(chunk)
        }
    }

    private func readContainerAndRemainder(initialBuffer: Data = Data()) async throws -> (MTPContainer, Data) {
        // 上一个数据容器恰为包长整数倍时设备会发零长度包，需跳过
        var buffer = initialBuffer
        try await receiveNonEmpty(into: &buffer, minBytes: MTPContainer.headerSize)
        var r = ByteReader(buffer)
        let length = Int(try r.u32())     // 超过 4GB 的数据容器长度为 0xFFFFFFFF
        guard length >= MTPContainer.headerSize, length != Int(UInt32.max) else {
            throw MTPError.malformedData("不支持的容器长度 \(length)")
        }
        try await receiveNonEmpty(into: &buffer, minBytes: length)
        let container = try MTPContainer.decode(buffer.prefix(length))
        let remainder = buffer.count > length ? Data(buffer.dropFirst(length)) : Data()
        return (container, remainder)
    }

    private func checked(_ result: MTPResult) throws -> MTPResult {
        guard result.responseCode == MTPResponseCode.ok else {
            throw MTPError.responseFailed(code: result.responseCode)
        }
        return result
    }

    // MARK: 高层操作（M0 只读子集）

    public func deviceInfo() async throws -> MTPDeviceInfo {
        try MTPDeviceInfo.parse(try checked(try await execute(MTPOperation.getDeviceInfo)).data)
    }

    public func openSession(id: UInt32 = 1) async throws {
        let res = try await execute(MTPOperation.openSession, params: [id])
        guard res.responseCode == MTPResponseCode.ok || res.responseCode == MTPResponseCode.sessionAlreadyOpen else {
            throw MTPError.responseFailed(code: res.responseCode)
        }
    }

    public func closeSession() async throws {
        _ = try await execute(MTPOperation.closeSession)
    }

    public func storages() async throws -> [MTPStorageInfo] {
        var r = ByteReader(try checked(try await execute(MTPOperation.getStorageIDs)).data)
        var out: [MTPStorageInfo] = []
        for id in try r.u32Array() {
            let d = try checked(try await execute(MTPOperation.getStorageInfo, params: [id])).data
            out.append(try MTPStorageInfo.parse(d, id: id))
        }
        return out
    }

    /// 获取某目录下的对象句柄数组；`parent` 为 0xFFFFFFFF 表示存储根。
    public func objectHandles(storage: UInt32, parent: UInt32 = 0xFFFF_FFFF) async throws -> [UInt32] {
        var r = ByteReader(try checked(try await execute(MTPOperation.getObjectHandles, params: [storage, 0, parent])).data)
        return try r.u32Array()
    }

    /// 获取单个对象的元信息。
    public func objectInfo(handle: UInt32) async throws -> MTPObjectInfo {
        let d = try checked(try await execute(MTPOperation.getObjectInfo, params: [handle])).data
        return try MTPObjectInfo.parse(d, handle: handle)
    }

    /// 读取设备原生缩略图（GetThumb），不支持或空数据时返回 nil。
    public func thumbnail(handle: UInt32) async throws -> Data? {
        let res = try await execute(MTPOperation.getThumb, params: [handle])
        guard res.responseCode == MTPResponseCode.ok, !res.data.isEmpty else {
            return nil
        }
        return res.data
    }

    /// 部分读取对象字节（GetPartialObject）。
    public func partialObject(handle: UInt32, offset: UInt32, maxBytes: UInt32) async throws -> Data {
        try checked(try await execute(MTPOperation.getPartialObject, params: [handle, offset, maxBytes])).data
    }

    /// 流式下载完整对象（GetObject），按 64 KB 块回调，不在内存中缓存整文件。
    public func downloadObject(
        handle: UInt32,
        onChunk: @Sendable (Data) throws -> Void,
        progress: @Sendable (UInt64) -> Void
    ) async throws {
        try await withTransactionLock {
            let tid = nextTransactionID
            nextTransactionID &+= 1
            try await transport.send(MTPContainer.command(MTPOperation.getObject, tid: tid, params: [handle]).encoded())

            var headerBuf = Data()
            try await receiveNonEmpty(into: &headerBuf, minBytes: MTPContainer.headerSize)
            var r = ByteReader(headerBuf)
            let totalLen = try r.u32()
            let rawType = try r.u16()
            let code = try r.u16()
            _ = try r.u32() // tid

            guard let type = MTPContainerType(rawValue: rawType) else {
                throw MTPError.malformedData("未知容器类型 \(rawType)")
            }
            if type == .response {
                if Int(totalLen) > headerBuf.count {
                    try await receiveNonEmpty(into: &headerBuf, minBytes: Int(totalLen))
                }
                throw MTPError.responseFailed(code: code)
            }
            guard type == .data else {
                throw MTPError.unexpectedContainer("GetObject 预期数据容器，收到 \(type)")
            }

            let initial = Data(headerBuf.dropFirst(MTPContainer.headerSize))
            var received: UInt64 = 0
            var leftover = Data()

            if totalLen != UInt32.max {
                guard Int(totalLen) >= MTPContainer.headerSize else {
                    throw MTPError.malformedData("无效的数据容器长度 \(totalLen)")
                }
                let expectedPayload = UInt64(totalLen) - UInt64(MTPContainer.headerSize)
                if !initial.isEmpty {
                    let take = min(UInt64(initial.count), expectedPayload)
                    if take > 0 {
                        try onChunk(Data(initial.prefix(Int(take))))
                        received += take
                        progress(received)
                    }
                    if UInt64(initial.count) > take {
                        leftover.append(contentsOf: initial.dropFirst(Int(take)))
                    }
                }
                var emptyCount = 0
                while received < expectedPayload {
                    try Task.checkCancellation()
                    let pkt = try await transport.receive(maxLength: readChunk)
                    if pkt.isEmpty {
                        emptyCount += 1
                        if emptyCount >= 8 {
                            throw MTPError.transport("下载数据时连续收到空 USB 数据包")
                        }
                        continue
                    }
                    emptyCount = 0
                    let need = expectedPayload - received
                    let use = min(UInt64(pkt.count), need)
                    if use > 0 {
                        try onChunk(Data(pkt.prefix(Int(use))))
                        received += use
                        progress(received)
                    }
                    if UInt64(pkt.count) > use {
                        leftover.append(contentsOf: pkt.dropFirst(Int(use)))
                    }
                }
            } else {
                // >=4GB 对象长度字段为 0xFFFFFFFF，按短包或零长度包结束数据阶段
                if !initial.isEmpty {
                    try onChunk(initial)
                    received += UInt64(initial.count)
                    progress(received)
                }
                if headerBuf.count % 512 == 0 {
                    while true {
                        try Task.checkCancellation()
                        let pkt = try await transport.receive(maxLength: readChunk)
                        if pkt.isEmpty { break }
                        try onChunk(pkt)
                        received += UInt64(pkt.count)
                        progress(received)
                        if pkt.count % 512 != 0 { break }
                    }
                }
            }

            let (resp, _) = try await readContainerAndRemainder(initialBuffer: leftover)
            guard resp.type == .response else {
                throw MTPError.unexpectedContainer("GetObject 预期响应容器，收到 \(resp.type)")
            }
            _ = try checked(MTPResult(data: Data(), responseCode: resp.code, responseParams: parseResponseParams(resp.payload)))
        }
    }

    /// 流式上传文件（SendObjectInfo + SendObject）。将 12 字节数据容器头与首批文件字节合并为 64 KB 对齐写出。
    public func uploadObject(
        storageID: UInt32,
        parentHandle: UInt32,
        filename: String,
        fileSize: UInt64,
        dateString: String = "",
        readChunk: @Sendable (Int) throws -> Data,
        progress: @Sendable (UInt64) -> Void
    ) async throws -> UInt32 {
        try await withTransactionLock {
            let infoData = MTPObjectInfo.encodeForSend(
                storageID: storageID,
                parent: parentHandle,
                filename: filename,
                size: fileSize,
                isDirectory: false,
                dateString: dateString
            )
            let infoRes = try checked(try await executeWithDataUnchecked(
                MTPOperation.sendObjectInfo,
                params: [storageID, parentHandle],
                payload: infoData
            ))
            var assignedHandle = infoRes.responseParams.count >= 3 ? infoRes.responseParams[2] : 0

            try Task.checkCancellation()

            let tid = nextTransactionID
            nextTransactionID &+= 1
            try await transport.send(MTPContainer.command(MTPOperation.sendObject, tid: tid, params: []).encoded())

            let containerLen: UInt32 = (fileSize + UInt64(MTPContainer.headerSize)) >= UInt64(UInt32.max)
                ? UInt32.max
                : UInt32(fileSize + UInt64(MTPContainer.headerSize))

            var headerWriter = ByteWriter()
            headerWriter.u32(containerLen)
            headerWriter.u16(MTPContainerType.data.rawValue)
            headerWriter.u16(MTPOperation.sendObject)
            headerWriter.u32(tid)

            let firstCap = self.readChunk - MTPContainer.headerSize
            let firstToRead = Int(min(UInt64(firstCap), fileSize))
            let firstData = firstToRead > 0 ? try readChunk(firstToRead) : Data()
            if firstToRead > 0 && firstData.isEmpty {
                throw MTPError.malformedData("上传源文件为空或提前结束")
            }

            var firstPacket = headerWriter.data
            firstPacket.reserveCapacity(MTPContainer.headerSize + firstData.count)
            firstPacket.append(firstData)
            try await transport.send(firstPacket)

            var sent = UInt64(firstData.count)
            progress(sent)

            while sent < fileSize {
                try Task.checkCancellation()
                let toRead = Int(min(UInt64(self.readChunk), fileSize - sent))
                let chunk = try readChunk(toRead)
                guard !chunk.isEmpty else {
                    throw MTPError.malformedData("上传源文件读取提前结束")
                }
                try await transport.send(chunk)
                sent += UInt64(chunk.count)
                progress(sent)
            }

            let (resp, _) = try await readContainerAndRemainder()
            guard resp.type == .response else {
                throw MTPError.unexpectedContainer("SendObject 预期响应容器，收到 \(resp.type)")
            }
            let checkedResp = try checked(MTPResult(data: Data(), responseCode: resp.code, responseParams: parseResponseParams(resp.payload)))
            if assignedHandle == 0, checkedResp.responseParams.count >= 3 {
                assignedHandle = checkedResp.responseParams[2]
            }
            return assignedHandle
        }
    }

    /// 在指定父目录下新建文件夹（SendObjectInfo，Association 格式 0x3001），返回新对象句柄。
    public func makeDirectory(
        storageID: UInt32,
        parentHandle: UInt32,
        name: String,
        dateString: String = ""
    ) async throws -> UInt32 {
        try await withTransactionLock {
            let infoData = MTPObjectInfo.encodeForSend(
                storageID: storageID,
                parent: parentHandle,
                filename: name,
                size: 0,
                isDirectory: true,
                dateString: dateString
            )
            let res = try checked(try await executeWithDataUnchecked(
                MTPOperation.sendObjectInfo,
                params: [storageID, parentHandle],
                payload: infoData
            ))
            return res.responseParams.count >= 3 ? res.responseParams[2] : 0
        }
    }

    /// 删除指定句柄的对象或目录（DeleteObject）。
    public func deleteObject(handle: UInt32) async throws {
        _ = try checked(try await execute(MTPOperation.deleteObject, params: [handle, 0]))
    }

    /// 列出某目录的直接子项；`parent` 为 0xFFFFFFFF 表示存储根。逐项取 ObjectInfo，大目录会很慢（待优化）。
    public func list(storage: UInt32, parent: UInt32 = 0xFFFF_FFFF) async throws -> [MTPObjectInfo] {
        var out: [MTPObjectInfo] = []
        for h in try await objectHandles(storage: storage, parent: parent) {
            out.append(try await objectInfo(handle: h))
        }
        return out
    }
}
