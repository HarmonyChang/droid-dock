import Foundation

/// 设备层与文件提供方统一错误类型。
enum DeviceError: Error, Sendable, Equatable, LocalizedError {
    case deviceLocked
    case permissionDenied
    case busy
    case disconnected
    case storageFull
    case invalidName
    case unsupported
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .deviceLocked:
            return "设备已锁定或未开启文件传输模式，请在手机上解锁并选择「文件传输」。"
        case .permissionDenied:
            return "访问 USB 设备接口被拒绝，请检查系统权限或重新插拔设备。"
        case .busy:
            return "设备正忙或被其他应用占用，请稍后重试。"
        case .disconnected:
            return "设备连接已断开。"
        case .storageFull:
            return "设备存储空间不足。"
        case .invalidName:
            return "文件名或路径包含不支持的字符。"
        case .unsupported:
            return "当前设备或阶段暂不支持该操作。"
        case .underlying(let message):
            return message
        }
    }
}
