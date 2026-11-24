import XCTest
@testable import USBMTP

final class MTPCodecTests: XCTestCase {
    private func mtpString(_ s: String) -> Data {
        guard !s.isEmpty else { return Data([0]) }
        var d = Data([UInt8(s.utf16.count + 1)])
        for u in s.utf16 + [0] { d.append(contentsOf: [UInt8(u & 0xFF), UInt8(u >> 8)]) }
        return d
    }

    func testContainerRoundTrip() throws {
        let c = MTPContainer.command(MTPOperation.getObjectHandles, tid: 7, params: [1, 0, 0xFFFF_FFFF])
        let bytes = c.encoded()
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(Array(bytes.prefix(4)), [24, 0, 0, 0])      // 小端长度
        XCTAssertEqual(try MTPContainer.decode(bytes), c)
    }

    func testDecodeRejectsLengthMismatch() {
        var bytes = MTPContainer(type: .response, code: 0x2001, transactionID: 1).encoded()
        bytes.append(0)
        XCTAssertThrowsError(try MTPContainer.decode(bytes))
    }

    func testStringParsing() throws {
        var r = ByteReader(mtpString("DCIM") + mtpString(""))
        XCTAssertEqual(try r.string(), "DCIM")
        XCTAssertEqual(try r.string(), "")
    }

    func testStringChinese() throws {
        var r = ByteReader(mtpString("相册.jpg"))
        XCTAssertEqual(try r.string(), "相册.jpg")
    }

    func testReaderThrowsOnShortData() {
        var r = ByteReader(Data([1, 2]))
        XCTAssertThrowsError(try r.u32())
    }

    func testObjectInfoParse() throws {
        var w = ByteWriter()
        w.u32(0x10001); w.u16(0x3801); w.u16(0); w.u32(2048)
        w.u16(0x3808); [UInt32](repeating: 0, count: 3).forEach { w.u32($0) }
        [UInt32](repeating: 0, count: 3).forEach { w.u32($0) }
        w.u32(5); w.u16(0); w.u32(0); w.u32(0)
        w.data.append(mtpString("IMG_1.jpg") + mtpString("20261116T101010") + mtpString("20261116T101011") + mtpString(""))
        let info = try MTPObjectInfo.parse(w.data, handle: 9)
        XCTAssertEqual(info.filename, "IMG_1.jpg")
        XCTAssertEqual(info.parent, 5)
        XCTAssertEqual(info.compressedSize, 2048)
        XCTAssertFalse(info.isDirectory)
        XCTAssertEqual(info.dateModified, "20261116T101011")
    }

    func testObjectInfoEncodeRoundTrip() throws {
        let fileData = MTPObjectInfo.encodeForSend(
            storageID: 0x10001,
            parent: 42,
            filename: "holiday_照片.jpg",
            size: 1_048_576,
            isDirectory: false,
            dateString: "20261116T120000"
        )
        let parsedFile = try MTPObjectInfo.parse(fileData, handle: 99)
        XCTAssertEqual(parsedFile.storageID, 0x10001)
        XCTAssertEqual(parsedFile.parent, 42)
        XCTAssertEqual(parsedFile.filename, "holiday_照片.jpg")
        XCTAssertEqual(parsedFile.compressedSize, 1_048_576)
        XCTAssertEqual(parsedFile.format, 0x3801)
        XCTAssertFalse(parsedFile.isDirectory)
        XCTAssertEqual(parsedFile.dateCreated, "20261116T120000")
        XCTAssertEqual(parsedFile.dateModified, "20261116T120000")

        let dirData = MTPObjectInfo.encodeForSend(
            storageID: 0x10001,
            parent: 0xFFFF_FFFF,
            filename: "新建相册",
            size: 0,
            isDirectory: true
        )
        let parsedDir = try MTPObjectInfo.parse(dirData, handle: 100)
        XCTAssertTrue(parsedDir.isDirectory)
        XCTAssertEqual(parsedDir.format, MTPObjectInfo.associationFormat)
        XCTAssertEqual(parsedDir.filename, "新建相册")
        XCTAssertEqual(parsedDir.compressedSize, 0)
    }

