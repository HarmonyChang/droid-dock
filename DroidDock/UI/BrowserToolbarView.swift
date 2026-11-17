import SwiftUI

/// 主区域顶部工具栏（52 pt 高）：导航前进后退、标题计数、视图切换、搜索与传输入口。
struct BrowserToolbarView: View {
    let appState: AppState

    private var palette: ElegantPalette { appState.palette }

    var body: some View {
        @Bindable var browser = appState.browser

        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    Task { await browser.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .disabled(!browser.canGoBack)

                Button {
                    Task { await browser.goForward() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .disabled(!browser.canGoForward)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(browser.currentTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                if appState.effectiveDeviceState == .ready && browser.selectedSidebar != .transfers {
                    Text("\(browser.filteredNodes.count) 项 · 已选 \(browser.selectedNodeIDs.count) 项")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
            }

            Spacer()

            Picker("视图", selection: $browser.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                TextField("搜索文件名", text: $browser.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.primaryText)
                if !browser.searchQuery.isEmpty {
                    Button {
                        browser.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 176)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(palette.dividerColor, lineWidth: 1)
            )

            Button("上传到手机") {
                guard let storageID = browser.activeStorageID else { return }
                TransferPanelHelper.pickFilesAndUpload(
                    to: browser.effectiveUploadDirectory,
                    storage: storageID,
                    transferModel: appState.transferModel
                )
            }
            .buttonStyle(.bordered)
            .disabled(appState.effectiveDeviceState != .ready || browser.activeStorageID == nil)

            Button("导入到 Mac") {
                let selected = browser.selectedNodes
                if selected.isEmpty {
                    browser.infoBannerMessage = "请先选中要导入的照片或文件，也可以直接从窗口拖拽到访达。"
                    return
                }
                TransferPanelHelper.pickDestinationAndDownload(
                    nodes: selected,
                    transferModel: appState.transferModel
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(appState.effectiveDeviceState != .ready)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(palette.toolbarBackground)
    }
}
