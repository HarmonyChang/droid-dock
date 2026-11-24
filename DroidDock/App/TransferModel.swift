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
    private(set) var overallProgress: Double = 0
    private(set) var totalTaskCount: Int = 0
    private(set) var nonCancelledCount: Int = 0
    private(set) var activeCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var completedCount: Int = 0
    private(set) var activeOrCurrentTask: TransferTask?
    private(set) var isPreparing: Bool = false
    private(set) var preparingMessage: String?
    var isTrayDismissed: Bool = false

    private var onUploadCompleted: (@MainActor () -> Void)?
    private var onDisconnectDetected: (@MainActor (DeviceID) -> Void)?
    private var onTransferActivityChanged: (@MainActor (Bool) -> Void)?
    private var isReportingTransferActivity: Bool = false
    private var transferActivity: NSObjectProtocol?

    init() {
        Task { [weak self] in
            await self?.wireQueueHandlers()
        }
    }

    func configureCallbacks(
        onUploadCompleted: @escaping @MainActor () -> Void,
        onDisconnectDetected: @escaping @MainActor (DeviceID) -> Void,
        onTransferActivityChanged: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.onUploadCompleted = onUploadCompleted
        self.onDisconnectDetected = onDisconnectDetected
        self.onTransferActivityChanged = onTransferActivityChanged
    }

    var shouldShowTray: Bool {
        guard !isTrayDismissed else { return false }
        return isPreparing || (totalTaskCount > 0 && (activeCount > 0 || failedCount > 0 || completedCount > 0))
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
        isPreparing = true
        preparingMessage = "正在扫描待传文件…"
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
        let hadActive = activeCount > 0 || failedCount > 0 || isPreparing
        let wasWorking = isReportingTransferActivity
        tasks = snapshot.tasks
        conflictStrategy = snapshot.conflictStrategy
        overallSpeedBytesPerSec = snapshot.overallSpeedBytesPerSec
        overallProgress = snapshot.overallProgress
        totalTaskCount = snapshot.totalTaskCount
        nonCancelledCount = snapshot.nonCancelledCount
        activeCount = snapshot.activeCount
        failedCount = snapshot.failedCount
        completedCount = snapshot.completedCount
        activeOrCurrentTask = snapshot.activeTask
            ?? snapshot.tasks.last {
                if case .failed = $0.state { return true }
                return false
            }
            ?? snapshot.tasks.last
        isPreparing = snapshot.isPreparing
        preparingMessage = snapshot.preparingMessage

        let isNowWorking = snapshot.activeCount > 0 || snapshot.isPreparing
        if isNowWorking && !wasWorking {
            isReportingTransferActivity = true
            transferActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "正在通过 USB 与 Android 设备传输文件"
            )
            onTransferActivityChanged?(true)
        } else if !isNowWorking && wasWorking {
            isReportingTransferActivity = false
            if let token = transferActivity {
                ProcessInfo.processInfo.endActivity(token)
                transferActivity = nil
            }
            onTransferActivityChanged?(false)
        }

        if !hadActive && (snapshot.activeCount > 0 || snapshot.failedCount > 0 || snapshot.isPreparing) {
            isTrayDismissed = false
        }
    }
}
