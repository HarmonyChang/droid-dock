import Foundation

// 依据 USB-IF《Media Transfer Protocol》公开规范实现；禁止复制 libmtp 等 GPL/LGPL 代码。

public enum MTPContainerType: UInt16, Sendable {
    case command = 1, data = 2, response = 3, event = 4
}

public enum MTPOperation {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getStorageInfo: UInt16 = 0x1005
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let getThumb: UInt16 = 0x100A
    public static let deleteObject: UInt16 = 0x100B
    public static let sendObjectInfo: UInt16 = 0x100C
    public static let sendObject: UInt16 = 0x100D
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let getPartialObject: UInt16 = 0x101B
}

public enum MTPDeviceProperty {
    public static let batteryLevel: UInt16 = 0x5001
    public static let deviceFriendlyName: UInt16 = 0xD402
}

public enum MTPResponseCode {
    public static let ok: UInt16 = 0x2001
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let storeFull: UInt16 = 0x200C
    public static let objectWriteProtected: UInt16 = 0x200D
    public static let storeReadOnly: UInt16 = 0x200E
    public static let accessDenied: UInt16 = 0x200F
    public static let invalidParentObject: UInt16 = 0x201A
    public static let sessionAlreadyOpen: UInt16 = 0x201E
}

public enum MTPError: Error, Sendable, Equatable {
    case malformedData(String)
    case unexpectedContainer(String)
    case responseFailed(code: UInt16)
    case timeout(String)
    case busy(String)
    case transport(String)
    case noDevice
}

/// 容器：12 字节头（长度、类型、操作码/响应码、事务号，小端）+ 参数或数据负载。
public struct MTPContainer: Sendable, Equatable {
    public static let headerSize = 12
    public var type: MTPContainerType
    public var code: UInt16
    public var transactionID: UInt32
    public var payload: Data

    public init(type: MTPContainerType, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
        self.type = type
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u32(UInt32(Self.headerSize + payload.count))
        w.u16(type.rawValue)
        w.u16(code)
        w.u32(transactionID)
        w.data.append(payload)
        return w.data
    }

    /// 从完整字节流解析（长度字段必须与数据一致）。
    public static func decode(_ bytes: Data) throws -> MTPContainer {
        var r = ByteReader(bytes)
        let length = try r.u32()
        let rawType = try r.u16()
        let code = try r.u16()
        let tid = try r.u32()
        guard let type = MTPContainerType(rawValue: rawType) else {
            throw MTPError.malformedData("未知容器类型 \(rawType)")
        }
        guard Int(length) == bytes.count, bytes.count >= headerSize else {
            throw MTPError.malformedData("容器长度 \(length) 与数据 \(bytes.count) 不符")
        }
        return MTPContainer(type: type, code: code, transactionID: tid, payload: Data(bytes.suffix(from: bytes.startIndex + headerSize)))
    }

    public static func command(_ op: UInt16, tid: UInt32, params: [UInt32]) -> MTPContainer {
        var w = ByteWriter()
        params.forEach { w.u32($0) }
        return MTPContainer(type: .command, code: op, transactionID: tid, payload: w.data)
    }
}

public struct ByteWriter {
    public var data = Data()
    public init() {}
    public mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    public mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }

    /// 写入 MTP 字符串：1 字节字符数（含结尾 0），后接 UTF-16LE；空串写入单个 0 字节。
    public mutating func string(_ s: String) {
        if s.isEmpty {
            data.append(0)
            return
        }
        let units = Array(s.utf16.prefix(254))
        data.append(UInt8(units.count + 1))
        for u in units { u16(u) }
        u16(0)
    }
}

public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0
    public init(_ data: Data) { bytes = Array(data) }
    public var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw MTPError.malformedData("数据不足：需要 \(n)，剩余 \(remaining)") }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }
    public mutating func u8() throws -> UInt8 {
        guard let b = try take(1).first else { throw MTPError.malformedData("数据不足") }
        return b
    }
    public mutating func u16() throws -> UInt16 {
        try take(2).enumerated().reduce(0) { $0 | UInt16($1.element) << (8 * UInt16($1.offset)) }
    }
    public mutating func u32() throws -> UInt32 {
        try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
    public mutating func u64() throws -> UInt64 {
        try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
    /// MTP 字符串：1 字节字符数（含结尾 0），后接 UTF-16LE；0 表示空串。
    public mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        let raw = try take(count * 2)
        var units: [UInt16] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            units.append(UInt16(raw[i]) | UInt16(raw[i + 1]) << 8)
            i += 2
        }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    public mutating func u16Array() throws -> [UInt16] {
        let n = Int(try u32())
        return try (0..<n).map { _ in try u16() }
    }
    public mutating func u32Array() throws -> [UInt32] {
        let n = Int(try u32())
        return try (0..<n).map { _ in try u32() }
    }
}

// MARK: - 数据集

public struct MTPDeviceInfo: Sendable {
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String
    public let operationsSupported: [UInt16]
    public let devicePropertiesSupported: [UInt16]

    public var supportsGetThumb: Bool { operationsSupported.contains(MTPOperation.getThumb) }
    public var supportsGetPartialObject: Bool { operationsSupported.contains(MTPOperation.getPartialObject) }
    public var supportsBatteryLevel: Bool { devicePropertiesSupported.contains(MTPDeviceProperty.batteryLevel) }

