import Foundation

/// 单台设备的文件操作串行会话 actor（MTP 不支持并发事务）。
actor DeviceSession {
    private let provider: any FileProvider
    private var isDisconnected = false

    init(provider: any FileProvider) {
        self.provider = provider
    }

    func storages() async throws -> [StorageInfo] {
        try await run { try await provider.storages() }
    }

    func list(dir: String, storage: UInt32) async throws -> [RemoteNode] {
        try await run { try await provider.list(dir: dir, storage: storage) }
    }

    func listMedia(storage: UInt32, limit: Int = 240) async throws -> [RemoteNode] {
        try await run { try await provider.listMedia(storage: storage, limit: limit) }
    }

    func thumbnail(for node: RemoteNode) async throws -> Data? {
        try await run { try await provider.thumbnail(for: node) }
    }

    func download(_ node: RemoteNode, to url: URL, progress: @Sendable (UInt64) -> Void) async throws {
        try await run { try await provider.download(node, to: url, progress: progress) }
    }

    func upload(
        from url: URL,
        toDir: String,
        remoteName: String? = nil,
        storage: UInt32,
        progress: @Sendable (UInt64) -> Void
    ) async throws -> RemoteNode {
        try await run { try await provider.upload(from: url, toDir: toDir, remoteName: remoteName, storage: storage, progress: progress) }
    }

    func delete(_ node: RemoteNode) async throws {
        try await run { try await provider.delete(node) }
    }

    func makeDirectory(_ name: String, in dir: String, storage: UInt32) async throws {
        try await run { try await provider.makeDirectory(name, in: dir, storage: storage) }
    }

    private func run<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        if isDisconnected {
            throw DeviceError.disconnected
        }
        do {
            return try await operation()
        } catch let error as CancellationError {
            throw error
        } catch let error as DeviceError {
            if case .disconnected = error {
                isDisconnected = true
            }
            throw error
        } catch {
            throw DeviceError.underlying(error.localizedDescription)
        }
    }
}
