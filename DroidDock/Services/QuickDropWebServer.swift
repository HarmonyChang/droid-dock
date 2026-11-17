import AppKit
import AVFoundation
import Darwin
import Foundation
import ImageIO
import Network
import Observation
import UniformTypeIdentifiers

/// 扫码快传可预览媒体条目（单个照片/视频或投送文件夹内的媒体）。
struct QuickDropSharedMediaEntry: Identifiable, Sendable, Equatable {
    let id: String
    let filename: String
    let relativePath: String
    let localURL: URL
    let sizeBytes: UInt64
    let kind: MediaKind
}

/// 扫码快传已接收文件记录。
struct QuickDropReceivedItem: Identifiable, Sendable, Equatable {
    let id: String
    let filename: String
    let localURL: URL
    let sizeBytes: UInt64
    let receivedAt: Date
}

/// 从 Mac 投送给手机网页端下载的文件或文件夹条目。
struct QuickDropSharedItem: Identifiable, Sendable, Equatable {
    let id: String
    let filename: String
    let localURL: URL
    let sizeBytes: UInt64
    let isDirectory: Bool
    let itemCount: Int
    let mediaEntries: [QuickDropSharedMediaEntry]
}

/// 面向新手用户的内建局域网「扫码快传」HTTP 服务：免装 App、免开开发者选项，同 Wi-Fi 扫码即互传且手机不断网。
@MainActor
@Observable
final class QuickDropWebServer {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var lanIPAddress: String?
    private(set) var serverURLString: String?
    private(set) var qrImage: NSImage?
    private(set) var statusMessage: String = "正在启动扫码快传服务…"
    private(set) var receivedItems: [QuickDropReceivedItem] = []
    private(set) var sharedItems: [QuickDropSharedItem] = []
    private(set) var activeReceivingFilename: String?
    let receiveDirectoryURL: URL

