import Foundation

/// 传输方向：下载到 Mac 或上传到手机。
enum TransferDirection: String, Sendable {
    case download
    case upload
}

/// 单个传输任务状态。
enum TransferState: Equatable, Sendable {
    case queued
    case running
    case completed
    case failed(String)
    case cancelled
}

/// 单条文件传输任务模型。
struct TransferTask: Identifiable, Sendable, Equatable {
    let id: UUID
    let direction: TransferDirection
    let filename: String
    let totalBytes: UInt64
    var transferredBytes: UInt64
    let sourceDisplay: String
    let destinationDisplay: String
    var state: TransferState
    var speedBytesPerSec: Double
    var retryCount: Int
    var statusNote: String?
    let remoteNode: RemoteNode?
    let localURL: URL?
    let remoteDir: String?
    let storageID: UInt32?
    let exactDestinationURL: URL?
    let createdAt: Date

    var isActive: Bool {
        state == .queued || state == .running
    }

    var progress: Double {
        if case .completed = state {
            return 1
        }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    var etaSeconds: Double? {
        guard case .running = state, speedBytesPerSec > 1 else { return nil }
        guard totalBytes > transferredBytes else { return 0 }
        return Double(totalBytes - transferredBytes) / speedBytesPerSec
    }
}

/// 队列状态快照，供 UI 只读展示。
struct TransferSnapshot: Sendable {
    let tasks: [TransferTask]
    let conflictStrategy: ConflictStrategy
    let overallSpeedBytesPerSec: Double
    let activeCount: Int
    let failedCount: Int
    let completedCount: Int
    let hasRunningWorker: Bool
}

/// 单线程串行文件传输调度器，统一管理下载（原子 `.droiddock-part` + rename）、上传、重试与 3 秒 EMA 速率平滑。
actor TransferQueue {
    private var session: DeviceSession?
    private var deviceID: DeviceID?
    private var tasks: [TransferTask] = []
    private var activeJobTask: Task<Void, Never>?
    private var runningTaskID: UUID?
    private var conflictStrategy: ConflictStrategy = .rename
    private var snapshotHandler: (@Sendable (TransferSnapshot) -> Void)?
    private var uploadCompletedHandler: (@Sendable () -> Void)?
    private var disconnectHandler: (@Sendable (DeviceID) -> Void)?
    private var completionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func configureHandlers(
        onSnapshot: @escaping @Sendable (TransferSnapshot) -> Void,
        onUploadCompleted: @escaping @Sendable () -> Void,
        onDisconnect: @escaping @Sendable (DeviceID) -> Void
    ) {
        snapshotHandler = onSnapshot
        uploadCompletedHandler = onUploadCompleted
        disconnectHandler = onDisconnect
        emitSnapshot()
    }

    func snapshot() -> TransferSnapshot {
        buildSnapshot()
    }

    func setConflictStrategy(_ strategy: ConflictStrategy) {
        conflictStrategy = strategy
        emitSnapshot()
    }

    func attachSession(_ newSession: DeviceSession?, deviceID newDeviceID: DeviceID?) {
        session = newSession
        deviceID = newDeviceID
        if newSession == nil {
            activeJobTask?.cancel()
            activeJobTask = nil
            runningTaskID = nil
            var changed = false
            for idx in tasks.indices where tasks[idx].isActive {
                let id = tasks[idx].id
                tasks[idx].state = .failed("设备连接已断开")
                tasks[idx].speedBytesPerSec = 0
                changed = true
                resolveWaiter(id, error: DeviceError.disconnected)
            }
            if changed {
                emitSnapshot()
            }
        } else {
            scheduleNextIfNeeded()
        }
    }

    /// 批量将远端文件或目录树加入下载队列。
    @discardableResult
    func enqueueDownloads(nodes: [RemoteNode], toLocalDirectory directoryURL: URL) async -> [UUID] {
        var addedIDs: [UUID] = []
        for node in nodes {
            if node.isDirectory {
                let subDirURL = directoryURL.appendingPathComponent(node.name, isDirectory: true)
                await enqueueDirectoryDownload(node: node, toLocalDirectory: subDirURL, addedIDs: &addedIDs)
            } else {
                let id = appendDownloadTask(node: node, directoryURL: directoryURL, exactDestinationURL: nil)
                addedIDs.append(id)
            }
        }
        emitSnapshot()
        scheduleNextIfNeeded()
        return addedIDs
    }

    /// 供 `NSFilePromiseProvider` 使用：排队下载到指定最终文件路径并等待完成。
    func downloadImmediately(_ node: RemoteNode, toExactURL destinationURL: URL) async throws {
        let taskID = appendDownloadTask(
            node: node,
            directoryURL: destinationURL.deletingLastPathComponent(),
            exactDestinationURL: destinationURL
        )
        // 若前置校验已直接标为失败，则立即抛出错误
        if let idx = tasks.firstIndex(where: { $0.id == taskID }),
           case .failed(let msg) = tasks[idx].state {
            emitSnapshot()
            throw DeviceError.underlying(msg)
        }
        emitSnapshot()
        scheduleNextIfNeeded()
        try await withCheckedThrowingContinuation { continuation in
            if let idx = tasks.firstIndex(where: { $0.id == taskID }) {
                switch tasks[idx].state {
                case .completed:
                    continuation.resume()
                    return
                case .failed(let msg):
                    continuation.resume(throwing: DeviceError.underlying(msg))
                    return
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                    return
                case .queued, .running:
                    break
                }
            }
            completionWaiters[taskID] = continuation
        }
    }

    /// 批量将本地文件或目录加入上传队列（前置校验不通过的任务直接标为 `.failed` 以便反馈）。
    @discardableResult
    func enqueueUploads(urls: [URL], toRemoteDir remoteDir: String, storage: UInt32) async -> [UUID] {
        let normalizedDir = PathUtils.normalize(remoteDir)
        var addedIDs: [UUID] = []
        for url in urls {
            collectUploadTasks(from: url, remoteDir: normalizedDir, storage: storage, addedIDs: &addedIDs)
        }
        emitSnapshot()
        scheduleNextIfNeeded()
        return addedIDs
    }

    func retry(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch tasks[idx].state {
        case .failed, .cancelled:
            tasks[idx].state = .queued
            tasks[idx].transferredBytes = 0
            tasks[idx].speedBytesPerSec = 0
            tasks[idx].retryCount = 0
            tasks[idx].statusNote = nil
            emitSnapshot()
            scheduleNextIfNeeded()
        case .queued, .running, .completed:
            break
        }
    }

    func retryAllFailed() {
        var changed = false
        for idx in tasks.indices {
            if case .failed = tasks[idx].state {
                tasks[idx].state = .queued
                tasks[idx].transferredBytes = 0
                tasks[idx].speedBytesPerSec = 0
                tasks[idx].retryCount = 0
                tasks[idx].statusNote = nil
                changed = true
            }
        }
        if changed {
            emitSnapshot()
            scheduleNextIfNeeded()
        }
    }

    func cancel(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch tasks[idx].state {
        case .queued:
            tasks[idx].state = .cancelled
            tasks[idx].speedBytesPerSec = 0
            resolveWaiter(taskID, error: CancellationError())
            emitSnapshot()
        case .running:
            tasks[idx].state = .cancelled
            tasks[idx].speedBytesPerSec = 0
            if runningTaskID == taskID {
                activeJobTask?.cancel()
            }
            resolveWaiter(taskID, error: CancellationError())
            emitSnapshot()
        case .completed, .failed, .cancelled:
            break
        }
    }

    func cancelAll() {
        var changed = false
        for idx in tasks.indices where tasks[idx].isActive {
            let id = tasks[idx].id
            tasks[idx].state = .cancelled
            tasks[idx].speedBytesPerSec = 0
            resolveWaiter(id, error: CancellationError())
            changed = true
        }
        activeJobTask?.cancel()
        if changed {
            emitSnapshot()
        }
    }

    func clearFinished() {
        tasks.removeAll { !$0.isActive }
        emitSnapshot()
    }

    // MARK: - 任务收集与入队辅助

    private func enqueueDirectoryDownload(node: RemoteNode, toLocalDirectory dirURL: URL, addedIDs: inout [UUID]) async {
        guard let session else {
            let taskID = UUID()
            tasks.append(TransferTask(
                id: taskID,
                direction: .download,
                filename: node.name,
                totalBytes: node.size,
                transferredBytes: 0,
                sourceDisplay: node.path,
                destinationDisplay: dirURL.path,
                state: .failed(DeviceError.disconnected.localizedDescription),
                speedBytesPerSec: 0,
                retryCount: 0,
                statusNote: nil,
                remoteNode: node,
                localURL: dirURL,
                remoteDir: nil,
                storageID: node.storageID,
                exactDestinationURL: nil,
                createdAt: Date()
            ))
            addedIDs.append(taskID)
            return
        }
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let children = try await session.list(dir: node.path, storage: node.storageID)
            for child in children {
                if child.isDirectory {
                    await enqueueDirectoryDownload(
                        node: child,
                        toLocalDirectory: dirURL.appendingPathComponent(child.name, isDirectory: true),
                        addedIDs: &addedIDs
                    )
                } else {
                    addedIDs.append(appendDownloadTask(node: child, directoryURL: dirURL, exactDestinationURL: nil))
                }
            }
        } catch {
            let taskID = UUID()
            tasks.append(TransferTask(
                id: taskID,
                direction: .download,
                filename: node.name,
                totalBytes: 0,
                transferredBytes: 0,
                sourceDisplay: node.path,
                destinationDisplay: dirURL.path,
                state: .failed(error.localizedDescription),
                speedBytesPerSec: 0,
                retryCount: 0,
                statusNote: nil,
                remoteNode: node,
                localURL: dirURL,
                remoteDir: nil,
                storageID: node.storageID,
                exactDestinationURL: nil,
                createdAt: Date()
            ))
            addedIDs.append(taskID)
        }
    }

