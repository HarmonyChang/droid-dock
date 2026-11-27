import AppKit
import Foundation
import ImageIO
import Observation

/// 照片详细信息与 EXIF 拍摄参数摘要（用于查看器右上角浮窗展示）。
struct PhotoMetadata: Sendable, Equatable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let fileSizeBytes: UInt64
    let formatName: String
    let cameraModel: String?
    let lensModel: String?
    let focalLengthText: String?
    let apertureText: String?
    let shutterSpeedText: String?
    let isoText: String?
    let exposureBiasText: String?
    let capturedAt: Date?
    let colorProfileName: String?
    let gpsText: String?
    let isOriginalLoaded: Bool

    var dimensionsText: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var megapixelsText: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        let mp = Double(pixelWidth * pixelHeight) / 1_000_000.0
        if mp >= 0.1 {
            return String(format: "%.1f MP", mp)
        }
        return "\(max(1, (pixelWidth * pixelHeight) / 1000)) KP"
    }

    var exposureTags: [String] {
        [focalLengthText, apertureText, shutterSpeedText, isoText, exposureBiasText].compactMap { $0 }
    }

    static func initial(from node: RemoteNode) -> PhotoMetadata {
        PhotoMetadata(
            pixelWidth: nil,
            pixelHeight: nil,
            fileSizeBytes: node.size,
            formatName: inferredFormatName(for: node.name),
            cameraModel: nil,
            lensModel: nil,
            focalLengthText: nil,
            apertureText: nil,
            shutterSpeedText: nil,
            isoText: nil,
            exposureBiasText: nil,
            capturedAt: node.modified,
            colorProfileName: nil,
            gpsText: nil,
            isOriginalLoaded: false
        )
    }

    static func extract(from url: URL, node: RemoteNode, isOriginal: Bool) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return initial(from: node)
        }
        return extract(from: source, node: node, isOriginal: isOriginal)
    }

    static func extract(from source: CGImageSource, node: RemoteNode, isOriginal: Bool) -> PhotoMetadata {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? (tiff?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue
            ?? 1
        // EXIF 方向 5–8 表示横竖屏旋转 90°/270°，需交换传感器宽高得到真实视觉尺寸
        if [5, 6, 7, 8].contains(orientation), let w = width, let h = height {
            width = h
            height = w
        }

        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cameraModel: String?
        if let model, !model.isEmpty {
            if let make, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) {
                cameraModel = "\(make) \(model)"
            } else {
                cameraModel = model
            }
        } else if let make, !make.isEmpty {
            cameraModel = make
        } else {
            cameraModel = nil
        }

        let lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let focal35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
        let focalRaw = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
        let focalLengthText: String? = (focal35 ?? focalRaw).flatMap { val in
            guard val > 0 else { return nil }
            if focal35 != nil || abs(val - val.rounded()) < 0.05 {
                return "\(Int(val.rounded())) mm"
            }
            return String(format: "%.1f mm", val)
        }

        let apertureText: String?
        if let f = (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue, f > 0 {
            apertureText = abs(f - f.rounded()) < 0.05 ? String(format: "f/%.0f", f) : String(format: "f/%.1f", f)
        } else {
            apertureText = nil
        }

        let shutterSpeedText: String?
        if let t = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, t > 0 {
            if t >= 1.0 {
                let raw = String(format: "%.1f", t)
                shutterSpeedText = (raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw) + " s"
            } else {
                let denom = max(1, Int((1.0 / t).rounded()))
                shutterSpeedText = "1/\(denom) s"
            }
        } else {
            shutterSpeedText = nil
        }

        let isoText: String?
        if let n = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first, n.intValue > 0 {
            isoText = "ISO \(n.intValue)"
        } else {
            isoText = nil
        }

        let exposureBiasText: String?
        if let bias = (exif?[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue {
            exposureBiasText = abs(bias) < 0.05 ? "0 EV" : String(format: "%+.1f EV", bias)
        } else {
            exposureBiasText = nil
        }

        let dateStr = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let capturedAt = dateStr.flatMap(parseEXIFDate) ?? node.modified

        let colorProfileName = (props[kCGImagePropertyProfileName] as? String)?.nilIfEmpty
            ?? (props[kCGImagePropertyColorModel] as? String)?.nilIfEmpty

        let gpsText: String?
        if let lat = (gps?[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps?[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let latRef = (gps?[kCGImagePropertyGPSLatitudeRef] as? String) ?? (lat >= 0 ? "N" : "S")
            let lonRef = (gps?[kCGImagePropertyGPSLongitudeRef] as? String) ?? (lon >= 0 ? "E" : "W")
            gpsText = String(format: "%.4f° %@, %.4f° %@", abs(lat), latRef, abs(lon), lonRef)
        } else {
            gpsText = nil
        }

        return PhotoMetadata(
            pixelWidth: width,
            pixelHeight: height,
            fileSizeBytes: node.size,
            formatName: inferredFormatName(for: node.name),
            cameraModel: cameraModel,
            lensModel: lensModel,
            focalLengthText: focalLengthText,
            apertureText: apertureText,
            shutterSpeedText: shutterSpeedText,
            isoText: isoText,
            exposureBiasText: exposureBiasText,
            capturedAt: capturedAt,
            colorProfileName: colorProfileName,
            gpsText: gpsText,
            isOriginalLoaded: isOriginal
        )
    }

    private static func inferredFormatName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.uppercased()
        if ext == "JPG" { return "JPEG" }
        return ext.isEmpty ? "图片" : ext
    }

    private static func parseEXIFDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case photos
    case videos
    case screenshots
    case internalStorage
    case downloads
    case documents
    case transfers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "相册"
        case .videos: return "视频"
        case .screenshots: return "截图"
        case .internalStorage: return "内部存储"
        case .downloads: return "下载"
        case .documents: return "文档"
        case .transfers: return "传输队列"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .videos: return "play.rectangle.fill"
        case .screenshots: return "viewfinder"
        case .internalStorage: return "internaldrive.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .documents: return "doc.text.fill"
        case .transfers: return "arrow.up.arrow.down.circle.fill"
        }
    }

    var isMediaSection: Bool {
        switch self {
        case .photos, .videos, .screenshots:
            return true
        case .internalStorage, .downloads, .documents, .transfers:
            return false
        }
    }

    var defaultPath: String? {
        switch self {
        case .photos: return "/DCIM"
        case .videos: return "/Movies"
        case .screenshots: return "/Pictures/Screenshots"
        case .internalStorage: return "/"
        case .downloads: return "/Download"
        case .documents: return "/Documents"
        case .transfers: return nil
        }
    }

    var defaultUploadDirectory: String {
        switch self {
        case .photos: return "/Pictures"
        case .videos: return "/Movies"
        case .screenshots: return "/Pictures/Screenshots"
        case .internalStorage: return "/"
        case .downloads: return "/Download"
        case .documents: return "/Documents"
        case .transfers: return "/Download"
        }
    }
}

enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case photos = "照片"
    case videos = "视频"
    case screenshots = "截图"

    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Sendable {
    case grid
    case list

    var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        }
    }
}

