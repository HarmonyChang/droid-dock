import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主浏览内容区：覆盖媒体日期分组视图（含真实缩略图）与文件夹路径视图、双向拖拽传输，以及 5 类核心状态。
struct BrowserContentView: View {
    let appState: AppState

    @State private var isDropTargeted = false
    @State private var hoveredDropFolderID: String?
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?
    @State private var isCreatingFolder = false
    @State private var pendingDeleteNodes: [RemoteNode] = []
    @State private var showDeleteConfirmation = false

    private var palette: ElegantPalette { appState.palette }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = appState.browser.errorMessage {
                bannerView(text: errorMessage, isError: true) {
                    appState.browser.errorMessage = nil
                }
            } else if let infoMessage = appState.browser.infoBannerMessage {
                bannerView(text: infoMessage, isError: false) {
                    appState.browser.infoBannerMessage = nil
                }
            }

            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.contentBackground)
        .onDeleteCommand {
            triggerDelete(nodes: appState.browser.selectedNodes)
        }
        .background(folderShortcutView)
        .sheet(isPresented: $showNewFolderSheet) {
            newFolderSheet
        }
        .alert("删除确认", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {
                pendingDeleteNodes = []
            }
            Button("删除", role: .destructive) {
                let targets = pendingDeleteNodes
                pendingDeleteNodes = []
                Task { await appState.browser.deleteNodes(targets) }
            }
        } message: {
            if pendingDeleteNodes.count == 1, let first = pendingDeleteNodes.first {
                Text("确定要从手机中删除「\(first.name)」吗？\(first.isDirectory ? "其内部文件也将被一并删除，" : "")此操作不可撤销。")
            } else {
                Text("确定要从手机中删除已选中的 \(pendingDeleteNodes.count) 项吗？此操作不可撤销。")
            }
        }
    }

    private var folderShortcutView: some View {
        Group {
            if appState.browser.canMutateDirectory {
                Button("") {
                    openNewFolderSheet()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            if !appState.browser.selectedNodes.isEmpty && appState.effectiveDeviceState == .ready {
                Button("") {
                    triggerDelete(nodes: appState.browser.selectedNodes)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var mainContent: some View {
        if appState.deviceManager.currentDevice == nil {
            noDeviceView
        } else if appState.effectiveDeviceState == .locked {
            lockedDeviceView
        } else if case .error(let deviceError) = appState.effectiveDeviceState {
            errorStateView(deviceError)
        } else if appState.effectiveDeviceState != .ready {
            connectingView
        } else if appState.browser.selectedSidebar == .transfers {
            TransfersQueueView(appState: appState)
        } else if appState.browser.isMediaMode {
            mediaBrowserView
                .overlay {
                    if isDropTargeted {
                        dropOverlay(targetDir: appState.browser.effectiveUploadDirectory)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers, targetDir: appState.browser.effectiveUploadDirectory)
                }
        } else {
            folderBrowserView
                .overlay {
                    if isDropTargeted && hoveredDropFolderID == nil {
                        dropOverlay(targetDir: appState.browser.currentPath)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers, targetDir: appState.browser.currentPath)
                }
        }
    }

    // MARK: - 媒体聚合视图（纯照片/视频，无文件夹）

    private var mediaBrowserView: some View {
        VStack(spacing: 0) {
            mediaFilterBar
            Divider().overlay(palette.dividerColor)

            if appState.browser.isLoading && appState.browser.mediaNodes.isEmpty {
                loadingStateView("正在聚合手机相册与媒体...")
            } else if appState.browser.filteredNodes.isEmpty {
                emptyDirectoryView(
                    icon: "photo.on.rectangle.angled",
                    title: appState.browser.searchQuery.isEmpty ? "未发现匹配的照片或视频" : "没有找到匹配项"
                )
            } else {
                switch appState.browser.viewMode {
                case .grid:
                    mediaGridView
                case .list:
                    listView
                }
            }
        }
    }

    private var mediaFilterBar: some View {
        @Bindable var browser = appState.browser

        return HStack(spacing: 8) {
            ForEach(MediaFilter.allCases) { filter in
                let isSelected = browser.mediaFilter == filter
                Button {
                    browser.mediaFilter = filter
                    browser.clearSelection()
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .foregroundStyle(isSelected ? Color.white : palette.primaryText)
                        .background(
                            Capsule()
                                .fill(isSelected ? palette.accent : palette.surfaceSoft)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if !browser.selectedNodes.isEmpty {
                Button(role: .destructive) {
                    triggerDelete(nodes: browser.selectedNodes)
                } label: {
                    Label("删除 (\(browser.selectedNodes.count))", systemImage: "trash")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await browser.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)
            .help("刷新媒体列表")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(palette.contentBackground)
    }

    private var mediaGridView: some View {
        let columns = [GridItem(.adaptive(minimum: 132), spacing: 6)]

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(appState.browser.groupedMediaSections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                            Text("\(section.items.count) 项")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.secondaryText)
                        }

                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(section.items) { node in
                                gridTile(for: node, showFileName: false)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, appState.transferModel.shouldShowTray ? 70 : 0)
        }
    }

    // MARK: - 文件夹浏览视图

    private var folderBrowserView: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider().overlay(palette.dividerColor)

            if appState.browser.isLoading && appState.browser.nodes.isEmpty {
                loadingStateView("正在读取手机目录...")
            } else if appState.browser.filteredNodes.isEmpty {
                emptyDirectoryView(
                    icon: "folder",
                    title: appState.browser.searchQuery.isEmpty ? "当前目录为空" : "没有匹配的文件"
                )
            } else {
                switch appState.browser.viewMode {
                case .grid:
                    folderGridView
                case .list:
                    listView
                }
            }
        }
    }

    private var folderGridView: some View {
        let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(appState.browser.filteredNodes) { node in
                    gridTile(for: node, showFileName: true)
                }
            }
            .padding(16)
            .padding(.bottom, appState.transferModel.shouldShowTray ? 70 : 0)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            if appState.browser.storages.count > 1, let currentStorage = appState.browser.currentStorage {
                Menu {
                    ForEach(appState.browser.storages) { storage in
                        Button(storage.name) {
                            Task { await appState.browser.selectStorage(storage.id) }
                        }
                    }
                } label: {
                    Label(currentStorage.name, systemImage: "externaldrive")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text("/")
                    .foregroundStyle(palette.secondaryText)
            }

            let rootName = appState.browser.currentStorage?.name ?? "内部存储"
            let crumbs = PathUtils.breadcrumbs(for: appState.browser.currentPath, rootTitle: rootName)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(palette.secondaryText)
                        }
                        Button(crumb.name) {
                            Task { await appState.browser.navigate(to: crumb.path) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: index == crumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == crumbs.count - 1 ? palette.primaryText : palette.secondaryText)
                    }
                }
            }

            Spacer()

            if !appState.browser.selectedNodes.isEmpty {
                Button(role: .destructive) {
                    triggerDelete(nodes: appState.browser.selectedNodes)
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if appState.browser.canMutateDirectory {
                Button {
                    openNewFolderSheet()
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在当前目录新建文件夹 (⌘⇧N)")
            }

            if appState.browser.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await appState.browser.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)
            .help("刷新当前目录")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.surfaceSoft.opacity(0.45))
    }

    // MARK: - 通用单元格与列表行

    private func gridTile(for node: RemoteNode, showFileName: Bool) -> some View {
        let isSelected = appState.browser.selectedNodeIDs.contains(node.id)
        let badge = palette.nodeBadgeColors(for: node)

        return VStack(spacing: 6) {
            ZStack {
                NodeThumbnailView(
                    browser: appState.browser,
                    node: node,
                    badge: badge,
                    iconName: iconName(for: node),
                    showFileName: showFileName,
                    secondaryTextColor: palette.secondaryText
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? palette.accent : palette.dividerColor.opacity(0.6), lineWidth: isSelected ? 3 : 0.5)
                )

                if node.kind == .video {
                    VStack {
                        Spacer()
                        HStack {
                            Label("视频", systemImage: "play.fill")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(Color.white)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                            Spacer()
                        }
                    }
                    .padding(6)
                }

                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(palette.accent)
                                .background(Circle().fill(Color.white).padding(2))
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            if showFileName {
                VStack(spacing: 1) {
                    Text(node.name)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let hint = folderHint(for: node) {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .modifier(NodeInteractionModifier(
            appState: appState,
            node: node,
            isSelected: isSelected,
            hoveredDropFolderID: $hoveredDropFolderID,
            onRequestDelete: { targets in triggerDelete(nodes: targets) }
        ))
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("修改时间").frame(width: 160, alignment: .leading)
                Text("大小").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider().overlay(palette.dividerColor)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(appState.browser.filteredNodes) { node in
                        listRow(for: node)
                    }
                }
                .padding(.vertical, 4)
                .padding(.bottom, appState.transferModel.shouldShowTray ? 70 : 0)
            }
        }
    }

    private func listRow(for node: RemoteNode) -> some View {
        let isSelected = appState.browser.selectedNodeIDs.contains(node.id)
        let badge = palette.nodeBadgeColors(for: node)

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.22) : badge.bg)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: iconName(for: node))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : badge.fg)
                }

            HStack(spacing: 6) {
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let hint = folderHint(for: node) {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formattedDate(node.modified))
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : palette.secondaryText)
                .frame(width: 160, alignment: .leading)

            Text(node.isDirectory ? "--" : PathUtils.formatByteCount(node.size))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : palette.secondaryText)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? palette.accent : Color.clear)
                .padding(.horizontal, 8)
        )
        .modifier(NodeInteractionModifier(
            appState: appState,
            node: node,
            isSelected: isSelected,
            hoveredDropFolderID: $hoveredDropFolderID,
            onRequestDelete: { targets in triggerDelete(nodes: targets) }
        ))
    }

    // MARK: - 引导与空状态

    private var noDeviceView: some View {
        VStack(spacing: 14) {
            DroidDockLogoView(size: 72, accent: palette.accent)
            Text("请使用 USB 数据线连接手机，或通过同一 Wi-Fi 无线连接")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text("有线连接请解锁屏幕并在通知栏选择「文件传输」；无线连接可在同网络下扫码或直接发现（不影响手机上网）。")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                Button("重新检测") {
                    Task { await appState.refreshDevices() }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)

                Button {
                    appState.showWirelessPairingSheet = true
                } label: {
                    Label("无线连接（同一 Wi-Fi）", systemImage: "wifi")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedDeviceView: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.warningColor.opacity(0.14))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "lock.iphone")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(palette.warningColor)
                }
            Text("正在等待手机开放文件访问权限")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text("解锁手机并在通知栏 USB 用途中选择「文件传输」后，应用将自动加载；若手机已授权仍未显示，可尝试重新插拔 USB 用途切换。")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
                Text("正在自动轮询存储就绪状态…")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
            }
            Button("立即重试") {
                Task { await appState.refreshDevices() }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorStateView(_ error: DeviceError) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Color(red: 0.78, green: 0.24, blue: 0.24))
            Text("无法访问设备")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text(error.localizedDescription)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Button("重新连接") {
                Task { await appState.refreshDevices() }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectingView: some View {
        loadingStateView("正在建立 MTP 会话...")
    }

    private func loadingStateView(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(palette.accent)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建文件夹")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            Text("将在「\(appState.browser.effectiveUploadDirectory)」下创建")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)

            TextField("请输入文件夹名称", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitNewFolder()
                }

            if let newFolderError {
                Text(newFolderError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 0.78, green: 0.24, blue: 0.24))
            }

            HStack {
                Spacer()
                Button("取消") {
                    showNewFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isCreatingFolder ? "创建中…" : "创建") {
                    submitNewFolder()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(isCreatingFolder || newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func dropOverlay(targetDir: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .foregroundStyle(palette.accent)
            .background(palette.accentSoft.opacity(0.25))
            .padding(12)
            .overlay(alignment: .center) {
                Label("松开即可上传到 \(targetDir)", systemImage: "arrow.up.doc.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(palette.primaryText)
                    .background(Capsule().fill(palette.cardBackground).shadow(radius: 6))
            }
            .allowsHitTesting(false)
    }

    private func openNewFolderSheet() {
        guard appState.browser.canMutateDirectory else { return }
        newFolderName = ""
        newFolderError = nil
        showNewFolderSheet = true
    }

    private func submitNewFolder() {
        guard !isCreatingFolder else { return }
        let name = newFolderName
        if let reason = PathUtils.validateAndroidFilename(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
            newFolderError = reason
            return
        }
        isCreatingFolder = true
        newFolderError = nil
        Task {
            let errorText = await appState.browser.createDirectory(name: name)
            isCreatingFolder = false
            if let errorText {
                newFolderError = errorText
            } else {
                showNewFolderSheet = false
            }
        }
    }

    private func triggerDelete(nodes: [RemoteNode]) {
        guard !nodes.isEmpty, appState.effectiveDeviceState == .ready else { return }
        pendingDeleteNodes = nodes
        showDeleteConfirmation = true
    }

    private func handleDrop(providers: [NSItemProvider], targetDir: String) -> Bool {
        guard appState.effectiveDeviceState == .ready,
              let storageID = appState.browser.activeStorageID else {
            return false
        }
        let transferModel = appState.transferModel
        DropURLResolver.extractFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                await transferModel.enqueueUploads(urls: urls, to: targetDir, storage: storageID)
            }
        }
        return true
    }

    private func emptyDirectoryView(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(palette.secondaryText)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bannerView(text: String, isError: Bool, onDismiss: @escaping () -> Void) -> some View {
        let tintColor = isError ? Color(red: 0.78, green: 0.24, blue: 0.24) : palette.accent
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(tintColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tintColor.opacity(0.09))
    }

    private func iconName(for node: RemoteNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch node.kind {
        case .photo: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .document: return "doc.text.fill"
        case .other: return "doc.fill"
        }
    }

    private func folderHint(for node: RemoteNode) -> String? {
        guard node.isDirectory else { return nil }
        switch node.path {
        case "/DCIM": return "相机与相册"
        case "/Pictures": return "图片"
        case "/Movies": return "视频"
        case "/Download": return "下载"
        case "/Documents": return "文档"
        case "/Music": return "音乐"
        case "/Recordings": return "录音"
        default: return nil
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 统一为文件与文件夹单元格附加点击选择、双击打开、`NSFilePromiseProvider` 拖出、文件夹拖入及右键菜单。
private struct NodeInteractionModifier: ViewModifier {
    let appState: AppState
    let node: RemoteNode
    let isSelected: Bool
    @Binding var hoveredDropFolderID: String?
    let onRequestDelete: ([RemoteNode]) -> Void

    private var targetNodes: [RemoteNode] {
        if appState.browser.selectedNodeIDs.contains(node.id) {
            let selected = appState.browser.selectedNodes
            if !selected.isEmpty { return selected }
        }
        return [node]
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                RemoteTileInteractionOverlay(
                    node: node,
                    isSelected: isSelected,
                    selectedNodesProvider: { appState.browser.selectedNodes },
                    transferModel: appState.transferModel,
                    onTap: { additive in
                        appState.browser.toggleSelection(node.id, additive: additive)
                    },
                    onDoubleTap: {
                        Task { await appState.browser.openNode(node) }
                    },
                    onSecondarySelect: {
                        appState.browser.toggleSelection(node.id, additive: false)
                    }
                )
            }
            .overlay {
                if node.isDirectory && hoveredDropFolderID == node.id {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(appState.palette.accent, lineWidth: 2)
                        .background(appState.palette.accentSoft.opacity(0.28).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [.fileURL],
                isTargeted: Binding(
                    get: { hoveredDropFolderID == node.id },
                    set: { targeted in
                        guard node.isDirectory else { return }
                        if targeted {
                            hoveredDropFolderID = node.id
                        } else if hoveredDropFolderID == node.id {
                            hoveredDropFolderID = nil
                        }
                    }
                )
            ) { providers in
                guard node.isDirectory,
                      appState.effectiveDeviceState == .ready,
                      let storageID = appState.browser.activeStorageID else {
                    return false
                }
                let transferModel = appState.transferModel
                let destDir = node.path
                DropURLResolver.extractFileURLs(from: providers) { urls in
                    guard !urls.isEmpty else { return }
                    Task { @MainActor in
                        await transferModel.enqueueUploads(urls: urls, to: destDir, storage: storageID)
                    }
                }
                return true
            }
            .contextMenu {
                if node.isDirectory {
                    Button("打开文件夹") {
                        Task { await appState.browser.openNode(node) }
                    }
                } else {
                    Button(node.kind == .photo ? "查看图片" : "快速预览") {
                        Task { await appState.browser.openPreview(for: node) }
                    }
                }
                Button("导入到 Mac…") {
                    TransferPanelHelper.pickDestinationAndDownload(
                        nodes: targetNodes,
                        transferModel: appState.transferModel
                    )
                }
                Divider()
                Button("删除…", role: .destructive) {
                    onRequestDelete(targetNodes)
                }
            }
    }
}

/// 基于 AppKit 的单元格交互层：无冲突支持单击/多选、双击打开以及 `NSFilePromiseProvider` 拖出到 Finder。
private struct RemoteTileInteractionOverlay: NSViewRepresentable {
    let node: RemoteNode
    let isSelected: Bool
    let selectedNodesProvider: () -> [RemoteNode]
    let transferModel: TransferModel
    let onTap: (Bool) -> Void
    let onDoubleTap: () -> Void
    let onSecondarySelect: () -> Void

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: InteractionNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: InteractionNSView) {
        view.node = node
        view.isSelected = isSelected
        view.selectedNodesProvider = selectedNodesProvider
        view.transferModel = transferModel
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        view.onSecondarySelect = onSecondarySelect
    }
}

private final class InteractionNSView: NSView, NSDraggingSource {
    var node: RemoteNode?
    var isSelected = false
    var selectedNodesProvider: (() -> [RemoteNode])?
    var transferModel: TransferModel?
    var onTap: ((Bool) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onSecondarySelect: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder is NSTextView {
            window?.makeFirstResponder(nil)
        }
        mouseDownEvent = event
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag,
              let startEvent = mouseDownEvent,
              let node,
              let transferModel else {
            return
        }
        let dx = event.locationInWindow.x - startEvent.locationInWindow.x
        let dy = event.locationInWindow.y - startEvent.locationInWindow.y
        guard hypot(dx, dy) >= 4 else { return }

        let dragNodes: [RemoteNode]
        if isSelected, let selected = selectedNodesProvider?().filter({ !$0.isDirectory }), !selected.isEmpty {
            dragNodes = selected
        } else if !node.isDirectory {
            dragNodes = [node]
        } else {
            return
        }

        didStartDrag = true
        let items: [NSDraggingItem] = dragNodes.enumerated().map { idx, dragNode in
            let ext = (dragNode.name as NSString).pathExtension
            let fileType = (UTType(filenameExtension: ext) ?? .data).identifier
            let delegate = RemoteFilePromiseDelegate(node: dragNode, transferModel: transferModel)
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let preview = dragPreviewImage(for: dragNode, totalCount: dragNodes.count, index: idx)
            let rect = NSRect(
                x: bounds.midX - preview.size.width / 2,
                y: bounds.midY - preview.size.height / 2,
                width: preview.size.width,
                height: preview.size.height
            )
            item.setDraggingFrame(rect, contents: preview)
            return item
        }
        beginDraggingSession(with: items, event: startEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didStartDrag {
            if event.clickCount >= 2 {
                onDoubleTap?()
            } else {
                let additive = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
                onTap?(additive)
            }
        }
        mouseDownEvent = nil
        didStartDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        if !isSelected {
            onSecondarySelect?()
        }
        super.rightMouseDown(with: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .generic
    }

    private func dragPreviewImage(for node: RemoteNode, totalCount: Int, index: Int) -> NSImage {
        let size = NSSize(width: 48, height: 48)
        let image = NSImage(size: size)
        image.lockFocus()
        let symbolName = node.kind == .video ? "film.fill" : (node.kind == .photo ? "photo.fill" : "doc.fill")
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            symbol.draw(in: NSRect(x: 6, y: 6, width: 36, height: 36))
        }
        if totalCount > 1 && index == 0 {
            let badgeText = "\(totalCount)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let badgeRect = NSRect(x: 26, y: 26, width: 20, height: 20)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            let textSize = badgeText.size(withAttributes: attrs)
            badgeText.draw(
                at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
                withAttributes: attrs
            )
        }
        image.unlockFocus()
        return image
    }
}

/// 满足 `NSFilePromiseProviderDelegate`，将拖出目标文件路径转交给 `TransferModel` 流式写入。
private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "droiddock.filepromise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    let node: RemoteNode
    let transferModel: TransferModel

    init(node: RemoteNode, transferModel: TransferModel) {
        self.node = node
        self.transferModel = transferModel
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        node.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let node = self.node
        let model = self.transferModel
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = LockedPromiseErrorBox()
        Task { @MainActor in
            do {
                try await model.downloadForDragPromise(node, to: url)
            } catch {
                errorBox.set(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        completionHandler(errorBox.get())
    }
}

private final class LockedPromiseErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private struct NodeThumbnailView: View {
    let browser: BrowserModel
    let node: RemoteNode
    let badge: (fg: Color, bg: Color)
    let iconName: String
    let showFileName: Bool
    let secondaryTextColor: Color

    @State private var loadedImage: NSImage?

    var body: some View {
        let displayImage = loadedImage ?? browser.cachedThumbnailImage(for: node)

        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(badge.bg)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let displayImage {
                    Image(nsImage: displayImage)
                        .interpolation(.medium)
                        .resizable()
                        .scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(badge.fg)
                        if !node.isDirectory && showFileName {
                            Text(PathUtils.formatByteCount(node.size))
                                .font(.system(size: 10))
                                .foregroundStyle(secondaryTextColor)
                        }
                    }
                }
            }
            .task(id: node.id) {
                if let cached = browser.cachedThumbnailImage(for: node) {
                    loadedImage = cached
                    return
                }
                loadedImage = nil
                guard !node.isDirectory, node.kind == .photo || node.kind == .video else { return }
                loadedImage = await browser.loadThumbnailImage(for: node)
            }
    }
}
