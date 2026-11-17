import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// M4 诊断日志导出服务：汇总当前设备状态、传输状态与进程内最近 `OSLog` 日志，保存为纯文本报告。
@MainActor
enum DiagnosticsService {
    static func buildReport(appState: AppState) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var lines: [String] = []
        lines.append("=== DroidDock 诊断报告 ===")
        lines.append("生成时间: \(now)")
        lines.append("应用版本: \(version) (\(build))")
        lines.append("系统版本: \(osVersion)")
        lines.append("")

        lines.append("[当前连接设备]")
        if appState.deviceManager.devices.isEmpty {
            lines.append("- 未检测到支持 MTP 的 USB 设备")
        } else {
            for dev in appState.deviceManager.devices {
                let state = appState.deviceManager.deviceStates[dev.id]
                let marker = dev.id == appState.deviceManager.selectedDeviceID ? " [当前选中]" : ""
                lines.append("- \(dev.name)\(marker) | id=\(dev.id.rawValue) | manufacturer=\(dev.manufacturer) | model=\(dev.model) | state=\(String(describing: state))")
            }
        }
        lines.append("")

        lines.append("[存储卷]")
        if appState.browser.storages.isEmpty {
            lines.append("- 无可用存储卷 (isDeviceLocked=\(appState.browser.isDeviceLocked))")
        } else {
            for storage in appState.browser.storages {
                lines.append("- [\(storage.id)] \(storage.name) | 已用 \(PathUtils.formatByteCount(storage.usedBytes)) / 总计 \(PathUtils.formatByteCount(storage.totalBytes))")
            }
        }
        lines.append("")

        lines.append("[传输队列摘要]")
        let tm = appState.transferModel
        lines.append("进行中: \(tm.activeCount), 已完成: \(tm.completedCount), 失败: \(tm.failedCount), 冲突策略: \(tm.conflictStrategy.rawValue)")
        let failedTasks = tm.tasks.filter {
            if case .failed = $0.state { return true }
            return false
        }
        for task in failedTasks.prefix(20) {
            if case .failed(let reason) = task.state {
                lines.append("- 失败任务: \(task.filename) (\(task.direction.rawValue)) -> \(reason)")
            }
        }
        lines.append("")

        lines.append("[最近运行日志 (com.droiddock.app)]")
        let recentLogs = collectRecentOSLogLines(limit: 200)
        if recentLogs.isEmpty {
            lines.append("- 暂无进程内日志条目")
        } else {
            lines.append(contentsOf: recentLogs)
        }
        return lines.joined(separator: "\n")
    }

    static func exportDiagnosticsReport(appState: AppState) {
        let report = buildReport(appState: appState)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultFilename = "DroidDock-Diagnostics-\(formatter.string(from: Date())).txt"

        let panel = NSSavePanel()
        panel.title = "导出 DroidDock 诊断日志"
        panel.nameFieldStringValue = defaultFilename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let targetURL = panel.url else { return }
        do {
            try report.write(to: targetURL, atomically: true, encoding: .utf8)
            appState.browser.infoBannerMessage = "诊断日志已保存到：\(targetURL.lastPathComponent)"
        } catch {
            appState.browser.errorMessage = "保存诊断日志失败：\(error.localizedDescription)"
        }
    }

    private static func collectRecentOSLogLines(limit: Int) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-1800))
            let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let entries = try store.getEntries(at: position, matching: predicate)
            let formatter = ISO8601DateFormatter()
            var output: [String] = []
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let time = formatter.string(from: logEntry.date)
                output.append("\(time) [\(logEntry.category)] \(logEntry.composedMessage)")
            }
            if output.count > limit {
                return Array(output.suffix(limit))
            }
            return output
        } catch {
            return ["读取 OSLog 失败：\(error.localizedDescription)"]
        }
    }
}