struct MediaDateSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [RemoteNode]
}

/// 主窗口文件与媒体浏览状态模型。
@MainActor
@Observable
final class BrowserModel {
    var selectedSidebar: SidebarSection = .photos
    var mediaFilter: MediaFilter = .all
    var viewMode: ViewMode = .grid
    var searchQuery: String = ""
    var selectedNodeIDs: Set<String> = []
    private(set) var storages: [StorageInfo] = []
    var selectedStorageID: UInt32?
    private(set) var currentPath: String = "/"
    private(set) var nodes: [RemoteNode] = []
    private(set) var mediaNodes: [RemoteNode] = []
    private(set) var isLoading: Bool = false
    private(set) var isDeviceLocked: Bool = false
    var errorMessage: String?
    var infoBannerMessage: String?

    private(set) var thumbnailCache: [String: Data] = [:]
    private var loadingThumbnails: Set<String> = []
    private var failedThumbnails: Set<String> = []
    private var hasLoadedMedia = false

    private(set) var previewingNode: RemoteNode?
    private(set) var previewLocalURL: URL?
    private(set) var previewFullImage: NSImage?
    private(set) var previewMetadata: PhotoMetadata?
    private(set) var previewProgress: Double = 0
    private(set) var isLoadingPreview: Bool = false
    private(set) var previewError: String?
    private var previewLoadTask: Task<Void, Never>?
    private var previewPrefetchTask: Task<Void, Never>?
    private var lockedRetryTask: Task<Void, Never>?

    private let mediaIndexStore: MediaIndexStore
    private let thumbnailPipeline: ThumbnailPipeline

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var activeSession: DeviceSession?
    private var activeDeviceID: DeviceID?
    private var onDisconnect: (@MainActor (DeviceID) -> Void)?

