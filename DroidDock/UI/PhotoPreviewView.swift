import AppKit
import Quartz
import SwiftUI

/// 系统 Quick Look（空格键或工具栏触发）控制器：基于临时缓存文件路径唤起 `QLPreviewPanel`。
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private let urlStorage = LockedPreviewURL()

    private override init() {
        super.init()
    }

    func present(url: URL) {
        urlStorage.set(url)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urlStorage.get() == nil ? 0 : 1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index == 0, let url = urlStorage.get() else {
            return nil
        }
        return url as NSURL
    }
}

private final class LockedPreviewURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func set(_ newURL: URL?) {
        lock.lock()
        url = newURL
        lock.unlock()
    }

    func get() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }
}

/// 内置高清图片查看器：支持优先高清原图渲染、右上角照片信息卡片、双击放大/还原（1.0x ↔ 2.5x）、双指捏合、拖拽平移及左右翻页切换。
struct PhotoLightboxView: View {
    let appState: AppState
    let node: RemoteNode

    @State private var zoomScale: CGFloat = 1.0
    @State private var baseMagnification: CGFloat = 1.0
    @State private var steadyOffset: CGSize = .zero
    @State private var dragDelta: CGSize = .zero
    @State private var showMetadataPanel: Bool = true

    private var palette: ElegantPalette { appState.palette }

