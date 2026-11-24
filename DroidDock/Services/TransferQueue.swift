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

/// 队列状态快照，供 UI 只读展示（大数据量时仅携带窗口化重点条目，摘要统计 O(1) 直出）。
struct TransferSnapshot: Sendable {
    let tasks: [TransferTask]
    let conflictStrategy: ConflictStrategy
    let overallSpeedBytesPerSec: Double
    let overallProgress: Double
    let totalTaskCount: Int
    let nonCancelledCount: Int
    let activeCount: Int
    let failedCount: Int
    let completedCount: Int
    let activeTask: TransferTask?
    let hasRunningWorker: Bool
    let isPreparing: Bool
    let preparingMessage: String?
}

/// 单线程串行文件传输调度器，统一管理下载（原子 `.droiddock-part` + rename）、上传、重试与 3 秒 EMA 速率平滑。
actor TransferQueue {
    private static let maxWindowedTasksInSnapshot = 300
    private static let snapshotThrottleSeconds: CFAbsoluteTime = 0.10

    private var session: DeviceSession?
    private var deviceID: DeviceID?
    private var tasks: [TransferTask] = []
    private var taskIndexByID: [UUID: Int] = [:]
    private var queueSearchCursor: Int = 0
    private var queuedCount: Int = 0
    private var runningCount: Int = 0
    private var completedCount: Int = 0
    private var failedCount: Int = 0
    private var cancelledCount: Int = 0
    private var totalPlannedBytes: UInt64 = 0
    private var settledBytes: UInt64 = 0
    private var recentFailedIndices: [Int] = []
    private var recentCompletedIndices: [Int] = []

    private var activeJobTask: Task<Void, Never>?
    private var runningTaskID: UUID?
    private var conflictStrategy: ConflictStrategy = .rename
    private var snapshotHandler: (@Sendable (TransferSnapshot) -> Void)?
    private var uploadCompletedHandler: (@Sendable () -> Void)?
    private var disconnectHandler: (@Sendable (DeviceID) -> Void)?
    private var completionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    private var activePrepareCount: Int = 0
    private var preparingScannedCount: Int = 0
    private var scanCancelFlag: ScanCancelFlag?
    private var ensuredDirectories: Set<String> = []
    private var cachedRemoteDirectories: [String: [RemoteNode]] = [:]
    private var hasPendingUploadRefresh: Bool = false
    private var lastSnapshotEmitTime: CFAbsoluteTime = 0

    func configureHandlers(
        onSnapshot: @escaping @Sendable (TransferSnapshot) -> Void,
        onUploadCompleted: @escaping @Sendable () -> Void,
        onDisconnect: @escaping @Sendable (DeviceID) -> Void
    ) {
        snapshotHandler = onSnapshot
        uploadCompletedHandler = onUploadCompleted
        disconnectHandler = onDisconnect
        emitSnapshot(force: true)
    }

    func snapshot() -> TransferSnapshot {
        buildSnapshot()
    }

    func setConflictStrategy(_ strategy: ConflictStrategy) {
        conflictStrategy = strategy
        emitSnapshot(force: true)
    }

    func attachSession(_ newSession: DeviceSession?, deviceID newDeviceID: DeviceID?) {
        session = newSession
        deviceID = newDeviceID
        ensuredDirectories.removeAll()
        cachedRemoteDirectories.removeAll()

        if newSession == nil {
            scanCancelFlag?.cancel()
            activeJobTask?.cancel()
            activeJobTask = nil
            runningTaskID = nil
            var changed = false
            for idx in tasks.indices where tasks[idx].isActive {
                let id = tasks[idx].id
                transitionTask(at: idx, to: .failed("设备连接已断开"), speed: 0, statusNote: .some(nil))
                changed = true
                resolveWaiter(id, error: DeviceError.disconnected)
            }
            if changed {
                emitSnapshot(force: true)
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
        emitSnapshot(force: true)
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
        if let idx = taskIndexByID[taskID],
           case .failed(let msg) = tasks[idx].state {
            emitSnapshot(force: true)
            throw DeviceError.underlying(msg)
        }
        emitSnapshot(force: true)
        scheduleNextIfNeeded()
        try await withCheckedThrowingContinuation { continuation in
            if let idx = taskIndexByID[taskID] {
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

    /// 批量将本地文件或大目录后台流式加入上传队列：0 ms 反馈扫描进度，每批 500 项边扫描边开始传输。
    @discardableResult
    func enqueueUploads(urls: [URL], toRemoteDir remoteDir: String, storage: UInt32) async -> [UUID] {
        let normalizedDir = PathUtils.normalize(remoteDir)
        let cancelFlag = ScanCancelFlag()
        scanCancelFlag = cancelFlag
        activePrepareCount += 1
        preparingScannedCount = 0
        emitSnapshot(force: true)

        let stream = AsyncStream<[PreparedUploadEntry]> { continuation in
            Task.detached(priority: .userInitiated) {
                var batch: [PreparedUploadEntry] = []
                batch.reserveCapacity(500)
                for url in urls {
                    if cancelFlag.isCancelled { break }
                    Self.streamCollectUploadEntries(
                        from: url,
                        remoteDir: normalizedDir,
                        storage: storage,
                        cancelFlag: cancelFlag,
                        batch: &batch
                    ) { readyBatch in
                        continuation.yield(readyBatch)
                    }
                }
                if !batch.isEmpty {
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }

        var addedIDs: [UUID] = []
        for await batch in stream {
            if cancelFlag.isCancelled { break }
            addedIDs.reserveCapacity(addedIDs.count + batch.count)
            for entry in batch {
                let id = UUID()
                let task: TransferTask
                switch entry {
                case .valid(let url, let filename, let targetDir, let st, let size):
                    task = TransferTask(
                        id: id,
                        direction: .upload,
                        filename: filename,
                        totalBytes: size,
                        transferredBytes: 0,
                        sourceDisplay: url.path,
                        destinationDisplay: PathUtils.join(targetDir, filename),
                        state: .queued,
                        speedBytesPerSec: 0,
                        retryCount: 0,
                        statusNote: nil,
                        remoteNode: nil,
                        localURL: url,
                        remoteDir: targetDir,
                        storageID: st,
                        exactDestinationURL: nil,
                        createdAt: Date()
                    )
                case .invalid(let url, let filename, let targetDir, let st, let reason):
                    task = TransferTask(
                        id: id,
                        direction: .upload,
                        filename: filename,
                        totalBytes: 0,
                        transferredBytes: 0,
                        sourceDisplay: url.path,
                        destinationDisplay: PathUtils.join(targetDir, filename),
                        state: .failed(reason),
                        speedBytesPerSec: 0,
                        retryCount: 0,
                        statusNote: nil,
                        remoteNode: nil,
                        localURL: url,
                        remoteDir: targetDir,
                        storageID: st,
                        exactDestinationURL: nil,
                        createdAt: Date()
                    )
                }
                appendTask(task)
                addedIDs.append(id)
            }
            preparingScannedCount += batch.count
            scheduleNextIfNeeded()
            emitSnapshot(force: addedIDs.count <= 500)
        }

        activePrepareCount = max(0, activePrepareCount - 1)
        if activePrepareCount == 0 {
            preparingScannedCount = 0
            if scanCancelFlag === cancelFlag {
                scanCancelFlag = nil
            }
        }
        emitSnapshot(force: true)
        scheduleNextIfNeeded()
        flushPendingUploadRefreshIfIdle()
        return addedIDs
    }

    func retry(taskID: UUID) {
        guard let idx = taskIndexByID[taskID] else { return }
        switch tasks[idx].state {
        case .failed, .cancelled:
            transitionTask(at: idx, to: .queued, transferred: 0, speed: 0, retryCount: 0, statusNote: .some(nil))
            queueSearchCursor = min(queueSearchCursor, idx)
            emitSnapshot(force: true)
            scheduleNextIfNeeded()
        case .queued, .running, .completed:
            break
        }
    }

    func retryAllFailed() {
        guard failedCount > 0 else { return }
        ensuredDirectories.removeAll()
        cachedRemoteDirectories.removeAll()
        var firstRetriedIndex: Int?
        for idx in tasks.indices {
            if case .failed = tasks[idx].state {
                transitionTask(at: idx, to: .queued, transferred: 0, speed: 0, retryCount: 0, statusNote: .some(nil))
                if firstRetriedIndex == nil {
                    firstRetriedIndex = idx
                }
            }
        }
        if let firstRetriedIndex {
            queueSearchCursor = min(queueSearchCursor, firstRetriedIndex)
        }
        recentFailedIndices.removeAll()
        emitSnapshot(force: true)
        scheduleNextIfNeeded()
    }

    func cancel(taskID: UUID) {
        guard let idx = taskIndexByID[taskID] else { return }
        switch tasks[idx].state {
        case .queued:
            transitionTask(at: idx, to: .cancelled, speed: 0)
            resolveWaiter(taskID, error: CancellationError())
            emitSnapshot(force: true)
        case .running:
            transitionTask(at: idx, to: .cancelled, speed: 0)
            if runningTaskID == taskID {
                activeJobTask?.cancel()
            }
            resolveWaiter(taskID, error: CancellationError())
            emitSnapshot(force: true)
        case .completed, .failed, .cancelled:
            break
        }
    }

    func cancelAll() {
        scanCancelFlag?.cancel()
        var changed = false
        for idx in tasks.indices where tasks[idx].isActive {
            let id = tasks[idx].id
            transitionTask(at: idx, to: .cancelled, speed: 0)
            resolveWaiter(id, error: CancellationError())
            changed = true
        }
        activeJobTask?.cancel()
        flushPendingUploadRefreshIfIdle()
        if changed || activePrepareCount > 0 {
            emitSnapshot(force: true)
        }
    }

    func clearFinished() {
        tasks.removeAll { !$0.isActive }
        rebuildBookkeepingAfterCompaction()
        emitSnapshot(force: true)
    }

    // MARK: - 任务收集与入队辅助

    private func enqueueDirectoryDownload(node: RemoteNode, toLocalDirectory dirURL: URL, addedIDs: inout [UUID]) async {
        guard let session else {
            let taskID = UUID()
            appendTask(TransferTask(
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
            appendTask(TransferTask(
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
        appendTask(TransferTask(
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

    private static func streamCollectUploadEntries(
        from rootURL: URL,
        remoteDir: String,
        storage: UInt32,
        cancelFlag: ScanCancelFlag,
        batch: inout [PreparedUploadEntry],
        flush: ([PreparedUploadEntry]) -> Void
    ) {
        let rootName = rootURL.lastPathComponent
        if let invalidReason = PathUtils.validateAndroidFilename(rootName) {
            batch.append(.invalid(
                url: rootURL,
                filename: rootName,
                remoteDir: remoteDir,
                storage: storage,
                reason: invalidReason
            ))
            if batch.count >= 500 {
                flush(batch)
                batch.removeAll(keepingCapacity: true)
            }
            return
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: rootURL.path)
        } catch {
            batch.append(.invalid(
                url: rootURL,
                filename: rootName,
                remoteDir: remoteDir,
                storage: storage,
                reason: "无法读取本地文件：\(error.localizedDescription)"
            ))
            if batch.count >= 500 {
                flush(batch)
                batch.removeAll(keepingCapacity: true)
            }
            return
        }

        if (attrs[.type] as? FileAttributeType) != .typeDirectory {
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            batch.append(.valid(
                url: rootURL,
                filename: rootName,
                remoteDir: remoteDir,
                storage: storage,
                size: fileSize
            ))
            if batch.count >= 500 {
                flush(batch)
                batch.removeAll(keepingCapacity: true)
            }
            return
        }

        let rootRemoteDir = PathUtils.join(remoteDir, rootName)
        let rawRootPath = rootURL.standardizedFileURL.path
        let resolvedRootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let itemURL = enumerator?.nextObject() as? URL {
            if cancelFlag.isCancelled { break }
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator?.skipDescendants()
                }
                continue
            }

            let itemPath = itemURL.standardizedFileURL.path
            let relativePath: String
            if let rel = relativeSubpath(of: itemPath, under: rawRootPath) {
                relativePath = rel
            } else if let rel = relativeSubpath(of: itemURL.resolvingSymlinksInPath().standardizedFileURL.path, under: resolvedRootPath) {
                relativePath = rel
            } else {
                continue
            }

            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let itemName = components.last else { continue }

            var targetDir = rootRemoteDir
            if components.count > 1 {
                for segment in components.dropLast() {
                    targetDir = PathUtils.join(targetDir, segment)
                }
            }

            if values?.isDirectory == true {
                if let invalidReason = PathUtils.validateAndroidFilename(itemName) {
                    batch.append(.invalid(
                        url: itemURL,
                        filename: itemName,
                        remoteDir: targetDir,
                        storage: storage,
                        reason: invalidReason
                    ))
                    enumerator?.skipDescendants()
                    if batch.count >= 500 {
                        flush(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                continue
            }

            if let invalidReason = PathUtils.validateAndroidFilename(itemName) {
                batch.append(.invalid(
                    url: itemURL,
                    filename: itemName,
                    remoteDir: targetDir,
                    storage: storage,
                    reason: invalidReason
                ))
            } else {
                let fileSize: UInt64
                if let byteCount = values?.fileSize {
                    fileSize = UInt64(max(0, byteCount))
                } else {
                    fileSize = (try? FileManager.default.attributesOfItem(atPath: itemURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                }
                batch.append(.valid(
                    url: itemURL,
                    filename: itemName,
                    remoteDir: targetDir,
                    storage: storage,
                    size: fileSize
                ))
            }

            if batch.count >= 500 {
                flush(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
    }

    private static func relativeSubpath(of path: String, under rootPath: String) -> String? {
        let base = rootPath == "/" ? "/" : (rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath)
        if base == "/" {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        if path == base {
            return ""
        }
        let prefix = base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
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
        guard runningTaskID == nil, queuedCount > 0 else { return }
        var idx = max(0, queueSearchCursor)
        while idx < tasks.count {
            if case .queued = tasks[idx].state {
                queueSearchCursor = idx + 1
                let taskID = tasks[idx].id
                runningTaskID = taskID
                transitionTask(at: idx, to: .running)
                emitSnapshot(force: true)
                activeJobTask = Task { [weak self] in
                    await self?.runTask(id: taskID)
                }
                return
            }
            idx += 1
        }
        queueSearchCursor = tasks.count
    }

    private func runTask(id: UUID) async {
        defer {
            if runningTaskID == id {
                runningTaskID = nil
                activeJobTask = nil
            }
            scheduleNextIfNeeded()
            if runningTaskID == nil {
                flushPendingUploadRefreshIfIdle()
                emitSnapshot(force: true)
            }
        }

        while true {
            guard let idx = taskIndexByID[id] else { return }
            if case .cancelled = tasks[idx].state {
                resolveWaiter(id, error: CancellationError())
                return
            }
            guard let currentSession = session else {
                transitionTask(
                    at: idx,
                    to: .failed(DeviceError.disconnected.localizedDescription),
                    speed: 0
                )
                resolveWaiter(id, error: DeviceError.disconnected)
                emitSnapshot(force: true)
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

                if let finishedIdx = taskIndexByID[id] {
                    if case .cancelled = tasks[finishedIdx].state {
                        resolveWaiter(id, error: CancellationError())
                        emitSnapshot(force: true)
                        return
                    }
                    let hadStatusNote = tasks[finishedIdx].statusNote != nil
                    let finalTransferred = hadStatusNote
                        ? tasks[finishedIdx].transferredBytes
                        : max(tasks[finishedIdx].transferredBytes, tasks[finishedIdx].totalBytes)
                    transitionTask(
                        at: finishedIdx,
                        to: .completed,
                        transferred: finalTransferred,
                        speed: 0
                    )
                    resolveWaiter(id, error: nil)
                    if task.direction == .upload && !hadStatusNote {
                        hasPendingUploadRefresh = true
                    }
                    emitSnapshot()
                }
                return
            } catch is CancellationError {
                if let failedIdx = taskIndexByID[id] {
                    if tasks[failedIdx].isActive {
                        transitionTask(at: failedIdx, to: .cancelled, speed: 0)
                    } else {
                        tasks[failedIdx].speedBytesPerSec = 0
                    }
                    resolveWaiter(id, error: CancellationError())
                    emitSnapshot(force: true)
                }
                return
            } catch {
                let deviceError = (error as? DeviceError) ?? .underlying(error.localizedDescription)
                if case .disconnected = deviceError, let devID = deviceID {
                    disconnectHandler?(devID)
                }
                let canRetry: Bool
                if let currentIdx = taskIndexByID[id] {
                    canRetry = tasks[currentIdx].retryCount == 0
                        && tasks[currentIdx].state != .cancelled
                        && Self.isRetryableError(deviceError)
                } else {
                    canRetry = false
                }

                if canRetry, let retryIdx = taskIndexByID[id] {
                    if let dir = tasks[retryIdx].remoteDir, let st = tasks[retryIdx].storageID {
                        let key = Self.directoryCacheKey(dir: dir, storage: st)
                        ensuredDirectories.remove(key)
                        cachedRemoteDirectories.removeValue(forKey: key)
                    }
                    tasks[retryIdx].retryCount += 1
                    tasks[retryIdx].transferredBytes = 0
                    tasks[retryIdx].speedBytesPerSec = 0
                    tasks[retryIdx].statusNote = "自动重试中…"
                    emitSnapshot(force: true)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                if let failedIdx = taskIndexByID[id] {
                    if tasks[failedIdx].state != .cancelled {
                        transitionTask(
                            at: failedIdx,
                            to: .failed(deviceError.localizedDescription),
                            speed: 0,
                            statusNote: .some(nil)
                        )
                    } else {
                        tasks[failedIdx].speedBytesPerSec = 0
                    }
                    resolveWaiter(id, error: deviceError)
                    emitSnapshot(force: true)
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
                if let idx = taskIndexByID[task.id] {
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

        let normalizedDir = PathUtils.normalize(remoteDir)
        try await ensureRemoteDirectory(normalizedDir, storage: storage, session: session)
        let dirKey = Self.directoryCacheKey(dir: normalizedDir, storage: storage)
        let existingNodes = try await cachedList(dir: normalizedDir, storage: storage, session: session)
        let existingNames = Set(existingNodes.map(\.name))

        let finalName: String
        let overwriteExisting: Bool
        switch PathUtils.resolveConflictDestination(name: task.filename, existingNames: existingNames, strategy: conflictStrategy) {
        case .skip:
            if let idx = taskIndexByID[task.id] {
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
            if var cached = cachedRemoteDirectories[dirKey] {
                cached.removeAll { $0.id == targetExisting.id }
                cachedRemoteDirectories[dirKey] = cached
            }
        }

        let tracker = ProgressTracker { [weak self] bytes, speed in
            guard let self else { return }
            Task { await self.updateTaskProgress(taskID: task.id, transferred: bytes, speed: speed) }
        }

        let uploadedNode = try await session.upload(
            from: sourceURL,
            toDir: normalizedDir,
            remoteName: finalName,
            storage: storage
        ) { bytes in
            tracker.record(bytes: bytes)
        }
        if var cached = cachedRemoteDirectories[dirKey] {
            cached.append(uploadedNode)
            cachedRemoteDirectories[dirKey] = cached
        }
        updateTaskProgress(taskID: task.id, transferred: max(task.totalBytes, tracker.lastBytes), speed: tracker.currentSpeed)
    }

    private static func directoryCacheKey(dir: String, storage: UInt32) -> String {
        "\(storage):\(PathUtils.normalize(dir))"
    }

    private func cachedList(dir: String, storage: UInt32, session: DeviceSession) async throws -> [RemoteNode] {
        let normalized = PathUtils.normalize(dir)
        let key = Self.directoryCacheKey(dir: normalized, storage: storage)
        if let cached = cachedRemoteDirectories[key] {
            return cached
        }
        let children = try await session.list(dir: normalized, storage: storage)
        if cachedRemoteDirectories.count >= 128 {
            cachedRemoteDirectories.removeAll(keepingCapacity: true)
        }
        cachedRemoteDirectories[key] = children
        return children
    }

    private func ensureRemoteDirectory(_ normalizedDir: String, storage: UInt32, session: DeviceSession) async throws {
        let cleanDir = PathUtils.normalize(normalizedDir)
        guard cleanDir != "/" else { return }
        let fullKey = Self.directoryCacheKey(dir: cleanDir, storage: storage)
        if ensuredDirectories.contains(fullKey) {
            return
        }
        var current = "/"
        for component in cleanDir.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(component)
            let nextPath = PathUtils.join(current, segment)
            let nextKey = Self.directoryCacheKey(dir: nextPath, storage: storage)
            if !ensuredDirectories.contains(nextKey) {
                let children = try await cachedList(dir: current, storage: storage, session: session)
                if !children.contains(where: { $0.isDirectory && $0.name == segment }) {
                    try await session.makeDirectory(segment, in: current, storage: storage)
                    let parentKey = Self.directoryCacheKey(dir: current, storage: storage)
                    var updatedChildren = cachedRemoteDirectories[parentKey] ?? children
                    if !updatedChildren.contains(where: { $0.isDirectory && $0.name == segment }) {
                        updatedChildren.append(RemoteNode(
                            id: "\(storage):mkdir:\(nextPath)",
                            storageID: storage,
                            path: nextPath,
                            name: segment,
                            isDirectory: true,
                            size: 0,
                            modified: Date(),
                            kind: .other
                        ))
                    }
                    cachedRemoteDirectories[parentKey] = updatedChildren
                }
                if ensuredDirectories.count >= 2048 {
                    ensuredDirectories.removeAll(keepingCapacity: true)
                }
                ensuredDirectories.insert(nextKey)
            }
            current = nextPath
        }
    }

    private func updateTaskProgress(taskID: UUID, transferred: UInt64, speed: Double) {
        guard let idx = taskIndexByID[taskID],
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

    private func appendTask(_ task: TransferTask) {
        let idx = tasks.count
        tasks.append(task)
        taskIndexByID[task.id] = idx
        switch task.state {
        case .queued:
            queuedCount += 1
            queueSearchCursor = min(queueSearchCursor, idx)
            totalPlannedBytes &+= task.totalBytes
        case .running:
            runningCount += 1
            totalPlannedBytes &+= task.totalBytes
        case .completed:
            completedCount += 1
            totalPlannedBytes &+= task.totalBytes
            settledBytes &+= task.totalBytes
            appendBoundedIndex(idx, to: &recentCompletedIndices)
        case .failed:
            failedCount += 1
            totalPlannedBytes &+= task.totalBytes
            appendBoundedIndex(idx, to: &recentFailedIndices)
        case .cancelled:
            cancelledCount += 1
        }
    }

    private func transitionTask(
        at idx: Int,
        to newState: TransferState,
        transferred: UInt64? = nil,
        speed: Double? = nil,
        retryCount: Int? = nil,
        statusNote: String?? = nil
    ) {
        let oldState = tasks[idx].state
        let totalBytes = tasks[idx].totalBytes

        switch oldState {
        case .queued:
            queuedCount = max(0, queuedCount - 1)
            totalPlannedBytes &-= min(totalPlannedBytes, totalBytes)
        case .running:
            runningCount = max(0, runningCount - 1)
            totalPlannedBytes &-= min(totalPlannedBytes, totalBytes)
        case .completed:
            completedCount = max(0, completedCount - 1)
            totalPlannedBytes &-= min(totalPlannedBytes, totalBytes)
            settledBytes &-= min(settledBytes, totalBytes)
        case .failed:
            failedCount = max(0, failedCount - 1)
            totalPlannedBytes &-= min(totalPlannedBytes, totalBytes)
        case .cancelled:
            cancelledCount = max(0, cancelledCount - 1)
        }

        tasks[idx].state = newState
        if let transferred {
            tasks[idx].transferredBytes = transferred
        }
        if let speed {
            tasks[idx].speedBytesPerSec = speed
        }
        if let retryCount {
            tasks[idx].retryCount = retryCount
        }
        if let statusNote {
            tasks[idx].statusNote = statusNote
        }

        switch newState {
        case .queued:
            queuedCount += 1
            queueSearchCursor = min(queueSearchCursor, idx)
            totalPlannedBytes &+= totalBytes
        case .running:
            runningCount += 1
            totalPlannedBytes &+= totalBytes
        case .completed:
            completedCount += 1
            totalPlannedBytes &+= totalBytes
            settledBytes &+= totalBytes
            appendBoundedIndex(idx, to: &recentCompletedIndices)
        case .failed:
            failedCount += 1
            totalPlannedBytes &+= totalBytes
            appendBoundedIndex(idx, to: &recentFailedIndices)
        case .cancelled:
            cancelledCount += 1
        }
    }

    private func appendBoundedIndex(_ idx: Int, to buffer: inout [Int]) {
        buffer.append(idx)
        if buffer.count > 1000 {
            buffer.removeFirst(500)
        }
    }

    private func rebuildBookkeepingAfterCompaction() {
        taskIndexByID.removeAll(keepingCapacity: true)
        taskIndexByID.reserveCapacity(tasks.count)
        queueSearchCursor = tasks.count
        queuedCount = 0
        runningCount = 0
        completedCount = 0
        failedCount = 0
        cancelledCount = 0
        totalPlannedBytes = 0
        settledBytes = 0
        recentFailedIndices.removeAll(keepingCapacity: true)
        recentCompletedIndices.removeAll(keepingCapacity: true)

        for (idx, task) in tasks.enumerated() {
            taskIndexByID[task.id] = idx
            switch task.state {
            case .queued:
                queuedCount += 1
                queueSearchCursor = min(queueSearchCursor, idx)
                totalPlannedBytes &+= task.totalBytes
            case .running:
                runningCount += 1
                totalPlannedBytes &+= task.totalBytes
            case .completed:
                completedCount += 1
                totalPlannedBytes &+= task.totalBytes
                settledBytes &+= task.totalBytes
                appendBoundedIndex(idx, to: &recentCompletedIndices)
            case .failed:
                failedCount += 1
                totalPlannedBytes &+= task.totalBytes
                appendBoundedIndex(idx, to: &recentFailedIndices)
            case .cancelled:
                cancelledCount += 1
            }
        }
    }

    private func flushPendingUploadRefreshIfIdle() {
        guard runningTaskID == nil,
              queuedCount == 0,
              activePrepareCount == 0,
              hasPendingUploadRefresh else {
            return
        }
        hasPendingUploadRefresh = false
        uploadCompletedHandler?()
    }

    private func buildSnapshot() -> TransferSnapshot {
        let activeTask: TransferTask?
        if let runningTaskID, let idx = taskIndexByID[runningTaskID], idx < tasks.count {
            activeTask = tasks[idx]
        } else {
            activeTask = nil
        }

        let activeSpeed: Double
        let runningTransferred: UInt64
        if let activeTask, activeTask.state == .running {
            activeSpeed = activeTask.speedBytesPerSec
            runningTransferred = min(activeTask.totalBytes, activeTask.transferredBytes)
        } else {
            activeSpeed = 0
            runningTransferred = 0
        }

        let nonCancelled = max(0, tasks.count - cancelledCount)
        let active = queuedCount + runningCount
        let totalDoneBytes = min(totalPlannedBytes, settledBytes &+ runningTransferred)
        let overallProgress: Double
        if totalPlannedBytes > 0 {
            overallProgress = min(1.0, Double(totalDoneBytes) / Double(totalPlannedBytes))
        } else if nonCancelled > 0 {
            overallProgress = min(1.0, Double(completedCount) / Double(nonCancelled))
        } else {
            overallProgress = 0
        }

        let isPreparing = activePrepareCount > 0
        let preparingMessage = isPreparing ? "正在扫描待传文件（已发现 \(preparingScannedCount) 项）…" : nil

        return TransferSnapshot(
            tasks: windowedTasks(activeTask: activeTask),
            conflictStrategy: conflictStrategy,
            overallSpeedBytesPerSec: activeSpeed,
            overallProgress: overallProgress,
            totalTaskCount: tasks.count,
            nonCancelledCount: nonCancelled,
            activeCount: active,
            failedCount: failedCount,
            completedCount: completedCount,
            activeTask: activeTask,
            hasRunningWorker: runningTaskID != nil || isPreparing,
            isPreparing: isPreparing,
            preparingMessage: preparingMessage
        )
    }

    private func windowedTasks(activeTask: TransferTask?) -> [TransferTask] {
        let limit = Self.maxWindowedTasksInSnapshot
        guard tasks.count > 400 else {
            return tasks
        }

        var pickedSet = Set<Int>()
        pickedSet.reserveCapacity(limit)
        var pickedIndices: [Int] = []
        pickedIndices.reserveCapacity(limit)

        if let activeTask, let activeIdx = taskIndexByID[activeTask.id], pickedSet.insert(activeIdx).inserted {
            pickedIndices.append(activeIdx)
        }

        var failedPicked = 0
        for idx in recentFailedIndices.reversed() where idx < tasks.count {
            if failedPicked >= 100 || pickedIndices.count >= limit { break }
            if case .failed = tasks[idx].state, pickedSet.insert(idx).inserted {
                pickedIndices.append(idx)
                failedPicked += 1
            }
        }

        var queuedPicked = 0
        var cursor = max(0, queueSearchCursor)
        while cursor < tasks.count && queuedPicked < 120 && pickedIndices.count < limit {
            if case .queued = tasks[cursor].state, pickedSet.insert(cursor).inserted {
                pickedIndices.append(cursor)
                queuedPicked += 1
            }
            cursor += 1
        }

        for idx in recentCompletedIndices.reversed() where idx < tasks.count {
            if pickedIndices.count >= limit { break }
            if case .completed = tasks[idx].state, pickedSet.insert(idx).inserted {
                pickedIndices.append(idx)
            }
        }

        if pickedIndices.count < limit {
            for idx in tasks.indices.reversed() {
                if pickedIndices.count >= limit { break }
                if pickedSet.insert(idx).inserted {
                    pickedIndices.append(idx)
                }
            }
        }

        pickedIndices.sort()
        return pickedIndices.map { tasks[$0] }
    }

    private func emitSnapshot(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force && (now - lastSnapshotEmitTime) < Self.snapshotThrottleSeconds {
            return
        }
        lastSnapshotEmitTime = now
        snapshotHandler?(buildSnapshot())
    }
}

private enum PreparedUploadEntry: Sendable {
    case valid(url: URL, filename: String, remoteDir: String, storage: UInt32, size: UInt64)
    case invalid(url: URL, filename: String, remoteDir: String, storage: UInt32, reason: String)
}

private final class ScanCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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