    init(
        mediaIndexStore: MediaIndexStore = MediaIndexStore(),
        thumbnailPipeline: ThumbnailPipeline = ThumbnailPipeline()
    ) {
        self.mediaIndexStore = mediaIndexStore
        self.thumbnailPipeline = thumbnailPipeline
        Self.prunePreviewCacheIfNeeded()
    }

    var isMediaMode: Bool { selectedSidebar.isMediaSection }
    var canGoBack: Bool { !isMediaMode && !backStack.isEmpty }
    var canGoForward: Bool { !isMediaMode && !forwardStack.isEmpty }
    var canMutateDirectory: Bool { activeSession != nil && !isDeviceLocked && !isMediaMode && selectedSidebar != .transfers }
    var activeStorageID: UInt32? { selectedStorageID ?? storages.first?.id }

    var effectiveUploadDirectory: String {
        if isMediaMode || selectedSidebar == .transfers {
            return selectedSidebar.defaultUploadDirectory
        }
        return currentPath
    }

    var selectedNodes: [RemoteNode] {
        filteredNodes.filter { selectedNodeIDs.contains($0.id) }
    }

    var previewablePhotos: [RemoteNode] {
        filteredNodes.filter { !$0.isDirectory && $0.kind == .photo }
    }

    var currentStorage: StorageInfo? {
        guard let selectedStorageID else { return storages.first }
        return storages.first { $0.id == selectedStorageID } ?? storages.first
    }

    var filteredNodes: [RemoteNode] {
        let base: [RemoteNode]
        if isMediaMode {
            base = mediaNodes.filter { node in
                guard !node.isDirectory, (node.kind == .photo || node.kind == .video) else {
                    return false
                }
                switch mediaFilter {
                case .all:
                    return true
                case .photos:
                    return node.kind == .photo
                case .videos:
                    return node.kind == .video
                case .screenshots:
                    return Self.isScreenshot(node)
                }
            }
        } else {
            base = nodes
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var groupedMediaSections: [MediaDateSection] {
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        var groups: [Date: [RemoteNode]] = [:]
        var unknownItems: [RemoteNode] = []

        for node in filteredNodes {
            if let modified = node.modified {
                let day = calendar.startOfDay(for: modified)
                groups[day, default: []].append(node)
            } else {
                unknownItems.append(node)
            }
        }

        let sortedDays = groups.keys.sorted(by: >)
        var sections = sortedDays.map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "今天"
            } else if calendar.isDateInYesterday(day) {
                title = "昨天"
            } else {
                let year = calendar.component(.year, from: day)
                let month = calendar.component(.month, from: day)
                let dayNum = calendar.component(.day, from: day)
                title = year == currentYear ? "\(month) 月 \(dayNum) 日" : "\(year) 年 \(month) 月 \(dayNum) 日"
            }
            return MediaDateSection(
                id: String(day.timeIntervalSince1970),
                title: title,
                items: groups[day] ?? []
            )
        }

        if !unknownItems.isEmpty {
            sections.append(MediaDateSection(id: "earlier", title: "更早", items: unknownItems))
        }
        return sections
    }

    var mediaCounts: (all: Int, photos: Int, videos: Int, screenshots: Int) {
        var photos = 0
        var videos = 0
        var screenshots = 0
        for node in mediaNodes where !node.isDirectory {
            if node.kind == .photo { photos += 1 }
            if node.kind == .video { videos += 1 }
            if Self.isScreenshot(node) { screenshots += 1 }
        }
        return (mediaNodes.count, photos, videos, screenshots)
    }

    var currentTitle: String {
        if isMediaMode || selectedSidebar == .transfers {
            return selectedSidebar.title
        }
        if currentPath == "/" {
            return currentStorage?.name ?? selectedSidebar.title
        }
        return PathUtils.filename(of: currentPath)
    }

    func configureDisconnectHandler(_ handler: @escaping @MainActor (DeviceID) -> Void) {
        onDisconnect = handler
    }

