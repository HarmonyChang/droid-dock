import AppKit
import SwiftUI

/// 应用主窗口根视图：NavigationSplitView + 右侧工具栏与浏览内容区、悬浮传输托盘与双击缩放图片查看器。
struct MainWindowView: View {
    let appState: AppState

    @State private var keyMonitor: Any?

    var body: some View {
        @Bindable var bindableState = appState
        return ZStack {
            NavigationSplitView {
                SidebarView(appState: appState)
                    .navigationSplitViewColumnWidth(232)
            } detail: {
                VStack(spacing: 0) {
                    BrowserToolbarView(appState: appState)
                    Divider().overlay(appState.palette.dividerColor)
                    ZStack(alignment: .bottom) {
                        BrowserContentView(appState: appState)

                        if appState.transferModel.shouldShowTray && appState.browser.selectedSidebar != .transfers {
                            TransferTrayView(appState: appState)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: appState.transferModel.shouldShowTray)
                }
            }

            if let previewNode = appState.browser.previewingNode {
                PhotoLightboxView(appState: appState, node: previewNode)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: appState.browser.previewingNode?.id)
        .preferredColorScheme(.light)
        .tint(appState.palette.accent)
        .background(keyboardShortcuts)
        .onAppear {
            installKeyMonitorIfNeeded()
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
        .sheet(isPresented: $bindableState.showWirelessPairingSheet) {
            WirelessPairingSheetView(appState: appState)
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") {
                appState.browser.selectAllVisible()
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("") {
                Task { await appState.browser.reload() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }

            // 图片查看器打开时始终优先响应 Esc / 空格 / 左右方向键切换照片（不受背后搜索框焦点影响）
            if appState.browser.previewingNode != nil {
                switch event.keyCode {
                case 53, 49:
                    appState.browser.closePreview()
                    return nil
                case 123:
                    Task { @MainActor in
                        await appState.browser.previewAdjacentPhoto(step: -1)
                    }
                    return nil
                case 124:
                    Task { @MainActor in
                        await appState.browser.previewAdjacentPhoto(step: 1)
                    }
                    return nil
                default:
                    return event
                }
            }

            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            // 空格键：预览选中文件
            if event.keyCode == 49, !appState.browser.selectedNodes.isEmpty {
                Task { @MainActor in
                    await appState.browser.toggleSpacePreview()
                }
                return nil
            }
            return event
        }
    }
}
