import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 多级缩略图流水线：内存 `NSCache` → 磁盘 LRU 缓存（默认上限 2 GB）→ 设备原生缩略图 → 临时下载后 ImageIO/AVAssetImageGenerator 生成 320 px 缩略图。
actor ThumbnailPipeline {
    static let maxThumbnailDimension: Int = 320
    static let defaultDiskCacheLimitBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maxFallbackPhotoBytes: UInt64 = 4 * 1024 * 1024
    static let maxFallbackVideoBytes: UInt64 = 2 * 1024 * 1024

    private let cacheDirectory: URL
    private let maxDiskBytes: UInt64
    private let memoryCache = SendableMemoryCache()
    private let imageCache = SendableImageCache()
    private let maxConcurrentDecodes: Int
    private var activeDecodes = 0
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
    private var isDeviceSlotBusy = false
    private var isPreviewPrioritized = false
    private var isTransferPrioritized = false
    private var deviceSlotWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        cacheDirectory: URL? = nil,
        maxDiskBytes: UInt64 = ThumbnailPipeline.defaultDiskCacheLimitBytes
    ) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = cachesRoot
                .appendingPathComponent("com.droiddock.app", isDirectory: true)
                .appendingPathComponent("Thumbnails", isDirectory: true)
        }
        self.maxDiskBytes = maxDiskBytes
        self.maxConcurrentDecodes = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    /// 规范化缓存键：`sha1(deviceID|storage|path|size|mtime)`，输出 40 位小写十六进制。
    nonisolated static func cacheKey(deviceID: String, node: RemoteNode) -> String {
        let mtimeInt = Int64(node.modified?.timeIntervalSince1970 ?? 0)
        let raw = "\(deviceID)|\(node.storageID)|\(node.path)|\(node.size)|\(mtimeInt)"
        let digest = Insecure.SHA1.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 内存缓存快读（主线程渲染前可直接命中，无需异步切回 actor）。
    nonisolated func memoryCachedThumbnail(for node: RemoteNode, deviceID: String) -> Data? {
        let key = Self.cacheKey(deviceID: deviceID, node: node)
        return memoryCache.data(forKey: key)
    }

    /// 已解码位图零耗时快读（仅查 `NSCache<NSString, NSImage>`，适合网格首次渲染同步读取）。
    nonisolated func memoryCachedImage(for node: RemoteNode, deviceID: String) -> NSImage? {
        let key = Self.cacheKey(deviceID: deviceID, node: node)
        return imageCache.image(forKey: key)
    }

    /// 优先加载已解码的 `NSImage` 缩略图，并在后台线程完成位图解码，避免主线程重绘卡顿。
    func thumbnailImage(for node: RemoteNode, deviceID: String, session: DeviceSession) async throws -> NSImage? {
        let key = Self.cacheKey(deviceID: deviceID, node: node)
        if let hit = imageCache.image(forKey: key) {
            return hit
        }
        guard let data = try await thumbnail(for: node, deviceID: deviceID, session: session) else {
            return nil
        }
        if let hit = imageCache.image(forKey: key) {
            return hit
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            NSImage(data: data)
        }.value
        if let decoded {
            imageCache.setImage(decoded, forKey: key, byteCost: data.count)
        }
        return decoded
    }

    /// 当用户打开高清原图预览时暂停后台缩略图设备 I/O，确保双击查看秒级拿到原图。
    func setPreviewPrioritized(_ active: Bool) {
        isPreviewPrioritized = active
        if !active {
            wakeNextDeviceWaiterIfPossible()
        }
    }

    /// 当批量传输队列运行时暂停后台缩略图设备 I/O，避免抢占同一条 USB MTP 管道。
    func setTransferPrioritized(_ active: Bool) {
        isTransferPrioritized = active
        if !active {
            wakeNextDeviceWaiterIfPossible()
        }
    }

    /// 按顺序尝试：内存 → 磁盘 → LIFO 设备通道（原生 `GetThumb` / 128 KB EXIF）→ 小文件下载后生成 320 px JPEG。
    func thumbnail(for node: RemoteNode, deviceID: String, session: DeviceSession) async throws -> Data? {
        guard !node.isDirectory, node.kind == .photo || node.kind == .video else {
            return nil
        }
        let key = Self.cacheKey(deviceID: deviceID, node: node)

        if let memHit = memoryCache.data(forKey: key) {
            return memHit
        }

        let diskURL = cacheDirectory.appendingPathComponent("\(key).jpg")
        if let diskData = readDiskCache(at: diskURL) {
            memoryCache.setData(diskData, forKey: key)
            return diskData
        }

        try Task.checkCancellation()

        // 第三/四级需要访问设备：走 LIFO 栈调度（当前视口最新可见图片优先）并让路高清原图下载
        return try await withDeviceThumbnailSlot {
            if let memHit = memoryCache.data(forKey: key) {
                return memHit
            }
            if let diskData = readDiskCache(at: diskURL) {
                memoryCache.setData(diskData, forKey: key)
                return diskData
            }
            try Task.checkCancellation()

            // 第三级：设备原生缩略图（GetThumb）或照片前 128 KB 内嵌 EXIF 缩略图
            if let nativeData = try await session.thumbnail(for: node), !nativeData.isEmpty {
                let normalized = Self.downsampleImageData(nativeData, maxPixelSize: Self.maxThumbnailDimension) ?? nativeData
                store(data: normalized, key: key, diskURL: diskURL)
                return normalized
            }

            try Task.checkCancellation()

            // 第三级（视频扩展）：通过按需局部字节读取 + AVAssetResourceLoader 仅拉取头尾索引与首个关键帧生成封面
            if node.kind == .video, node.size > 0, Self.supportsPartialVideoCover(for: node.name) {
                if let videoCover = try await Self.extractRemoteVideoThumbnail(
                    for: node,
                    session: session,
                    maxPixelSize: Self.maxThumbnailDimension
                ) {
                    store(data: videoCover, key: key, diskURL: diskURL)
                    return videoCover
                }
            }

            try Task.checkCancellation()

            // 第四级兜底：仅对小体积文件下载原件生成缩略图，避免 4K 视频或超大原片堵死串行管道
            let fallbackLimit = node.kind == .video ? Self.maxFallbackVideoBytes : Self.maxFallbackPhotoBytes
            if node.size > 0 && node.size > fallbackLimit {
                return nil
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("droiddock-thumb-\(UUID().uuidString)-\(node.name)")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            try await session.download(node, to: tempURL) { _ in }
            try Task.checkCancellation()

            let generated: Data? = try await withDecodeSlot {
                if node.kind == .photo {
                    return Self.generatePhotoThumbnail(at: tempURL, maxPixelSize: Self.maxThumbnailDimension)
                } else {
                    return try await Self.generateVideoThumbnail(at: tempURL, maxPixelSize: Self.maxThumbnailDimension)
                }
            }

            guard let generated, !generated.isEmpty else {
                return nil
            }
            store(data: generated, key: key, diskURL: diskURL)
            return generated
        }
    }

    /// 执行磁盘缓存容量检查与按修改时间 LRU 淘汰。
    func enforceDiskLimit() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct CachedFile {
            let url: URL
            let modified: Date
            let size: UInt64
        }

        var files: [CachedFile] = []
        var totalSize: UInt64 = 0
        for url in entries where url.pathExtension.lowercased() == "jpg" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let modified = values.contentModificationDate ?? .distantPast
            files.append(CachedFile(url: url, modified: modified, size: size))
            totalSize += size
        }

        guard totalSize > maxDiskBytes else { return }

        // 最久未访问的文件（mtime 最早）优先清理
        files.sort { $0.modified < $1.modified }
        for item in files {
            guard totalSize > maxDiskBytes else { break }
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                totalSize = totalSize >= item.size ? totalSize - item.size : 0
            }
        }
    }

    // MARK: - 私有辅助

    private func readDiskCache(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    private func store(data: Data, key: String, diskURL: URL) {
        memoryCache.setData(data, forKey: key)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: diskURL, options: [.atomic])
        enforceDiskLimit()
    }

    private func withDeviceThumbnailSlot<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        while isDeviceSlotBusy || isPreviewPrioritized || isTransferPrioritized {
            if Task.isCancelled {
                wakeNextDeviceWaiterIfPossible()
                throw CancellationError()
            }
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if !isDeviceSlotBusy && !isPreviewPrioritized && !isTransferPrioritized && !Task.isCancelled {
                        continuation.resume()
                    } else if Task.isCancelled {
                        continuation.resume()
                    } else {
                        deviceSlotWaiters.append((waiterID, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelDeviceWaiter(id: waiterID) }
            }
        }
        if Task.isCancelled {
            wakeNextDeviceWaiterIfPossible()
            throw CancellationError()
        }
        isDeviceSlotBusy = true
        defer {
            isDeviceSlotBusy = false
            wakeNextDeviceWaiterIfPossible()
        }
        return try await work()
    }

    private func cancelDeviceWaiter(id: UUID) {
        if let idx = deviceSlotWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = deviceSlotWaiters.remove(at: idx)
            waiter.continuation.resume()
        }
    }

    private func wakeNextDeviceWaiterIfPossible() {
        guard !isDeviceSlotBusy, !isPreviewPrioritized, !isTransferPrioritized else { return }
        if let latest = deviceSlotWaiters.popLast() {
            latest.continuation.resume()
        }
    }

    private func withDecodeSlot<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        while activeDecodes >= maxConcurrentDecodes {
            await withCheckedContinuation { decodeWaiters.append($0) }
        }
        try Task.checkCancellation()
        activeDecodes += 1
        defer {
            activeDecodes -= 1
            if !decodeWaiters.isEmpty {
                decodeWaiters.removeFirst().resume()
            }
        }
        return try await work()
    }

    private static func downsampleImageData(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= maxPixelSize,
           CGImageSourceGetStatus(source) == .statusComplete {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(cgImage: cgImage)
    }

    private static func generatePhotoThumbnail(at url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(cgImage: cgImage)
    }

    private static func generateVideoThumbnail(at url: URL, maxPixelSize: Int) async throws -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        let preferredTime = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let result = try? await generator.image(at: preferredTime) {
            return encodeJPEG(cgImage: result.image)
        }
        if let fallback = try? await generator.image(at: .zero) {
            return encodeJPEG(cgImage: fallback.image)
        }
        return nil
    }

    private static func encodeJPEG(cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static let partialVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp"]

    private static func supportsPartialVideoCover(for filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return partialVideoExtensions.contains(ext)
    }

    private static func extractRemoteVideoThumbnail(
        for node: RemoteNode,
        session: DeviceSession,
        maxPixelSize: Int
    ) async throws -> Data? {
        guard let initialHead = try await session.readPartial(
            node,
            offset: 0,
            length: Int(RemoteVideoResourceLoader.blockSize)
        ), !initialHead.isEmpty else {
            return nil
        }
        try Task.checkCancellation()

        let ext = (node.name as NSString).pathExtension.lowercased()
        let contentTypeID = UTType(filenameExtension: ext)?.identifier ?? UTType.mpeg4Movie.identifier
        guard let virtualURL = URL(string: "\(RemoteVideoResourceLoader.customScheme)://video/\(UUID().uuidString).\(ext.isEmpty ? "mp4" : ext)") else {
            return nil
        }

        let box = VideoFrameExtractorBox(
            virtualURL: virtualURL,
            node: node,
            session: session,
            contentTypeIdentifier: contentTypeID,
            initialBlockZero: initialHead,
            maxPixelSize: maxPixelSize
        )

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    defer { box.cancelAndClose() }
                    let targetTimes = [CMTime(seconds: 0.5, preferredTimescale: 600), .zero]
                    for time in targetTimes {
                        try Task.checkCancellation()
                        if let cgImage = try? await box.generator.image(at: time).image {
                            return encodeJPEG(cgImage: cgImage)
                        }
                        if let disconnectedError = box.loader.consumeDisconnectError() {
                            throw disconnectedError
                        }
                    }
                    return nil
                }

                group.addTask {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    box.cancelAndClose()
                    return nil
                }

                let firstResult = try await group.next() ?? nil
                group.cancelAll()
                return firstResult
            }
        } onCancel: {
            box.cancelAndClose()
        }
    }
}