    private func appendDownloadTask(node: RemoteNode, directoryURL: URL, exactDestinationURL: URL?) -> UUID {
        let taskID = UUID()
        let filename = exactDestinationURL?.lastPathComponent ?? node.name
        let validationError = validateDownloadFilename(filename)
        let destDisplay = exactDestinationURL?.path ?? directoryURL.appendingPathComponent(filename).path

        let initialState: TransferState = validationError.map { .failed($0) } ?? .queued
        tasks.append(TransferTask(
            id: taskID,
            direction: .download,
            filename: filename,
            totalBytes: node.size,
            transferredBytes: 0,
            sourceDisplay: node.path,
            destinationDisplay: destDisplay,
            state: initialState,
            speedBytesPerSec: 0,
            retryCount: 0,
            statusNote: nil,
            remoteNode: node,
            localURL: directoryURL,
            remoteDir: nil,
            storageID: node.storageID,
            exactDestinationURL: exactDestinationURL,
            createdAt: Date()
        ))
        return taskID
    }

    private func collectUploadTasks(from url: URL, remoteDir: String, storage: UInt32, addedIDs: inout [UUID]) {
        let filename = url.lastPathComponent
        let targetDisplay = PathUtils.join(remoteDir, filename)

        if let invalidReason = PathUtils.validateAndroidFilename(filename) {
            let id = UUID()
            tasks.append(TransferTask(
                id: id,
                direction: .upload,
                filename: filename,
                totalBytes: 0,
                transferredBytes: 0,
                sourceDisplay: url.path,
                destinationDisplay: targetDisplay,
                state: .failed(invalidReason),
                speedBytesPerSec: 0,
                retryCount: 0,
                statusNote: nil,
                remoteNode: nil,
                localURL: url,
                remoteDir: remoteDir,
                storageID: storage,
                exactDestinationURL: nil,
                createdAt: Date()
            ))
            addedIDs.append(id)
            return
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let id = UUID()
            tasks.append(TransferTask(
                id: id,
                direction: .upload,
                filename: filename,
                totalBytes: 0,
                transferredBytes: 0,
                sourceDisplay: url.path,
                destinationDisplay: targetDisplay,
                state: .failed("无法读取本地文件：\(error.localizedDescription)"),
                speedBytesPerSec: 0,
                retryCount: 0,
                statusNote: nil,
                remoteNode: nil,
                localURL: url,
                remoteDir: remoteDir,
                storageID: storage,
                exactDestinationURL: nil,
                createdAt: Date()
            ))
            addedIDs.append(id)
            return
        }

        if (attrs[.type] as? FileAttributeType) == .typeDirectory {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return
            }
            let childRemoteDir = PathUtils.join(remoteDir, filename)
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                collectUploadTasks(from: child, remoteDir: childRemoteDir, storage: storage, addedIDs: &addedIDs)
            }
            return
        }

        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let id = UUID()
        tasks.append(TransferTask(
            id: id,
            direction: .upload,
            filename: filename,
            totalBytes: fileSize,
            transferredBytes: 0,
            sourceDisplay: url.path,
            destinationDisplay: targetDisplay,
            state: .queued,
            speedBytesPerSec: 0,
            retryCount: 0,
            statusNote: nil,
            remoteNode: nil,
            localURL: url,
            remoteDir: remoteDir,
            storageID: storage,
            exactDestinationURL: nil,
            createdAt: Date()
        ))
        addedIDs.append(id)
    }

    private func validateDownloadFilename(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || name == "." || name == ".." {
            return "非法文件名：\(name)"
        }
        if name.contains("/") || name.contains("\0") {
            return "文件名包含非法路径字符：\(name)"
        }
        return nil
    }

    // MARK: - 串行调度执行

    private func scheduleNextIfNeeded() {
        guard runningTaskID == nil else { return }
        guard let nextIndex = tasks.firstIndex(where: { $0.state == .queued }) else {
            return
        }
        let taskID = tasks[nextIndex].id
        runningTaskID = taskID
        tasks[nextIndex].state = .running
        emitSnapshot()

        activeJobTask = Task { [weak self] in
            await self?.runTask(id: taskID)
        }
    }

    private func runTask(id: UUID) async {
        defer {
            if runningTaskID == id {
                runningTaskID = nil
                activeJobTask = nil
            }
            scheduleNextIfNeeded()
            if runningTaskID == nil {
                emitSnapshot()
            }
        }

        while true {
            guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
            if case .cancelled = tasks[idx].state {
                resolveWaiter(id, error: CancellationError())
                return
            }
            guard let currentSession = session else {
                tasks[idx].state = .failed(DeviceError.disconnected.localizedDescription)
                tasks[idx].speedBytesPerSec = 0
                resolveWaiter(id, error: DeviceError.disconnected)
                emitSnapshot()
                return
            }

            let task = tasks[idx]
            do {
                switch task.direction {
                case .download:
                    try await performDownload(task: task, session: currentSession)
                case .upload:
                    try await performUpload(task: task, session: currentSession)
                }

                if let finishedIdx = tasks.firstIndex(where: { $0.id == id }) {
                    if case .cancelled = tasks[finishedIdx].state {
                        resolveWaiter(id, error: CancellationError())
                        emitSnapshot()
                        return
                    }
                    tasks[finishedIdx].state = .completed
                    tasks[finishedIdx].speedBytesPerSec = 0
                    if tasks[finishedIdx].statusNote == nil {
                        tasks[finishedIdx].transferredBytes = max(tasks[finishedIdx].transferredBytes, tasks[finishedIdx].totalBytes)
                    }
                    resolveWaiter(id, error: nil)
                    emitSnapshot()
                    if task.direction == .upload && tasks[finishedIdx].statusNote == nil {
                        uploadCompletedHandler?()
                    }
                }
                return
            } catch is CancellationError {
                if let failedIdx = tasks.firstIndex(where: { $0.id == id }) {
                    if tasks[failedIdx].isActive {
                        tasks[failedIdx].state = .cancelled
                    }
                    tasks[failedIdx].speedBytesPerSec = 0
                    resolveWaiter(id, error: CancellationError())
                    emitSnapshot()
                }
                return
            } catch {
                let deviceError = (error as? DeviceError) ?? .underlying(error.localizedDescription)
                if case .disconnected = deviceError, let devID = deviceID {
                    disconnectHandler?(devID)
                }
                let canRetry: Bool
                if let currentIdx = tasks.firstIndex(where: { $0.id == id }) {
                    canRetry = tasks[currentIdx].retryCount == 0
                        && tasks[currentIdx].state != .cancelled
                        && Self.isRetryableError(deviceError)
                } else {
                    canRetry = false
                }

                if canRetry, let retryIdx = tasks.firstIndex(where: { $0.id == id }) {
                    tasks[retryIdx].retryCount += 1
                    tasks[retryIdx].transferredBytes = 0
                    tasks[retryIdx].speedBytesPerSec = 0
                    tasks[retryIdx].statusNote = "自动重试中…"
                    emitSnapshot()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                if let failedIdx = tasks.firstIndex(where: { $0.id == id }) {
                    if tasks[failedIdx].state != .cancelled {
                        tasks[failedIdx].state = .failed(deviceError.localizedDescription)
                        tasks[failedIdx].statusNote = nil
                    }
                    tasks[failedIdx].speedBytesPerSec = 0
                    resolveWaiter(id, error: deviceError)
                    emitSnapshot()
                }
                return
            }
        }
    }

    private func performDownload(task: TransferTask, session: DeviceSession) async throws {
        guard let node = task.remoteNode, let dirURL = task.localURL else {
            throw DeviceError.underlying("缺少下载任务信息")
        }
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let finalURL: URL
        let overwriteExisting: Bool
        if let exactURL = task.exactDestinationURL {
            finalURL = exactURL
            overwriteExisting = true
        } else {
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? [])
            switch PathUtils.resolveConflictDestination(name: task.filename, existingNames: existing, strategy: conflictStrategy) {
            case .skip:
                if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[idx].statusNote = "已跳过"
                }
                return
            case .proceed(let finalName, let overwrite):
                finalURL = dirURL.appendingPathComponent(finalName)
                overwriteExisting = overwrite
            }
        }

        let partURL = URL(fileURLWithPath: finalURL.path + ".droiddock-part")
        try? FileManager.default.removeItem(at: partURL)
        var movedSuccessfully = false
        defer {
            if !movedSuccessfully {
                try? FileManager.default.removeItem(at: partURL)
            }
        }

        let tracker = ProgressTracker { [weak self] bytes, speed in
            guard let self else { return }
            Task { await self.updateTaskProgress(taskID: task.id, transferred: bytes, speed: speed) }
        }

        try await session.download(node, to: partURL) { bytes in
            tracker.record(bytes: bytes)
        }
        try Task.checkCancellation()

        if overwriteExisting && FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partURL)
        } else {
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        }
        movedSuccessfully = true
        updateTaskProgress(taskID: task.id, transferred: max(task.totalBytes, tracker.lastBytes), speed: tracker.currentSpeed)
    }

    private func performUpload(task: TransferTask, session: DeviceSession) async throws {
        guard let sourceURL = task.localURL,
              let remoteDir = task.remoteDir,
              let storage = task.storageID else {
            throw DeviceError.underlying("缺少上传任务信息")
        }
        if let reason = PathUtils.validateAndroidFilename(task.filename) {
            throw DeviceError.underlying(reason)
        }

        try await ensureRemoteDirectory(remoteDir, storage: storage, session: session)
        let existingNodes = try await session.list(dir: remoteDir, storage: storage)
        let existingNames = Set(existingNodes.map(\.name))

        let finalName: String
        let overwriteExisting: Bool
        switch PathUtils.resolveConflictDestination(name: task.filename, existingNames: existingNames, strategy: conflictStrategy) {
        case .skip:
            if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[idx].statusNote = "已跳过"
            }
            return
        case .proceed(let resolvedName, let overwrite):
            finalName = resolvedName
            overwriteExisting = overwrite
        }

        if overwriteExisting,
           let targetExisting = existingNodes.first(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            try await session.delete(targetExisting)
        }

        let tracker = ProgressTracker { [weak self] bytes, speed in
            guard let self else { return }
            Task { await self.updateTaskProgress(taskID: task.id, transferred: bytes, speed: speed) }
        }

        _ = try await session.upload(
            from: sourceURL,
            toDir: remoteDir,
            remoteName: finalName,
            storage: storage
        ) { bytes in
            tracker.record(bytes: bytes)
        }
        updateTaskProgress(taskID: task.id, transferred: max(task.totalBytes, tracker.lastBytes), speed: tracker.currentSpeed)
    }

    private func ensureRemoteDirectory(_ normalizedDir: String, storage: UInt32, session: DeviceSession) async throws {
        guard normalizedDir != "/" else { return }
        var current = "/"
        for component in normalizedDir.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(component)
            let nextPath = PathUtils.join(current, segment)
            let children = try await session.list(dir: current, storage: storage)
            if !children.contains(where: { $0.isDirectory && $0.name == segment }) {
                try await session.makeDirectory(segment, in: current, storage: storage)
            }
            current = nextPath
        }
    }

    private func updateTaskProgress(taskID: UUID, transferred: UInt64, speed: Double) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[idx].state == .running else {
            return
        }
        tasks[idx].transferredBytes = transferred
        tasks[idx].speedBytesPerSec = speed
        emitSnapshot()
    }

    private func resolveWaiter(_ taskID: UUID, error: Error?) {
        guard let continuation = completionWaiters.removeValue(forKey: taskID) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private static func isRetryableError(_ error: DeviceError) -> Bool {
        switch error {
        case .disconnected, .deviceLocked, .invalidName, .storageFull, .permissionDenied:
            return false
        case .busy, .unsupported, .underlying:
            return true
        }
    }

    private func buildSnapshot() -> TransferSnapshot {
        var active = 0
        var failed = 0
        var completed = 0
        var activeSpeed = 0.0
        for task in tasks {
            switch task.state {
            case .queued:
                active += 1
            case .running:
                active += 1
                activeSpeed += task.speedBytesPerSec
            case .completed:
                completed += 1
            case .failed:
                failed += 1
            case .cancelled:
                break
            }
        }
        return TransferSnapshot(
            tasks: tasks,
            conflictStrategy: conflictStrategy,
            overallSpeedBytesPerSec: activeSpeed,
            activeCount: active,
            failedCount: failed,
            completedCount: completed,
            hasRunningWorker: runningTaskID != nil
        )
    }

    private func emitSnapshot() {
        snapshotHandler?(buildSnapshot())
    }
}

