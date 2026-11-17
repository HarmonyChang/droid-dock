import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 无线连接弹窗：默认进入新手友好「扫码快传模式」（免设置、不断网），同时提供「无线调试模式」全盘相册管理及开启指引。
struct WirelessPairingSheetView: View {
    let appState: AppState

    enum WirelessMode: String, CaseIterable, Identifiable {
        case quickDrop = "扫码快传（推荐新手 · 免设置）"
        case wirelessADB = "无线调试（全盘管理）"

        var id: String { rawValue }
    }

    enum ADBSubMode: String, CaseIterable, Identifiable {
        case qrScan = "二维码配对"
        case manualAndLAN = "同网与配对码"

        var id: String { rawValue }
    }

    @State private var wirelessMode: WirelessMode = .quickDrop
    @State private var adbSubMode: ADBSubMode = .qrScan
    @State private var showHowToEnableGuide = true
    @State private var isDropTargeted = false

    @State private var adbAvailable = false
    @State private var isInstallingADB = false
    @State private var hostInput = ""
    @State private var pairingPortInput = ""
    @State private var pairingCodeInput = ""
    @State private var connectPortInput = ""
    @State private var actionMessage: String?
    @State private var actionIsError = false
    @State private var isBusy = false

    private var palette: ElegantPalette { appState.palette }
    private var discovery: ADBDiscoveryService { appState.adbDiscovery }
    private var quickDrop: QuickDropWebServer { appState.quickDropServer }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            Picker("无线模式", selection: $wirelessMode) {
                ForEach(WirelessMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Group {
                switch wirelessMode {
                case .quickDrop:
                    quickDropView
                case .wirelessADB:
                    wirelessADBView
                }
            }
        }
        .padding(20)
        .frame(width: 680)
        .background(palette.contentBackground)
        .task {
            quickDrop.start()
            adbAvailable = await appState.adbClient.isAvailable()
        }
        .onChange(of: wirelessMode) { _, newMode in
            if newMode == .wirelessADB {
                discovery.startDiscovery()
                discovery.startQRPairingSession()
            } else {
                discovery.stopQRPairingSession()
                quickDrop.start()
            }
        }
        .onChange(of: discovery.qrPairingStatus) { _, status in
            if case .connected(let endpoint) = status {
                actionIsError = false
                actionMessage = "已成功连接到 \(endpoint)"
                Task { @MainActor in
                    await appState.refreshDevices()
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    appState.showWirelessPairingSheet = false
                }
            }
        }
        .onDisappear {
            discovery.stopQRPairingSession()
        }
    }

    // MARK: - 顶部标题栏