private final class VideoFrameExtractorBox: @unchecked Sendable {
    let loader: RemoteVideoResourceLoader
    let asset: AVURLAsset
    let generator: AVAssetImageGenerator
    private let loaderQueue = DispatchQueue(label: "droiddock.videothumb.loader")

    init(
        virtualURL: URL,
        node: RemoteNode,
        session: DeviceSession,
        contentTypeIdentifier: String,
        initialBlockZero: Data,
        maxPixelSize: Int
    ) {
        self.loader = RemoteVideoResourceLoader(
            node: node,
            session: session,
            contentTypeIdentifier: contentTypeIdentifier,
            initialBlockZero: initialBlockZero
        )
        self.asset = AVURLAsset(url: virtualURL)
        self.asset.resourceLoader.setDelegate(self.loader, queue: self.loaderQueue)
        self.generator = AVAssetImageGenerator(asset: self.asset)
        self.generator.appliesPreferredTrackTransform = true
        self.generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        self.generator.requestedTimeToleranceBefore = .positiveInfinity
        self.generator.requestedTimeToleranceAfter = .positiveInfinity
    }

    func cancelAndClose() {
        generator.cancelAllCGImageGeneration()
        loader.close()
    }
}

/// 通过按需 128 KB 局部读取向 `AVURLAsset` 提供视频首帧所需字节，避免下载整部大视频。
private final class RemoteVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let customScheme = "droiddock-remote-video"
    static let blockSize: UInt64 = 131_072
    private static let maxReadBudgetBytes: Int = 4 * 1024 * 1024

    private let node: RemoteNode
    private let session: DeviceSession
    private let contentTypeIdentifier: String
    private let lock = NSLock()
    private var blockCache: [UInt64: Data] = [:]
    private var totalFetchedBytes: Int
    private var inFlightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isClosed = false
    private var disconnectError: DeviceError?

    init(
        node: RemoteNode,
        session: DeviceSession,
        contentTypeIdentifier: String,
        initialBlockZero: Data
    ) {
        self.node = node
        self.session = session
        self.contentTypeIdentifier = contentTypeIdentifier
        self.blockCache[0] = initialBlockZero
        self.totalFetchedBytes = initialBlockZero.count
    }

    func consumeDisconnectError() -> DeviceError? {
        lock.withLock { disconnectError }
    }

    func close() {
        let tasksToCancel = lock.withLock { () -> [Task<Void, Never>] in
            isClosed = true
            let list = Array(inFlightTasks.values)
            inFlightTasks.removeAll()
            return list
        }
        for task in tasksToCancel {
            task.cancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if lock.withLock({ isClosed }) {
            return false
        }

        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = contentTypeIdentifier
            infoRequest.contentLength = Int64(node.size)
            infoRequest.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let reqKey = ObjectIdentifier(loadingRequest)
        let box = LoadingRequestBox(loadingRequest)
        let task = Task { [weak self] in
            guard let self else {
                box.request.finishLoading(with: CancellationError())
                return
            }
            defer {
                self.lock.withLock {
                    _ = self.inFlightTasks.removeValue(forKey: reqKey)
                }
            }
            await self.serveDataRequest(box.request, dataRequest: dataRequest)
        }

        lock.withLock {
            if isClosed {
                task.cancel()
            } else {
                inFlightTasks[reqKey] = task
            }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let reqKey = ObjectIdentifier(loadingRequest)
        let task = lock.withLock { inFlightTasks.removeValue(forKey: reqKey) }
        task?.cancel()
    }

    private func serveDataRequest(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        dataRequest: AVAssetResourceLoadingDataRequest
    ) async {
        let startOffset = UInt64(max(0, dataRequest.currentOffset))
        guard startOffset < node.size else {
            loadingRequest.finishLoading()
            return
        }

        let remainingToEOF = node.size - startOffset
        let targetEnd: UInt64
        if dataRequest.requestsAllDataToEndOfResource {
            targetEnd = node.size
        } else {
            let requestedLen = UInt64(max(0, dataRequest.requestedLength))
            targetEnd = startOffset + min(requestedLen, remainingToEOF)
        }

        var cursor = startOffset
        while cursor < targetEnd {
            if Task.isCancelled || lock.withLock({ isClosed }) {
                loadingRequest.finishLoading(with: CancellationError())
                return
            }

            let blockStart = (cursor / Self.blockSize) * Self.blockSize
            let blockData: Data
            do {
                guard let loaded = try await loadBlock(at: blockStart) else {
                    loadingRequest.finishLoading()
                    return
                }
                blockData = loaded
            } catch let devError as DeviceError {
                if case .disconnected = devError {
                    lock.withLock { disconnectError = .disconnected }
                }
                loadingRequest.finishLoading(with: devError)
                return
            } catch {
                loadingRequest.finishLoading(with: error)
                return
            }

            let offsetInBlock = Int(cursor - blockStart)
            guard offsetInBlock < blockData.count else {
                loadingRequest.finishLoading()
                return
            }

            let maxSliceEnd = min(blockData.count, offsetInBlock + Int(min(UInt64(Int.max), targetEnd - cursor)))
            let slice = blockData.subdata(in: offsetInBlock..<maxSliceEnd)
            if slice.isEmpty {
                break
            }
            dataRequest.respond(with: slice)
            cursor += UInt64(slice.count)
        }

        loadingRequest.finishLoading()
    }

    private func loadBlock(at blockStart: UInt64) async throws -> Data? {
        if let cached = lock.withLock({ blockCache[blockStart] }) {
            return cached
        }
        guard blockStart < node.size else { return nil }
        let requestLen = Int(min(Self.blockSize, node.size - blockStart))

        let allowed = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            return totalFetchedBytes + requestLen <= Self.maxReadBudgetBytes
        }
        guard allowed else {
            throw DeviceError.unsupported
        }

        guard let fetched = try await session.readPartial(node, offset: blockStart, length: requestLen),
              !fetched.isEmpty else {
            return nil
        }

        lock.withLock {
            if blockCache[blockStart] == nil {
                blockCache[blockStart] = fetched
                totalFetchedBytes += fetched.count
            }
        }
        return fetched
    }
}

private final class LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }
}

private final class SendableMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 800
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    func data(forKey key: String) -> Data? {
        cache.object(forKey: key as NSString) as Data?
    }

    func setData(_ data: Data, forKey key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

private final class SendableImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 800
        return c
    }()

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, forKey key: String, byteCost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: byteCost)
    }
}
