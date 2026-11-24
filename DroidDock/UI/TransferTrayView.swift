import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 顶部工具栏 / 右键菜单共用的传输文件面板辅助。
@MainActor
enum TransferPanelHelper {
    static func pickDestinationAndDownload(nodes: [RemoteNode], transferModel: TransferModel) {
        guard !nodes.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "选择保存位置"
        panel.message = "将选中的 \(nodes.count) 项从手机导入到 Mac"
        panel.prompt = "导入到此处"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let dirURL = panel.url else { return }
        Task {
            await transferModel.enqueueDownloads(nodes: nodes, to: dirURL)
        }
    }

    static func pickFilesAndUpload(to remoteDir: String, storage: UInt32, transferModel: TransferModel) {
        let panel = NSOpenPanel()
        panel.title = "选择要上传到手机的文件"
        panel.message = "目标路径：\(remoteDir)"
        panel.prompt = "上传到手机"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task {
            await transferModel.enqueueUploads(urls: urls, to: remoteDir, storage: storage)
        }
    }

    static func formatETA(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        if m > 0 {
            return String(format: "%d 分 %02d 秒", m, s)
        }
        return "\(s) 秒"
    }
}

/// 底部浮层（高 56 pt、圆角 12 pt）：实时传输摘要、进度条与取消/清空快捷入口。
struct TransferTrayView: View {
    let appState: AppState

    private var palette: ElegantPalette { appState.palette }
    private var model: TransferModel { appState.transferModel }

