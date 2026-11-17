import Foundation
@testable import DroidDock

/// 内存假设备文件提供方，用于隔离真实 USB 设备运行单元测试。
actor FakeFileProvider: FileProvider {
    var storagesList: [StorageInfo]
    var directories: [UInt32: [String: [RemoteNode]]]
    var thumbnails: [String: Data]
    var filePayloads: [String: Data]
    var nextError: Error?
    var transientFailureQueue: [Error] = []
    var downloadChunkDelayNanoseconds: UInt64 = 0
    private var nextHandleID: UInt32 = 9000
    private(set) var recordedOperations: [String] = []

    init(
        storages: [StorageInfo] = [StorageInfo(id: 65537, name: "内部共享存储空间", totalBytes: 128_000_000_000, freeBytes: 64_000_000_000)],
        directories: [UInt32: [String: [RemoteNode]]] = [:],
        thumbnails: [String: Data] = [:],
        filePayloads: [String: Data] = [:],
        nextError: Error? = nil
    ) {
        self.storagesList = storages
        self.directories = directories
        self.thumbnails = thumbnails
        self.filePayloads = filePayloads
        self.nextError = nextError
    }

    func setNextError(_ error: Error?) {
        nextError = error
    }

    func enqueueTransientErrors(_ errors: [Error]) {
        transientFailureQueue.append(contentsOf: errors)
    }

    func setDownloadDelay(nanoseconds: UInt64) {
        downloadChunkDelayNanoseconds = nanoseconds
    }

    func setPayload(_ data: Data, for nodeID: String) {
        filePayloads[nodeID] = data
    }

    func payload(for nodeID: String) -> Data? {
        filePayloads[nodeID]
    }

    func setStorages(_ storages: [StorageInfo]) {
        storagesList = storages
    }

    func storages() async throws -> [StorageInfo] {
        recordedOperations.append("storages")
        if let nextError {
            throw nextError
        }
        return storagesList
    }

    func list(dir: String, storage: UInt32) async throws -> [RemoteNode] {
        let normalized = PathUtils.normalize(dir)
        recordedOperations.append("list:\(storage):\(normalized)")
        if let nextError {
            throw nextError
        }
        return (directories[storage]?[normalized] ?? []).filter { !$0.name.hasPrefix(".") }
    }

    func listMedia(storage: UInt32, limit: Int) async throws -> [RemoteNode] {
        recordedOperations.append("listMedia:\(storage):\(limit)")
        if let nextError {
            throw nextError
        }
        let allNodes = (directories[storage] ?? [:]).values.flatMap { $0 }
        let media = allNodes
            .filter { !$0.isDirectory && !$0.name.hasPrefix(".") && ($0.kind == .photo || $0.kind == .video) }
            .sorted { lhs, rhs in
                let lDate = lhs.modified ?? .distantPast
                let rDate = rhs.modified ?? .distantPast
                if lDate != rDate {
                    return lDate > rDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            }
        return Array(media.prefix(limit))
    }

    func thumbnail(for node: RemoteNode) async throws -> Data? {
        recordedOperations.append("thumbnail:\(node.id)")
        if let nextError {
            throw nextError
        }
        return thumbnails[node.id]
    }

    func download(_ node: RemoteNode, to url: URL, progress: @Sendable (UInt64) -> Void) async throws {
        recordedOperations.append("download:\(node.id)")
        if let nextError {
            throw nextError
        }
        if !transientFailureQueue.isEmpty {
            let err = transientFailureQueue.removeFirst()
            throw err
        }

        let payload = filePayloads[node.id] ?? Data(repeating: 0x42, count: Int(min(node.size, 1_048_576)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let chunkSize = max(1, payload.count / 3)
        var offset = 0
        while offset < payload.count {
            try Task.checkCancellation()
            let end = min(payload.count, offset + chunkSize)
            try handle.write(contentsOf: payload[offset..<end])
            offset = end
            progress(UInt64(offset))
            if downloadChunkDelayNanoseconds > 0 && offset < payload.count {
                try await Task.sleep(nanoseconds: downloadChunkDelayNanoseconds)
                if !transientFailureQueue.isEmpty {
                    let err = transientFailureQueue.removeFirst()
                    throw err
                }
            }
        }
        if payload.isEmpty {
            progress(0)
        }
    }

    func upload(
        from url: URL,
        toDir: String,
        remoteName: String?,
        storage: UInt32,
        progress: @Sendable (UInt64) -> Void
    ) async throws -> RemoteNode {
        let normalized = PathUtils.normalize(toDir)
        let finalName = remoteName ?? url.lastPathComponent
        recordedOperations.append("upload:\(storage):\(normalized)/\(finalName)")
        if let nextError {
            throw nextError
        }
        if !transientFailureQueue.isEmpty {
            let err = transientFailureQueue.removeFirst()
            throw err
        }
        if PathUtils.validateAndroidFilename(finalName) != nil {
            throw DeviceError.invalidName
        }

        let data = try Data(contentsOf: url)
        progress(UInt64(data.count))

        nextHandleID &+= 1
        let nodeID = "\(storage):\(nextHandleID)"
        let node = RemoteNode(
            id: nodeID,
            storageID: storage,
            path: PathUtils.join(normalized, finalName),
            name: finalName,
            isDirectory: false,
            size: UInt64(data.count),
            modified: Date(),
            kind: PathUtils.inferMediaKind(filename: finalName)
        )
        filePayloads[nodeID] = data
        directories[storage, default: [:]][normalized, default: []].append(node)
        return node
    }

    func delete(_ node: RemoteNode) async throws {
        recordedOperations.append("delete:\(node.id)")
        if let nextError {
            throw nextError
        }
        let parent = PathUtils.parentPath(of: node.path)
        directories[node.storageID]?[parent]?.removeAll { $0.id == node.id }
        filePayloads.removeValue(forKey: node.id)
        if node.isDirectory {
            let prefix = node.path + "/"
            if var storageMap = directories[node.storageID] {
                storageMap.removeValue(forKey: node.path)
                for key in storageMap.keys where key.hasPrefix(prefix) {
                    storageMap.removeValue(forKey: key)
                }
                directories[node.storageID] = storageMap
            }
        }
    }

    func makeDirectory(_ name: String, in dir: String, storage: UInt32) async throws {
        let normalized = PathUtils.normalize(dir)
        recordedOperations.append("mkdir:\(storage):\(normalized)/\(name)")
        if let nextError {
            throw nextError
        }
        if PathUtils.validateAndroidFilename(name) != nil {
            throw DeviceError.invalidName
        }
        nextHandleID &+= 1
        let dirPath = PathUtils.join(normalized, name)
        let node = RemoteNode(
            id: "\(storage):\(nextHandleID)",
            storageID: storage,
            path: dirPath,
            name: name,
            isDirectory: true,
            size: 0,
            modified: Date(),
            kind: .other
        )
        directories[storage, default: [:]][normalized, default: []].append(node)
        if directories[storage]?[dirPath] == nil {
            directories[storage, default: [:]][dirPath] = []
        }
    }
}

/// 可控假设备后端，模拟热插拔与状态切换。
final class FakeDeviceBackend: DeviceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [DeviceID: any FileProvider] = [:]
    private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]
    private(set) var refreshCount = 0

    func register(provider: any FileProvider, for id: DeviceID) {
        lock.withLock {
            providers[id] = provider
        }
    }

    func emit(_ event: DeviceEvent) {
        let active = lock.withLock { Array(continuations.values) }
        for continuation in active {
            continuation.yield(event)
        }
    }

    func events() -> AsyncStream<DeviceEvent> {
        let key = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                continuations[key] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.continuations.removeValue(forKey: key)
                }
            }
        }
    }

    func open(_ id: DeviceID) async throws -> any FileProvider {
        guard let provider = lock.withLock({ providers[id] }) else {
            throw DeviceError.disconnected
        }
        return provider
    }

    func refresh() async {
        lock.withLock {
            refreshCount += 1
        }
    }
}