    func testDeviceInfoParsesDevicePropertiesSupported() throws {
        var w = ByteWriter()
        w.u16(100) // StandardVersion
        w.u32(6)   // VendorExtensionID
        w.u16(100) // MTPVersion
        w.string("android.com: 1.0;")
        w.u16(0)   // FunctionalMode
        w.u32(2); w.u16(MTPOperation.getDeviceInfo); w.u16(MTPOperation.getDevicePropValue)
        w.u32(0)   // EventsSupported
        w.u32(2); w.u16(MTPDeviceProperty.batteryLevel); w.u16(MTPDeviceProperty.deviceFriendlyName)
        w.u32(0)   // CaptureFormats
        w.u32(0)   // PlaybackFormats
        w.string("OnePlus")
        w.string("PKX110")
        w.string("1.0")
        w.string("ABC123")

        let info = try MTPDeviceInfo.parse(w.data)
        XCTAssertEqual(info.manufacturer, "OnePlus")
        XCTAssertEqual(info.model, "PKX110")
        XCTAssertEqual(info.devicePropertiesSupported, [MTPDeviceProperty.batteryLevel, MTPDeviceProperty.deviceFriendlyName])
        XCTAssertTrue(info.supportsBatteryLevel)
    }
}

/// 脚本化传输：按顺序返回预置的字节块，验证会话的事务/分块拼装逻辑。
final class ScriptedTransport: MTPTransport, @unchecked Sendable {
    var sent: [Data] = []
    var replies: [Data]
    init(replies: [Data]) { self.replies = replies }
    func send(_ data: Data) async throws { sent.append(data) }
    func receive(maxLength: Int) async throws -> Data { replies.removeFirst() }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func mutate(_ block: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        block(&_value)
    }
}

