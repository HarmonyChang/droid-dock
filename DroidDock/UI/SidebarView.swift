import AppKit
import SwiftUI

/// 左侧边栏（固定 232 pt）：设备状态卡、儒雅彩色导航分组、配色预览切换、底部存储用量条。
struct SidebarView: View {
    let appState: AppState

    @State private var showDeviceDetailsPopover = false

    private let mediaItems: [SidebarSection] = [.photos, .videos, .screenshots]
    private let fileItems: [SidebarSection] = [.internalStorage, .downloads, .documents]
    private let transferItems: [SidebarSection] = [.transfers]

    private var palette: ElegantPalette { appState.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            brandHeader
            deviceCard
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionGroup(title: "媒体", items: mediaItems)
                    sectionGroup(title: "文件", items: fileItems)
                    sectionGroup(title: "传输", items: transferItems)
                }
            }
            Spacer(minLength: 0)
            paletteSwitcher
            if let storage = appState.browser.currentStorage {
                storageFooter(storage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(minWidth: 232, idealWidth: 232, maxWidth: 232)
        .background(palette.sidebarBackground)
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            DroidDockLogoView(size: 28, accent: palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("DroidDock")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Button {
                        appState.showUpdateSheet = true
                    } label: {
                        Text(appState.updateService.shouldHighlightUpdate ? "新版本" : "v\(appState.updateService.currentVersionString)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(appState.updateService.shouldHighlightUpdate ? Color.white : palette.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(appState.updateService.shouldHighlightUpdate ? palette.accent : palette.surfaceSoft)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("查看版本记录与检查自动升级")
                }
                Text("有线 · 无线传输助手")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
            Button {
                appState.showWirelessPairingSheet = true
            } label: {
                Image(systemName: "wifi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.accentSoft))
            }
            .buttonStyle(.plain)
            .help("同网无线连接 / 扫码配对")
        }
        .padding(.horizontal, 2)
    }

    private var deviceCard: some View {
        let isWiFi = appState.deviceManager.currentDevice?.transport == .wifi
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.accentSoft)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: isWiFi ? "wifi" : "smartphone")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    if appState.deviceManager.devices.count > 1 {
                        Menu {
                            ForEach(appState.deviceManager.devices) { device in
                                Button(device.name) {
                                    Task { await appState.selectDevice(device.id) }
                                }
                            }
                        } label: {
                            Text(appState.deviceManager.currentDevice?.name ?? "未连接设备")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                    } else {
                        Text(appState.deviceManager.currentDevice?.name ?? "未连接设备")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                Spacer(minLength: 0)

                if appState.deviceManager.currentDevice != nil {
                    Button {
                        showDeviceDetailsPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(showDeviceDetailsPopover ? palette.accent : palette.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看设备详情（电量、网络与链路信息）")
                }
            }

            if appState.effectiveDeviceState == .ready,
               let status = appState.currentDeviceStatus {
                Button {
                    showDeviceDetailsPopover.toggle()
                } label: {
                    telemetryStrip(status)
                }
                .buttonStyle(.plain)
                .help("点击查看完整设备状态")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(palette.cardBackground)
                .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(palette.dividerColor, lineWidth: 1)
        )
        .popover(isPresented: $showDeviceDetailsPopover, arrowEdge: .trailing) {
            DeviceDetailsPopoverView(appState: appState)
        }
    }

    @ViewBuilder
    private func telemetryStrip(_ status: DeviceStatusInfo) -> some View {
        HStack(spacing: 6) {
            if let level = status.batteryLevel {
                HStack(spacing: 3) {
                    Image(systemName: Self.batteryIconName(level: level, charging: status.chargingState))
                        .font(.system(size: 10.5))
                        .foregroundStyle(batteryColor(level: level, charging: status.chargingState))
                    Text("\(level)%")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.primaryText)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.surfaceSoft)
                )
            }

            HStack(spacing: 3) {
                Image(systemName: Self.networkOrLinkIconName(for: status))
                    .font(.system(size: 10))
                    .foregroundStyle(networkPillColor(for: status))
                Text(Self.compactNetworkOrLinkLabel(for: status))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.surfaceSoft)
            )

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func batteryColor(level: Int, charging: BatteryChargingState) -> Color {
        if charging == .charging || charging == .full {
            return palette.successColor
        }
        if level <= 10 {
            return Color(red: 0.78, green: 0.24, blue: 0.24)
        }
        if level <= 20 {
            return palette.warningColor
        }
        return palette.successColor
    }

    private func networkPillColor(for status: DeviceStatusInfo) -> Color {
        switch status.networkType {
        case .offline:
            return palette.warningColor
        case .unavailable:
            return palette.secondaryText
        default:
            return palette.accent
        }
    }

    fileprivate static func batteryIconName(level: Int, charging: BatteryChargingState) -> String {
        if charging == .charging {
            return "battery.100.bolt"
        }
        switch level {
        case 85...100: return "battery.100"
        case 60..<85: return "battery.75"
        case 35..<60: return "battery.50"
        case 15..<35: return "battery.25"
        default: return "battery.0"
        }
    }

    fileprivate static func networkOrLinkIconName(for status: DeviceStatusInfo) -> String {
        switch status.networkType {
        case .wifi: return "wifi"
        case .cellular5G, .cellular4G, .cellular3G, .cellular: return "antenna.radiowaves.left.and.right"
        case .ethernet: return "network"
        case .offline: return "wifi.slash"
        case .unavailable: return "cable.connector"
        }
    }

    fileprivate static func compactNetworkOrLinkLabel(for status: DeviceStatusInfo) -> String {
        if status.networkType != .unavailable {
            return status.networkType.rawValue
        }
        if let detail = status.connectionDetail {
            if detail.contains("USB 3.2") { return "USB 3.2" }
            if detail.contains("USB 3.1") { return "USB 3.1" }
            if detail.contains("USB 3.0") { return "USB 3.0" }
            if detail.contains("USB 2.0") { return "USB 2.0" }
        }
        return "USB MTP"
    }

    private func sectionGroup(title: String, items: [SidebarSection]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            ForEach(items) { item in
                let isSelected = appState.browser.selectedSidebar == item
                let badge = palette.sidebarBadgeColors(for: item)

                Button {
                    Task { await appState.browser.selectSidebar(item) }
                } label: {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.2) : badge.bg)
                            .frame(width: 24, height: 24)
                            .overlay {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.white : badge.fg)
                            }
                        Text(item.title)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        Spacer()
                        if let countText = sidebarCountText(for: item) {
                            Text(countText)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : palette.secondaryText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(isSelected ? Color.white : palette.primaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? palette.accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var paletteSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("儒雅配色")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text(palette.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.accent)
            }

            HStack(spacing: 6) {
                ForEach(ElegantPalette.allCases) { option in
                    let isSelected = option == palette
                    Button {
                        appState.palette = option
                    } label: {
                        HStack(spacing: 0) {
                            option.sidebarBackground
                            option.accent
                        }
                        .frame(height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? option.accent : palette.dividerColor, lineWidth: isSelected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("\(option.title)：\(option.subtitle)")
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.cardBackground.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(palette.dividerColor, lineWidth: 1)
        )
    }

    private func storageFooter(_ storage: StorageInfo) -> some View {
        let ratio = storage.totalBytes > 0
            ? min(1.0, max(0.0, Double(storage.usedBytes) / Double(storage.totalBytes)))
            : 0.0

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(storage.name)
                    .lineLimit(1)
                Spacer()
                Text("\(PathUtils.formatByteCount(storage.usedBytes)) / \(PathUtils.formatByteCount(storage.totalBytes))")
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.secondaryText)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.dividerColor)
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 5)
        }
        .padding(.top, 4)
    }

    private func sidebarCountText(for section: SidebarSection) -> String? {
        if section == .transfers {
            if appState.transferModel.activeCount > 0 {
                return "\(appState.transferModel.activeCount) 进行中"
            }
            if appState.transferModel.failedCount > 0 {
                return "\(appState.transferModel.failedCount) 失败"
            }
            return nil
        }
        guard appState.effectiveDeviceState == .ready, !appState.browser.mediaNodes.isEmpty else {
            return nil
        }
        let counts = appState.browser.mediaCounts
        switch section {
        case .photos:
            return "\(counts.all)"
        case .videos:
            return "\(counts.videos)"
        case .screenshots:
            return "\(counts.screenshots)"
        default:
            return nil
        }
    }

    private var statusColor: Color {
        guard appState.deviceManager.currentDevice != nil else {
            return Color.secondary.opacity(0.5)
        }
        switch appState.effectiveDeviceState {
        case .ready:
            return palette.successColor
        case .locked, .detected, .busy:
            return palette.warningColor
        case .error:
            return Color(red: 0.78, green: 0.24, blue: 0.24)
        case .none:
            return Color.secondary.opacity(0.5)
        }
    }

    private var statusText: String {
        guard let device = appState.deviceManager.currentDevice else {
            return "未连接设备"
        }
        let linkLabel = device.transport == .wifi ? "Wi-Fi 无线" : "USB 有线"
        switch appState.effectiveDeviceState {
        case .ready:
            return "已连接 · \(linkLabel)"
        case .locked:
            return "待解锁 · \(linkLabel)"
        case .detected, .busy:
            return "正在连接 · \(linkLabel)"
        case .error:
            return "连接异常 · \(linkLabel)"
        case .none:
            return "未连接设备"
        }
    }
}

/// 手机状态详情浮窗：展示电池、手机网络、IP 地址、系统版本、USB/Wi-Fi 链路与存储概要。
private struct DeviceDetailsPopoverView: View {
    let appState: AppState

    @State private var copiedKey: String?

    private var palette: ElegantPalette { appState.palette }

    var body: some View {
        let device = appState.deviceManager.currentDevice
        let status = appState.currentDeviceStatus
        let isTransferring = appState.transferModel.activeCount > 0 || appState.transferModel.isPreparing

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.accentSoft)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: device?.transport == .wifi ? "wifi" : "smartphone")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device?.name ?? "未连接设备")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if let device {
                        let subtitle = [device.manufacturer, device.model]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    Task { await appState.refreshDeviceStatus(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isTransferring ? palette.secondaryText.opacity(0.45) : palette.accent)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.surfaceSoft)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isTransferring || appState.isRefreshingDeviceStatus || appState.effectiveDeviceState != .ready)
                .help(isTransferring ? "文件传输进行中，暂缓主动轮询以免占用通道" : "立即刷新设备状态")
            }

            Divider().overlay(palette.dividerColor)

            // 电量区域
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("电池电量")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    if let level = status?.batteryLevel, let status {
                        HStack(spacing: 6) {
                            Image(systemName: SidebarView.batteryIconName(level: level, charging: status.chargingState))
                                .font(.system(size: 12))
                                .foregroundStyle(level <= 20 && status.chargingState != .charging ? palette.warningColor : palette.successColor)
                            Text("\(level)%")
                                .font(.system(size: 12.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(palette.primaryText)
                            if status.chargingState != .unknown {
                                Text(status.chargingState.rawValue)
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.secondaryText)
                            }
                            if let temp = status.batteryTempCelsius {
                                Text(String(format: "%.1f°C", temp))
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                    } else {
                        Text("设备 MTP 未上报")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                if let level = status?.batteryLevel {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.dividerColor)
                            Capsule()
                                .fill(level <= 15 ? palette.warningColor : palette.successColor)
                                .frame(width: proxy.size.width * min(1, max(0, Double(level) / 100.0)))
                        }
                    }
                    .frame(height: 5)
                }
            }

            Divider().overlay(palette.dividerColor)

            // 网络与系统链路明细
            VStack(alignment: .leading, spacing: 8) {
                detailRow(
                    title: "手机网络",
                    value: networkDisplayText(status)
                )

                if status?.networkType == .unavailable {
                    Text("纯 USB MTP 协议仅传输文件，切换或同时连接「无线调试」即可实时显示手机 Wi-Fi / 5G 与局域网 IP。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let ip = status?.ipAddress {
                    copyableRow(key: "ip", title: "局域网 IP", value: ip)
                }

                if let version = status?.androidVersion {
                    detailRow(title: "系统 / 固件", value: version)
                }

                detailRow(
                    title: "连接方式",
                    value: status?.connectionDetail ?? (device?.transport == .wifi ? "Wi-Fi 无线调试" : "USB 有线")
                )

                if let storage = appState.browser.currentStorage {
                    detailRow(
                        title: "内部存储",
                        value: "可用 \(PathUtils.formatByteCount(storage.freeBytes)) / 共 \(PathUtils.formatByteCount(storage.totalBytes))"
                    )
                }

                if let serial = device?.serialNumber, !serial.isEmpty {
                    copyableRow(key: "serial", title: "设备序列号", value: serial)
                }
            }

            Divider().overlay(palette.dividerColor)

            HStack {
                Text(footerText(status: status, isTransferring: isTransferring))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(palette.cardBackground)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func copyableRow(key: String, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryText)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copiedKey = key
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if copiedKey == key {
                        copiedKey = nil
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: copiedKey == key ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copiedKey == key ? palette.successColor : palette.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .help("点击复制")
        }
    }

    private func networkDisplayText(_ status: DeviceStatusInfo?) -> String {
        guard let status else { return "读取中…" }
        switch status.networkType {
        case .wifi:
            if let ssid = status.wifiSSID, !ssid.isEmpty {
                return "Wi-Fi（\(ssid)）"
            }
            return "Wi-Fi"
        case .unavailable:
            return "USB MTP 协议暂不提供"
        default:
            return status.networkType.rawValue
        }
    }

    private func footerText(status: DeviceStatusInfo?, isTransferring: Bool) -> String {
        if isTransferring {
            return "传输进行中 · 已暂停状态自动轮询以保障带宽"
        }
        guard let updatedAt = status?.updatedAt else {
            return "等待设备就绪后读取状态"
        }
        return "更新于 \(Self.timeFormatter.string(from: updatedAt))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
