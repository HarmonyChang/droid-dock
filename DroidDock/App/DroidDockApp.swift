import AppKit
import SwiftUI

@main
struct DroidDockApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView(appState: appState)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    NSApplication.shared.applicationIconImage = AppIconRenderer.makeApplicationIcon(size: 512)
                    appState.start()
                }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandMenu("设备与诊断") {
                Button("无线连接手机…") {
                    appState.showWirelessPairingSheet = true
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("重新检测 USB / 无线设备") {
                    Task { await appState.refreshDevices() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("导出诊断日志…") {
                    DiagnosticsService.exportDiagnosticsReport(appState: appState)
                }
            }
        }
    }
}
