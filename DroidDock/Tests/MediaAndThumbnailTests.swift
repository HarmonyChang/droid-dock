import AppKit
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import DroidDock

@MainActor
final class MediaAndThumbnailTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidDockM3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCacheKeySHA1FormatAndSensitivity() {
        let baseDate = Date(timeIntervalSince1970: 1_760_000_000)
        let node = RemoteNode(
            id: "65537:10",
            storageID: 65537,
            path: "/DCIM/Camera/IMG_001.jpg",
            name: "IMG_001.jpg",
            isDirectory: false,
            size: 123_456,
            modified: baseDate,
            kind: .photo
        )

        let key1 = ThumbnailPipeline.cacheKey(deviceID: "dev-A", node: node)
        XCTAssertEqual(key1.count, 40)
        XCTAssertTrue(key1.allSatisfy { $0.isHexDigit })

        let expectedInput = "dev-A|65537|/DCIM/Camera/IMG_001.jpg|123456|1760000000"
        let expectedHex = Insecure.SHA1.hash(data: Data(expectedInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(key1, expectedHex)

        // 修改任意字段（设备 / 路径 / 大小 / 时间戳）都必须生成不同的缓存键
        let diffDevice = ThumbnailPipeline.cacheKey(deviceID: "dev-B", node: node)
        let diffSize = ThumbnailPipeline.cacheKey(
            deviceID: "dev-A",
            node: RemoteNode(id: node.id, storageID: node.storageID, path: node.path, name: node.name, isDirectory: false, size: 123_457, modified: baseDate, kind: .photo)
        )
        let diffTime = ThumbnailPipeline.cacheKey(
            deviceID: "dev-A",
            node: RemoteNode(id: node.id, storageID: node.storageID, path: node.path, name: node.name, isDirectory: false, size: 123_456, modified: baseDate.addingTimeInterval(2), kind: .photo)
        )
        XCTAssertNotEqual(key1, diffDevice)
        XCTAssertNotEqual(key1, diffSize)
        XCTAssertNotEqual(key1, diffTime)
    }

    func testThumbnailPipelineFallbackImageGenerationAndDiskCache() async throws {
        let storageID: UInt32 = 65537
        let largePNG = try XCTUnwrap(makeTestPNGData(width: 800, height: 600, color: .systemTeal))
        let node = RemoteNode(
            id: "\(storageID):50",
            storageID: storageID,
            path: "/DCIM/Camera/LARGE_TEST.png",
            name: "LARGE_TEST.png",
            isDirectory: false,
            size: UInt64(largePNG.count),
            modified: Date(timeIntervalSince1970: 1_760_000_100),
            kind: .photo
        )

        // thumbnails 为空：强制触发临时下载 + ImageIO 生成 ≤ 320 px 缩略图兜底路径
        let provider = FakeFileProvider(
            directories: [storageID: ["/DCIM/Camera": [node]]],
            thumbnails: [:],
            filePayloads: [node.id: largePNG]
        )
        let session = DeviceSession(provider: provider)
        let cacheDir = tempRoot.appendingPathComponent("ThumbCache", isDirectory: true)
        let pipeline = ThumbnailPipeline(cacheDirectory: cacheDir, maxDiskBytes: 8 * 1024 * 1024)

        let fetched = try await pipeline.thumbnail(for: node, deviceID: "dev-1", session: session)
        let thumbData = try XCTUnwrap(fetched)
        let thumbImage = try XCTUnwrap(NSImage(data: thumbData))
        XCTAssertLessThanOrEqual(max(thumbImage.size.width, thumbImage.size.height), 320)

        let key = ThumbnailPipeline.cacheKey(deviceID: "dev-1", node: node)
        let diskFile = cacheDir.appendingPathComponent("\(key).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskFile.path))

        // 验证重新创建 pipeline（模拟重连清内存后）可直接命中磁盘缓存而不访问断线设备
        await provider.setNextError(DeviceError.disconnected)
        let freshPipeline = ThumbnailPipeline(cacheDirectory: cacheDir, maxDiskBytes: 8 * 1024 * 1024)
        let cachedFromDisk = try await freshPipeline.thumbnail(for: node, deviceID: "dev-1", session: session)
        XCTAssertEqual(cachedFromDisk, thumbData)
    }

    func testThumbnailPipelineLRUEviction() async throws {
        let cacheDir = tempRoot.appendingPathComponent("LRUCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let payload = Data(repeating: 0xAA, count: 600)
        let oldURL = cacheDir.appendingPathComponent("old.jpg")
        let midURL = cacheDir.appendingPathComponent("mid.jpg")
        let newURL = cacheDir.appendingPathComponent("new.jpg")

        try payload.write(to: oldURL)
        try payload.write(to: midURL)
        try payload.write(to: newURL)

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: midURL.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newURL.path)

        // 上限 1250 字节（仅容得下 2 个 600B 文件），最旧的 old.jpg 应被淘汰
        let pipeline = ThumbnailPipeline(cacheDirectory: cacheDir, maxDiskBytes: 1250)
        await pipeline.enforceDiskLimit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: midURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testThumbnailPipelineSkipsFallbackDownloadForOversizedVideo() async throws {
        let storageID: UInt32 = 65537
        let hugeVideo = RemoteNode(
            id: "\(storageID):999",
            storageID: storageID,
            path: "/DCIM/Camera/4K_MOVIE.mp4",
            name: "4K_MOVIE.mp4",
            isDirectory: false,
            size: ThumbnailPipeline.maxFallbackVideoBytes + 1_048_576,
            modified: Date(),
            kind: .video
        )
        let provider = FakeFileProvider(directories: [storageID: ["/DCIM/Camera": [hugeVideo]]])
        let session = DeviceSession(provider: provider)
        let cacheDir = tempRoot.appendingPathComponent("HugeSkipCache", isDirectory: true)
        let pipeline = ThumbnailPipeline(cacheDirectory: cacheDir, maxDiskBytes: 4 * 1024 * 1024)

        let thumb = try await pipeline.thumbnail(for: hugeVideo, deviceID: "dev-wifi", session: session)
        XCTAssertNil(thumb)
        let ops = await provider.recordedOperations
        XCTAssertFalse(ops.contains(where: { $0.hasPrefix("download:") }))
    }

    func testMediaIndexStoreSQLitePersistenceAndPhotoPreview() async throws {
        let dbURL = tempRoot.appendingPathComponent("media_index.sqlite3")
        let cacheDir = tempRoot.appendingPathComponent("BrowserThumbs", isDirectory: true)
        let store = MediaIndexStore(databaseURL: dbURL)
        let pipeline = ThumbnailPipeline(cacheDirectory: cacheDir, maxDiskBytes: 4 * 1024 * 1024)

        let storageID: UInt32 = 65537
        let deviceKey = "m3-test-device"
        let pngData = try XCTUnwrap(makeTestPNGData(width: 400, height: 300, color: .systemIndigo))

        let olderPhoto = RemoteNode(
            id: "\(storageID):101",
            storageID: storageID,
            path: "/DCIM/Camera/IMG_OLD.png",
            name: "IMG_OLD.png",
            isDirectory: false,
            size: UInt64(pngData.count),
            modified: Date(timeIntervalSince1970: 1_760_000_000),
            kind: .photo
        )
        let newerPhoto = RemoteNode(
            id: "\(storageID):102",
            storageID: storageID,
            path: "/DCIM/Camera/IMG_NEW.png",
            name: "IMG_NEW.png",
            isDirectory: false,
            size: UInt64(pngData.count),
            modified: Date(timeIntervalSince1970: 1_760_100_000),
            kind: .photo
        )

        await store.syncMedia(deviceID: deviceKey, storage: storageID, nodes: [olderPhoto, newerPhoto])
        let loaded = await store.loadMedia(deviceID: deviceKey, storage: storageID)
        XCTAssertEqual(loaded.map(\.name), ["IMG_NEW.png", "IMG_OLD.png"])

        // 增量同步移除旧项
        await store.syncMedia(deviceID: deviceKey, storage: storageID, nodes: [newerPhoto])
        let loadedAfterSync = await store.loadMedia(deviceID: deviceKey, storage: storageID)
        XCTAssertEqual(loadedAfterSync.map(\.name), ["IMG_NEW.png"])

        // 验证 BrowserModel 优先读取缓存并在双击照片时打开放大查看器
        let provider = FakeFileProvider(
            directories: [storageID: ["/DCIM/Camera": [olderPhoto, newerPhoto]]],
            filePayloads: [olderPhoto.id: pngData, newerPhoto.id: pngData]
        )
        let session = DeviceSession(provider: provider)
        let browser = BrowserModel(mediaIndexStore: store, thumbnailPipeline: pipeline)
        await browser.attachSession(session, deviceID: DeviceID(rawValue: deviceKey))
        XCTAssertEqual(browser.mediaNodes.count, 2)

        await browser.openNode(newerPhoto)
        XCTAssertEqual(browser.previewingNode?.id, newerPhoto.id)
        let previewURL = try XCTUnwrap(browser.previewLocalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
        XCTAssertEqual(try Data(contentsOf: previewURL), pngData)
        if let cacheURL = browser.previewLocalURL {
            try? FileManager.default.removeItem(at: cacheURL)
        }

        // 切下一张、切回上一张，边界不再越界，以及关闭预览
        await browser.previewAdjacentPhoto(step: 1)
        XCTAssertEqual(browser.previewingNode?.id, olderPhoto.id)
        await browser.previewAdjacentPhoto(step: 1)
        XCTAssertEqual(browser.previewingNode?.id, olderPhoto.id)
        await browser.previewAdjacentPhoto(step: -1)
        XCTAssertEqual(browser.previewingNode?.id, newerPhoto.id)
        await browser.previewAdjacentPhoto(step: -1)
        XCTAssertEqual(browser.previewingNode?.id, newerPhoto.id)
        if let firstCache = previewURL as URL? {
            try? FileManager.default.removeItem(at: firstCache)
        }
        if let secondCacheURL = browser.previewLocalURL {
            try? FileManager.default.removeItem(at: secondCacheURL)
        }
        browser.closePreview()
        XCTAssertNil(browser.previewingNode)
        XCTAssertNil(browser.previewLocalURL)
    }

    private func makeTestPNGData(width: Int, height: Int, color: NSColor) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
