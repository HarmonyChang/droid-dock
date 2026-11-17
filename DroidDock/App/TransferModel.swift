import Foundation
import Observation

/// 传输队列的 `@MainActor` 可观察视图模型，桥接 `TransferQueue` actor 与 SwiftUI。
@MainActor
@Observable
final class TransferModel {
    let queue = TransferQueue()

    private(set) var tasks: [TransferTask] = []
    var conflictStrategy: ConflictStrategy = .rename
    private(set) var overallSpeedBytesPerSec: Double = 0
    private(set) var activeCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var completedCount: Int = 0
    var isTrayDismissed: Bool = false

    private var onUploadCompleted: (@MainActor () -> Void)?
    private var onDisconnectDetected: (@MainActor (DeviceID) -> Void)?

    init() {
        Task { [weak self] in
            await self?.wireQueueHandlers()
        }
    }

    func configureCallbacks(
        onUploadCompleted: @escaping @MainActor () -> Void,
        onDisconnectDetected: @escaping @MainActor (DeviceID) -> Void
    ) {
        self.onUploadCompleted = onUploadCompleted
        self.onDisconnectDetected = onDisconnectDetected
    }

    var shouldShowTray: Bool {
        guard !isTrayDismissed else { return false }
        return !tasks.isEmpty && (activeCount > 0 || failedCount > 0 || completedCount > 0)
    }

    var overallProgress: Double {
        let relevant = tasks.filter { $0.state != .cancelled }
        guard !relevant.isEmpty else { return 0 }
        let total = relevant.reduce(UInt64(0)) { $0 + max($1.totalBytes, $1.transferredBytes) }
        guard total > 0 else {
            let doneCount = relevant.filter { $0.state == .completed }.count
            return Double(doneCount) / Double(relevant.count)
        }
        let done = relevant.reduce(UInt64(0)) { sum, task in
            if case .completed = task.state {
                return sum + max(task.totalBytes, task.transferredBytes)
            }
            return sum + task.transferredBytes
        }
        return min(1, Double(done) / Double(total))
    }

    var activeOrCurrentTask: TransferTask? {
        tasks.first { $0.state == .running }
            ?? tasks.first { $0.state == .queued }
            ?? tasks.last {
                if case .failed = $0.state { return true }
                return false
            }
            ?? tasks.last
    }

    func attachSession(_ session: DeviceSession?, deviceID: DeviceID?) async {
        await queue.attachSession(session, deviceID: deviceID)
    }

    func updateConflictStrategy(_ strategy: ConflictStrategy) {
        conflictStrategy = strategy
        Task { await queue.setConflictStrategy(strategy) }
    }

    func enqueueDownloads(nodes: [RemoteNode], to directoryURL: URL) async {
        guard !nodes.isEmpty else { return }
        isTrayDismissed = false
        _ = await queue.enqueueDownloads(nodes: nodes, toLocalDirectory: directoryURL)
    }

    func downloadForDragPromise(_ node: RemoteNode, to exactURL: URL) async throws {
        isTrayDismissed = false
        try await queue.downloadImmediately(node, toExactURL: exactURL)
    }

    func enqueueUploads(urls: [URL], to remoteDir: String, storage: UInt32) async {
        guard !urls.isEmpty else { return }
        isTrayDismissed = false
        _ = await queue.enqueueUploads(urls: urls, toRemoteDir: remoteDir, storage: storage)
    }

    func retry(_ id: UUID) {
        isTrayDismissed = false
        Task { await queue.retry(taskID: id) }
    }

    func retryAllFailed() {
        isTrayDismissed = false
        Task { await queue.retryAllFailed() }
    }

    func cancel(_ id: UUID) {
        Task { await queue.cancel(taskID: id) }
    }

    func cancelAll() {
        Task { await queue.cancelAll() }
    }

    func clearFinished() {
        Task { await queue.clearFinished() }
    }

    func dismissTray() {
        isTrayDismissed = true
    }

    private func wireQueueHandlers() async {
        await queue.configureHandlers(
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.apply(snapshot)
                }
            },
            onUploadCompleted: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onUploadCompleted?()
                }
            },
            onDisconnect: { [weak self] deviceID in
                Task { @MainActor [weak self] in
                    self?.onDisconnectDetected?(deviceID)
                }
            }
        )
    }

    private func apply(_ snapshot: TransferSnapshot) {
        let hadActive = activeCount > 0 || failedCount > 0
        tasks = snapshot.tasks
        conflictStrategy = snapshot.conflictStrategy
        overallSpeedBytesPerSec = snapshot.overallSpeedBytesPerSec
        activeCount = snapshot.activeCount
        failedCount = snapshot.failedCount
        completedCount = snapshot.completedCount
        if !hadActive && (snapshot.activeCount > 0 || snapshot.failedCount > 0) {
            isTrayDismissed = false
        }
    }
}