/// 3 秒窗口指数移动平均（EMA）速率平滑与 80ms 节流采样器。
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (UInt64, Double) -> Void
    private var lastSampleTime: CFAbsoluteTime
    private var lastEmitTime: CFAbsoluteTime
    private(set) var lastBytes: UInt64 = 0
    private(set) var currentSpeed: Double = 0

    init(emit: @escaping @Sendable (UInt64, Double) -> Void) {
        self.emit = emit
        let now = CFAbsoluteTimeGetCurrent()
        self.lastSampleTime = now
        self.lastEmitTime = now
    }

    func record(bytes: UInt64) {
        let now = CFAbsoluteTimeGetCurrent()
        var shouldEmit = false
        var speedSnapshot = 0.0

        lock.lock()
        let dt = now - lastSampleTime
        if dt >= 0.15 {
            let deltaBytes = bytes >= lastBytes ? bytes - lastBytes : bytes
            let instantRate = Double(deltaBytes) / dt
            let alpha = 1.0 - exp(-dt / 3.0)
            currentSpeed = currentSpeed == 0 ? instantRate : currentSpeed + alpha * (instantRate - currentSpeed)
            lastSampleTime = now
            lastBytes = bytes
        } else if bytes > lastBytes && lastBytes == 0 {
            lastBytes = bytes
        }
        speedSnapshot = currentSpeed
        if now - lastEmitTime >= 0.08 {
            lastEmitTime = now
            shouldEmit = true
        }
        lock.unlock()

        if shouldEmit {
            emit(bytes, speedSnapshot)
        }
    }
}
