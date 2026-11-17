import Foundation
import XCTest
@testable import DroidDock

@MainActor
final class TransferTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidDockTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testValidateAndroidFilenameAndConflictResolution() {
        XCTAssertNil(PathUtils.validateAndroidFilename("IMG_2026_01.jpg"))
        XCTAssertNil(PathUtils.validateAndroidFilename("旅行照片 2026.png"))
        XCTAssertNotNil(PathUtils.validateAndroidFilename(""))
        XCTAssertNotNil(PathUtils.validateAndroidFilename("   "))
        XCTAssertNotNil(PathUtils.validateAndroidFilename("."))
        XCTAssertNotNil(PathUtils.validateAndroidFilename(".."))
        XCTAssertNotNil(PathUtils.validateAndroidFilename("a/b.txt"))
        XCTAssertNotNil(PathUtils.validateAndroidFilename("bad:name.txt"))
        XCTAssertNotNil(PathUtils.validateAndroidFilename("bad*name?.txt"))

        let existing: Set<String> = ["Photo.JPG", "photo (1).jpg", "Notes"]
        XCTAssertEqual(
            PathUtils.resolveConflictDestination(name: "photo.jpg", existingNames: existing, strategy: .rename),
            .proceed(finalName: "photo (2).jpg", overwriteExisting: false)
        )
        XCTAssertEqual(
            PathUtils.resolveConflictDestination(name: "Notes", existingNames: existing, strategy: .rename),
            .proceed(finalName: "Notes (1)", overwriteExisting: false)
        )
        XCTAssertEqual(
            PathUtils.resolveConflictDestination(name: "photo.jpg", existingNames: existing, strategy: .overwrite),
            .proceed(finalName: "photo.jpg", overwriteExisting: true)
        )
        XCTAssertEqual(
            PathUtils.resolveConflictDestination(name: "photo.jpg", existingNames: existing, strategy: .skip),
            .skip
        )
    }

    func testDownloadWritesAtomicallyAndRemovesPartFile() async throws {
        let storageID: UInt32 = 65537
        let payload = Data("hello-droiddock-download-payload".utf8)
        let node = RemoteNode(
            id: "\(storageID):10",
            storageID: storageID,
            path: "/Download/report.txt",
            name: "report.txt",
            isDirectory: false,
            size: UInt64(payload.count),
            modified: Date(),
            kind: .document
        )
        let provider = FakeFileProvider(
            directories: [storageID: ["/Download": [node]]],
            filePayloads: [node.id: payload]
        )
        let session = DeviceSession(provider: provider)
        let queue = TransferQueue()
        await queue.attachSession(session, deviceID: DeviceID(rawValue: "fake-1"))

        let destDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let ids = await queue.enqueueDownloads(nodes: [node], toLocalDirectory: destDir)
        XCTAssertEqual(ids.count, 1)
        try await waitUntilIdle(queue)

        let finalURL = destDir.appendingPathComponent("report.txt")
        let partURL = URL(fileURLWithPath: finalURL.path + ".droiddock-part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), payload)

        let snap = await queue.snapshot()
        XCTAssertEqual(snap.completedCount, 1)
        XCTAssertEqual(snap.failedCount, 0)
    }

    func testDownloadFailureCleansUpPartFileAndMarksFailed() async throws {
        let storageID: UInt32 = 65537
        let payload = Data(repeating: 0x33, count: 4096)
        let node = RemoteNode(
            id: "\(storageID):11",
            storageID: storageID,
            path: "/Download/broken.bin",
            name: "broken.bin",
            isDirectory: false,
            size: UInt64(payload.count),
            modified: Date(),
            kind: .other
        )
        let provider = FakeFileProvider(
            directories: [storageID: ["/Download": [node]]],
            filePayloads: [node.id: payload]
        )
        await provider.setDownloadDelay(nanoseconds: 20_000_000)
        // 两次失败耗尽 1 次自动重试，验证失败后清理 .droiddock-part
        await provider.enqueueTransientErrors([DeviceError.busy, DeviceError.busy])

        let session = DeviceSession(provider: provider)
        let queue = TransferQueue()
        await queue.attachSession(session, deviceID: DeviceID(rawValue: "fake-1"))

        let destDir = tempRoot.appendingPathComponent("FailedDest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let taskIDs = await queue.enqueueDownloads(nodes: [node], toLocalDirectory: destDir)

        try await waitUntilIdle(queue)

        let finalURL = destDir.appendingPathComponent("broken.bin")
        let partURL = URL(fileURLWithPath: finalURL.path + ".droiddock-part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))

        let snap = await queue.snapshot()
        let task = try XCTUnwrap(snap.tasks.first { $0.id == taskIDs[0] })
        if case .failed(let msg) = task.state {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("期望任务失败状态，实际为 \(task.state)")
        }
        XCTAssertEqual(task.retryCount, 1)
    }

    func testDownloadAutoRetryOnceSucceedsAndCancelCleansPartFile() async throws {
        let storageID: UInt32 = 65537
        let payload = Data("retry-success-data".utf8)
        let node = RemoteNode(
            id: "\(storageID):12",
            storageID: storageID,
            path: "/Download/ok.txt",
            name: "ok.txt",
            isDirectory: false,
            size: UInt64(payload.count),
            modified: Date(),
            kind: .document
        )
        let slowNode = RemoteNode(
            id: "\(storageID):13",
            storageID: storageID,
            path: "/Download/slow.bin",
            name: "slow.bin",
            isDirectory: false,
            size: 9000,
            modified: Date(),
            kind: .other
        )
        let provider = FakeFileProvider(
            directories: [storageID: ["/Download": [node, slowNode]]],
            filePayloads: [node.id: payload, slowNode.id: Data(repeating: 0x55, count: 9000)]
        )
        await provider.enqueueTransientErrors([DeviceError.busy])

        let session = DeviceSession(provider: provider)
        let queue = TransferQueue()
        await queue.attachSession(session, deviceID: DeviceID(rawValue: "fake-1"))

        let destDir = tempRoot.appendingPathComponent("RetryAndCancel", isDirectory: true)
        _ = await queue.enqueueDownloads(nodes: [node], toLocalDirectory: destDir)
        try await waitUntilIdle(queue)

        let snap1 = await queue.snapshot()
        XCTAssertEqual(snap1.completedCount, 1)
        XCTAssertEqual(snap1.tasks.first?.retryCount, 1)

        // 再测取消时清理 .droiddock-part
        await provider.setDownloadDelay(nanoseconds: 120_000_000)
        let cancelIDs = await queue.enqueueDownloads(nodes: [slowNode], toLocalDirectory: destDir)
        try await Task.sleep(nanoseconds: 40_000_000)
        await queue.cancel(taskID: cancelIDs[0])
        try await waitUntilIdle(queue)

        let slowFinal = destDir.appendingPathComponent("slow.bin")
        let slowPart = URL(fileURLWithPath: slowFinal.path + ".droiddock-part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: slowFinal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: slowPart.path))

        let snap2 = await queue.snapshot()
        XCTAssertEqual(snap2.tasks.last?.state, .cancelled)
    }

    func testUploadConflictsAndPreFlightInvalidFilename() async throws {
        let storageID: UInt32 = 65537
        let existingNode = RemoteNode(
            id: "\(storageID):20",
            storageID: storageID,
            path: "/Documents/note.txt",
            name: "note.txt",
            isDirectory: false,
            size: 3,
            modified: Date(),
            kind: .document
        )
        let provider = FakeFileProvider(
            directories: [storageID: ["/": [], "/Documents": [existingNode]]],
            filePayloads: [existingNode.id: Data("old".utf8)]
        )
        let session = DeviceSession(provider: provider)
        let queue = TransferQueue()
        await queue.attachSession(session, deviceID: DeviceID(rawValue: "fake-1"))

        let localNote = tempRoot.appendingPathComponent("note.txt")
        try Data("new-content".utf8).write(to: localNote)

        // 1. 前置文件名合法性校验（冒号为 Android 非法字符），不启动传输直接标失败
        let badURL = tempRoot.appendingPathComponent("bad:file.txt")
        let badIDs = await queue.enqueueUploads(urls: [badURL], toRemoteDir: "/Documents", storage: storageID)
        let badSnap = await queue.snapshot()
        let badTask = try XCTUnwrap(badSnap.tasks.first { $0.id == badIDs[0] })
        if case .failed = badTask.state {} else {
            XCTFail("非法文件名应直接标记为失败")
        }

        // 2. rename 策略生成 note (1).txt
        await queue.setConflictStrategy(.rename)
        _ = await queue.enqueueUploads(urls: [localNote], toRemoteDir: "/Documents", storage: storageID)
        try await waitUntilIdle(queue)
        let dirAfterRename = try await provider.list(dir: "/Documents", storage: storageID)
        XCTAssertTrue(dirAfterRename.contains { $0.name == "note (1).txt" })

        // 3. skip 策略不覆盖原文件
        try Data("skipped-content".utf8).write(to: localNote)
        await queue.setConflictStrategy(.skip)
        _ = await queue.enqueueUploads(urls: [localNote], toRemoteDir: "/Documents", storage: storageID)
        try await waitUntilIdle(queue)
        let skippedPayload = await provider.payload(for: existingNode.id)
        XCTAssertEqual(skippedPayload, Data("old".utf8))

        // 4. overwrite 策略替换原文件
        try Data("overwritten".utf8).write(to: localNote)
        await queue.setConflictStrategy(.overwrite)
        _ = await queue.enqueueUploads(urls: [localNote], toRemoteDir: "/Documents", storage: storageID)
        try await waitUntilIdle(queue)
        let dirAfterOverwrite = try await provider.list(dir: "/Documents", storage: storageID)
        let latest = try XCTUnwrap(dirAfterOverwrite.first { $0.name == "note.txt" })
        let overwrittenPayload = await provider.payload(for: latest.id)
        XCTAssertEqual(overwrittenPayload, Data("overwritten".utf8))
    }

    func testBrowserCreateDirectoryAndDeleteNodes() async throws {
        let storageID: UInt32 = 65537
        let existingFile = RemoteNode(
            id: "\(storageID):30",
            storageID: storageID,
            path: "/Download/old.apk",
            name: "old.apk",
            isDirectory: false,
            size: 120,
            modified: Date(),
            kind: .document
        )
        let provider = FakeFileProvider(directories: [
            storageID: [
                "/": [],
                "/Download": [existingFile],
            ],
        ])
        let session = DeviceSession(provider: provider)
        let browser = BrowserModel()
        await browser.attachSession(session, deviceID: DeviceID(rawValue: "fake-1"))
        await browser.selectSidebar(.downloads)
        XCTAssertEqual(browser.nodes.count, 1)

        // 非法目录名被拒绝
        let invalidResult = await browser.createDirectory(name: "bad/dir")
        XCTAssertNotNil(invalidResult)

        // 合法目录创建成功
        let okResult = await browser.createDirectory(name: "WorkFiles")
        XCTAssertNil(okResult)
        XCTAssertTrue(browser.nodes.contains { $0.name == "WorkFiles" && $0.isDirectory })

        // 删除文件成功并从视图消失
        await browser.deleteNodes([existingFile])
        XCTAssertFalse(browser.nodes.contains { $0.id == existingFile.id })
    }

    private func waitUntilIdle(_ queue: TransferQueue, timeoutSeconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let snap = await queue.snapshot()
            if snap.activeCount == 0 && !snap.hasRunningWorker {
                return
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTFail("传输队列在 \(timeoutSeconds)s 内未空闲")
    }
}