    private(set) var token: String = QuickDropWebServer.generateToken()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "droiddock.quickdrop.http")
    private let snapshotBox = QuickDropServerSnapshotBox()

    init(receiveDirectoryURL: URL? = nil) {
        if let receiveDirectoryURL {
            self.receiveDirectoryURL = receiveDirectoryURL
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
            self.receiveDirectoryURL = downloads.appendingPathComponent("DroidDock-快传", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.receiveDirectoryURL, withIntermediateDirectories: true)
        syncSnapshotBox()
    }

    func start() {
        if listener != nil, isRunning {
            return
        }
        stop()

        do {
            try FileManager.default.createDirectory(at: receiveDirectoryURL, withIntermediateDirectories: true)
            let newListener = try NWListener(using: .tcp)
            let snapshotBox = self.snapshotBox
            newListener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(newState)
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                let connQueue = DispatchQueue(
                    label: "droiddock.quickdrop.conn.\(UUID().uuidString.prefix(8))",
                    qos: .userInitiated
                )
                let handler = QuickDropConnectionHandler(
                    connection: connection,
                    queue: connQueue,
                    snapshotBox: snapshotBox,
                    onReceiving: { [weak self] filename in
                        Task { @MainActor [weak self] in
                            self?.activeReceivingFilename = filename
                        }
                    },
                    onReceivedFile: { [weak self] item in
                        Task { @MainActor [weak self] in
                            self?.activeReceivingFilename = nil
                            self?.receivedItems.insert(item, at: 0)
                        }
                    },
                    onTransferEnded: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.activeReceivingFilename = nil
                        }
                    }
                )
                handler.start()
            }
            listener = newListener
            newListener.start(queue: queue)
            statusMessage = "正在获取局域网地址…"
        } catch {
            isRunning = false
            statusMessage = "启动扫码快传失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        snapshotBox.cancelAllHandlers()
        snapshotBox.cleanupTemporaryArchives()
        isRunning = false
        port = 0
        serverURLString = nil
        activeReceivingFilename = nil
    }

    func refreshTokenAndQR() {
        token = Self.generateToken()
        syncSnapshotBox()
        rebuildQRAndURL()
    }

    func addSharedFiles(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            if sharedItems.contains(where: { $0.localURL == url }) {
                continue
            }
            let item = Self.buildSharedItem(for: url, isDirectory: isDir.boolValue)
            sharedItems.append(item)
        }
        syncSnapshotBox()
    }

    func removeSharedFile(_ id: String) {
        if let removed = sharedItems.first(where: { $0.id == id }) {
            snapshotBox.invalidateCaches(
                itemID: id,
                mediaIDs: removed.mediaEntries.map(\.id)
            )
        }
        sharedItems.removeAll { $0.id == id }
        syncSnapshotBox()
    }

    func clearReceivedRecords() {
        receivedItems.removeAll()
    }

    func openReceiveDirectoryInFinder() {
        try? FileManager.default.createDirectory(at: receiveDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(receiveDirectoryURL)
    }

    func revealItemInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            isRunning = true
            port = listener?.port?.rawValue ?? 0
            rebuildQRAndURL()
        case .failed(let error):
            isRunning = false
            statusMessage = "局域网快传监听失败：\(error.localizedDescription)"
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func rebuildQRAndURL() {
        let ip = Self.primaryLANIPv4Address()
        lanIPAddress = ip
        guard isRunning, port > 0, let ip else {
            serverURLString = nil
            qrImage = nil
            statusMessage = ip == nil ? "未检测到 Wi-Fi 局域网 IP，请先将 Mac 连接到 Wi-Fi" : "正在准备快传服务…"
            return
        }
        let urlString = "http://\(ip):\(port)/?t=\(token)"
        serverURLString = urlString
        qrImage = ADBDiscoveryService.renderQRCode(from: urlString)
        statusMessage = "同一 Wi-Fi 下手机扫码即可互传（手机保持正常上网）"
    }

    private func syncSnapshotBox() {
        snapshotBox.update(
            token: token,
            receiveDir: receiveDirectoryURL,
            sharedItems: sharedItems
        )
    }

    // MARK: - 网络与请求解析辅助

    nonisolated static func generateToken() -> String {
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz")
        return String((0..<10).compactMap { _ in alphabet.randomElement() })
    }

    /// 优先返回 `en0`/`en1` 等 Wi-Fi / 以太网物理网卡的私有 IPv4 地址。
    nonisolated static func primaryLANIPv4Address() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return nil
        }
        defer { freeifaddrs(firstAddr) }

        var preferredWiFi: String?
        var fallbackPrivate: String?
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let ptr = current {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp, !isLoopback, let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("utun") && !name.hasPrefix("awdl") && !name.hasPrefix("llw") {
                    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if let cStr = withUnsafePointer(to: &addr.sin_addr, { sinPtr in
                        inet_ntop(AF_INET, sinPtr, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
                    }) {
                        let ip = String(cString: cStr)
                        if isPrivateLANIPv4(ip) {
                            if name == "en0" || name == "en1" {
                                preferredWiFi = preferredWiFi ?? ip
                            } else {
                                fallbackPrivate = fallbackPrivate ?? ip
                            }
                        }
                    }
                }
            }
            current = interface.ifa_next
        }
        return preferredWiFi ?? fallbackPrivate
    }

    nonisolated static func isPrivateLANIPv4(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") {
            return true
        }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    nonisolated static func parseHTTPHeaderBlock(_ headerText: String) -> (method: String, target: String, headers: [String: String])? {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
        return (parts[0].uppercased(), parts[1], headers)
    }

    nonisolated static func sanitizeReceivedFilename(_ rawName: String) -> String {
        let decoded = rawName.removingPercentEncoding ?? rawName
        let base = URL(fileURLWithPath: decoded).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        let cleaned = base.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "file_\(Int(Date().timeIntervalSince1970))"
        }
        return cleaned
    }

    nonisolated static func sanitizeRelativeSubpath(_ rawSubpath: String?) -> [String] {
        guard let rawSubpath, !rawSubpath.isEmpty else { return [] }
        let forbidden = CharacterSet(charactersIn: ":*?\"<>|\0")
        let segments = rawSubpath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { seg -> String in
                String(seg)
                    .components(separatedBy: forbidden)
                    .joined(separator: "_")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return Array(segments.prefix(12))
    }

    private static func buildSharedItem(for url: URL, isDirectory: Bool) -> QuickDropSharedItem {
        let itemID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        if !isDirectory {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let kind = PathUtils.inferMediaKind(filename: url.lastPathComponent)
            let mediaEntries: [QuickDropSharedMediaEntry]
            if kind == .photo || kind == .video {
                mediaEntries = [QuickDropSharedMediaEntry(
                    id: UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                    filename: url.lastPathComponent,
                    relativePath: url.lastPathComponent,
                    localURL: url,
                    sizeBytes: size,
                    kind: kind
                )]
            } else {
                mediaEntries = []
            }
            return QuickDropSharedItem(
                id: itemID,
                filename: url.lastPathComponent,
                localURL: url,
                sizeBytes: size,
                isDirectory: false,
                itemCount: 1,
                mediaEntries: mediaEntries
            )
        }

        var totalBytes: UInt64 = 0
        var totalFiles = 0
        var collectedMedia: [(relPath: String, fileURL: URL, size: UInt64, kind: MediaKind)] = []
        let basePathPrefix = url.path.hasSuffix("/") ? url.path : (url.path + "/")

        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let size = UInt64(max(0, values?.fileSize ?? 0))
                totalBytes += size
                totalFiles += 1

                let relPath = fileURL.path.hasPrefix(basePathPrefix)
                    ? String(fileURL.path.dropFirst(basePathPrefix.count))
                    : fileURL.lastPathComponent
                let kind = PathUtils.inferMediaKind(filename: fileURL.lastPathComponent)
                if kind == .photo || kind == .video {
                    collectedMedia.append((relPath, fileURL, size, kind))
                }
            }
        }

        collectedMedia.sort { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
        let mediaEntries = collectedMedia.prefix(120).map { entry in
            QuickDropSharedMediaEntry(
                id: UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                filename: entry.fileURL.lastPathComponent,
                relativePath: entry.relPath,
                localURL: entry.fileURL,
                sizeBytes: entry.size,
                kind: entry.kind
            )
        }

        return QuickDropSharedItem(
            id: itemID,
            filename: url.lastPathComponent,
            localURL: url,
            sizeBytes: totalBytes,
            isDirectory: true,
            itemCount: totalFiles,
            mediaEntries: mediaEntries
        )
    }
}