    func attachSession(_ session: DeviceSession, deviceID: DeviceID) async {
        lockedRetryTask?.cancel()
        lockedRetryTask = nil
        activeSession = session
        activeDeviceID = deviceID
        errorMessage = nil
        infoBannerMessage = nil
        isDeviceLocked = false
        hasLoadedMedia = false
        mediaNodes = []
        nodes = []
        thumbnailCache.removeAll()
        loadingThumbnails.removeAll()
        failedThumbnails.removeAll()
        backStack.removeAll()
        forwardStack.removeAll()
        selectedNodeIDs.removeAll()

        isLoading = true
        defer { isLoading = false }

        do {
            var fetchedStorages = try await session.storages()
            // 刚切换 USB 文件传输模式时存储枚举可能存在短暂延迟，先快速重查 3 次避免误弹未授权提示
            for _ in 0..<3 where fetchedStorages.isEmpty {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard activeSession != nil, activeDeviceID == deviceID else { return }
                fetchedStorages = try await session.storages()
            }
            guard !fetchedStorages.isEmpty else {
                storages = []
                selectedStorageID = nil
                nodes = []
                mediaNodes = []
                isDeviceLocked = true
                startLockedStoragePolling(session: session, deviceID: deviceID)
                return
            }
            storages = fetchedStorages
            if selectedStorageID == nil || !fetchedStorages.contains(where: { $0.id == selectedStorageID }) {
                selectedStorageID = fetchedStorages.first?.id
            }
            await loadActiveSection(forceRefreshMedia: true)
        } catch let error as DeviceError {
            handleDeviceError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetForDisconnectedOrLocked(locked: Bool) {
        lockedRetryTask?.cancel()
        lockedRetryTask = nil
        activeSession = nil
        activeDeviceID = nil
        isDeviceLocked = locked
        storages = []
        selectedStorageID = nil
        nodes = []
        mediaNodes = []
        hasLoadedMedia = false
        thumbnailCache.removeAll()
        loadingThumbnails.removeAll()
        failedThumbnails.removeAll()
        selectedNodeIDs.removeAll()
        backStack.removeAll()
        forwardStack.removeAll()
        closePreview()
        isLoading = false
        if !locked {
            errorMessage = nil
        }
    }

    private func startLockedStoragePolling(session: DeviceSession, deviceID: DeviceID) {
        lockedRetryTask?.cancel()
        lockedRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.activeDeviceID == deviceID,
                      self.isDeviceLocked else {
                    return
                }
                do {
                    let recovered = try await session.storages()
                    guard !Task.isCancelled, self.activeDeviceID == deviceID else { return }
                    if !recovered.isEmpty {
                        self.isDeviceLocked = false
                        self.storages = recovered
                        self.selectedStorageID = recovered.first?.id
                        await self.loadActiveSection(forceRefreshMedia: true)
                        return
                    }
                } catch let error as DeviceError {
                    if case .disconnected = error {
                        self.handleDeviceError(error)
                    }
                    return
                } catch {
                    return
                }
            }
        }
    }

    func selectSidebar(_ section: SidebarSection) async {
        selectedSidebar = section
        selectedNodeIDs.removeAll()
        errorMessage = nil
        switch section {
        case .photos:
            mediaFilter = .all
            await loadActiveSection(forceRefreshMedia: false)
        case .videos:
            mediaFilter = .videos
            await loadActiveSection(forceRefreshMedia: false)
        case .screenshots:
            mediaFilter = .screenshots
            await loadActiveSection(forceRefreshMedia: false)
        case .internalStorage, .downloads, .documents:
            backStack.removeAll()
            forwardStack.removeAll()
            currentPath = PathUtils.normalize(section.defaultPath ?? "/")
            await loadDirectory(path: currentPath)
        case .transfers:
            nodes = []
        }
    }

    func openNode(_ node: RemoteNode) async {
        guard node.isDirectory else {
            selectedNodeIDs = [node.id]
            await openPreview(for: node)
            return
        }
        await navigate(to: node.path)
    }

