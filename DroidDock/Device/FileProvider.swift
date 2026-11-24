import Foundation

/// 设备传输链路类型（USB 有线 / 局域网 Wi-Fi 无线）。
enum DeviceTransportKind: String, Sendable, Equatable {
    case usb
    case wifi
}

/// 设备唯一标识：序列号优先，退化为 vid:pid+locationID 或无线序列标识。
struct DeviceID: Hashable, Sendable {
    let rawValue: String
}

struct DeviceInfo: Sendable, Equatable, Identifiable {
    let id: DeviceID
    let name: String
    let manufacturer: String
    let model: String
    let serialNumber: String
    let transport: DeviceTransportKind

    init(
        id: DeviceID,
        name: String,
        manufacturer: String,
        model: String,
        serialNumber: String,
        transport: DeviceTransportKind = .usb
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.transport = transport
    }
}

struct StorageInfo: Sendable, Equatable, Identifiable {
    let id: UInt32
    let name: String
    let totalBytes: UInt64
    let freeBytes: UInt64

    var usedBytes: UInt64 {
        totalBytes >= freeBytes ? totalBytes - freeBytes : 0
    }
}

enum MediaKind: Sendable, Equatable {
    case photo
    case video
    case audio
    case document
    case other
}

struct RemoteNode: Sendable, Identifiable, Hashable {
    let id: String
    let storageID: UInt32
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date?
    let kind: MediaKind
}

enum DeviceState: Sendable, Equatable {
    case detected
    case locked
    case ready
    case busy
    case error(DeviceError)
}

enum DeviceEvent: Sendable {
    case attached(DeviceInfo)
    case detached(DeviceID)
    case stateChanged(DeviceID, DeviceState)
}

struct DeviceStatusInfo: Sendable, Equatable {
    enum ChargingState: String, Sendable, Equatable {
        case charging = "充电中"
        case full = "已充满"
        case discharging = "使用电池"
        case unknown = "未上报"
    }

    enum NetworkType: String, Sendable, Equatable {
        case wifi = "Wi-Fi"
        case cellular5G = "5G"
        case cellular4G = "4G"
        case cellular3G = "3G"
        case cellular = "蜂窝网络"
        case ethernet = "有线网络"
        case offline = "无网络"
        case unavailable = "未知"
    }

    let batteryLevel: Int?
    let chargingState: ChargingState
    let batteryTempCelsius: Double?
    let networkType: NetworkType
    let wifiSSID: String?
    let ipAddress: String?
    let androidVersion: String?
    let connectionDetail: String?
    let updatedAt: Date
}

typealias BatteryChargingState = DeviceStatusInfo.ChargingState
typealias DeviceNetworkType = DeviceStatusInfo.NetworkType

protocol FileProvider: Sendable {
    func storages() async throws -> [StorageInfo]
    func list(dir: String, storage: UInt32) async throws -> [RemoteNode]
    func listMedia(storage: UInt32, limit: Int) async throws -> [RemoteNode]
    func thumbnail(for node: RemoteNode) async throws -> Data?
    func download(_ node: RemoteNode, to url: URL, progress: @Sendable (UInt64) -> Void) async throws
    func upload(from url: URL, toDir: String, remoteName: String?, storage: UInt32, progress: @Sendable (UInt64) -> Void) async throws -> RemoteNode
    func delete(_ node: RemoteNode) async throws
    func makeDirectory(_ name: String, in dir: String, storage: UInt32) async throws
    func deviceStatus() async throws -> DeviceStatusInfo?
}

extension FileProvider {
    func upload(from url: URL, toDir: String, storage: UInt32, progress: @Sendable (UInt64) -> Void) async throws -> RemoteNode {
        try await upload(from: url, toDir: toDir, remoteName: nil, storage: storage, progress: progress)
    }

    func deviceStatus() async throws -> DeviceStatusInfo? {
        nil
    }
}

protocol DeviceBackend: Sendable {
    func events() -> AsyncStream<DeviceEvent>
    func open(_ id: DeviceID) async throws -> any FileProvider
    func refresh() async
    func invalidateAndReconnect(_ id: DeviceID) async
}

extension DeviceBackend {
    func invalidateAndReconnect(_ id: DeviceID) async {
        await refresh()
    }
}