private final class QuickDropServerSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private let tempRootDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DroidDockQuickDrop-\(UUID().uuidString)", isDirectory: true)
    private var token = ""
    private var receiveDir = FileManager.default.temporaryDirectory
    private var sharedItems: [QuickDropSharedItem] = []
    private var mediaLookup: [String: QuickDropSharedMediaEntry] = [:]
    private var thumbCache: [String: Data] = [:]
    private var zipCache: [String: URL] = [:]
    private var activeHandlers: [UUID: QuickDropConnectionHandler] = [:]

    deinit {
        try? FileManager.default.removeItem(at: tempRootDir)
    }

    func update(token: String, receiveDir: URL, sharedItems: [QuickDropSharedItem]) {
        var lookup: [String: QuickDropSharedMediaEntry] = [:]
        for item in sharedItems {
            for media in item.mediaEntries {
                lookup[media.id] = media
            }
        }
        lock.lock()
        self.token = token
        self.receiveDir = receiveDir
        self.sharedItems = sharedItems
        self.mediaLookup = lookup
        lock.unlock()
    }

    func snapshot() -> (token: String, receiveDir: URL, sharedItems: [QuickDropSharedItem]) {
        lock.lock()
        defer { lock.unlock() }
        return (token, receiveDir, sharedItems)
    }

    func mediaEntry(for id: String) -> QuickDropSharedMediaEntry? {
        lock.lock()
        defer { lock.unlock() }
        return mediaLookup[id]
    }

    func cachedThumbnail(for mediaID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return thumbCache[mediaID]
    }

    func storeThumbnail(_ data: Data, for mediaID: String) {
        lock.lock()
        if thumbCache.count >= 240, let oldest = thumbCache.keys.first {
            thumbCache.removeValue(forKey: oldest)
        }
        thumbCache[mediaID] = data
        lock.unlock()
    }

    func cachedZipURL(for itemID: String) -> URL? {
        lock.lock()
        let url = zipCache[itemID]
        lock.unlock()
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func storeZipURL(_ url: URL, for itemID: String) {
        lock.lock()
        let previous = zipCache.updateValue(url, forKey: itemID)
        lock.unlock()
        if let previous, previous != url {
            try? FileManager.default.removeItem(at: previous)
        }
    }

    func ensureTempRootDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: tempRootDir, withIntermediateDirectories: true)
        return tempRootDir
    }

    func invalidateCaches(itemID: String, mediaIDs: [String]) {
        lock.lock()
        let zipURL = zipCache.removeValue(forKey: itemID)
        for mediaID in mediaIDs {
            thumbCache.removeValue(forKey: mediaID)
        }
        lock.unlock()
        if let zipURL {
            try? FileManager.default.removeItem(at: zipURL)
        }
    }

    func cleanupTemporaryArchives() {
        lock.lock()
        let oldZips = Array(zipCache.values)
        zipCache.removeAll()
        thumbCache.removeAll()
        lock.unlock()
        for url in oldZips {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: tempRootDir)
    }

    func registerHandler(_ handler: QuickDropConnectionHandler, id: UUID) {
        lock.lock()
        activeHandlers[id] = handler
        lock.unlock()
    }

    func unregisterHandler(id: UUID) {
        lock.lock()
        let removed = activeHandlers.removeValue(forKey: id)
        lock.unlock()
        _ = removed
    }

    func cancelAllHandlers() {
        lock.lock()
        let handlers = Array(activeHandlers.values)
        activeHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler.forceClose()
        }
    }
}

private final class QuickDropConnectionHandler: @unchecked Sendable {
    private let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let snapshotBox: QuickDropServerSnapshotBox
    private let onReceiving: @Sendable (String) -> Void
    private let onReceivedFile: @Sendable (QuickDropReceivedItem) -> Void
    private let onTransferEnded: @Sendable () -> Void

    private var headerBuffer = Data()
    private var uploadState: ActiveUploadState?
    private var isClosed = false