    var body: some View {
        let photos = appState.browser.previewablePhotos
        let currentIndex = photos.firstIndex(where: { $0.id == node.id })
        let canStepPrev = (currentIndex ?? 0) > 0
        let canStepNext = currentIndex.map { $0 + 1 < photos.count } ?? false

        ZStack {
            Color.black.opacity(0.86)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.browser.closePreview()
                }

            VStack(spacing: 0) {
                topBar(currentIndex: currentIndex, totalCount: photos.count)
                imageCanvas(
                    currentIndex: currentIndex,
                    totalCount: photos.count,
                    canStepPrev: canStepPrev,
                    canStepNext: canStepNext
                )
            }
        }
        .onAppear {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: node.id) { _, _ in
            resetTransform(animated: false)
        }
    }

    private func topBar(currentIndex: Int?, totalCount: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let dims = appState.browser.previewMetadata?.dimensionsText {
                        Text(dims)
                    }
                    Text(PathUtils.formatByteCount(node.size))
                    if let currentIndex, totalCount > 1 {
                        Text("· 第 \(currentIndex + 1) / \(totalCount) 张")
                    }
                    Text("· 双击图片放大/还原")
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.82))
                .monospacedDigit()
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    adjustZoom(by: -0.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(zoomScale > 1.01 ? Color.white : Color.white.opacity(0.4))
                .disabled(zoomScale <= 1.01)

                Button {
                    resetTransform(animated: true)
                } label: {
                    Text("\(Int((zoomScale * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 44)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .help("还原为 100%")

                Button {
                    adjustZoom(by: 0.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(zoomScale < 3.99 ? Color.white : Color.white.opacity(0.4))
                .disabled(zoomScale >= 3.99)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.12)))

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showMetadataPanel.toggle()
                }
            } label: {
                Label("信息", systemImage: showMetadataPanel ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(showMetadataPanel ? palette.accent.opacity(0.85) : Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .help("显示或隐藏右上角照片详细信息")

            if let localURL = appState.browser.previewLocalURL {
                Button("Quick Look") {
                    QuickLookController.shared.present(url: localURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.white)
            }

            Button("导入到 Mac…") {
                TransferPanelHelper.pickDestinationAndDownload(
                    nodes: [node],
                    transferModel: appState.transferModel
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(palette.accent)

            Button {
                appState.browser.closePreview()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("关闭预览 (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.35))
    }

    private func imageCanvas(currentIndex: Int?, totalCount: Int, canStepPrev: Bool, canStepNext: Bool) -> some View {
        let resolved = resolvedImageState

        return GeometryReader { geo in
            ZStack {
                if let resolved {
                    Image(nsImage: resolved.image)
                        .interpolation(.high)
                        .antialiased(true)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: max(120, geo.size.width - 110),
                            maxHeight: max(120, geo.size.height - 48)
                        )
                        .scaleEffect(zoomScale)
                        .offset(clampedOffset(in: geo.size))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            toggleDoubleClickZoom()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    guard zoomScale > 1.01 else { return }
                                    dragDelta = value.translation
                                }
                                .onEnded { value in
                                    guard zoomScale > 1.01 else {
                                        steadyOffset = .zero
                                        dragDelta = .zero
                                        return
                                    }
                                    let combined = CGSize(
                                        width: steadyOffset.width + value.translation.width,
                                        height: steadyOffset.height + value.translation.height
                                    )
                                    steadyOffset = clamp(combined, in: geo.size, scale: zoomScale)
                                    dragDelta = .zero
                                }
                        )
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    let next = min(4.0, max(1.0, baseMagnification * value.magnification))
                                    zoomScale = next
                                }
                                .onEnded { _ in
                                    baseMagnification = zoomScale
                                    if zoomScale <= 1.02 {
                                        resetTransform(animated: true)
                                    } else {
                                        steadyOffset = clamp(steadyOffset, in: geo.size, scale: zoomScale)
                                    }
                                }
                        )
                } else if appState.browser.isLoadingPreview {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Color.white)
                        Text(progressLoadingText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .monospacedDigit()
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.white.opacity(0.75))
                        Text(appState.browser.previewError ?? "无法加载图片预览")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.85))
                        Button("重试") {
                            Task { await appState.browser.openPreview(for: node) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                    }
                }

                if resolved?.isPlaceholder == true {
                    if appState.browser.isLoadingPreview {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color.white)
                                Text(progressLoadingText)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.white)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.68)))
                            .padding(.bottom, totalCount > 1 ? 58 : 18)
                        }
                        .allowsHitTesting(false)
                    } else if let previewError = appState.browser.previewError {
                        VStack {
                            Spacer()
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(palette.warningColor)
                                Text("高清原图读取失败（当前仅显示缩略图）：\(previewError)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.white)
                                    .lineLimit(1)
                                Button("重新加载") {
                                    Task { await appState.browser.openPreview(for: node) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .tint(palette.accent)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .padding(.bottom, totalCount > 1 ? 58 : 18)
                        }
                    }
                }

                if showMetadataPanel {
                    VStack {
                        HStack {
                            Spacer()
                            PhotoMetadataOverlayCard(
                                node: node,
                                metadata: appState.browser.previewMetadata ?? PhotoMetadata.initial(from: node),
                                isLoading: appState.browser.isLoadingPreview,
                                progress: appState.browser.previewProgress,
                                accent: palette.accent,
                                successColor: palette.successColor
                            )
                        }
                        Spacer()
                    }
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .allowsHitTesting(true)
                }

                HStack {
                    Button {
                        Task { await appState.browser.previewAdjacentPhoto(step: -1) }
                    } label: {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(
                                canStepPrev ? Color.white.opacity(0.88) : Color.white.opacity(0.22),
                                Color.black.opacity(0.35)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStepPrev)
                    .padding(.leading, 18)
                    .help("上一张 (←)")

                    Spacer()

                    Button {
                        Task { await appState.browser.previewAdjacentPhoto(step: 1) }
                    } label: {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(
                                canStepNext ? Color.white.opacity(0.88) : Color.white.opacity(0.22),
                                Color.black.opacity(0.35)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStepNext)
                    .padding(.trailing, 18)
                    .help("下一张 (→)")
                }

                if totalCount > 1, let currentIndex {
                    VStack {
                        Spacer()
                        HStack(spacing: 14) {
                            Button {
                                Task { await appState.browser.previewAdjacentPhoto(step: -1) }
                            } label: {
                                Label("上一张", systemImage: "chevron.left")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(canStepPrev ? Color.white : Color.white.opacity(0.35))
                            .disabled(!canStepPrev)

                            Text("\(currentIndex + 1) / \(totalCount)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .monospacedDigit()

                            Button {
                                Task { await appState.browser.previewAdjacentPhoto(step: 1) }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("下一张")
                                    Image(systemName: "chevron.right")
                                }
                                .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(canStepNext ? Color.white : Color.white.opacity(0.35))
                            .disabled(!canStepNext)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.bottom, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resolvedImageState: (image: NSImage, isPlaceholder: Bool)? {
        if let fullImage = appState.browser.previewFullImage {
            return (fullImage, false)
        }
        if let localURL = appState.browser.previewLocalURL,
           let fallbackFull = NSImage(contentsOf: localURL) {
            return (fallbackFull, false)
        }
        if let cachedThumb = appState.browser.cachedThumbnailImage(for: node) {
            return (cachedThumb, true)
        }
        if let thumbData = appState.browser.thumbnailData(for: node),
           let thumbImage = NSImage(data: thumbData) {
            return (thumbImage, true)
        }
        return nil
    }

    private var progressLoadingText: String {
        let pct = Int((appState.browser.previewProgress * 100).rounded())
        if pct > 0 && pct < 100 {
            return "正在读取高清原图 \(pct)%…"
        }
        return "正在从手机读取高清原图…"
    }

    private func toggleDoubleClickZoom() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.84)) {
            if zoomScale > 1.05 {
                zoomScale = 1.0
                baseMagnification = 1.0
                steadyOffset = .zero
                dragDelta = .zero
            } else {
                zoomScale = 2.5
                baseMagnification = 2.5
                steadyOffset = .zero
                dragDelta = .zero
            }
        }
    }

    private func adjustZoom(by delta: CGFloat) {
        let next = min(4.0, max(1.0, zoomScale + delta))
        withAnimation(.easeInOut(duration: 0.16)) {
            zoomScale = next
            baseMagnification = next
            if next <= 1.01 {
                steadyOffset = .zero
                dragDelta = .zero
            }
        }
    }

    private func resetTransform(animated: Bool) {
        let apply = {
            zoomScale = 1.0
            baseMagnification = 1.0
            steadyOffset = .zero
            dragDelta = .zero
        }
        if animated {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                apply()
            }
        } else {
            apply()
        }
    }

    private func clampedOffset(in containerSize: CGSize) -> CGSize {
        let raw = CGSize(
            width: steadyOffset.width + dragDelta.width,
            height: steadyOffset.height + dragDelta.height
        )
        return clamp(raw, in: containerSize, scale: zoomScale)
    }

    private func clamp(_ offset: CGSize, in containerSize: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1.01 else { return .zero }
        let maxX = containerSize.width * (scale - 1) * 0.55
        let maxY = containerSize.height * (scale - 1) * 0.55
        return CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height))
        )
    }
}

private struct PhotoMetadataOverlayCard: View {
    let node: RemoteNode
    let metadata: PhotoMetadata
    let isLoading: Bool
    let progress: Double
    let accent: Color
    let successColor: Color

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text("照片信息")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer()
                statusBadge
            }

            Divider().overlay(Color.white.opacity(0.14))

            VStack(alignment: .leading, spacing: 5) {
                infoRow(
                    label: "尺寸",
                    value: dimensionSummary
                )
                infoRow(
                    label: "大小 / 格式",
                    value: "\(PathUtils.formatByteCount(metadata.fileSizeBytes)) · \(metadata.formatName)"
                )
                if let capturedAt = metadata.capturedAt {
                    infoRow(label: "拍摄时间", value: Self.dateFormatter.string(from: capturedAt))
                }
                if let camera = metadata.cameraModel {
                    infoRow(label: "拍摄设备", value: camera)
                }
                if let lens = metadata.lensModel {
                    infoRow(label: "镜头", value: lens)
                }
                if let colorProfile = metadata.colorProfileName {
                    infoRow(label: "色彩配置", value: colorProfile)
                }
                if let gps = metadata.gpsText {
                    infoRow(label: "位置坐标", value: gps)
                }
                infoRow(label: "设备路径", value: node.path)
            }

            if !metadata.exposureTags.isEmpty {
                Divider().overlay(Color.white.opacity(0.14))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(metadata.exposureTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.92))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.14)))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 266, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.64))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if metadata.isOriginalLoaded {
            HStack(spacing: 4) {
                Circle()
                    .fill(successColor)
                    .frame(width: 6, height: 6)
                Text("高清原图")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        } else if isLoading {
            let pct = Int((progress * 100).rounded())
            Text(pct > 0 ? "读取原图 \(pct)%" : "读取原图中…")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(accent.opacity(0.75)))
        } else {
            Text("预览概览")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }

    private var dimensionSummary: String {
        if let dims = metadata.dimensionsText {
            if let mp = metadata.megapixelsText {
                return "\(dims)（\(mp)）"
            }
            return dims
        }
        return isLoading ? "读取原图后解析…" : "未知尺寸"
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.92))
                .monospacedDigit()
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
