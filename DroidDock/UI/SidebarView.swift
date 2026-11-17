import SwiftUI

/// 左侧边栏（固定 232 pt）：设备状态卡、儒雅彩色导航分组、配色预览切换、底部存储用量条。
struct SidebarView: View {
    let appState: AppState

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
                Text("DroidDock")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.primaryText)
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