    private var headerBar: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.accentSoft)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: wirelessMode == .quickDrop ? "qrcode" : "wifi")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(wirelessMode == .quickDrop ? "扫码快传（免开设置 · 同一 Wi-Fi 互传）" : "无线调试连接（全盘相册与文件管理）")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text("基于同一路由器 Wi-Fi 局域网传输；手机保持正常上网，无需拔掉外网")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()

            Button {
                appState.showWirelessPairingSheet = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 模式 1：新手扫码快传（默认）

    private var quickDropView: some View {
        HStack(alignment: .top, spacing: 18) {
            // 左侧：二维码 + 3 步新手引导
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 8) {
                    if let qrImage = quickDrop.qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 176, height: 176)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(palette.dividerColor, lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(palette.surfaceSoft)
                            .frame(width: 196, height: 196)
                            .overlay {
                                ProgressView().controlSize(.small)
                            }
                    }

                    if let urlString = quickDrop.serverURLString {
                        Text(urlString)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Button {
                            quickDrop.refreshTokenAndQR()
                        } label: {
                            Label("换一个码", systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if let urlString = quickDrop.serverURLString {
                            Button("复制地址") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(urlString, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text("无需装 App · 3 步开始互传")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    guideRow(step: "1", text: "手机与 Mac 连同一个 Wi-Fi（手机不断网）。")
                    guideRow(step: "2", text: "打开手机相机、微信扫一扫或浏览器扫描上方二维码。")
                    guideRow(step: "3", text: "在手机网页直接选照片/视频发给 Mac，或下载右侧投送文件。")
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.surfaceSoft.opacity(0.65)))
            }
            .frame(width: 245)

            // 右侧：投送给手机 + 手机发来的文件
            VStack(alignment: .leading, spacing: 12) {
                // 投送到手机区
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("投送 Mac 文件 / 文件夹到手机", systemImage: "arrow.up.doc.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        Button("选择文件 / 文件夹…") {
                            pickSharedFilesForQuickDrop()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(palette.accent)
                    }

                    if quickDrop.sharedItems.isEmpty {
                        Text("把 Mac 上的文件或整个文件夹拖到这里，或点击「选择文件 / 文件夹…」，手机扫码即可预览照片网格与打包下载。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                    .foregroundStyle(isDropTargeted ? palette.accent : palette.dividerColor)
                            )
                    } else {
                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(quickDrop.sharedItems) { item in
                                    HStack(spacing: 8) {
                                        Image(systemName: sharedIconName(for: item))
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(palette.accent)
                                        Text(item.filename)
                                            .font(.system(size: 12))
                                            .foregroundStyle(palette.primaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(sharedMetaText(for: item))
                                            .font(.system(size: 11))
                                            .foregroundStyle(palette.secondaryText)
                                            .monospacedDigit()
                                        Button {
                                            quickDrop.removeSharedFile(item.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(palette.secondaryText)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.surfaceSoft.opacity(0.6)))
                                }
                            }
                        }
                        .frame(maxHeight: 92)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isDropTargeted ? palette.accent : palette.dividerColor, lineWidth: isDropTargeted ? 2 : 1))
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    DropURLResolver.extractFileURLs(from: providers) { urls in
                        guard !urls.isEmpty else { return }
                        Task { @MainActor in
                            quickDrop.addSharedFiles(urls)
                        }
                    }
                    return true
                }

                // 接收记录区
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("从手机接收的文件", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        Button("打开接收目录") {
                            quickDrop.openReceiveDirectoryInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let receiving = quickDrop.activeReceivingFilename {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(palette.accent)
                            Text("正在接收：\(receiving)…")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(palette.accent)
                        }
                    }

                    if quickDrop.receivedItems.isEmpty {
                        Text("保存在「下载 / DroidDock-快传」。手机选中照片或文件发送后会自动出现在这里。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(quickDrop.receivedItems) { item in
                                    let kind = PathUtils.inferMediaKind(filename: item.filename)
                                    HStack(spacing: 8) {
                                        if kind == .photo {
                                            QuickDropLocalThumbView(url: item.localURL, palette: palette)
                                        } else {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(palette.successColor)
                                        }
                                        Text(item.filename)
                                            .font(.system(size: 12))
                                            .foregroundStyle(palette.primaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Text(PathUtils.formatByteCount(item.sizeBytes))
                                            .font(.system(size: 11))
                                            .foregroundStyle(palette.secondaryText)
                                            .monospacedDigit()
                                        Button("预览") {
                                            QuickLookController.shared.present(url: item.localURL)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11))
                                        Button("访达") {
                                            quickDrop.revealItemInFinder(item.localURL)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.surfaceSoft.opacity(0.6)))
                                }
                            }
                        }
                        .frame(maxHeight: 132)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(palette.dividerColor, lineWidth: 1))
            }
        }
    }

    // MARK: - 模式 2：无线调试全盘管理 + 开启教程

    private var wirelessADBView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !adbAvailable {
                adbMissingBanner
            }

            // 如何开启无线调试分步教程卡片
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showHowToEnableGuide.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.accent)
                        Text("如何开启手机「无线调试」？（一加 / 小米 / vivo / 三星通用）")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        Image(systemName: showHowToEnableGuide ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .buttonStyle(.plain)

                if showHowToEnableGuide {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("第 1 步 · 打开「开发者选项」（仅首次需要）：进入手机「设置 → 关于本机 / 关于手机 → 版本信息」，连续点击「版本号」（小米点「OS 版本」）7 次，输入锁屏密码即可开启。")
                        Text("第 2 步 · 开启「无线调试」并配对：进入「设置 → 系统与更新 / 其他设置 → 开发者选项 → 开启无线调试」，再点击「无线调试」文字进入详情页，选择「使用二维码配对设备」扫描下方二维码（或点「使用配对码」切换到右侧输入 6 位配对码）。")
                        Text("第 3 步 · 同网免扫码秒连：配对一次后，以后与 Mac 连在同一个 Wi-Fi 时只需打开手机「无线调试」开关即可自动连上，直接浏览完整相册与全盘文件。")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.surfaceSoft.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(palette.dividerColor, lineWidth: 1))

            Picker("配对方式", selection: $adbSubMode) {
                ForEach(ADBSubMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)

            Group {
                switch adbSubMode {
                case .qrScan:
                    qrPairingContent
                case .manualAndLAN:
                    manualAndLANContent
                }
            }

            if let actionMessage {
                HStack(spacing: 6) {
                    Image(systemName: actionIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text(actionMessage)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                .foregroundStyle(actionIsError ? Color(red: 0.78, green: 0.24, blue: 0.24) : palette.successColor)
            }
        }
    }

    private var adbMissingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(palette.warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("首次使用无线调试全盘模式需要启用官方 Android 组件（adb）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                Text("约 15 MB，将自动安装至应用支持目录，无需命令行配置。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Button(isInstallingADB ? "安装中…" : "一键安装") {
                installADB()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(palette.accent)
            .disabled(isInstallingADB)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.warningColor.opacity(0.12)))
    }

    private var qrPairingContent: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                if let qrImage = discovery.qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(palette.dividerColor, lineWidth: 1)
                        )
                }

                Button {
                    discovery.startQRPairingSession()
                } label: {
                    Label("刷新配对码", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("使用手机「无线调试 → 二维码配对设备」扫码")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)

                Text("支持在 Mac 完整浏览手机所有相册、320 px 缩略图、原图双击放大及全盘目录双向拖拽传输；不切换手机热点，手机不断网。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    if case .waitingScan = discovery.qrPairingStatus {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else if case .pairing = discovery.qrPairingStatus {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else if case .connecting = discovery.qrPairingStatus {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else if case .connected = discovery.qrPairingStatus {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.successColor)
                    }
                    Text(discovery.qrPairingStatus.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surfaceSoft))
            }
        }
    }

    private var manualAndLANContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("同一 Wi-Fi 内自动发现的无线调试设备（点击自动填充或直连）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Button("刷新") {
                        discovery.stopDiscovery()
                        discovery.startDiscovery()
                        Task { await appState.refreshDevices() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.accent)
                }

                if discovery.discoveredConnectEndpoints.isEmpty && discovery.discoveredPairingEndpoints.isEmpty {
                    Text("暂未收到手机无线调试广播；请按上方引导开启手机「无线调试」，或点「使用配对码配对设备」后填入下面 IP 与端口。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surfaceSoft.opacity(0.6)))
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(discovery.discoveredConnectEndpoints) { ep in
                                endpointRow(ep, roleLabel: "已配对连接端口") {
                                    hostInput = ep.host
                                    connectPortInput = "\(ep.port)"
                                    connectDirect()
                                }
                            }
                            ForEach(discovery.discoveredPairingEndpoints) { ep in
                                endpointRow(ep, roleLabel: "待配对端口") {
                                    hostInput = ep.host
                                    pairingPortInput = "\(ep.port)"
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 96)
                }
            }

            Divider().overlay(palette.dividerColor)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("IP 地址")
                        .font(.system(size: 12))
                        .frame(width: 64, alignment: .leading)
                    TextField("例如 192.168.1.25", text: $hostInput)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Text("配对端口")
                        .font(.system(size: 12))
                        .frame(width: 64, alignment: .leading)
                    TextField("5 位端口", text: $pairingPortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Text("配对码")
                        .font(.system(size: 12))
                    TextField("6 位数字", text: $pairingCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Spacer()
                    Button(isBusy ? "处理中…" : "配对并连接") {
                        pairWithManualCode()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(isBusy || !adbAvailable || hostInput.isEmpty || pairingPortInput.isEmpty || pairingCodeInput.isEmpty)
                }

                HStack(spacing: 8) {
                    Text("连接端口")
                        .font(.system(size: 12))
                        .frame(width: 64, alignment: .leading)
                    TextField("无线调试主页显示的端口", text: $connectPortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Spacer()
                    Button("直接连接") {
                        connectDirect()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !adbAvailable || hostInput.isEmpty || connectPortInput.isEmpty)
                }
            }
        }
    }

    private func endpointRow(_ endpoint: DiscoveredADBEndpoint, roleLabel: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: endpoint.isPairingService ? "key.fill" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.accent)
                Text(endpoint.serviceName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text("\(endpoint.host):\(endpoint.port)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
                Spacer()
                Text(roleLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(palette.accent)
                    .background(Capsule().fill(palette.accentSoft))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.dividerColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func guideRow(step: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(step)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(palette.accent))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sharedIconName(for item: QuickDropSharedItem) -> String {
        if item.isDirectory { return "folder.fill" }
        switch PathUtils.inferMediaKind(filename: item.filename) {
        case .photo: return "photo.fill"
        case .video: return "film.fill"
        default: return "doc.fill"
        }
    }

    private func sharedMetaText(for item: QuickDropSharedItem) -> String {
        if item.isDirectory {
            return "\(item.itemCount) 项 · \(PathUtils.formatByteCount(item.sizeBytes)) · ZIP"
        }
        return PathUtils.formatByteCount(item.sizeBytes)
    }

    private func pickSharedFilesForQuickDrop() {
        let panel = NSOpenPanel()
        panel.title = "选择要投送到手机的文件或文件夹"
        panel.prompt = "添加到投送列表"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        quickDrop.addSharedFiles(panel.urls)
    }

    private func installADB() {
        guard !isInstallingADB else { return }
        isInstallingADB = true
        actionMessage = nil
        Task {
            do {
                _ = try await appState.adbClient.installPlatformToolsIfNeeded()
                adbAvailable = true
                actionIsError = false
                actionMessage = "Android 无线调试组件已就绪，请扫码或选择同网设备连接。"
            } catch {
                actionIsError = true
                actionMessage = error.localizedDescription
            }
            isInstallingADB = false
        }
    }

    private func pairWithManualCode() {
        guard !isBusy, let port = Int(pairingPortInput.trimmingCharacters(in: .whitespaces)) else {
            actionIsError = true
            actionMessage = "请输入有效的配对端口号"
            return
        }
        isBusy = true
        actionMessage = nil
        Task {
            do {
                _ = try await discovery.pairWithCode(host: hostInput, port: port, code: pairingCodeInput)
                actionIsError = false
                actionMessage = "配对并连接成功！"
                await appState.refreshDevices()
            } catch {
                actionIsError = true
                actionMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func connectDirect() {
        guard !isBusy, let port = Int(connectPortInput.trimmingCharacters(in: .whitespaces)) else {
            actionIsError = true
            actionMessage = "请输入有效的连接端口号"
            return
        }
        isBusy = true
        actionMessage = nil
        Task {
            do {
                _ = try await discovery.connectDirect(host: hostInput, port: port)
                actionIsError = false
                actionMessage = "无线连接成功！"
                await appState.refreshDevices()
            } catch {
                actionIsError = true
                actionMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

private struct QuickDropLocalThumbView: View {
    let url: URL
    let palette: ElegantPalette
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: 24, height: 24)
        .background(palette.surfaceSoft)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: url) {
            let fileURL = url
            let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            image = decoded
        }
    }
}