    public init(
        manufacturer: String,
        model: String,
        deviceVersion: String,
        serialNumber: String,
        operationsSupported: [UInt16],
        devicePropertiesSupported: [UInt16] = []
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
        self.operationsSupported = operationsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
    }

    public static func parse(_ data: Data) throws -> MTPDeviceInfo {
        var r = ByteReader(data)
        _ = try r.u16()      // StandardVersion
        _ = try r.u32()      // VendorExtensionID
        _ = try r.u16()      // MTPVersion
        _ = try r.string()   // MTPExtensions
        _ = try r.u16()      // FunctionalMode
        let ops = try r.u16Array()
        _ = try r.u16Array() // EventsSupported
        let props = try r.u16Array() // DevicePropertiesSupported
        _ = try r.u16Array() // CaptureFormats
        _ = try r.u16Array() // PlaybackFormats
        return MTPDeviceInfo(
            manufacturer: try r.string(), model: try r.string(),
            deviceVersion: try r.string(), serialNumber: try r.string(),
            operationsSupported: ops,
            devicePropertiesSupported: props)
    }
}

public struct MTPStorageInfo: Sendable {
    public let id: UInt32
    public let maxCapacity: UInt64
    public let freeSpace: UInt64
    public let description: String

    public static func parse(_ data: Data, id: UInt32) throws -> MTPStorageInfo {
        var r = ByteReader(data)
        _ = try r.u16()  // StorageType
        _ = try r.u16()  // FilesystemType
        _ = try r.u16()  // AccessCapability
        let max = try r.u64()
        let free = try r.u64()
        _ = try r.u32()  // FreeSpaceInObjects
        return MTPStorageInfo(id: id, maxCapacity: max, freeSpace: free, description: try r.string())
    }
}

public struct MTPObjectInfo: Sendable {
    public static let associationFormat: UInt16 = 0x3001   // 目录
    public let handle: UInt32
    public let storageID: UInt32
    public let format: UInt16
    public let compressedSize: UInt32   // 0xFFFFFFFF 表示 ≥4GB（待验证）
    public let thumbFormat: UInt16
    public let parent: UInt32
    public let filename: String
    public let dateCreated: String      // 格式 YYYYMMDDThhmmss[.s][Z|±hhmm]，时区行为待验证
    public let dateModified: String
    public var isDirectory: Bool { format == Self.associationFormat }

    public static func parse(_ data: Data, handle: UInt32) throws -> MTPObjectInfo {
        var r = ByteReader(data)
        let storage = try r.u32()
        let format = try r.u16()
        _ = try r.u16()              // ProtectionStatus
        let size = try r.u32()
        let thumbFormat = try r.u16()
        _ = try r.u32(); _ = try r.u32(); _ = try r.u32()   // 缩略图尺寸
        _ = try r.u32(); _ = try r.u32(); _ = try r.u32()   // 图像宽高深
        let parent = try r.u32()
        _ = try r.u16()              // AssociationType
        _ = try r.u32()              // AssociationDesc
        _ = try r.u32()              // SequenceNumber
        return MTPObjectInfo(
            handle: handle, storageID: storage, format: format, compressedSize: size,
            thumbFormat: thumbFormat, parent: parent, filename: try r.string(),
            dateCreated: try r.string(), dateModified: try r.string())
    }

    /// 根据文件名扩展名推断 USB-IF MTP ObjectFormat 码。
    public static func inferFormat(filename: String, isDirectory: Bool) -> UInt16 {
        if isDirectory { return associationFormat }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return 0x3801
        case "png": return 0x380B
        case "gif": return 0x3807
        case "bmp": return 0x3804
        case "tif", "tiff": return 0x3802
        case "txt", "md", "log", "json", "xml", "csv": return 0x3004
        case "htm", "html": return 0x3005
        case "wav": return 0x3008
        case "mp3": return 0x3009
        case "mp4", "m4v": return 0xB982
        default: return 0x3000 // Undefined（Android MTP 通用接受格式）
        }
    }

    /// 构造用于 `SendObjectInfo` 的标准 ObjectInfo 数据集。
    public static func encodeForSend(
        storageID: UInt32,
        parent: UInt32,
        filename: String,
        size: UInt64,
        isDirectory: Bool,
        dateString: String = ""
    ) -> Data {
        var w = ByteWriter()
        w.u32(storageID)
        w.u16(inferFormat(filename: filename, isDirectory: isDirectory))
        w.u16(0) // ProtectionStatus
        w.u32(isDirectory ? 0 : UInt32(min(size, UInt64(UInt32.max))))
        w.u16(0) // ThumbFormat
        w.u32(0); w.u32(0); w.u32(0) // ThumbCompressedSize, ThumbPixWidth, ThumbPixHeight
        w.u32(0); w.u32(0); w.u32(0) // ImagePixWidth, ImagePixHeight, ImageBitDepth
        w.u32(parent)
        w.u16(isDirectory ? 0x0001 : 0) // AssociationType: 1 = Generic Folder
        w.u32(0) // AssociationDesc
        w.u32(0) // SequenceNumber
        w.string(filename)
        w.string(dateString) // DateCreated
        w.string(dateString) // DateModified
        w.string("")         // Keywords
        return w.data
    }
}
