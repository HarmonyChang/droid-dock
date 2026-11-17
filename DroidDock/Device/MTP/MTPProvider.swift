import Foundation
import ImageIO
import USBMTP

/// 基于 `USBMTP` 的 MTP 设备文件提供方；单设备所有操作由上层 `DeviceSession` 串行调用。
actor MTPFileProvider: FileProvider {
    private let session: MTPSession
    private var dirHandleCache: [UInt32: [String: UInt32]] = [:]
    private var nodeHandleCache: [String: UInt32] = [:]
    private var objectInfoCache: [UInt32: [UInt32: MTPObjectInfo]] = [:]

    init(session: MTPSession) {
        self.session = session
    }

    func storages() async throws -> [StorageInfo] {
        do {
            let list = try await session.storages()
            return list.map { info in
                StorageInfo(
                    id: info.id,
                    name: info.description.isEmpty ? "内部存储" : info.description,
                    totalBytes: info.maxCapacity,
                    freeBytes: info.freeSpace
                )
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    private static let priorityRootFolders = [
        "DCIM", "Pictures", "Movies", "Download", "Documents", "Music", "Recordings",
    ]

    func list(dir: String, storage: UInt32) async throws -> [RemoteNode] {
        let normalizedDir = PathUtils.normalize(dir)
        do {
            let parentHandle = try await resolveDirectoryHandle(normalizedDir, storage: storage)
            let handles = try await session.objectHandles(storage: storage, parent: parentHandle)
            var nodes: [RemoteNode] = []
            nodes.reserveCapacity(handles.count)
            for handle in handles {
                try Task.checkCancellation()
                let info = try await cachedOrFetchObjectInfo(storage: storage, handle: handle)
                let node = makeNode(from: info, storage: storage, parentDir: normalizedDir)
                guard !info.filename.hasPrefix(".") else { continue }
                nodes.append(node)
            }
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                if normalizedDir == "/" && lhs.isDirectory && rhs.isDirectory {
                    let leftRank = Self.priorityRootFolders.firstIndex(of: lhs.name) ?? Int.max
                    let rightRank = Self.priorityRootFolders.firstIndex(of: rhs.name) ?? Int.max
                    if leftRank != rightRank {
                        return leftRank < rightRank
                    }
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    func listMedia(storage: UInt32, limit: Int) async throws -> [RemoteNode] {
        do {
            var candidateDirs = [
                "/DCIM/Camera",
                "/DCIM/Screenshots",
                "/Pictures/Screenshots",
                "/Pictures",
                "/Movies",
            ]
            if let dcimChildren = try? await list(dir: "/DCIM", storage: storage) {
                for child in dcimChildren where child.isDirectory && !child.name.hasPrefix(".") {
                    if !candidateDirs.contains(child.path) {
                        candidateDirs.append(child.path)
                    }
                }
            }

            var queues: [(dirPath: String, handles: [UInt32])] = []
            for dirPath in candidateDirs {
                do {
                    let parentHandle = try await resolveDirectoryHandle(dirPath, storage: storage)
                    let handles = try await session.objectHandles(storage: storage, parent: parentHandle)
                    if !handles.isEmpty {
                        queues.append((dirPath, Array(handles.reversed())))
                    }
                } catch let error as DeviceError {
                    if case .disconnected = error {
                        throw error
                    }
                    continue
                } catch {
                    if case .disconnected = Self.mapError(error) {
                        throw DeviceError.disconnected
                    }
                    continue
                }
            }

            // 轮流从各媒体目录取最新句柄，避免单一超大目录占满配额
            var selectedHandles: [(dirPath: String, handle: UInt32)] = []
            var offsets = Array(repeating: 0, count: queues.count)
            let batchSize = 40
            while selectedHandles.count < limit {
                var progressed = false
                for idx in queues.indices {
                    let start = offsets[idx]
                    let total = queues[idx].handles.count
                    guard start < total else { continue }
                    let end = min(total, start + batchSize)
                    for h in queues[idx].handles[start..<end] {
                        selectedHandles.append((queues[idx].dirPath, h))
                        if selectedHandles.count >= limit { break }
                    }
                    offsets[idx] = end
                    progressed = true
                    if selectedHandles.count >= limit { break }
                }
                if !progressed { break }
            }

            var mediaNodes: [RemoteNode] = []
            var seenIDs: Set<String> = []
            for item in selectedHandles {
                try Task.checkCancellation()
                let info = try await cachedOrFetchObjectInfo(storage: storage, handle: item.handle)
                guard !info.isDirectory, !info.filename.hasPrefix(".") else { continue }
                let node = makeNode(from: info, storage: storage, parentDir: item.dirPath)
                guard node.kind == .photo || node.kind == .video else { continue }
                if seenIDs.insert(node.id).inserted {
                    mediaNodes.append(node)
                }
            }

            return mediaNodes.sorted { lhs, rhs in
                let leftDate = lhs.modified ?? .distantPast
                let rightDate = rhs.modified ?? .distantPast
                if leftDate != rightDate {
                    return leftDate > rightDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func thumbnail(for node: RemoteNode) async throws -> Data? {
        do {
            try Task.checkCancellation()
            let objectHandle: UInt32
            if let cached = nodeHandleCache[node.id] {
                objectHandle = cached
            } else if let suffix = node.id.split(separator: ":").last, let parsed = UInt32(suffix) {
                objectHandle = parsed
            } else {
                return nil
            }
            if let native = try await session.thumbnail(handle: objectHandle), !native.isEmpty {
                return native
            }
            // 对无原生 GetThumb 的照片先读取前 128 KB 提取内嵌 EXIF 缩略图，避免逐张下载原图拖慢网格滑动
            if node.kind == .photo, node.size > 0 {
                let headBytes = UInt32(min(node.size, 131_072))
                if let partial = try? await session.partialObject(handle: objectHandle, offset: 0, maxBytes: headBytes),
                   !partial.isEmpty {
                    if UInt64(partial.count) >= node.size {
                        return partial
                    }
                    if let exifThumb = Self.extractEmbeddedEXIFThumbnail(from: partial, maxPixelSize: 320) {
                        return exifThumb
                    }
                }
            }
            return nil
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    private nonisolated static func extractEmbeddedEXIFThumbnail(from partialData: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(partialData as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, cgImage, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return out as Data
    }

    private func cachedOrFetchObjectInfo(storage: UInt32, handle: UInt32) async throws -> MTPObjectInfo {
        if let cached = objectInfoCache[storage]?[handle] {
            return cached
        }
        let fetched = try await session.objectInfo(handle: handle)
        objectInfoCache[storage, default: [:]][handle] = fetched
        return fetched
    }

    private func handle(for node: RemoteNode) throws -> UInt32 {
        if let cached = nodeHandleCache[node.id] {
            return cached
        }
        if let suffix = node.id.split(separator: ":").last, let parsed = UInt32(suffix) {
            return parsed
        }
        throw DeviceError.underlying("找不到对象句柄：\(node.name)")
    }

    func download(_ node: RemoteNode, to url: URL, progress: @Sendable (UInt64) -> Void) async throws {
        guard !node.isDirectory else {
            throw DeviceError.unsupported
        }
        let objectHandle = try handle(for: node)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.createFile(atPath: url.path, contents: nil) {
                throw DeviceError.underlying("无法创建本地临时文件：\(url.lastPathComponent)")
            }
            let fileHandle = try FileHandle(forWritingTo: url)
            defer { try? fileHandle.close() }
            let writer = LockedFileHandle(fileHandle)
            try await session.downloadObject(
                handle: objectHandle,
                onChunk: { chunk in
                    try writer.write(chunk)
                },
                progress: progress
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func upload(
        from url: URL,
        toDir: String,
        remoteName: String? = nil,
        storage: UInt32,
        progress: @Sendable (UInt64) -> Void
    ) async throws -> RemoteNode {
        let filename = remoteName ?? url.lastPathComponent
        if PathUtils.validateAndroidFilename(filename) != nil {
            throw DeviceError.invalidName
        }
        let normalizedDir = PathUtils.normalize(toDir)
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw DeviceError.underlying("无法读取本地文件：\(url.lastPathComponent)")
        }
        if (attrs[.type] as? FileAttributeType) == .typeDirectory {
            throw DeviceError.unsupported
        }
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modDate = attrs[.modificationDate] as? Date

        do {
            let parentHandle = try await resolveDirectoryHandle(normalizedDir, storage: storage)
            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }
            let reader = LockedFileHandle(fileHandle)

            let assignedHandle = try await session.uploadObject(
                storageID: storage,
                parentHandle: parentHandle,
                filename: filename,
                fileSize: fileSize,
                dateString: modDate.map(PathUtils.formatMTPDate) ?? "",
                readChunk: { maxBytes in
                    try reader.read(upToCount: maxBytes)
                },
                progress: progress
            )

            if assignedHandle != 0, let info = try? await session.objectInfo(handle: assignedHandle) {
                return makeNode(from: info, storage: storage, parentDir: normalizedDir)
            }
            if let matched = try? await list(dir: normalizedDir, storage: storage).first(where: { $0.name == filename }) {
                return matched
            }
            return RemoteNode(
                id: "\(storage):\(assignedHandle)",
                storageID: storage,
                path: PathUtils.join(normalizedDir, filename),
                name: filename,
                isDirectory: false,
                size: fileSize,
                modified: modDate,
                kind: PathUtils.inferMediaKind(filename: filename)
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func delete(_ node: RemoteNode) async throws {
        let objectHandle = try handle(for: node)
        do {
            try await session.deleteObject(handle: objectHandle)
            nodeHandleCache.removeValue(forKey: node.id)
            objectInfoCache[node.storageID]?.removeValue(forKey: objectHandle)
            if node.isDirectory {
                let prefix = node.path == "/" ? "/" : node.path + "/"
                if var map = dirHandleCache[node.storageID] {
                    map.removeValue(forKey: node.path)
                    for key in map.keys where key.hasPrefix(prefix) {
                        map.removeValue(forKey: key)
                    }
                    dirHandleCache[node.storageID] = map
                }
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    func makeDirectory(_ name: String, in dir: String, storage: UInt32) async throws {
        if PathUtils.validateAndroidFilename(name) != nil {
            throw DeviceError.invalidName
        }
        let normalizedDir = PathUtils.normalize(dir)
        do {
            let parentHandle = try await resolveDirectoryHandle(normalizedDir, storage: storage)
            let createdHandle = try await session.makeDirectory(
                storageID: storage,
                parentHandle: parentHandle,
                name: name,
                dateString: PathUtils.formatMTPDate(Date())
            )
            if createdHandle != 0 {
                let newPath = PathUtils.join(normalizedDir, name)
                dirHandleCache[storage, default: ["/" : 0xFFFF_FFFF]][newPath] = createdHandle
                nodeHandleCache["\(storage):\(createdHandle)"] = createdHandle
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.mapError(error)
        }
    }

    private func resolveDirectoryHandle(_ normalizedDir: String, storage: UInt32) async throws -> UInt32 {
        if normalizedDir == "/" {
            dirHandleCache[storage, default: [:]]["/"] = 0xFFFF_FFFF
            return 0xFFFF_FFFF
        }
        if let cached = dirHandleCache[storage]?[normalizedDir] {
            return cached
        }

        var currentHandle: UInt32 = 0xFFFF_FFFF
        var currentPath = ""
        for component in normalizedDir.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(component)
            let parentPath = currentPath.isEmpty ? "/" : currentPath
            currentPath += "/" + segment

            if let cached = dirHandleCache[storage]?[currentPath] {
                currentHandle = cached
                continue
            }

            let handles = try await session.objectHandles(storage: storage, parent: currentHandle)
            var matched: UInt32?
            for handle in handles {
                try Task.checkCancellation()
                let info = try await cachedOrFetchObjectInfo(storage: storage, handle: handle)
                _ = makeNode(from: info, storage: storage, parentDir: parentPath)
                if info.isDirectory && info.filename == segment {
                    matched = info.handle
                }
            }
            guard let foundHandle = matched else {
                throw DeviceError.underlying("目录不存在：\(currentPath)")
            }
            currentHandle = foundHandle
        }
        return currentHandle
    }

    private func makeNode(from info: MTPObjectInfo, storage: UInt32, parentDir: String) -> RemoteNode {
        let nodePath = PathUtils.join(parentDir, info.filename)
        let nodeID = "\(storage):\(info.handle)"
        nodeHandleCache[nodeID] = info.handle
        if info.isDirectory {
            dirHandleCache[storage, default: ["/" : 0xFFFF_FFFF]][nodePath] = info.handle
        }
        let modified = PathUtils.parseMTPDate(info.dateModified) ?? PathUtils.parseMTPDate(info.dateCreated)
        let kind: MediaKind = info.isDirectory ? .other : PathUtils.inferMediaKind(filename: info.filename)
        return RemoteNode(
            id: nodeID,
            storageID: storage,
            path: nodePath,
            name: info.filename,
            isDirectory: info.isDirectory,
            size: UInt64(info.compressedSize),
            modified: modified,
            kind: kind
        )
    }

    static func mapError(_ error: Error) -> DeviceError {
        if let deviceError = error as? DeviceError {
            return deviceError
        }
        if let mtpError = error as? MTPError {
            switch mtpError {
            case .noDevice, .transport:
                return .disconnected
            case .responseFailed(let code):
                switch code {
                case 0x2003:
                    return .disconnected
                case 0x2005:
                    return .unsupported
                case 0x2009:
                    return .underlying("目标对象不存在或已被移除")
                case 0x200C:
                    return .storageFull
                case 0x200D, 0x200E, 0x200F:
                    return .permissionDenied
                case 0x2019:
                    return .busy
                case 0x201A:
                    return .underlying("目标目录不存在")
                case 0x201D:
                    return .invalidName
                default:
                    return .underlying(String(format: "MTP 响应错误：0x%04X", code))
                }
            case .malformedData(let msg), .unexpectedContainer(let msg):
                return .underlying(msg)
            }
        }
        let nsError = error as NSError
        if nsError.domain == "IOUSBHostErrorDomain" {
            // -536870199 / -536870203 为占用错误，其余 I/O 失败在已建立会话时通常意味着断线或模式切换
            if nsError.code == -536870199 || nsError.code == -536870203 {
                return .busy
            }
            return .disconnected
        }
        return .underlying(error.localizedDescription)
    }
}

/// 基于 `USBEnumerator` 与 `USBHotplugMonitor` 的 USB MTP 设备后端。
final class MTPDeviceBackend: DeviceBackend, @unchecked Sendable {
    private actor Coordinator {
        struct Entry {
            let info: DeviceInfo
            var state: DeviceState
            let session: MTPSession
            let provider: MTPFileProvider
            var watcherTask: Task<Void, Never>?
        }

        private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]
        private var entries: [DeviceID: Entry] = [:]
        private var hotplugTask: Task<Void, Never>?
        private var isScanning = false
        private var pendingRescan = false
        private var pendingFastRetry = false

        func addStream() -> AsyncStream<DeviceEvent> {
            let id = UUID()
            return AsyncStream { continuation in
                continuations[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removeStream(id) }
                }
                for entry in entries.values {
                    continuation.yield(.attached(entry.info))
                    continuation.yield(.stateChanged(entry.info.id, entry.state))
                }
                startMonitoringIfNeeded()
                Task { await scanNow(fastRetryForSwitch: false) }
            }
        }

        func open(_ id: DeviceID) throws -> any FileProvider {
            guard let entry = entries[id] else {
                throw DeviceError.disconnected
            }
            return entry.provider
        }

        func refresh() async {
            // 若已有处于 locked 的设备，先做一次存储状态检测
            for (id, entry) in entries where entry.state == .locked || entry.state == .detected {
                do {
                    let storages = try await entry.session.storages()
                    if !storages.isEmpty {
                        updateState(id, to: .ready)
                    }
                } catch {
                    await handleBrokenSession(for: id)
                }
            }
            await scanNow(fastRetryForSwitch: false)
        }

        private func removeStream(_ id: UUID) {
            continuations[id] = nil
        }

        private func emit(_ event: DeviceEvent) {
            for continuation in continuations.values {
                continuation.yield(event)
            }
        }

        private func startMonitoringIfNeeded() {
            guard hotplugTask == nil else { return }
            hotplugTask = Task { [weak self] in
                for await _ in USBHotplugMonitor.events() {
                    guard let self else { return }
                    await self.scanNow(fastRetryForSwitch: true)
                }
            }
        }

        private func deviceID(for candidate: USBInterfaceCandidate) -> DeviceID {
            if !candidate.serial.isEmpty {
                return DeviceID(rawValue: candidate.serial)
            }
            return DeviceID(
                rawValue: String(format: "%04x:%04x@%x", candidate.vendorID, candidate.productID, candidate.locationID)
            )
        }

        private func scanNow(fastRetryForSwitch: Bool) async {
            if isScanning {
                pendingRescan = true
                if fastRetryForSwitch {
                    pendingFastRetry = true
                }
                return
            }
            isScanning = true
            defer { isScanning = false }

            var useFastRetry = fastRetryForSwitch
            repeat {
                pendingRescan = false
                pendingFastRetry = false
                await performScanPass(fastRetryForSwitch: useFastRetry)
                useFastRetry = pendingFastRetry
            } while pendingRescan
        }

        private func performScanPass(fastRetryForSwitch: Bool) async {
            let candidates = USBEnumerator.candidates().filter(\.looksLikeMTP)
            var activeIDs: Set<DeviceID> = []
            for candidate in candidates {
                activeIDs.insert(deviceID(for: candidate))
            }

            // 检查已移除设备（等待短暂重枚举窗口，避免切换 USB 模式时误报拔出）
            let missingIDs = entries.keys.filter { !activeIDs.contains($0) }
            if !missingIDs.isEmpty && fastRetryForSwitch {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let recheck = USBEnumerator.candidates().filter(\.looksLikeMTP)
                let recheckIDs = Set(recheck.map { deviceID(for: $0) })
                for id in missingIDs where !recheckIDs.contains(id) {
                    removeEntry(id)
                }
            } else {
                for id in missingIDs {
                    removeEntry(id)
                }
            }

            // 发现并连接新接口
            let latestCandidates = USBEnumerator.candidates().filter(\.looksLikeMTP)
            for candidate in latestCandidates {
                let id = deviceID(for: candidate)
                if entries[id] != nil {
                    continue
                }
                await connectCandidate(candidate, id: id)
            }
        }

        private func connectCandidate(_ candidate: USBInterfaceCandidate, id: DeviceID) async {
            do {
                let transport = try IOUSBHostTransport(candidate: candidate)
                let session = MTPSession(transport: transport)
                let devInfo = try await session.deviceInfo()
                try await session.openSession()
                let storages = try await fetchStoragesWithWarmup(session: session)

                let fallbackName = [devInfo.manufacturer, devInfo.model]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let displayName = !candidate.deviceName.isEmpty
                    ? candidate.deviceName
                    : (fallbackName.isEmpty ? "Android 设备" : fallbackName)

                let info = DeviceInfo(
                    id: id,
                    name: displayName,
                    manufacturer: devInfo.manufacturer,
                    model: devInfo.model,
                    serialNumber: devInfo.serialNumber.isEmpty ? candidate.serial : devInfo.serialNumber
                )
                let initialState: DeviceState = storages.isEmpty ? .locked : .ready
                let provider = MTPFileProvider(session: session)
                var entry = Entry(
                    info: info,
                    state: initialState,
                    session: session,
                    provider: provider,
                    watcherTask: nil
                )
                if initialState == .locked {
                    entry.watcherTask = Task { [weak self] in
                        await self?.watchLockedDevice(id: id, session: session)
                    }
                }
                entries[id] = entry
                Log.device.info("Connected MTP device: \(displayName, privacy: .public), state=\(String(describing: initialState), privacy: .public)")
                emit(.attached(info))
                emit(.stateChanged(id, initialState))
            } catch {
                let mapped = MTPFileProvider.mapError(error)
                Log.device.error("Failed to open MTP candidate \(id.rawValue, privacy: .public): \(mapped.localizedDescription, privacy: .public)")
                if case .busy = mapped {
                    let info = DeviceInfo(
                        id: id,
                        name: candidate.deviceName.isEmpty ? "Android 设备" : candidate.deviceName,
                        manufacturer: "",
                        model: "",
                        serialNumber: candidate.serial
                    )
                    emit(.attached(info))
                    emit(.stateChanged(id, .error(mapped)))
                }
            }
        }

        private func fetchStoragesWithWarmup(session: MTPSession) async throws -> [MTPStorageInfo] {
            // 刚插线或刚切到文件传输模式时，Android MtpServer 可能短暂返回空存储列表，预热重试最多 ~1.2s
            for attempt in 0..<6 {
                let storages = try await session.storages()
                if !storages.isEmpty {
                    return storages
                }
                if attempt == 2 {
                    try? await session.closeSession()
                    try? await session.openSession()
                }
                if attempt < 5 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            return []
        }

        private func watchLockedDevice(id: DeviceID, session: MTPSession) async {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, entries[id] != nil else { return }
                tick += 1
                do {
                    var storages = try await session.storages()
                    if storages.isEmpty && tick % 2 == 0 {
                        try? await session.closeSession()
                        try await session.openSession()
                        storages = try await session.storages()
                    }
                    if !storages.isEmpty {
                        updateState(id, to: .ready)
                        return
                    }
                } catch {
                    await handleBrokenSession(for: id)
                    return
                }
            }
        }

        private func handleBrokenSession(for id: DeviceID) async {
            removeEntry(id)
            // 10ms 轮询抢占重枚举后的设备，确保抢在 O+Connect Service (1.9s) 与 ptpcamerad 之前接管
            for _ in 0..<150 {
                guard !Task.isCancelled else { return }
                let candidates = USBEnumerator.candidates().filter(\.looksLikeMTP)
                if let match = candidates.first(where: { deviceID(for: $0) == id }) ?? candidates.first {
                    let newID = deviceID(for: match)
                    if entries[newID] == nil {
                        await connectCandidate(match, id: newID)
                    }
                    if entries[newID] != nil {
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        private func updateState(_ id: DeviceID, to newState: DeviceState) {
            guard var entry = entries[id] else { return }
            if newState == .ready {
                entry.watcherTask?.cancel()
                entry.watcherTask = nil
            }
            entry.state = newState
            entries[id] = entry
            emit(.stateChanged(id, newState))
        }

        private func removeEntry(_ id: DeviceID) {
            guard let existing = entries.removeValue(forKey: id) else { return }
            existing.watcherTask?.cancel()
            Log.device.info("Detached MTP device: \(existing.info.name, privacy: .public)")
            emit(.detached(id))
        }
    }

    private let coordinator = Coordinator()

    func events() -> AsyncStream<DeviceEvent> {
        // 同步返回流，内部异步注册并驱动热插拔
        AsyncStream { continuation in
            let forwardTask = Task {
                for await event in await coordinator.addStream() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwardTask.cancel()
            }
        }
    }

    func open(_ id: DeviceID) async throws -> any FileProvider {
        try await coordinator.open(id)
    }

    func refresh() async {
        await coordinator.refresh()
    }
}

private final class LockedFileHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func read(upToCount count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try handle.read(upToCount: count) ?? Data()
    }
}