    var body: some View {
        let total = model.nonCancelledCount
        let currentIndex = min(
            total,
            model.completedCount + model.failedCount + (model.activeCount > 0 ? 1 : 0)
        )

        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(headlineText(currentIndex: currentIndex, total: total))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let current = model.activeOrCurrentTask {
                        Text(current.filename)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .trailing)
                    }
                }

                if model.isPreparing && model.activeCount == 0 {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(palette.accent)
                } else {
                    ProgressView(value: model.overallProgress)
                        .progressViewStyle(.linear)
                        .tint(model.failedCount > 0 && model.activeCount == 0 ? palette.warningColor : palette.accent)
                }
            }

            HStack(spacing: 6) {
                Button("队列") {
                    Task { await appState.browser.selectSidebar(.transfers) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if model.failedCount > 0 {
                    Button("重试") {
                        model.retryAllFailed()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if model.activeCount > 0 {
                    Button("取消") {
                        model.cancelAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("清空") {
                        model.clearFinished()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        model.dismissTray()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("收起传输浮层")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.cardBackground)
                .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.dividerColor, lineWidth: 1)
        )
    }

    private var statusIcon: some View {
        let iconName: String
        let fg: Color
        let bg: Color

        if model.activeCount > 0 || model.isPreparing {
            let isUpload = model.activeOrCurrentTask?.direction == .upload || model.isPreparing
            iconName = isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
            fg = palette.accent
            bg = palette.accentSoft
        } else if model.failedCount > 0 {
            iconName = "exclamationmark.triangle.fill"
            fg = Color(red: 0.78, green: 0.24, blue: 0.24)
            bg = Color(red: 0.78, green: 0.24, blue: 0.24).opacity(0.12)
        } else {
            iconName = "checkmark.circle.fill"
            fg = palette.successColor
            bg = palette.successColor.opacity(0.14)
        }

        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(bg)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(fg)
            }
    }

    private func headlineText(currentIndex: Int, total: Int) -> String {
        if model.isPreparing && model.activeCount == 0 {
            return model.preparingMessage ?? "正在扫描待传文件…"
        }
        if model.activeCount > 0 {
            var title = "正在传输第 \(max(1, currentIndex))/\(max(1, total)) 项"
            if model.isPreparing {
                title += "（扫描中，已发现 \(model.totalTaskCount) 项）"
            }
            var parts = [title]
            if model.overallSpeedBytesPerSec > 1 {
                let speed = PathUtils.formatByteCount(UInt64(model.overallSpeedBytesPerSec))
                parts.append("\(speed)/s")
            }
            if let eta = TransferPanelHelper.formatETA(model.activeOrCurrentTask?.etaSeconds) {
                parts.append("剩余 \(eta)")
            }
            return parts.joined(separator: " · ")
        }
        if model.failedCount > 0 {
            return "传输结束 · \(model.completedCount) 成功 · \(model.failedCount) 失败"
        }
        return "已完成 \(model.completedCount) 项传输"
    }
}

/// 完整传输队列视图：展示进行中/历史/失败明细、同名冲突策略切换与批量重试/取消。
struct TransfersQueueView: View {
    let appState: AppState

    @State private var isDropTargeted = false

    private var palette: ElegantPalette { appState.palette }
    private var model: TransferModel { appState.transferModel }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(palette.dividerColor)

            if model.tasks.isEmpty && !model.isPreparing {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if model.tasks.count < model.totalTaskCount {
                            Text("队列共 \(model.totalTaskCount) 项，为保持流畅仅展示当前、失败及最近条目（\(model.tasks.count) 条）。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 4)
                        }
                        ForEach(model.tasks) { task in
                            taskRow(task)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.contentBackground)
        .overlay {
            if isDropTargeted && appState.effectiveDeviceState == .ready {
                dropOverlay
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("传输队列")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text("总计 \(model.totalTaskCount) · 进行中 \(model.activeCount) · 已完成 \(model.completedCount) · 失败 \(model.failedCount)" + (model.isPreparing ? " · 扫描中…" : ""))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
            }

            Spacer()

            HStack(spacing: 6) {
                Text("同名冲突")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)

                Picker("同名冲突", selection: Binding(
                    get: { model.conflictStrategy },
                    set: { model.updateConflictStrategy($0) }
                )) {
                    ForEach(ConflictStrategy.allCases) { strategy in
                        Text(strategy.rawValue).tag(strategy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            Button("全部重试") {
                model.retryAllFailed()
            }
            .buttonStyle(.bordered)
            .disabled(model.failedCount == 0)

            Button("取消全部") {
                model.cancelAll()
            }
            .buttonStyle(.bordered)
            .disabled(model.activeCount == 0 && !model.isPreparing)

            Button("清空已完成") {
                model.clearFinished()
            }
            .buttonStyle(.bordered)
            .disabled(model.totalTaskCount <= model.activeCount)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.surfaceSoft.opacity(0.45))
    }

    private func taskRow(_ task: TransferTask) -> some View {
        let isUpload = task.direction == .upload
        let badgeFG: Color
        let badgeBG: Color
        switch task.state {
        case .failed:
            badgeFG = Color(red: 0.78, green: 0.24, blue: 0.24)
            badgeBG = badgeFG.opacity(0.12)
        case .completed:
            badgeFG = palette.successColor
            badgeBG = badgeFG.opacity(0.14)
        case .cancelled:
            badgeFG = palette.secondaryText
            badgeBG = palette.surfaceSoft
        case .queued, .running:
            badgeFG = palette.accent
            badgeBG = palette.accentSoft
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(badgeBG)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: isUpload ? "arrow.up" : "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(badgeFG)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.filename)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(isUpload ? "上传到手机" : "导入到 Mac")
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(badgeFG)
                            .background(Capsule().fill(badgeBG))
                    }

                    Text("\(task.sourceDisplay) -> \(task.destinationDisplay)")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(statusSummary(for: task))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(statusTextColor(for: task))
                        .monospacedDigit()

                    if task.totalBytes > 0 {
                        Text("\(PathUtils.formatByteCount(task.transferredBytes)) / \(PathUtils.formatByteCount(task.totalBytes))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .monospacedDigit()
                    }
                }

                if task.isActive {
                    Button {
                        model.cancel(task.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("取消此任务")
                } else if canRetry(task.state) {
                    Button("重试") {
                        model.retry(task.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if task.state == .running || task.state == .queued {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
            }

            if case .failed(let message) = task.state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                }
                .foregroundStyle(Color(red: 0.78, green: 0.24, blue: 0.24))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.dividerColor, lineWidth: 1)
        )
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.accentSoft)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(palette.accent)
                }
            Text("当前没有传输任务")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text("可直接将 Mac 中的文件拖入窗口上传到手机，或将手机里的照片拖到访达保存。")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .foregroundStyle(palette.accent)
            .background(palette.accentSoft.opacity(0.25))
            .padding(12)
            .overlay(alignment: .center) {
                Label("松开鼠标上传到 \(appState.browser.effectiveUploadDirectory)", systemImage: "arrow.up.doc.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(palette.primaryText)
                    .background(Capsule().fill(palette.cardBackground).shadow(radius: 6))
            }
            .allowsHitTesting(false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard appState.effectiveDeviceState == .ready,
              let storageID = appState.browser.activeStorageID else {
            return false
        }
        let targetDir = appState.browser.effectiveUploadDirectory
        let transferModel = appState.transferModel
        DropURLResolver.extractFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                await transferModel.enqueueUploads(urls: urls, to: targetDir, storage: storageID)
            }
        }
        return true
    }

    private func canRetry(_ state: TransferState) -> Bool {
        switch state {
        case .failed, .cancelled:
            return true
        case .queued, .running, .completed:
            return false
        }
    }

    private func statusSummary(for task: TransferTask) -> String {
        switch task.state {
        case .queued:
            return "等待中"
        case .running:
            var items: [String] = []
            if let note = task.statusNote {
                items.append(note)
            }
            if task.speedBytesPerSec > 1 {
                items.append("\(PathUtils.formatByteCount(UInt64(task.speedBytesPerSec)))/s")
            } else {
                items.append("\(Int((task.progress * 100).rounded()))%")
            }
            if let eta = TransferPanelHelper.formatETA(task.etaSeconds) {
                items.append("剩余 \(eta)")
            }
            return items.joined(separator: " · ")
        case .completed:
            return task.statusNote ?? "已完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private func statusTextColor(for task: TransferTask) -> Color {
        switch task.state {
        case .failed:
            return Color(red: 0.78, green: 0.24, blue: 0.24)
        case .completed:
            return palette.successColor
        case .cancelled:
            return palette.secondaryText
        case .queued, .running:
            return palette.accent
        }
    }
}

/// 从 SwiftUI `.onDrop` 提供的 `NSItemProvider` 列表中解析本地文件 URL。
enum DropURLResolver {
    static func extractFileURLs(
        from providers: [NSItemProvider],
        completion: @escaping @Sendable ([URL]) -> Void
    ) {
        let group = DispatchGroup()
        let collector = LockedURLList()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    collector.append(url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.append(url)
                } else if let path = item as? String,
                          let url = URL(string: path), url.isFileURL {
                    collector.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            completion(collector.snapshot())
        }
    }
}

private final class LockedURLList: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
