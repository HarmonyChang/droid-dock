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

/// 内置高清图片查看器：支持双击图片放大/还原（1.0x ↔ 2.5x）、双指捏合、拖拽平移及左右翻页切换。
struct PhotoLightboxView: View {
    let appState: AppState
    let node: RemoteNode

    @State private var zoomScale: CGFloat = 1.0
    @State private var baseMagnification: CGFloat = 1.0
    @State private var steadyOffset: CGSize = .zero
    @State private var dragDelta: CGSize = .zero

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
        GeometryReader { geo in
            ZStack {
                if let image = resolvedImage {
                    Image(nsImage: image)
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
                        Text("正在从手机读取原图…")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.85))
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

                if appState.browser.isLoadingPreview && resolvedImage != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.white)
                            Text("正在加载高清原图…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .padding(.bottom, 18)
                    }
                    .allowsHitTesting(false)
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

    private var resolvedImage: NSImage? {
        if let localURL = appState.browser.previewLocalURL,
           let fullImage = NSImage(contentsOf: localURL) {
            return fullImage
        }
        if let thumbData = appState.browser.thumbnailData(for: node),
           let thumbImage = NSImage(data: thumbData) {
            return thumbImage
        }
        return nil
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
