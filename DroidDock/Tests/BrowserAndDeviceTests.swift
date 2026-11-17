import AppKit
import XCTest
@testable import DroidDock

final class BrowserAndDeviceTests: XCTestCase {
    func testPathUtilsNormalizationAndComponents() {
        XCTAssertEqual(PathUtils.normalize(""), "/")
        XCTAssertEqual(PathUtils.normalize("///DCIM//Camera/"), "/DCIM/Camera")
        XCTAssertEqual(PathUtils.normalize("/DCIM/Camera/../Screenshots/./"), "/DCIM/Screenshots")
        XCTAssertEqual(PathUtils.join("/", "DCIM"), "/DCIM")
        XCTAssertEqual(PathUtils.join("/DCIM/", "Camera"), "/DCIM/Camera")
        XCTAssertEqual(PathUtils.parentPath(of: "/DCIM/Camera"), "/DCIM")
        XCTAssertEqual(PathUtils.parentPath(of: "/DCIM"), "/")
        XCTAssertEqual(PathUtils.filename(of: "/DCIM/Camera/IMG_001.jpg"), "IMG_001.jpg")

        let crumbs = PathUtils.breadcrumbs(for: "/DCIM/Camera")
        XCTAssertEqual(crumbs.map(\.name), ["内部存储", "DCIM", "Camera"])
        XCTAssertEqual(crumbs.map(\.path), ["/", "/DCIM", "/DCIM/Camera"])
    }

    func testMediaKindInference() {
        XCTAssertEqual(PathUtils.inferMediaKind(filename: "photo.HEIC"), .photo)
        XCTAssertEqual(PathUtils.inferMediaKind(filename: "clip.mp4"), .video)
        XCTAssertEqual(PathUtils.inferMediaKind(filename: "track.flac"), .audio)
        XCTAssertEqual(PathUtils.inferMediaKind(filename: "spec.pdf"), .document)
        XCTAssertEqual(PathUtils.inferMediaKind(filename: "archive.bin"), .other)
    }

    func testParseMTPDate() throws {
        let local = PathUtils.parseMTPDate("20260115T201015")
        XCTAssertNotNil(local)

        let utc = try XCTUnwrap(PathUtils.parseMTPDate("20260115T201015Z"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utc)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 20)
        XCTAssertEqual(comps.minute, 10)
        XCTAssertEqual(comps.second, 15)

        XCTAssertNil(PathUtils.parseMTPDate(""))
        XCTAssertNil(PathUtils.parseMTPDate("invalid-date"))
    }

    func testDeviceSessionMapsDisconnectAndBlocksSubsequentCalls() async throws {
        let fake = FakeFileProvider()
        let session = DeviceSession(provider: fake)

        let storages = try await session.storages()
        XCTAssertEqual(storages.count, 1)

        await fake.setNextError(DeviceError.disconnected)
        do {
            _ = try await session.list(dir: "/", storage: 65537)
            XCTFail("Expected disconnected error")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .disconnected)
        }