    /// 打开图片内建缩放查看器（抢占设备带宽优先读取高清原图并解析 EXIF），或为视频/文档下载缓存后唤起系统 Quick Look。
    func openPreview(for node: RemoteNode) async {
        guard !node.isDirectory, let session = activeSession else { return }
        let devID = activeDeviceID?.rawValue ?? "default"
        previewLoadTask?.cancel()
        previewPrefetchTask?.cancel()
        previewPrefetchTask = nil
        previewError = nil
        previewProgress = 0

        if node.kind == .photo {
            selectedNodeIDs = [node.id]
            previewingNode = node
            previewFullImage = nil
            previewMetadata = PhotoMetadata.initial(from: node)

            let cacheURL = previewCacheURL(for: node, deviceID: devID)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                previewLocalURL = cacheURL
                isLoadingPreview = true
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        if self.previewingNode?.id == node.id {
                            self.isLoadingPreview = false
                        }
                    }
                    let decoded = await Self.decodeHighResImageAndMetadata(from: cacheURL, node: node)
                    guard !Task.isCancelled, self.previewingNode?.id == node.id else { return }
                    if let image = decoded.image {
                        self.previewFullImage = image
                        self.previewMetadata = decoded.metadata
                    } else {
                        self.previewError = "无法解析本地缓存图片"
                    }
                    self.scheduleAdjacentPreviewPrefetch(after: node, deviceID: devID, session: session)
                }
                previewLoadTask = task
                await task.value
                return
            }

            previewLocalURL = nil
            isLoadingPreview = true
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.thumbnailPipeline.setPreviewPrioritized(true)
                defer {
                    Task { await self.thumbnailPipeline.setPreviewPrioritized(false) }
                    if self.previewingNode?.id == node.id {
                        self.isLoadingPreview = false
                    }
                }
                do {
                    do {
                        try await self.downloadPreviewWithProgress(node: node, to: cacheURL, session: session)
                    } catch let error as DeviceError {
                        if case .disconnected = error { throw error }
                        // 设备通道偶发忙碌或先序事务退避时短暂等待并重试 1 次
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        try Task.checkCancellation()
                        try await self.downloadPreviewWithProgress(node: node, to: cacheURL, session: session)
                    }
                    try Task.checkCancellation()
                    let decoded = await Self.decodeHighResImageAndMetadata(from: cacheURL, node: node)
                    guard !Task.isCancelled, self.previewingNode?.id == node.id else { return }
                    self.previewLocalURL = cacheURL
                    if let image = decoded.image {
                        self.previewFullImage = image
                        self.previewMetadata = decoded.metadata
                        self.previewProgress = 1.0
                    } else {
                        self.previewError = "原图格式暂不支持直接解码"
                    }
                    self.scheduleAdjacentPreviewPrefetch(after: node, deviceID: devID, session: session)
                } catch is CancellationError {
                    return
                } catch let error as DeviceError {
                    if case .disconnected = error {
                        self.handleDeviceError(error)
                    } else if self.previewingNode?.id == node.id {
                        self.previewError = error.localizedDescription
                    }
                } catch {
                    if self.previewingNode?.id == node.id {
                        self.previewError = error.localizedDescription
                    }
                }
            }
            previewLoadTask = task
            await task.value
            return
        }

        // 视频、音频、文档及其他文件使用 macOS 系统 Quick Look 预览
        let cacheURL = previewCacheURL(for: node, deviceID: devID)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            QuickLookController.shared.present(url: cacheURL)
            return
        }

        infoBannerMessage = "正在准备预览：\(node.name)…"
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.downloadPreviewFile(node: node, to: cacheURL, session: session)
                guard !Task.isCancelled else { return }
                self.infoBannerMessage = nil
                QuickLookController.shared.present(url: cacheURL)
            } catch is CancellationError {
                self.infoBannerMessage = nil
            } catch let error as DeviceError {
                self.infoBannerMessage = nil
                if case .disconnected = error {
                    self.handleDeviceError(error)
                } else {
                    self.errorMessage = error.localizedDescription
                }
            } catch {
                self.infoBannerMessage = nil
                self.errorMessage = error.localizedDescription
            }
        }
        previewLoadTask = task
        await task.value
    }

    func closePreview() {
        previewLoadTask?.cancel()
        previewLoadTask = nil
        previewPrefetchTask?.cancel()
        previewPrefetchTask = nil
        previewingNode = nil
        previewLocalURL = nil
        previewFullImage = nil
        previewMetadata = nil
        previewProgress = 0
        previewError = nil
        isLoadingPreview = false
    }

    func previewAdjacentPhoto(step: Int) async {
        guard let current = previewingNode else { return }
        let photos = previewablePhotos
        guard let idx = photos.firstIndex(where: { $0.id == current.id }) else { return }
        let targetIdx = idx + step
        guard photos.indices.contains(targetIdx) else { return }
        await openPreview(for: photos[targetIdx])
    }

    func toggleSpacePreview() async {
        if previewingNode != nil {
            closePreview()
        } else if let target = selectedNodes.first(where: { !$0.isDirectory }) {
            await openPreview(for: target)
        }
    }

    func setTransferPrioritized(_ active: Bool) async {
        await thumbnailPipeline.setTransferPrioritized(active)
    }

    /// 在当前目录创建新文件夹；成功返回 nil，失败返回可读错误消息。
    func createDirectory(name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalidReason = PathUtils.validateAndroidFilename(trimmed) {
            return invalidReason
        }
        guard let session = activeSession, let storageID = activeStorageID else {
            return DeviceError.disconnected.localizedDescription
        }
        let targetDir = effectiveUploadDirectory
        do {
            try await session.makeDirectory(trimmed, in: targetDir, storage: storageID)
            await refreshStorages()
            await loadActiveSection(forceRefreshMedia: isMediaMode)
            return nil
        } catch let error as DeviceError {
            if case .disconnected = error {
                handleDeviceError(error)
            }
            return error.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// 批量删除指定远端节点，并刷新当前视图。
    func deleteNodes(_ nodesToDelete: [RemoteNode]) async {
        guard !nodesToDelete.isEmpty else { return }
        guard let session = activeSession else {
            errorMessage = DeviceError.disconnected.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            for node in nodesToDelete {
                try await session.delete(node)
                selectedNodeIDs.remove(node.id)
                thumbnailCache.removeValue(forKey: node.id)
                loadingThumbnails.remove(node.id)
                failedThumbnails.remove(node.id)
                if previewingNode?.id == node.id {
                    closePreview()
                }
            }
            if let deviceID = activeDeviceID?.rawValue, let storageID = nodesToDelete.first?.storageID {
                await mediaIndexStore.removeMedia(
                    deviceID: deviceID,
                    storage: storageID,
                    paths: nodesToDelete.map(\.path)
                )
            }
            await refreshStorages()
            await loadActiveSection(forceRefreshMedia: true)
        } catch let error as DeviceError {
            if case .disconnected = error {
                handleDeviceError(error)
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to path: String) async {
        let normalized = PathUtils.normalize(path)
        if normalized != currentPath {
            backStack.append(currentPath)
            forwardStack.removeAll()
            currentPath = normalized
        }
        selectedNodeIDs.removeAll()
        await loadDirectory(path: normalized)
    }

    func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        currentPath = previous
        selectedNodeIDs.removeAll()
        await loadDirectory(path: previous)
    }

    func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        currentPath = next
        selectedNodeIDs.removeAll()
        await loadDirectory(path: next)
    }

    func selectStorage(_ id: UInt32) async {
        guard id != selectedStorageID else { return }
        selectedStorageID = id
        backStack.removeAll()
        forwardStack.removeAll()
        selectedNodeIDs.removeAll()
        hasLoadedMedia = false
        mediaNodes = []
        currentPath = "/"
        await loadActiveSection(forceRefreshMedia: true)
    }

    func reload() async {
        await refreshStorages()
        guard selectedSidebar != .transfers else { return }
        await loadActiveSection(forceRefreshMedia: true)
    }

    /// 轻量刷新存储卷容量统计（`GetStorageInfo` / `df`），供传输期间或操作后实时更新左下角可用空间。
    func refreshStorages() async {
        guard let session = activeSession,
              let expectedDeviceID = activeDeviceID,
              !isDeviceLocked else {
            return
        }
        do {
            let fetched = try await session.storages()
            guard activeDeviceID == expectedDeviceID, !fetched.isEmpty else { return }
            storages = fetched
            if selectedStorageID == nil || !fetched.contains(where: { $0.id == selectedStorageID }) {
                selectedStorageID = fetched.first?.id
            }
        } catch let error as DeviceError {
            if case .disconnected = error {
                handleDeviceError(error)
            }
        } catch {
            return
        }
    }

    func toggleSelection(_ nodeID: String, additive: Bool) {
        if additive {
            if selectedNodeIDs.contains(nodeID) {
                selectedNodeIDs.remove(nodeID)
            } else {
                selectedNodeIDs.insert(nodeID)
            }
        } else {
            selectedNodeIDs = [nodeID]
        }
    }

    func selectAllVisible() {
        selectedNodeIDs = Set(filteredNodes.map(\.id))
    }

    func clearSelection() {
        selectedNodeIDs.removeAll()
    }

    func thumbnailData(for node: RemoteNode) -> Data? {
        thumbnailCache[node.id]
    }

    /// 零等待同步读取内存已解码缩略图，避免网格滚动期间反复触发全表重绘与主线程 JPEG 解码。
    func cachedThumbnailImage(for node: RemoteNode) -> NSImage? {
        guard !node.isDirectory, node.kind == .photo || node.kind == .video else {
            return nil
        }
        let deviceKey = activeDeviceID?.rawValue ?? "default"
        return thumbnailPipeline.memoryCachedImage(for: node, deviceID: deviceKey)
    }

    /// 仅供独立单元格调用的异步缩略图加载（命中内存/磁盘秒出；设备请求走 LIFO 最新可见优先调度）。
    func loadThumbnailImage(for node: RemoteNode) async -> NSImage? {
        guard !node.isDirectory,
              node.kind == .photo || node.kind == .video,
              !failedThumbnails.contains(node.id),
              let session = activeSession else {
            return nil
        }
        let expectedDeviceID = activeDeviceID
        let deviceKey = expectedDeviceID?.rawValue ?? "default"
        if let hit = thumbnailPipeline.memoryCachedImage(for: node, deviceID: deviceKey) {
            return hit
        }

        do {
            if let img = try await thumbnailPipeline.thumbnailImage(for: node, deviceID: deviceKey, session: session) {
                guard activeDeviceID == expectedDeviceID else { return nil }
                return img
            } else {
                failedThumbnails.insert(node.id)
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch let error as DeviceError {
            if case .disconnected = error {
                handleDeviceError(error)
            } else {
                failedThumbnails.insert(node.id)
            }
            return nil
        } catch {
            failedThumbnails.insert(node.id)
            return nil
        }
    }

    func loadThumbnailIfNeeded(for node: RemoteNode) async {
        guard !node.isDirectory,
              node.kind == .photo || node.kind == .video,
              thumbnailCache[node.id] == nil,
              !loadingThumbnails.contains(node.id),
              !failedThumbnails.contains(node.id),
              let session = activeSession else {
            return
        }
        let expectedDeviceID = activeDeviceID
        let deviceKey = expectedDeviceID?.rawValue ?? "default"
        if let memHit = thumbnailPipeline.memoryCachedThumbnail(for: node, deviceID: deviceKey) {
            thumbnailCache[node.id] = memHit
            return
        }

        loadingThumbnails.insert(node.id)
        defer { loadingThumbnails.remove(node.id) }

        do {
            if let data = try await thumbnailPipeline.thumbnail(for: node, deviceID: deviceKey, session: session),
               !data.isEmpty {
                guard activeDeviceID == expectedDeviceID else { return }
                thumbnailCache[node.id] = data
            } else {
                failedThumbnails.insert(node.id)
            }
        } catch is CancellationError {
            // 单元格滑出视口取消时不记失败，滚回时可继续加载
            return
        } catch let error as DeviceError {
            if case .disconnected = error {
                handleDeviceError(error)
            } else {
                failedThumbnails.insert(node.id)
            }
        } catch {
            failedThumbnails.insert(node.id)
        }
    }

    private func loadActiveSection(forceRefreshMedia: Bool) async {
        if isMediaMode {
            if !hasLoadedMedia || forceRefreshMedia {
                await loadMedia()
            }
        } else if selectedSidebar != .transfers {
            await loadDirectory(path: currentPath)
        }
    }

    private func loadMedia() async {
        guard let session = activeSession, let storageID = selectedStorageID ?? storages.first?.id else {
            mediaNodes = []
            return
        }
        selectedStorageID = storageID
        let devKey = activeDeviceID?.rawValue ?? "default"

        // 先读取本地 SQLite 媒体索引缓存以实现重连秒开
        if mediaNodes.isEmpty {
            let cached = await mediaIndexStore.loadMedia(deviceID: devKey, storage: storageID, limit: 5000)
            if !cached.isEmpty {
                mediaNodes = cached
            }
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let liveNodes = try await session.listMedia(storage: storageID, limit: 600)
            mediaNodes = liveNodes
            hasLoadedMedia = true
            await mediaIndexStore.syncMedia(deviceID: devKey, storage: storageID, nodes: liveNodes)
        } catch let error as DeviceError {
            handleDeviceError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadPreviewWithProgress(node: RemoteNode, to destURL: URL, session: DeviceSession) async throws {
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partURL = URL(fileURLWithPath: destURL.path + ".droiddock-part")
        try? FileManager.default.removeItem(at: partURL)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: partURL)
            }
        }
        let expectedSize = max(UInt64(1), node.size)
        let nodeID = node.id
        try await session.download(node, to: partURL) { [weak self] transferred in
            let ratio = min(0.99, Double(transferred) / Double(expectedSize))
            Task { @MainActor [weak self] in
                guard let self, self.previewingNode?.id == nodeID else { return }
                if ratio - self.previewProgress >= 0.02 || transferred >= expectedSize {
                    self.previewProgress = ratio
                }
            }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destURL.path) {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: partURL)
        } else {
            try FileManager.default.moveItem(at: partURL, to: destURL)
        }
        succeeded = true
        Self.prunePreviewCacheIfNeeded(excludingURL: destURL)
    }

    private func scheduleAdjacentPreviewPrefetch(after node: RemoteNode, deviceID: String, session: DeviceSession) {
        let photos = previewablePhotos
        guard let idx = photos.firstIndex(where: { $0.id == node.id }),
              idx + 1 < photos.count else {
            return
        }
        let nextNode = photos[idx + 1]
        let nextURL = previewCacheURL(for: nextNode, deviceID: deviceID)
        guard !FileManager.default.fileExists(atPath: nextURL.path) else { return }

        previewPrefetchTask?.cancel()
        previewPrefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.previewingNode?.id == node.id,
                  self.activeDeviceID?.rawValue ?? "default" == deviceID else {
                return
            }
            try? await self.downloadPreviewFile(node: nextNode, to: nextURL, session: session)
        }
    }

    private static func decodeHighResImageAndMetadata(
        from url: URL,
        node: RemoteNode
    ) async -> (image: NSImage?, metadata: PhotoMetadata) {
        await Task.detached(priority: .userInitiated) {
            let metadata = PhotoMetadata.extract(from: url, node: node, isOriginal: true)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let decodeOptions: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 6144,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    return (image, metadata)
                }
            }
            return (NSImage(contentsOf: url), metadata)
        }.value
    }

    private func downloadPreviewFile(node: RemoteNode, to destURL: URL, session: DeviceSession) async throws {
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partURL = URL(fileURLWithPath: destURL.path + ".droiddock-part")
        try? FileManager.default.removeItem(at: partURL)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: partURL)
            }
        }
        try await session.download(node, to: partURL) { _ in }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destURL.path) {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: partURL)
        } else {
            try FileManager.default.moveItem(at: partURL, to: destURL)
        }
        succeeded = true
        Self.prunePreviewCacheIfNeeded(excludingURL: destURL)
    }

    private static let maxPreviewCacheBytes: UInt64 = 512 * 1024 * 1024

    private static func previewCacheDirectory() -> URL {
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesRoot
            .appendingPathComponent("com.droiddock.app", isDirectory: true)
            .appendingPathComponent("PreviewCache", isDirectory: true)
    }

    private func previewCacheURL(for node: RemoteNode, deviceID: String) -> URL {
        let safeDevice = deviceID.replacingOccurrences(of: ":", with: "_")
        let safeID = node.id.replacingOccurrences(of: ":", with: "_")
        return Self.previewCacheDirectory()
            .appendingPathComponent("\(safeDevice)_\(safeID)_\(node.size)_\(node.name)")
    }

    private static func prunePreviewCacheIfNeeded(excludingURL: URL? = nil) {
        let dir = previewCacheDirectory()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct CachedPreview {
            let url: URL
            let modified: Date
            let size: UInt64
        }

        var files: [CachedPreview] = []
        var totalSize: UInt64 = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let modified = values.contentModificationDate ?? .distantPast
            files.append(CachedPreview(url: url, modified: modified, size: size))
            totalSize += size
        }

        guard totalSize > maxPreviewCacheBytes else { return }
        files.sort { $0.modified < $1.modified }
        for item in files {
            guard totalSize > maxPreviewCacheBytes else { break }
            if let excludingURL, item.url == excludingURL { continue }
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                totalSize = totalSize >= item.size ? totalSize - item.size : 0
            }
        }
    }

    private func loadDirectory(path: String) async {
        guard let session = activeSession, let storageID = selectedStorageID ?? storages.first?.id else {
            nodes = []
            return
        }
        selectedStorageID = storageID
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            nodes = try await session.list(dir: path, storage: storageID)
        } catch let error as DeviceError {
            handleDeviceError(error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleDeviceError(_ error: DeviceError) {
        switch error {
        case .deviceLocked:
            isDeviceLocked = true
            nodes = []
            mediaNodes = []
        case .disconnected:
            let failedID = activeDeviceID
            resetForDisconnectedOrLocked(locked: false)
            errorMessage = error.localizedDescription
            if let failedID {
                onDisconnect?(failedID)
            }
        default:
            nodes = []
            errorMessage = error.localizedDescription
        }
    }

    private static func isScreenshot(_ node: RemoteNode) -> Bool {
        node.path.localizedCaseInsensitiveContains("Screenshot")
            || node.name.localizedCaseInsensitiveContains("Screenshot")
            || node.name.contains("截图")
    }
}
