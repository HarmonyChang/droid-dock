import SwiftUI

/// 版本记录与自动升级弹窗：支持检查 GitHub Releases、在线下载校验并重启升级，以及浏览历史版本变更日志。
struct AppUpdateSheetView: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss

    private var palette: ElegantPalette { appState.palette }
    private var updateService: AppUpdateService { appState.updateService }

    private var isTransferring: Bool {
        appState.transferModel.activeCount > 0 || appState.transferModel.isPreparing
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(palette.dividerColor)

            VStack(alignment: .leading, spacing: 14) {
                updateStatusCard

                if isTransferring {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.warningColor)
                        Text("当前正在进行文件传输，请等待传输队列完成后再点击「立即升级」。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.primaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.warningColor.opacity(0.12))
                    )
                }

                changelogSection
            }
            .padding(18)
        }
        .frame(width: 560, height: 570)
        .background(palette.contentBackground)
        .preferredColorScheme(.light)
        .tint(palette.accent)
    }

    private var headerBar: some View {
        HStack(spacing: 11) {
            DroidDockLogoView(size: 34, accent: palette.accent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("DroidDock")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text("v\(updateService.currentVersionString) (Build \(updateService.currentBuildString))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(palette.accentSoft)
                        )
                }
                Text("版本更新记录与自动升级")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(palette.surfaceSoft))
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(palette.toolbarBackground)
    }

    private var updateStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                statusIconView

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(statusSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                actionButtons
            }

            if case .downloading(_, let progress, let received, let total) = updateService.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(palette.accent)
                    HStack {
                        Text(total > 0
                             ? "\(PathUtils.formatByteCount(UInt64(max(0, received)))) / \(PathUtils.formatByteCount(UInt64(total)))"
                             : PathUtils.formatByteCount(UInt64(max(0, received))))
                            .monospacedDigit()
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                }
            } else if case .verifying = updateService.state {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
            } else if case .installing = updateService.state {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
            }

            Divider().overlay(palette.dividerColor)

            HStack {
                Toggle("启动时自动检查 GitHub 更新", isOn: Binding(
                    get: { updateService.autoCheckEnabled },
                    set: { updateService.autoCheckEnabled = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)

                Spacer()

                if let checkedAt = updateService.lastCheckedAt {
                    Text("上次检查：\(Self.timeFormatter.string(from: checkedAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.cardBackground)
                .shadow(color: Color.black.opacity(0.04), radius: 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.dividerColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIconView: some View {
        switch updateService.state {
        case .checking, .verifying, .installing:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.accentSoft)
                .frame(width: 34, height: 34)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        case .available, .downloading:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.accentSoft)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(palette.accent)
                }
        case .upToDate:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.successColor.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(palette.successColor)
                }
        case .error:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.warningColor.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.warningColor)
                }
        case .idle:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.surfaceSoft)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.accent)
                }
        }
    }

    private var statusTitle: String {
        switch updateService.state {
        case .idle:
            return "当前运行 DroidDock v\(updateService.currentVersionString)"
        case .checking:
            return "正在检查更新…"
        case .upToDate:
            return "当前已是最新版本（v\(updateService.currentVersionString)）"
        case .available(let release):
            return "发现新版本 v\(release.versionString)"
        case .downloading(let release, _, _, _):
            return "正在下载 v\(release.versionString)…"
        case .verifying(let release):
            return "正在校验 v\(release.versionString) 安装包…"
        case .installing(let release):
            return "正在替换为 v\(release.versionString) 并重启…"
        case .error:
            return "检查或升级未完成"
        }
    }

    private var statusSubtitle: String {
        switch updateService.state {
        case .idle:
            return updateService.statusNote ?? "点击右侧按钮从 GitHub Releases 检查最新安装包。"
        case .checking:
            return "正在读取 \(AppUpdateService.githubOwner)/\(AppUpdateService.githubRepo) 的最新发布信息。"
        case .upToDate(let latest):
            return updateService.statusNote ?? "远端最新发布版本为 v\(latest)，无需升级。"
        case .available(let release):
            let sizeText = release.expectedSizeBytes > 0
                ? " · \(PathUtils.formatByteCount(UInt64(release.expectedSizeBytes)))"
                : ""
            return "\(release.title)\(sizeText)"
        case .downloading(let release, _, _, _):
            return release.downloadFilename
        case .verifying:
            return "正在核对 SHA-256 摘要与应用签名（codesign）。"
        case .installing:
            return "即将退出当前进程并在数秒内自动打开新版本。"
        case .error(let message):
            return message
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch updateService.state {
        case .idle, .upToDate, .error:
            Button("检查更新") {
                Task { await updateService.checkForUpdates(userInitiated: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

        case .checking, .verifying, .installing:
            EmptyView()

        case .available:
            HStack(spacing: 6) {
                Button("跳过") {
                    updateService.skipAvailableVersion()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("立即升级") {
                    updateService.downloadAndInstallUpdate(isTransferring: isTransferring)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isTransferring)
            }

        case .downloading:
            Button("取消") {
                updateService.cancelDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var changelogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("版本更新记录")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)

                Spacer()

                Button {
                    updateService.openReleasesPage()
                } label: {
                    HStack(spacing: 4) {
                        Text("GitHub Releases")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(updateService.mergedChangelog) { entry in
                        changelogRow(entry)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func changelogRow(_ entry: ChangelogEntry) -> some View {
        let isCurrent = SemanticVersion(entry.version) == SemanticVersion(updateService.currentVersionString)
        let isNewer: Bool = {
            guard let itemVer = SemanticVersion(entry.version),
                  let currentVer = SemanticVersion(updateService.currentVersionString) else {
                return false
            }
            return itemVer > currentVer
        }()

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("v\(entry.version)")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.primaryText)

                if isCurrent {
                    Text("当前版本")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.successColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(palette.successColor.opacity(0.14))
                        )
                } else if isNewer {
                    Text("可升级")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(palette.accentSoft)
                        )
                }

                Text(entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Spacer()

                if !entry.releaseDate.isEmpty {
                    Text(entry.releaseDate)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryText)
                }
            }

            if !entry.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(palette.accent)
                            Text(line)
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isCurrent ? palette.accent.opacity(0.35) : palette.dividerColor, lineWidth: 1)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