        // 即使底层清除错误，已标记断线的 DeviceSession 也必须持续抛出 .disconnected
        await fake.setNextError(nil)
        do {
            _ = try await session.storages()
            XCTFail("Expected invalidated session to stay disconnected")
        } catch let error as DeviceError {
            XCTAssertEqual(error, .disconnected)
        }
    }

    @MainActor
    func testBrowserModelNavigationAndSearch() async {
        let storageID: UInt32 = 65537
        let hiddenFolder = RemoteNode(
            id: "\(storageID):99", storageID: storageID, path: "/.convert_security_files", name: ".convert_security_files",
            isDirectory: true, size: 0, modified: nil, kind: .other
        )
        let dcimNode = RemoteNode(
            id: "\(storageID):1", storageID: storageID, path: "/DCIM", name: "DCIM",
            isDirectory: true, size: 0, modified: nil, kind: .other
        )
        let downloadNode = RemoteNode(
            id: "\(storageID):2", storageID: storageID, path: "/Download", name: "Download",
            isDirectory: true, size: 0, modified: nil, kind: .other
        )
        let cameraNode = RemoteNode(
            id: "\(storageID):3", storageID: storageID, path: "/DCIM/Camera", name: "Camera",
            isDirectory: true, size: 0, modified: nil, kind: .other
        )
        let hiddenFile = RemoteNode(
            id: "\(storageID):98", storageID: storageID, path: "/DCIM/.nomedia", name: ".nomedia",
            isDirectory: false, size: 48, modified: nil, kind: .other
        )
        let photoNode = RemoteNode(
            id: "\(storageID):4", storageID: storageID, path: "/DCIM/Camera/IMG_1001.jpg", name: "IMG_1001.jpg",
            isDirectory: false, size: 2048, modified: Date(), kind: .photo
        )
        let videoNode = RemoteNode(
            id: "\(storageID):5", storageID: storageID, path: "/DCIM/Camera/VID_1002.mp4", name: "VID_1002.mp4",
            isDirectory: false, size: 8192, modified: Date(), kind: .video
        )
        let screenshotNode = RemoteNode(
            id: "\(storageID):6", storageID: storageID, path: "/Pictures/Screenshots/Screenshot_2026.png", name: "Screenshot_2026.png",
            isDirectory: false, size: 1024, modified: Date(), kind: .photo
        )

        let fake = FakeFileProvider(
            directories: [
                storageID: [
                    "/": [hiddenFolder, dcimNode, downloadNode],
                    "/DCIM": [cameraNode, hiddenFile],
                    "/DCIM/Camera": [photoNode, videoNode],
                    "/Pictures/Screenshots": [screenshotNode],
                ]
            ],
            thumbnails: [photoNode.id: Data([0xFF, 0xD8, 0xFF])]
        )
        let session = DeviceSession(provider: fake)
        let browser = BrowserModel()

        // 默认进入「相册」媒体模式：绝不包含目录与隐藏文件，仅包含照片与视频
        await browser.attachSession(session, deviceID: DeviceID(rawValue: "test-serial"))
        XCTAssertFalse(browser.isDeviceLocked)
        XCTAssertTrue(browser.isMediaMode)
        XCTAssertTrue(browser.filteredNodes.allSatisfy { !$0.isDirectory && ($0.kind == .photo || $0.kind == .video) })
        XCTAssertEqual(browser.filteredNodes.count, 3)

        // 验证过滤胶囊与日期分组
        browser.mediaFilter = .videos
        XCTAssertEqual(browser.filteredNodes.map(\.name), ["VID_1002.mp4"])
        browser.mediaFilter = .screenshots
        XCTAssertEqual(browser.filteredNodes.map(\.name), ["Screenshot_2026.png"])
        browser.mediaFilter = .all
        XCTAssertEqual(browser.groupedMediaSections.first?.title, "今天")

        // 异步加载缩略图并缓存
        await browser.loadThumbnailIfNeeded(for: photoNode)
        XCTAssertEqual(browser.thumbnailData(for: photoNode), Data([0xFF, 0xD8, 0xFF]))

        // 切换到「内部存储」文件夹模式：隐藏目录已过滤
        await browser.selectSidebar(.internalStorage)
        XCTAssertFalse(browser.isMediaMode)
        XCTAssertEqual(browser.currentPath, "/")
        XCTAssertEqual(browser.nodes.map(\.name), ["DCIM", "Download"])
        XCTAssertFalse(browser.canGoBack)

        // 双击进入 DCIM（过滤掉 .nomedia）
        await browser.openNode(dcimNode)
        XCTAssertEqual(browser.currentPath, "/DCIM")
        XCTAssertEqual(browser.nodes.map(\.name), ["Camera"])
        XCTAssertTrue(browser.canGoBack)

        // 搜索过滤
        browser.searchQuery = "cam"
        XCTAssertEqual(browser.filteredNodes.map(\.name), ["Camera"])
        browser.searchQuery = ""

        // 后退与前进
        await browser.goBack()
        XCTAssertEqual(browser.currentPath, "/")
        XCTAssertTrue(browser.canGoForward)

        await browser.goForward()
        XCTAssertEqual(browser.currentPath, "/DCIM")
    }

    @MainActor
    func testEmptyStoragesMapsToLockedStateAndAutoRecovers() async throws {
        let storageID: UInt32 = 65537
        let emptyFake = FakeFileProvider(storages: [])
        let session = DeviceSession(provider: emptyFake)
        let browser = BrowserModel()

        await browser.attachSession(session, deviceID: DeviceID(rawValue: "locked-device"))
        XCTAssertTrue(browser.isDeviceLocked)
        XCTAssertTrue(browser.storages.isEmpty)
        XCTAssertTrue(browser.nodes.isEmpty)

        // 模拟用户在手机端解锁或切换「文件传输」后，后台自动恢复为就绪状态
        await emptyFake.setStorages([StorageInfo(id: storageID, name: "内部共享存储空间", totalBytes: 128_000_000_000, freeBytes: 64_000_000_000)])
        try await waitUntil(timeoutSeconds: 3.0) {
            !browser.isDeviceLocked && browser.storages.count == 1
        }
        XCTAssertFalse(browser.isDeviceLocked)
        XCTAssertEqual(browser.storages.count, 1)
    }

    @MainActor
    private func waitUntil(timeoutSeconds: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testAppStateLifecycleWithFakeBackend() async throws {
        let storageID: UInt32 = 65537
        let rootItem = RemoteNode(
            id: "\(storageID):10", storageID: storageID, path: "/Pictures", name: "Pictures",
            isDirectory: true, size: 0, modified: nil, kind: .other
        )
        let photoItem = RemoteNode(
            id: "\(storageID):11", storageID: storageID, path: "/DCIM/Camera/IMG_001.jpg", name: "IMG_001.jpg",
            isDirectory: false, size: 4096, modified: Date(), kind: .photo
        )
        let provider = FakeFileProvider(directories: [
            storageID: [
                "/": [rootItem],
                "/DCIM/Camera": [photoItem],
            ]
        ])
        let backend = FakeDeviceBackend()
        let deviceID = DeviceID(rawValue: "fake-13t")
        backend.register(provider: provider, for: deviceID)

        let manager = DeviceManager(backend: backend)
        let appState = AppState(deviceManager: manager)
        appState.start()
        defer { appState.stop() }

        let info = DeviceInfo(id: deviceID, name: "OnePlus 13T", manufacturer: "OnePlus", model: "PKX110", serialNumber: "fake-13t")
        backend.emit(.attached(info))
        backend.emit(.stateChanged(deviceID, .locked))
        try await waitUntil { appState.effectiveDeviceState == .locked }

        XCTAssertEqual(appState.effectiveDeviceState, .locked)
        XCTAssertTrue(appState.browser.filteredNodes.isEmpty)

        backend.emit(.stateChanged(deviceID, .ready))
        try await waitUntil { appState.effectiveDeviceState == .ready && !appState.browser.mediaNodes.isEmpty }

        XCTAssertEqual(appState.effectiveDeviceState, .ready)
        XCTAssertEqual(appState.browser.filteredNodes.map(\.name), ["IMG_001.jpg"])

        backend.emit(.detached(deviceID))
        try await waitUntil { appState.deviceManager.currentDevice == nil }

        XCTAssertNil(appState.deviceManager.currentDevice)
        XCTAssertTrue(appState.browser.filteredNodes.isEmpty)
    }

    @MainActor
    func testCompositeBackendMergesUSBAndWiFiDevices() async throws {
        let usbBackend = FakeDeviceBackend()
        let wifiBackend = FakeDeviceBackend()
        let usbID = DeviceID(rawValue: "usb-serial-1")
        let wifiID = DeviceID(rawValue: "wifi:192.168.1.30:38421")

        let usbProvider = FakeFileProvider(directories: [65537: ["/": []]])
        let wifiProvider = FakeFileProvider(directories: [1: ["/": [
            RemoteNode(id: "wifi-doc", storageID: 1, path: "/Download/manual.pdf", name: "manual.pdf", isDirectory: false, size: 512, modified: Date(), kind: .document),
        ]]])
        usbBackend.register(provider: usbProvider, for: usbID)
        wifiBackend.register(provider: wifiProvider, for: wifiID)

        let composite = CompositeDeviceBackend(backends: [usbBackend, wifiBackend])
        let manager = DeviceManager(backend: composite)
        let appState = AppState(deviceManager: manager)
        appState.start()
        defer { appState.stop() }

        let usbInfo = DeviceInfo(id: usbID, name: "Pixel USB", manufacturer: "Google", model: "Pixel", serialNumber: "usb-serial-1", transport: .usb)
        let wifiInfo = DeviceInfo(id: wifiID, name: "OnePlus Wi-Fi", manufacturer: "OnePlus", model: "PKX110", serialNumber: "192.168.1.30:38421", transport: .wifi)

        usbBackend.emit(.attached(usbInfo))
        usbBackend.emit(.stateChanged(usbID, .ready))
        wifiBackend.emit(.attached(wifiInfo))
        wifiBackend.emit(.stateChanged(wifiID, .ready))

        try await waitUntil { appState.deviceManager.devices.count == 2 }
        XCTAssertEqual(appState.deviceManager.currentDevice?.transport, .usb)

        await appState.selectDevice(wifiID)
        XCTAssertEqual(appState.deviceManager.currentDevice?.transport, .wifi)

        let opened = try await composite.open(wifiID)
        let list = try await opened.list(dir: "/", storage: 1)
        XCTAssertEqual(list.map(\.name), ["manual.pdf"])
    }

    @MainActor
    func testWirelessADBParsingAndQRPayload() {
        let dfOutput = """
        Filesystem      1K-blocks     Used Available Use% Mounted on
        /dev/fuse       112844800 41200000  71644800  37% /storage/emulated
        """
        let storage = ADBFileProvider.parseDFOutput(dfOutput)
        XCTAssertEqual(storage.totalBytes, 112_844_800 * 1024)
        XCTAssertEqual(storage.freeBytes, 71_644_800 * 1024)

        let statOutput = """
        directory|4096|1760000000|/storage/emulated/0/DCIM
        regular file|2048000|1760100000|/storage/emulated/0/DCIM/Camera/IMG_2026.jpg
        regular file|12|1760100000|/storage/emulated/0/.nomedia
        """
        let nodes = ADBFileProvider.parseStatLines(statOutput, storage: 1)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes[0].isDirectory)
        XCTAssertEqual(nodes[0].path, "/DCIM")
        XCTAssertEqual(nodes[1].kind, .photo)
        XCTAssertEqual(nodes[1].path, "/DCIM/Camera/IMG_2026.jpg")

        let devicesOutput = """
        List of devices attached
        192.168.1.50:39811     device product:PKX110 model:PKX110 device:OP5D transport_id:2
        adb-ABC123-xyz._adb-tls-connect._tcp\tdevice product:PKX110 model:OnePlus_13T transport_id:3
        USBONLYSERIAL123       device product:PKX110 model:PKX110 transport_id:1
        """
        let wireless = ADBClient.parseDevicesList(devicesOutput)
        XCTAssertEqual(wireless.count, 2)
        XCTAssertEqual(wireless[0].serial, "192.168.1.50:39811")
        XCTAssertEqual(wireless[1].model, "OnePlus 13T")

        let qrSession = ADBQRPairingSession.generate()
        XCTAssertTrue(qrSession.qrPayload.hasPrefix("WIFI:T:ADB;S:\(qrSession.serviceName);P:\(qrSession.password);;"))
        XCTAssertNotNil(ADBDiscoveryService.renderQRCode(from: qrSession.qrPayload))

        // 验证同台无线设备同时存在 IP:Port 与 mDNS 会话时自动去重并优先保留 mDNS + 在线会话
        let dupDevicesOutput = """
        List of devices attached
        192.168.1.50:39811     device product:PKX110 model:PKX110 device:OP5D transport_id:2
        adb-XYZ789._adb-tls-connect._tcp device product:PKX110 model:PKX110 device:OP5D transport_id:3
        """
        let deduped = ADBClient.parseDevicesList(dupDevicesOutput)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.serial, "adb-XYZ789._adb-tls-connect._tcp")

        // 验证 QuickDropWebServer 的 HTTP 请求头解析与安全文件名清理
        let rawHeader = "POST /api/upload?t=abc123&name=IMG_01.jpg HTTP/1.1\r\nHost: 192.168.1.10\r\nContent-Length: 4096"
        let parsedReq = QuickDropWebServer.parseHTTPHeaderBlock(rawHeader)
        XCTAssertEqual(parsedReq?.method, "POST")
        XCTAssertEqual(parsedReq?.headers["content-length"], "4096")
        XCTAssertEqual(QuickDropWebServer.sanitizeReceivedFilename("../../bad:name?.jpg"), "bad_name_.jpg")
        XCTAssertEqual(QuickDropWebServer.sanitizeRelativeSubpath("../Album2026/./Sub/../Day1"), ["Album2026", "Sub", "Day1"])
    }

    @MainActor
    func testQuickDropWebServerEndToEndUploadAndDownload() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickDropE2E-\(UUID().uuidString)", isDirectory: true)
        let receiveDir = tempRoot.appendingPathComponent("Received", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("SharedSource", isDirectory: true)
        let tripFolderURL = sourceDir.appendingPathComponent("TripPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: tripFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 使用超过 64 KB 的载荷，同时验证分块下载与分块上传的真实 TCP 回路行为
        let sharedFileURL = sourceDir.appendingPathComponent("mac-note.txt")
        let sharedPayload = Data((0..<96_000).map { UInt8(($0 * 7) % 251) })
        try sharedPayload.write(to: sharedFileURL)

        // 生成包含一张真实 JPEG 图片与一个说明文档的测试文件夹
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 480,
            pixelsHigh: 360,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.21, green: 0.36, blue: 0.49, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: 480, height: 360).fill()
        NSGraphicsContext.restoreGraphicsState()
        let folderPhotoData = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        let folderPhotoURL = tripFolderURL.appendingPathComponent("cover.jpg")
        try folderPhotoData.write(to: folderPhotoURL)
        try Data("Trip notes".utf8).write(to: tripFolderURL.appendingPathComponent("readme.txt"))

        let server = QuickDropWebServer(receiveDirectoryURL: receiveDir)
        server.addSharedFiles([sharedFileURL, tripFolderURL])
        server.start()
        defer { server.stop() }

        try await waitUntil(timeoutSeconds: 3.0) { server.isRunning && server.port > 0 }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)"))
        let token = server.token

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // 1. 未携带有效 token 访问 / 返回 403
        let (_, unauthorizedResp) = try await session.data(from: baseURL)
        XCTAssertEqual((unauthorizedResp as? HTTPURLResponse)?.statusCode, 403)

        // 2. 访问 /favicon.ico 返回 204
        let (_, faviconResp) = try await session.data(from: baseURL.appendingPathComponent("favicon.ico"))
        XCTAssertEqual((faviconResp as? HTTPURLResponse)?.statusCode, 204)

        // 3. 携带 token 访问首页返回 HTML（含文件夹按钮与相册预览容器）
        let homeURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/?t=\(token)"))
        let (homeData, homeResp) = try await session.data(from: homeURL)
        XCTAssertEqual((homeResp as? HTTPURLResponse)?.statusCode, 200)
        let homeHTML = String(data: homeData, encoding: .utf8) ?? ""
        XCTAssertTrue(homeHTML.contains("DroidDock 扫码快传"))
        XCTAssertTrue(homeHTML.contains("选文件夹"))
        XCTAssertTrue(homeHTML.contains("albumGrid"))

        // 4. 查询 /api/shared 列表包含单文件与文件夹媒体摘要
        let sharedAPIURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/api/shared?t=\(token)"))
        let (sharedListData, sharedListResp) = try await session.data(from: sharedAPIURL)
        XCTAssertEqual((sharedListResp as? HTTPURLResponse)?.statusCode, 200)
        let jsonArray = try XCTUnwrap(try JSONSerialization.jsonObject(with: sharedListData) as? [[String: Any]])
        XCTAssertEqual(jsonArray.count, 2)
        XCTAssertEqual(jsonArray[0]["filename"] as? String, "mac-note.txt")
        let sharedID = try XCTUnwrap(jsonArray[0]["id"] as? String)

        let folderEntry = try XCTUnwrap(jsonArray.first { ($0["filename"] as? String) == "TripPhotos" })
        XCTAssertEqual(folderEntry["isDirectory"] as? Bool, true)
        XCTAssertEqual(folderEntry["itemCount"] as? Int, 2)
        let folderID = try XCTUnwrap(folderEntry["id"] as? String)
        let mediaItems = try XCTUnwrap(folderEntry["mediaItems"] as? [[String: Any]])
        XCTAssertEqual(mediaItems.count, 1)
        let mediaID = try XCTUnwrap(mediaItems.first?["id"] as? String)

        // 5. 下载 /api/download/<fileID> 验证字节完全一致
        let downloadURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/api/download/\(sharedID)?t=\(token)"))
        let (downloadedData, downloadResp) = try await session.data(from: downloadURL)
        XCTAssertEqual((downloadResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(downloadedData, sharedPayload)

        // 6. 验证相册缩略图 /api/thumb/<mediaID> 与原图 /api/media/<mediaID>
        let thumbURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/api/thumb/\(mediaID)?t=\(token)"))
        let (thumbData, thumbResp) = try await session.data(from: thumbURL)
        XCTAssertEqual((thumbResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(thumbData.count, 100)
        XCTAssertEqual([UInt8](thumbData.prefix(2)), [0xFF, 0xD8]) // JPEG 魔数

        let mediaURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/api/media/\(mediaID)?t=\(token)"))
        let (fetchedMediaData, mediaResp) = try await session.data(from: mediaURL)
        XCTAssertEqual((mediaResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fetchedMediaData, folderPhotoData)

        // 7. 验证文件夹打包下载 /api/download/<folderID> 返回有效 ZIP（PK\x03\x04 签名）
        let zipURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/api/download/\(folderID)?t=\(token)"))
        let (zipData, zipResp) = try await session.data(from: zipURL)
        XCTAssertEqual((zipResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual([UInt8](zipData.prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        // 8. 上传 POST /api/upload 验证落盘、无 .droiddock-part 残留且 receivedItems 记录更新
        let uploadPayload = Data((0..<98_304).map { UInt8(($0 * 13 + 3) % 251) })
        let uploadURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/api/upload?t=\(token)&name=phone-photo.jpg"))
        var uploadReq = URLRequest(url: uploadURL)
        uploadReq.httpMethod = "POST"
        let (uploadRespData, uploadResp) = try await session.upload(for: uploadReq, from: uploadPayload)
        XCTAssertEqual((uploadResp as? HTTPURLResponse)?.statusCode, 200)
        let uploadJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: uploadRespData) as? [String: Any])
        XCTAssertEqual(uploadJSON["ok"] as? Bool, true)

        try await waitUntil(timeoutSeconds: 2.0) { server.receivedItems.first?.filename == "phone-photo.jpg" }
        let savedFileURL = receiveDir.appendingPathComponent("phone-photo.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFileURL.path))
        XCTAssertEqual(try Data(contentsOf: savedFileURL), uploadPayload)
        let receivedNames = try FileManager.default.contentsOfDirectory(atPath: receiveDir.path)
        XCTAssertFalse(receivedNames.contains { $0.hasSuffix(".droiddock-part") })

        // 9. 验证带 subpath 的文件夹结构上传
        let subUploadURL = try XCTUnwrap(URL(
            string: "http://127.0.0.1:\(server.port)/api/upload?t=\(token)&name=day1.jpg&subpath=Album2026%2FSub"
        ))
        var subReq = URLRequest(url: subUploadURL)
        subReq.httpMethod = "POST"
        let (_, subResp) = try await session.upload(for: subReq, from: folderPhotoData)
        XCTAssertEqual((subResp as? HTTPURLResponse)?.statusCode, 200)
        let nestedURL = receiveDir.appendingPathComponent("Album2026/Sub/day1.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
        XCTAssertEqual(try Data(contentsOf: nestedURL), folderPhotoData)
    }
}
