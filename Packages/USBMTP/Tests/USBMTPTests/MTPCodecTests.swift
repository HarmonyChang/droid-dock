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
}

/// 脚本化传输：按顺序返回预置的字节块，验证会话的事务/分块拼装逻辑。
final class ScriptedTransport: MTPTransport, @unchecked Sendable {
    var sent: [Data] = []
    var replies: [Data]
    init(replies: [Data]) { self.replies = replies }
    func send(_ data: Data) async throws { sent.append(data) }
    func receive(maxLength: Int) async throws -> Data { replies.removeFirst() }
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
}