    private struct ActiveUploadState {
        let filename: String
        let displayFilename: String
        let finalURL: URL
        let partURL: URL
        let handle: FileHandle
        let expectedBytes: Int64
        var receivedBytes: Int64
    }

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        snapshotBox: QuickDropServerSnapshotBox,
        onReceiving: @escaping @Sendable (String) -> Void,
        onReceivedFile: @escaping @Sendable (QuickDropReceivedItem) -> Void,
        onTransferEnded: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.snapshotBox = snapshotBox
        self.onReceiving = onReceiving
        self.onReceivedFile = onReceivedFile
        self.onTransferEnded = onTransferEnded
    }

    func start() {
        snapshotBox.registerHandler(self, id: id)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.closeConnection()
            } else if case .cancelled = state {
                self?.closeConnection()
            }
        }
        connection.start(queue: queue)
        receiveHeaderLoop()
    }

    func forceClose() {
        queue.async { [weak self] in
            self?.closeConnection()
        }
    }

    private func receiveHeaderLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Log.transfer.error("QuickDrop 读取请求头失败：\(error.localizedDescription, privacy: .public)")
                self.closeConnection()
                return
            }
            if let data, !data.isEmpty {
                self.headerBuffer.append(data)
            }
            let delimiter = Data("\r\n\r\n".utf8)
            if let range = self.headerBuffer.range(of: delimiter) {
                let headerData = self.headerBuffer.subdata(in: self.headerBuffer.startIndex..<range.lowerBound)
                let bodyPrefix = Data(self.headerBuffer.suffix(from: range.upperBound))
                self.headerBuffer.removeAll(keepingCapacity: false)
                self.handleParsedRequest(headerData: headerData, initialBody: bodyPrefix)
                return
            }
            if self.headerBuffer.count > 64 * 1024 {
                self.sendTextResponse(status: "431 Request Header Fields Too Large", body: "Header too large")
                return
            }
            if isComplete {
                self.closeConnection()
                return
            }
            self.receiveHeaderLoop()
        }
    }

    private func handleParsedRequest(headerData: Data, initialBody: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8),
              let parsed = QuickDropWebServer.parseHTTPHeaderBlock(headerText),
              let components = URLComponents(string: "http://localhost" + parsed.target) else {
            sendTextResponse(status: "400 Bad Request", body: "Invalid request")
            return
        }

        if parsed.method == "GET" && components.path == "/favicon.ico" {
            sendResponse(status: "204 No Content", contentType: "image/x-icon", body: Data())
            return
        }

        let snap = snapshotBox.snapshot()
        let providedToken = components.queryItems?.first(where: { $0.name == "t" })?.value ?? ""
        guard providedToken == snap.token else {
            sendTextResponse(status: "403 Forbidden", body: "访问令牌无效或已刷新，请重新扫描 Mac 上的最新二维码。")
            return
        }

        switch (parsed.method, components.path) {
        case ("GET", "/"):
            let html = Self.mobileWebHTML(token: snap.token)
            sendResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))

        case ("GET", "/api/shared"):
            let payload = snap.sharedItems.map { item -> [String: Any] in
                let itemKind: String
                if item.isDirectory {
                    itemKind = "folder"
                } else {
                    switch PathUtils.inferMediaKind(filename: item.filename) {
                    case .photo: itemKind = "photo"
                    case .video: itemKind = "video"
                    default: itemKind = "file"
                    }
                }
                let mediaList = item.mediaEntries.map { media -> [String: Any] in
                    [
                        "id": media.id,
                        "filename": media.filename,
                        "relativePath": media.relativePath,
                        "sizeBytes": media.sizeBytes,
                        "kind": media.kind == .video ? "video" : "photo",
                    ]
                }
                return [
                    "id": item.id,
                    "filename": item.filename,
                    "sizeBytes": item.sizeBytes,
                    "isDirectory": item.isDirectory,
                    "itemCount": item.itemCount,
                    "kind": itemKind,
                    "mediaItems": mediaList,
                ]
            }
            let jsonData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
            sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: jsonData)

        case ("GET", let path) where path.hasPrefix("/api/thumb/"):
            let mediaID = String(path.dropFirst("/api/thumb/".count))
            handleThumbnailRequest(mediaID: mediaID)

        case ("GET", let path) where path.hasPrefix("/api/media/"):
            let mediaID = String(path.dropFirst("/api/media/".count))
            let forceDownload = components.queryItems?.first(where: { $0.name == "dl" })?.value == "1"
            handleMediaRequest(mediaID: mediaID, forceDownload: forceDownload, rangeHeader: parsed.headers["range"])

        case ("GET", let path) where path.hasPrefix("/api/download/"):
            let itemID = String(path.dropFirst("/api/download/".count))
            guard let item = snap.sharedItems.first(where: { $0.id == itemID }) else {
                sendTextResponse(status: "404 Not Found", body: "文件不存在或已被移除")
                return
            }
            handleDownloadRequest(item: item, rangeHeader: parsed.headers["range"])

        case ("POST", "/api/upload"):
            let rawName = components.queryItems?.first(where: { $0.name == "name" })?.value ?? "upload.bin"
            let rawSubpath = components.queryItems?.first(where: { $0.name == "subpath" })?.value
            let cleanName = QuickDropWebServer.sanitizeReceivedFilename(rawName)
            let subpathSegments = QuickDropWebServer.sanitizeRelativeSubpath(rawSubpath)
            guard let clStr = parsed.headers["content-length"],
                  let contentLength = Int64(clStr),
                  contentLength >= 0 else {
                sendTextResponse(status: "411 Length Required", body: "Missing Content-Length")
                return
            }
            if parsed.headers["expect"]?.lowercased().contains("100-continue") == true {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            beginUpload(
                filename: cleanName,
                subpathSegments: subpathSegments,
                contentLength: contentLength,
                initialBody: initialBody,
                receiveDir: snap.receiveDir
            )

        default:
            sendTextResponse(status: "404 Not Found", body: "Not Found")
        }
    }

    private func beginUpload(
        filename: String,
        subpathSegments: [String],
        contentLength: Int64,
        initialBody: Data,
        receiveDir: URL
    ) {
        do {
            var targetDir = receiveDir
            for segment in subpathSegments {
                targetDir.appendPathComponent(segment, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: targetDir.path)) ?? [])
            let resolution = PathUtils.resolveConflictDestination(name: filename, existingNames: existing, strategy: .rename)
            let resolvedName: String
            switch resolution {
            case .proceed(let finalName, _):
                resolvedName = finalName
            case .skip:
                resolvedName = filename
            }

            let displayFilename = subpathSegments.isEmpty
                ? resolvedName
                : (subpathSegments + [resolvedName]).joined(separator: "/")
            let finalURL = targetDir.appendingPathComponent(resolvedName)
            let partURL = URL(fileURLWithPath: finalURL.path + ".droiddock-part")
            try? FileManager.default.removeItem(at: partURL)
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                sendTextResponse(status: "500 Internal Server Error", body: "无法创建接收文件")
                return
            }
            let handle = try FileHandle(forWritingTo: partURL)
            var state = ActiveUploadState(
                filename: resolvedName,
                displayFilename: displayFilename,
                finalURL: finalURL,
                partURL: partURL,
                handle: handle,
                expectedBytes: contentLength,
                receivedBytes: 0
            )
            onReceiving(displayFilename)

            if !initialBody.isEmpty, contentLength > 0 {
                let take = min(Int64(initialBody.count), contentLength)
                try handle.write(contentsOf: initialBody.prefix(Int(take)))
                state.receivedBytes += take
            }

            uploadState = state
            if state.receivedBytes >= contentLength {
                finalizeUpload()
            } else {
                continueReceivingUploadBody()
            }
        } catch {
            cleanupFailedUpload()
            sendTextResponse(status: "500 Internal Server Error", body: error.localizedDescription)
        }
    }

    private func continueReceivingUploadBody() {
        guard let state = uploadState else { return }
        let remaining = state.expectedBytes - state.receivedBytes
        if remaining <= 0 {
            finalizeUpload()
            return
        }
        let maxRead = Int(min(65536, remaining))
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRead) { [weak self] data, _, isComplete, error in
            guard let self, var currentState = self.uploadState else { return }
            if let error {
                Log.transfer.error("QuickDrop 接收上传块失败：\(error.localizedDescription, privacy: .public)")
                self.cleanupFailedUpload()
                self.closeConnection()
                return
            }
            if let data, !data.isEmpty {
                do {
                    let take = min(Int64(data.count), currentState.expectedBytes - currentState.receivedBytes)
                    try currentState.handle.write(contentsOf: data.prefix(Int(take)))
                    currentState.receivedBytes += take
                    self.uploadState = currentState
                } catch {
                    self.cleanupFailedUpload()
                    self.sendTextResponse(status: "500 Internal Server Error", body: error.localizedDescription)
                    return
                }
            }
            if currentState.receivedBytes >= currentState.expectedBytes {
                self.finalizeUpload()
            } else if isComplete {
                self.cleanupFailedUpload()
                self.sendTextResponse(status: "400 Bad Request", body: "连接提前断开，文件未接收完整")
            } else {
                self.continueReceivingUploadBody()
            }
        }
    }

    private func finalizeUpload() {
        guard let state = uploadState else { return }
        uploadState = nil
        do {
            try state.handle.close()
            try FileManager.default.moveItem(at: state.partURL, to: state.finalURL)
            let attrs = try? FileManager.default.attributesOfItem(atPath: state.finalURL.path)
            let finalSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? UInt64(max(0, state.receivedBytes))
            onReceivedFile(QuickDropReceivedItem(
                id: UUID().uuidString,
                filename: state.displayFilename,
                localURL: state.finalURL,
                sizeBytes: finalSize,
                receivedAt: Date()
            ))
            let respObj: [String: Any] = ["ok": true, "filename": state.displayFilename, "sizeBytes": finalSize]
            let json = (try? JSONSerialization.data(withJSONObject: respObj)) ?? Data("{\"ok\":true}".utf8)
            sendResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: json)
        } catch {
            try? FileManager.default.removeItem(at: state.partURL)
            onTransferEnded()
            sendTextResponse(status: "500 Internal Server Error", body: error.localizedDescription)
        }
    }

    private func cleanupFailedUpload() {
        guard let state = uploadState else { return }
        uploadState = nil
        try? state.handle.close()
        try? FileManager.default.removeItem(at: state.partURL)
        onTransferEnded()
    }

    private func handleThumbnailRequest(mediaID: String) {
        guard let entry = snapshotBox.mediaEntry(for: mediaID) else {
            sendTextResponse(status: "404 Not Found", body: "缩略图不存在")
            return
        }
        if let cached = snapshotBox.cachedThumbnail(for: mediaID) {
            sendResponse(status: "200 OK", contentType: "image/jpeg", body: cached, cacheControl: "private, max-age=3600")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let thumbData = await Self.generateThumbnailData(for: entry)
            self.queue.async { [weak self] in
                guard let self, !self.isClosed else { return }
                if let thumbData {
                    self.snapshotBox.storeThumbnail(thumbData, for: mediaID)
                    self.sendResponse(status: "200 OK", contentType: "image/jpeg", body: thumbData, cacheControl: "private, max-age=3600")
                } else {
                    self.sendTextResponse(status: "415 Unsupported Media Type", body: "无法生成预览缩略图")
                }
            }
        }
    }

    private func handleMediaRequest(mediaID: String, forceDownload: Bool, rangeHeader: String?) {
        guard let entry = snapshotBox.mediaEntry(for: mediaID),
              let size = Self.fileSize(at: entry.localURL),
              let handle = try? FileHandle(forReadingFrom: entry.localURL) else {
            sendTextResponse(status: "404 Not Found", body: "媒体文件不存在或已被移除")
            return
        }
        let mimeType = Self.mimeType(for: entry.localURL)
        streamFile(
            filename: entry.filename,
            totalSize: size,
            contentType: mimeType,
            inline: !forceDownload,
            handle: handle,
            rangeHeader: rangeHeader
        )
    }

    private func handleDownloadRequest(item: QuickDropSharedItem, rangeHeader: String?) {
        if !item.isDirectory {
            guard let size = Self.fileSize(at: item.localURL),
                  let handle = try? FileHandle(forReadingFrom: item.localURL) else {
                sendTextResponse(status: "404 Not Found", body: "文件不存在或已被移除")
                return
            }
            streamFile(
                filename: item.filename,
                totalSize: size,
                contentType: "application/octet-stream",
                inline: false,
                handle: handle,
                rangeHeader: rangeHeader
            )
            return
        }

        if let cachedZip = snapshotBox.cachedZipURL(for: item.id),
           let zipSize = Self.fileSize(at: cachedZip),
           let handle = try? FileHandle(forReadingFrom: cachedZip) {
            streamFile(
                filename: "\(item.filename).zip",
                totalSize: zipSize,
                contentType: "application/zip",
                inline: false,
                handle: handle,
                rangeHeader: rangeHeader
            )
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let zipURL = try self.createFolderZipArchive(for: item)
                let zipSize = Self.fileSize(at: zipURL) ?? 0
                let handle = try FileHandle(forReadingFrom: zipURL)
                self.queue.async { [weak self] in
                    guard let self, !self.isClosed else {
                        try? handle.close()
                        return
                    }
                    self.streamFile(
                        filename: "\(item.filename).zip",
                        totalSize: zipSize,
                        contentType: "application/zip",
                        inline: false,
                        handle: handle,
                        rangeHeader: rangeHeader
                    )
                }
            } catch {
                self.queue.async { [weak self] in
                    self?.sendTextResponse(status: "500 Internal Server Error", body: "文件夹打包失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func createFolderZipArchive(for item: QuickDropSharedItem) throws -> URL {
        if let cached = snapshotBox.cachedZipURL(for: item.id) {
            return cached
        }
        let tempRoot = try snapshotBox.ensureTempRootDirectory()
        let safeBase = QuickDropWebServer.sanitizeReceivedFilename(item.filename)
        let partZip = tempRoot.appendingPathComponent("\(item.id)-\(UUID().uuidString).zip.part")
        let finalZip = tempRoot.appendingPathComponent("\(item.id)-\(safeBase).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", item.localURL.path, partZip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: partZip.path) else {
            try? FileManager.default.removeItem(at: partZip)
            throw DeviceError.underlying("压缩目录失败（退出码 \(process.terminationStatus)）")
        }

        try? FileManager.default.removeItem(at: finalZip)
        try FileManager.default.moveItem(at: partZip, to: finalZip)
        snapshotBox.storeZipURL(finalZip, for: item.id)
        return finalZip
    }

    private func streamFile(
        filename: String,
        totalSize: UInt64,
        contentType: String,
        inline: Bool,
        handle: FileHandle,
        rangeHeader: String?
    ) {
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let disposition = "\(inline ? "inline" : "attachment"); filename*=UTF-8''\(encodedName)"

        let byteRange = Self.parseByteRange(rangeHeader, totalSize: totalSize)
        let statusLine: String
        let startOffset: UInt64
        let lengthToSend: UInt64
        var extraHeaders: [String] = []

        if let byteRange {
            statusLine = "HTTP/1.1 206 Partial Content"
            startOffset = byteRange.lowerBound
            lengthToSend = byteRange.upperBound - byteRange.lowerBound + 1
            extraHeaders.append("Content-Range: bytes \(byteRange.lowerBound)-\(byteRange.upperBound)/\(totalSize)")
            do {
                try handle.seek(toOffset: startOffset)
            } catch {
                try? handle.close()
                sendTextResponse(status: "500 Internal Server Error", body: "读取文件定位失败")
                return
            }
        } else {
            statusLine = "HTTP/1.1 200 OK"
            startOffset = 0
            lengthToSend = totalSize
        }

        var headerLines = [
            statusLine,
            "Content-Type: \(contentType)",
            "Content-Length: \(lengthToSend)",
            "Accept-Ranges: bytes",
            "Content-Disposition: \(disposition)",
        ]
        headerLines.append(contentsOf: extraHeaders)
        headerLines.append("Connection: close")
        headerLines.append("")
        headerLines.append("")
        let header = headerLines.joined(separator: "\r\n")

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                self?.closeConnection()
                return
            }
            self.sendNextDownloadChunk(handle: handle, remaining: lengthToSend)
        })
    }

    private func sendNextDownloadChunk(handle: FileHandle, remaining: UInt64) {
        if remaining == 0 {
            try? handle.close()
            closeConnection()
            return
        }
        let maxRead = Int(min(65536, remaining))
        let chunk = (try? handle.read(upToCount: maxRead)) ?? Data()
        if chunk.isEmpty {
            try? handle.close()
            closeConnection()
            return
        }
        let nextRemaining = remaining >= UInt64(chunk.count) ? remaining - UInt64(chunk.count) : 0
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                self?.closeConnection()
                return
            }
            self.sendNextDownloadChunk(handle: handle, remaining: nextRemaining)
        })
    }

    private func sendTextResponse(status: String, body: String) {
        sendResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private func sendResponse(
        status: String,
        contentType: String,
        body: Data,
        cacheControl: String = "no-store"
    ) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: \(cacheControl)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var packet = Data(header.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection()
        })
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attrs[.size] as? NSNumber)?.uint64Value
    }

    private static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension),
           let mime = utType.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func parseByteRange(_ header: String?, totalSize: UInt64) -> ClosedRange<UInt64>? {
        guard totalSize > 0, let header = header?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let spec = String(header.dropFirst("bytes=".count)).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        guard let start = UInt64(parts[0]), start < totalSize else {
            return nil
        }
        let end: UInt64
        if parts[1].isEmpty {
            end = totalSize - 1
        } else if let parsedEnd = UInt64(parts[1]), parsedEnd >= start {
            end = min(parsedEnd, totalSize - 1)
        } else {
            return nil
        }
        return start...end
    }

    private static func generateThumbnailData(for entry: QuickDropSharedMediaEntry) async -> Data? {
        if entry.kind == .photo {
            guard let source = CGImageSourceCreateWithURL(entry.localURL as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        }

        let asset = AVURLAsset(url: entry.localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        let preferredTime = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let result = try? await generator.image(at: preferredTime) {
            let rep = NSBitmapImageRep(cgImage: result.image)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        }
        if let fallback = try? await generator.image(at: .zero) {
            let rep = NSBitmapImageRep(cgImage: fallback.image)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        }
        return nil
    }

    private func closeConnection() {
        guard !isClosed else { return }
        isClosed = true
        cleanupFailedUpload()
        snapshotBox.unregisterHandler(id: id)
        connection.cancel()
    }

    private static func mobileWebHTML(token: String) -> String {
        let escapedToken = token.replacingOccurrences(of: "\"", with: "")
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <title>DroidDock 扫码快传</title>
        <style>
          body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;background:#FBF9F5;color:#1D2228;margin:0;padding:18px;}
          .wrap{max-width:560px;margin:0 auto;}
          .hero{display:flex;align-items:center;gap:12px;margin-bottom:16px;}
          .badge{width:40px;height:40px;border-radius:11px;background:#355C7D;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:17px;}
          .card{background:#fff;border:1px solid #E2DDD3;border-radius:14px;padding:16px;margin-bottom:14px;box-shadow:0 2px 8px rgba(0,0,0,0.04);}
          h2{font-size:16px;margin:0 0 6px;}
          h3{font-size:13.5px;margin:12px 0 8px;color:#355C7D;}
          p.sub{font-size:13px;color:#616873;margin:0 0 12px;line-height:1.5;}
          .btns{display:flex;gap:8px;flex-wrap:wrap;}
          label.btn{flex:1;min-width:96px;text-align:center;padding:10px 10px;border-radius:10px;background:#355C7D;color:#fff;font-size:13.5px;font-weight:600;cursor:pointer;}
          label.btn.sec{background:#EAE6DD;color:#1D2228;}
          input[type=file]{display:none;}
          .prog-wrap{margin-top:12px;display:none;}
          progress{width:100%;height:8px;accent-color:#355C7D;}
          .status{font-size:12.5px;color:#616873;margin-top:6px;}
          .local-strip{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-top:10px;}
          .local-cell{position:relative;aspect-ratio:1/1;border-radius:8px;overflow:hidden;background:#EFECE3;}
          .local-cell img{width:100%;height:100%;object-fit:cover;display:block;}
          .album-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:7px;margin-bottom:10px;}
          .tile{position:relative;aspect-ratio:1/1;border-radius:10px;overflow:hidden;background:#EFECE3;cursor:pointer;}
          .tile img{width:100%;height:100%;object-fit:cover;display:block;}
          .vbadge{position:absolute;left:6px;bottom:6px;background:rgba(0,0,0,0.62);color:#fff;font-size:10.5px;padding:2px 6px;border-radius:5px;font-weight:600;}
          .item{display:flex;align-items:center;justify-content:space-between;padding:10px 0;border-top:1px solid #EFECE3;gap:10px;}
          .item:first-child{border-top:none;}
          .name{font-size:13.5px;font-weight:500;word-break:break-all;}
          .size{font-size:12px;color:#616873;margin-top:2px;}
          a.dl{padding:6px 12px;border-radius:8px;background:#E2E9F0;color:#355C7D;text-decoration:none;font-size:12.5px;font-weight:600;white-space:nowrap;}
          .lb{position:fixed;inset:0;background:rgba(15,18,22,0.94);z-index:999;display:none;flex-direction:column;justify-content:space-between;color:#fff;}
          .lb.open{display:flex;}
          .lb-top{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;font-size:13px;gap:10px;}
          .lb-body{flex:1;display:flex;align-items:center;justify-content:center;padding:8px;overflow:hidden;position:relative;}
          .lb-body img,.lb-body video{max-width:100%;max-height:76vh;border-radius:8px;object-fit:contain;}
          .lb-foot{display:flex;align-items:center;justify-content:space-between;padding:12px 16px 22px;gap:10px;}
          .lb-btn{border:none;border-radius:9px;padding:8px 14px;background:rgba(255,255,255,0.16);color:#fff;font-size:13px;font-weight:600;cursor:pointer;text-decoration:none;}
          .lb-btn.pri{background:#355C7D;}
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="hero">
            <div class="badge">D</div>
            <div>
              <div style="font-size:17px;font-weight:700;">DroidDock 扫码快传</div>
              <div style="font-size:12px;color:#616873;">同一 Wi-Fi 直连 Mac · 支持文件夹与相册预览 · 手机不断网</div>
            </div>
          </div>

          <div class="card">
            <h2>发送照片 / 视频 / 文件夹到 Mac</h2>
            <p class="sub">无需安装 App，支持批量发图或直接上传整个文件夹（自动保留目录结构到「下载 / DroidDock-快传」）。</p>
            <div class="btns">
              <label class="btn">选照片 / 视频<input id="mediaInput" type="file" accept="image/*,video/*" multiple></label>
              <label class="btn sec">选文件<input id="anyInput" type="file" multiple></label>
              <label class="btn sec">选文件夹<input id="dirInput" type="file" webkitdirectory directory multiple></label>
            </div>
            <div id="localPreviewGrid" class="local-strip" style="display:none;"></div>
            <div class="prog-wrap" id="progWrap">
              <progress id="progBar" value="0" max="100"></progress>
              <div class="status" id="uploadStatus">准备上传…</div>
            </div>
          </div>

          <div class="card">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
              <h2 style="margin:0;">Mac 投送给你的内容</h2>
              <button onclick="loadShared(true)" style="border:none;background:none;color:#355C7D;font-size:12.5px;font-weight:600;cursor:pointer;">刷新</button>
            </div>
            <div id="albumSection" style="display:none;">
              <h3 id="albumTitle">相册预览</h3>
              <div id="albumGrid" class="album-grid"></div>
            </div>
            <div id="sharedList"><p class="sub" style="margin:0;">暂未收到 Mac 投送的内容。在 Mac 弹窗右侧拖入文件或文件夹即可在此预览与下载。</p></div>
          </div>
        </div>

        <div class="lb" id="lightbox">
          <div class="lb-top">
            <div style="min-width:0;">
              <div id="lbTitle" style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"></div>
              <div id="lbMeta" style="font-size:11.5px;color:#B8C0CC;margin-top:2px;"></div>
            </div>
            <button class="lb-btn" onclick="closeLightbox()">关闭</button>
          </div>
          <div class="lb-body" id="lbBody"></div>
          <div class="lb-foot">
            <button class="lb-btn" onclick="stepLightbox(-1)">上一张</button>
            <a id="lbDownload" class="lb-btn pri" href="#">下载保存</a>
            <button class="lb-btn" onclick="stepLightbox(1)">下一张</button>
          </div>
        </div>

        <script>
        const TOKEN = "\(escapedToken)";
        let allMedia = [];
        let activeIndex = -1;
        let lastSharedSignature = "";
        let localObjectURLs = [];

        function esc(s){ return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;"); }
        function fmt(b){ if(b<1024)return b+" B"; if(b<1048576)return (b/1024).toFixed(1)+" KB"; if(b<1073741824)return (b/1048576).toFixed(1)+" MB"; return (b/1073741824).toFixed(2)+" GB"; }

        function renderLocalPreviews(files){
          localObjectURLs.forEach(u => URL.revokeObjectURL(u));
          localObjectURLs = [];
          const grid = document.getElementById("localPreviewGrid");
          const imgs = Array.from(files).filter(f => (f.type||"").startsWith("image/")).slice(0, 8);
          if(!imgs.length){ grid.style.display="none"; grid.innerHTML=""; return; }
          grid.style.display="grid";
          grid.innerHTML = imgs.map(f => {
            const url = URL.createObjectURL(f);
            localObjectURLs.push(url);
            return `<div class="local-cell"><img src="${url}" alt=""></div>`;
          }).join("");
        }

        async function uploadFiles(files){
          if(!files || !files.length) return;
          renderLocalPreviews(files);
          const wrap=document.getElementById("progWrap"), bar=document.getElementById("progBar"), st=document.getElementById("uploadStatus");
          wrap.style.display="block";
          let ok=0;
          for(let i=0;i<files.length;i++){
            const f=files[i];
            const rel = f.webkitRelativePath || "";
            const slash = rel.lastIndexOf("/");
            const subpath = slash > 0 ? rel.slice(0, slash) : "";
            st.textContent=`正在发送第 ${i+1}/${files.length} 个：${subpath ? subpath+"/"+f.name : f.name}`;
            await new Promise((resolve,reject)=>{
              const xhr=new XMLHttpRequest();
              let qs = "/api/upload?t="+encodeURIComponent(TOKEN)+"&name="+encodeURIComponent(f.name);
              if(subpath) qs += "&subpath="+encodeURIComponent(subpath);
              xhr.open("POST", qs);
              xhr.upload.onprogress=(e)=>{ if(e.lengthComputable) bar.value=Math.round(e.loaded*100/e.total); };
              xhr.onload=()=> xhr.status>=200&&xhr.status<300 ? resolve() : reject(new Error(xhr.responseText||("HTTP "+xhr.status)));
              xhr.onerror=()=> reject(new Error("网络中断"));
              xhr.send(f);
            }).then(()=>{ ok++; }).catch(err=>{ st.textContent="上传失败："+err.message; });
          }
          bar.value=100;
          if(ok===files.length) st.textContent=`已成功发送 ${ok} 个文件到 Mac！`;
        }
        document.getElementById("mediaInput").addEventListener("change",(e)=>{ uploadFiles(e.target.files); e.target.value=""; });
        document.getElementById("anyInput").addEventListener("change",(e)=>{ uploadFiles(e.target.files); e.target.value=""; });
        document.getElementById("dirInput").addEventListener("change",(e)=>{ uploadFiles(e.target.files); e.target.value=""; });

        function openLightbox(idx){
          if(idx<0 || idx>=allMedia.length) return;
          activeIndex = idx;
          const m = allMedia[idx];
          document.getElementById("lbTitle").textContent = m.relativePath || m.filename;
          document.getElementById("lbMeta").textContent = `第 ${idx+1} / ${allMedia.length} 项 · ${fmt(m.sizeBytes)}`;
          const mediaUrl = `/api/media/${encodeURIComponent(m.id)}?t=${encodeURIComponent(TOKEN)}`;
          document.getElementById("lbDownload").href = mediaUrl + "&dl=1";
          const body = document.getElementById("lbBody");
          if(m.kind === "video"){
            body.innerHTML = `<video src="${mediaUrl}" controls autoplay playsinline></video>`;
          } else {
            body.innerHTML = `<img src="${mediaUrl}" alt="${esc(m.filename)}">`;
          }
          document.getElementById("lightbox").classList.add("open");
        }
        function closeLightbox(){
          document.getElementById("lightbox").classList.remove("open");
          document.getElementById("lbBody").innerHTML = "";
          activeIndex = -1;
        }
        function stepLightbox(delta){
          if(!allMedia.length || activeIndex<0) return;
          const next = (activeIndex + delta + allMedia.length) % allMedia.length;
          openLightbox(next);
        }
        let touchStartX = 0;
        document.getElementById("lbBody").addEventListener("touchstart", e=>{ touchStartX = e.changedTouches[0].clientX; }, {passive:true});
        document.getElementById("lbBody").addEventListener("touchend", e=>{
          const dx = e.changedTouches[0].clientX - touchStartX;
          if(dx > 45) stepLightbox(-1);
          else if(dx < -45) stepLightbox(1);
        }, {passive:true});

        async function loadShared(force){
          try{
            const r=await fetch("/api/shared?t="+encodeURIComponent(TOKEN));
            const rawText=await r.text();
            if(!force && rawText === lastSharedSignature) return;
            lastSharedSignature = rawText;
            const items=JSON.parse(rawText);

            const collected = [];
            items.forEach(it => {
              (it.mediaItems || []).forEach(m => collected.push(m));
            });
            allMedia = collected;

            const albumSection = document.getElementById("albumSection");
            const albumGrid = document.getElementById("albumGrid");
            if(allMedia.length){
              albumSection.style.display = "block";
              document.getElementById("albumTitle").textContent = `相册预览（${allMedia.length} 项）`;
              albumGrid.innerHTML = allMedia.map((m, idx) => {
                const thumbUrl = `/api/thumb/${encodeURIComponent(m.id)}?t=${encodeURIComponent(TOKEN)}`;
                const badge = m.kind === "video" ? `<span class="vbadge">▶ 视频</span>` : "";
                return `<div class="tile" onclick="openLightbox(${idx})"><img loading="lazy" src="${thumbUrl}" alt="${esc(m.filename)}">${badge}</div>`;
              }).join("");
            } else {
              albumSection.style.display = "none";
              albumGrid.innerHTML = "";
            }

            const box=document.getElementById("sharedList");
            if(!items.length){ box.innerHTML='<p class="sub" style="margin:0;">暂未收到 Mac 投送的内容。在 Mac 弹窗右侧拖入文件或文件夹即可在此预览与下载。</p>'; return; }
            box.innerHTML=items.map(it=>{
              const meta = it.isDirectory ? `文件夹 · ${it.itemCount} 项 · ${fmt(it.sizeBytes)}` : fmt(it.sizeBytes);
              const prefix = it.isDirectory ? "📁 " : "";
              const btnLabel = it.isDirectory ? "打包下载 ZIP" : "下载到手机";
              return `<div class="item"><div><div class="name">${prefix}${esc(it.filename)}</div><div class="size">${meta}</div></div><a class="dl" href="/api/download/${encodeURIComponent(it.id)}?t=${encodeURIComponent(TOKEN)}">${btnLabel}</a></div>`;
            }).join("");
          }catch(e){}
        }
        loadShared(true);
        setInterval(() => loadShared(false), 2500);
        </script>
        </body>
        </html>
        """
    }
}
