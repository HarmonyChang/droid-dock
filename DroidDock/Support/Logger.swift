import OSLog

/// 统一日志入口，按模块划分 category。
enum Log {
    static let subsystem = "com.droiddock.app"
    static let device = Logger(subsystem: subsystem, category: "device")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let media = Logger(subsystem: subsystem, category: "media")
}
