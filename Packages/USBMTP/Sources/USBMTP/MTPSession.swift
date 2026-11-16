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

    public init(transport: any MTPTransport) { self.transport = transport }

    /// 执行一次事务：命令 → （可选）数据阶段 → 响应。仅支持设备到主机方向的数据阶段（M0 只读验证）。
    public func execute(_ op: UInt16, params: [UInt32] = []) async throws -> MTPResult {
        let tid = nextTransactionID
        nextTransactionID &+= 1
        try await transport.send(MTPContainer.command(op, tid: tid, params: params).encoded())

        var data = Data()
        while true {
            let container = try await readContainer()
            switch container.type {
            case .data:
                data.append(container.payload)
            case .response:
                var r = ByteReader(container.payload)
                var rp: [UInt32] = []
                while r.remaining >= 4 { rp.append(try r.u32()) }
                return MTPResult(data: data, responseCode: container.code, responseParams: rp)
            default:
                throw MTPError.unexpectedContainer("事务 \(tid) 收到类型 \(container.type)")
            }
        }
    }

    private func readContainer() async throws -> MTPContainer {
        // 上一个数据容器恰为包长整数倍时设备会发零长度包，需跳过
        var buffer = Data()
        for _ in 0..<4 where buffer.isEmpty { buffer = try await transport.receive(maxLength: readChunk) }
        guard buffer.count >= MTPContainer.headerSize else {
            throw MTPError.malformedData("容器头不足 12 字节：\(buffer.count)")
        }
        var r = ByteReader(buffer)
        let length = Int(try r.u32())     // 超过 4GB 的数据容器长度为 0xFFFFFFFF，M0 不处理（待验证）
        guard length >= MTPContainer.headerSize, length != Int(UInt32.max) else {
            throw MTPError.malformedData("不支持的容器长度 \(length)")
        }
        while buffer.count < length {
            buffer.append(try await transport.receive(maxLength: readChunk))
        }
        return try MTPContainer.decode(buffer.prefix(length))
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

    /// 列出某目录的直接子项；`parent` 为 0xFFFFFFFF 表示存储根。逐项取 ObjectInfo，大目录会很慢（待优化）。
    public func list(storage: UInt32, parent: UInt32 = 0xFFFF_FFFF) async throws -> [MTPObjectInfo] {
        var r = ByteReader(try checked(try await execute(MTPOperation.getObjectHandles, params: [storage, 0, parent])).data)
        var out: [MTPObjectInfo] = []
        for h in try r.u32Array() {
            let d = try checked(try await execute(MTPOperation.getObjectInfo, params: [h])).data
            out.append(try MTPObjectInfo.parse(d, handle: h))
        }
        return out
    }
}