final class MTPSessionTests: XCTestCase {
    func testExecuteReassemblesChunkedDataThenResponse() async throws {
        let payload = Data((0..<20).map { UInt8($0) })
        let dataBytes = MTPContainer(type: .data, code: MTPOperation.getStorageIDs, transactionID: 1, payload: payload).encoded()
        let resp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1).encoded()
        let t = ScriptedTransport(replies: [dataBytes.prefix(15), dataBytes.suffix(from: 15), resp])
        let result = try await MTPSession(transport: t).execute(MTPOperation.getStorageIDs)
        XCTAssertEqual(result.data, payload)
        XCTAssertEqual(result.responseCode, MTPResponseCode.ok)
        XCTAssertEqual(t.sent.count, 1)
    }

    func testExecuteSkipsZeroLengthPacket() async throws {
        let dataBytes = MTPContainer(type: .data, code: MTPOperation.getStorageIDs, transactionID: 1, payload: Data([1, 2])).encoded()
        let resp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1).encoded()
        let t = ScriptedTransport(replies: [dataBytes, Data(), resp])
        let result = try await MTPSession(transport: t).execute(MTPOperation.getStorageIDs)
        XCTAssertEqual(result.data, Data([1, 2]))
    }

    func testDownloadObjectStreamsChunks() async throws {
        let payload = Data((0..<200).map { UInt8($0 & 0xFF) })
        let dataBytes = MTPContainer(type: .data, code: MTPOperation.getObject, transactionID: 1, payload: payload).encoded()
        let resp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1).encoded()
        let t = ScriptedTransport(replies: [
            dataBytes.prefix(20),
            Data(),
            Data(dataBytes.dropFirst(20).prefix(90)),
            Data(dataBytes.dropFirst(110)),
            resp
        ])
        let collected = LockedBox(Data())
        let progressEvents = LockedBox<[UInt64]>([])
        try await MTPSession(transport: t).downloadObject(
            handle: 7,
            onChunk: { chunk in collected.mutate { $0.append(chunk) } },
            progress: { bytes in progressEvents.mutate { $0.append(bytes) } }
        )
        XCTAssertEqual(collected.value, payload)
        XCTAssertEqual(progressEvents.value.last, 200)
        XCTAssertGreaterThanOrEqual(progressEvents.value.count, 3)
    }

    func testUploadObjectCoalescesHeaderAndStreams64K() async throws {
        // 70,000 字节 > 65,536 - 12，验证首个包恰好 65,536 字节且分两次写入
        let fileData = Data((0..<70_000).map { UInt8($0 & 0xFF) })
        var handlePayload = ByteWriter()
        handlePayload.u32(0x10001)
        handlePayload.u32(10)
        handlePayload.u32(888)
        let infoResp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1, payload: handlePayload.data).encoded()
        let sendResp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 2).encoded()
        let t = ScriptedTransport(replies: [infoResp, sendResp])

        let offset = LockedBox(0)
        let progressEvents = LockedBox<[UInt64]>([])
        let newHandle = try await MTPSession(transport: t).uploadObject(
            storageID: 0x10001,
            parentHandle: 10,
            filename: "video.mp4",
            fileSize: UInt64(fileData.count),
            readChunk: { maxBytes in
                var out = Data()
                offset.mutate { cur in
                    let end = min(fileData.count, cur + maxBytes)
                    out = fileData.subdata(in: cur..<end)
                    cur = end
                }
                return out
            },
            progress: { bytes in progressEvents.mutate { $0.append(bytes) } }
        )
        XCTAssertEqual(newHandle, 888)
        // sent[0]=SendObjectInfo cmd, sent[1]=SendObjectInfo data, sent[2]=SendObject cmd, sent[3]=Data pkt1(65536), sent[4]=Data pkt2
        XCTAssertEqual(t.sent.count, 5)
        XCTAssertEqual(t.sent[3].count, 65_536)
        XCTAssertEqual(t.sent[4].count, 70_000 - (65_536 - 12))
        XCTAssertEqual(progressEvents.value, [UInt64(65_536 - 12), 70_000])
    }

    func testMakeDirectoryAndDeleteObject() async throws {
        var handlePayload = ByteWriter()
        handlePayload.u32(0x10001); handlePayload.u32(0xFFFF_FFFF); handlePayload.u32(555)
        let mkResp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1, payload: handlePayload.data).encoded()
        let delResp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 2).encoded()
        let t = ScriptedTransport(replies: [mkResp, delResp])
        let session = MTPSession(transport: t)
        let created = try await session.makeDirectory(storageID: 0x10001, parentHandle: 0xFFFF_FFFF, name: "NewDir")
        XCTAssertEqual(created, 555)
        try await session.deleteObject(handle: 555)
        XCTAssertEqual(t.sent.count, 3)
        let infoData = try MTPContainer.decode(t.sent[1]).payload
        let parsed = try MTPObjectInfo.parse(infoData, handle: 0)
        XCTAssertTrue(parsed.isDirectory)
        XCTAssertEqual(parsed.filename, "NewDir")
    }

    func testUploadObjectSendsZLPOnMaxPacketSizeBoundary() async throws {
        // 500 + 12 = 512 字节，恰为 USB 2.0 Bulk wMaxPacketSize (512) 整数倍，必须在数据尾发送一次空 Data (ZLP)
        let exactOnePacketPayload = Data(repeating: 0x2A, count: 500)
        var handlePayload = ByteWriter()
        handlePayload.u32(0x10001); handlePayload.u32(10); handlePayload.u32(901)
        let infoResp1 = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1, payload: handlePayload.data).encoded()
        let sendResp1 = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 2).encoded()
        let t1 = ScriptedTransport(replies: [infoResp1, sendResp1])

        let offset1 = LockedBox(0)
        _ = try await MTPSession(transport: t1).uploadObject(
            storageID: 0x10001,
            parentHandle: 10,
            filename: "exact500.bin",
            fileSize: 500,
            readChunk: { maxBytes in
                var out = Data()
                offset1.mutate { cur in
                    let end = min(exactOnePacketPayload.count, cur + maxBytes)
                    out = exactOnePacketPayload.subdata(in: cur..<end)
                    cur = end
                }
                return out
            },
            progress: { _ in }
        )
        XCTAssertEqual(t1.sent.count, 5)
        XCTAssertEqual(t1.sent[3].count, 512)
        XCTAssertEqual(t1.sent[4], Data())

        // 65,524 + 12 = 65,536 字节（128 × 512），同样必须补发一次 ZLP
        let exactChunkPayload = Data(repeating: 0x3B, count: 65_524)
        let infoResp2 = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1, payload: handlePayload.data).encoded()
        let sendResp2 = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 2).encoded()
        let t2 = ScriptedTransport(replies: [infoResp2, sendResp2])

        let offset2 = LockedBox(0)
        _ = try await MTPSession(transport: t2).uploadObject(
            storageID: 0x10001,
            parentHandle: 10,
            filename: "exact65524.bin",
            fileSize: 65_524,
            readChunk: { maxBytes in
                var out = Data()
                offset2.mutate { cur in
                    let end = min(exactChunkPayload.count, cur + maxBytes)
                    out = exactChunkPayload.subdata(in: cur..<end)
                    cur = end
                }
                return out
            },
            progress: { _ in }
        )
        XCTAssertEqual(t2.sent.count, 5)
        XCTAssertEqual(t2.sent[3].count, 65_536)
        XCTAssertEqual(t2.sent[4], Data())
    }

    func testBatteryLevelReadsValidAndHandlesUnsupported() async throws {
        let batteryData = MTPContainer(
            type: .data,
            code: MTPOperation.getDevicePropValue,
            transactionID: 1,
            payload: Data([87])
        ).encoded()
        let okResp = MTPContainer(type: .response, code: MTPResponseCode.ok, transactionID: 1).encoded()
        let unsupportedResp = MTPContainer(type: .response, code: 0x200A, transactionID: 2).encoded()

        let t = ScriptedTransport(replies: [batteryData, okResp, unsupportedResp])
        let session = MTPSession(transport: t)

        let first = try await session.batteryLevel()
        XCTAssertEqual(first, 87)

        let second = try await session.batteryLevel()
        XCTAssertNil(second)
    }
}
