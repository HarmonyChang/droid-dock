import AppKit
import SwiftUI

/// DroidDock 品牌矢量标志（可用于侧栏页眉与未连接引导区）。
struct DroidDockLogoView: View {
    var size: CGFloat = 32
    var accent: Color = Color(red: 0.21, green: 0.36, blue: 0.49)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.95),
                            Color(red: 0.14, green: 0.27, blue: 0.39),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: max(0.8, size * 0.025))
                )

            // 底部 Dock 底座
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(Color(red: 0.96, green: 0.94, blue: 0.90))
                .frame(width: size * 0.62, height: size * 0.14)
                .offset(y: size * 0.24)

            // 手机剪影
            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .fill(Color(red: 0.98, green: 0.97, blue: 0.95))
                .frame(width: size * 0.36, height: size * 0.50)
                .offset(x: -size * 0.09, y: -size * 0.02)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                        .fill(Color(red: 0.17, green: 0.49, blue: 0.44))
                        .frame(width: size * 0.27, height: size * 0.37)
                        .offset(x: -size * 0.09, y: -size * 0.02)
                }

            // 双向传输圆章
            Circle()
                .fill(Color(red: 0.85, green: 0.58, blue: 0.25))
                .frame(width: size * 0.29, height: size * 0.29)
                .overlay(
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: max(8, size * 0.14), weight: .bold))
                        .foregroundStyle(Color.white)
                )
                .offset(x: size * 0.17, y: size * 0.05)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.12), radius: size * 0.08, y: size * 0.04)
    }
}

/// CoreGraphics 离屏渲染应用图标，启动时同步赋给 `NSApplication.shared.applicationIconImage`。
enum AppIconRenderer {
    static func makeApplicationIcon(size: CGFloat = 512) -> NSImage {
        let rep = makeBitmapRep(pixelSize: Int(size))
        let image = NSImage(size: NSSize(width: size, height: size))
        if let rep {
            image.addRepresentation(rep)
        }
        return image
    }

    static func makeBitmapRep(pixelSize: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let s = CGFloat(pixelSize)
        let cg = context.cgContext
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)

        // macOS 圆角方框规范留边（约 8.5%）
        let inset = s * 0.085
        let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let cardRadius = cardRect.width * 0.225
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

        // 柔和底阴影
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        cg.addPath(cardPath)
        cg.setFillColor(NSColor(red: 0.21, green: 0.36, blue: 0.49, alpha: 1.0).cgColor)
        cg.fillPath()
        cg.restoreGState()

        // 黛蓝宋锦渐变底色
        cg.saveGState()
        cg.addPath(cardPath)
        cg.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 0.26, green: 0.44, blue: 0.59, alpha: 1.0).cgColor,
                NSColor(red: 0.13, green: 0.24, blue: 0.35, alpha: 1.0).cgColor,
            ] as CFArray,
            locations: [0.0, 1.0]
        ) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
                end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
                options: []
            )
        }
        cg.restoreGState()

        // 顶部细微高光描边
        cg.saveGState()
        cg.addPath(cardPath)
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        cg.setLineWidth(max(1.0, s * 0.012))
        cg.strokePath()
        cg.restoreGState()

        // Dock 底座
        let dockW = cardRect.width * 0.66
        let dockH = cardRect.height * 0.14
        let dockRect = CGRect(
            x: cardRect.midX - dockW / 2,
            y: cardRect.minY + cardRect.height * 0.16,
            width: dockW,
            height: dockH
        )
        let dockPath = CGPath(roundedRect: dockRect, cornerWidth: dockH * 0.48, cornerHeight: dockH * 0.48, transform: nil)
        cg.addPath(dockPath)
        cg.setFillColor(NSColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1.0).cgColor)
        cg.fillPath()

        // 手机机身
        let phoneW = cardRect.width * 0.37
        let phoneH = cardRect.height * 0.52
        let phoneRect = CGRect(
            x: cardRect.midX - phoneW * 0.68,
            y: cardRect.midY - phoneH * 0.34,
            width: phoneW,
            height: phoneH
        )
        let phonePath = CGPath(roundedRect: phoneRect, cornerWidth: phoneW * 0.18, cornerHeight: phoneW * 0.18, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        cg.addPath(phonePath)
        cg.setFillColor(NSColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0).cgColor)
        cg.fillPath()
        cg.restoreGState()

        // 手机屏幕
        let bezel = phoneW * 0.12
        let screenRect = phoneRect.insetBy(dx: bezel, dy: bezel * 1.15)
        let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenRect.width * 0.12, cornerHeight: screenRect.width * 0.12, transform: nil)
        cg.addPath(screenPath)
        cg.setFillColor(NSColor(red: 0.18, green: 0.49, blue: 0.44, alpha: 1.0).cgColor)
        cg.fillPath()

        // 琥珀金传输圆徽标与双向箭头
        let badgeSize = cardRect.width * 0.31
        let badgeRect = CGRect(
            x: cardRect.midX + cardRect.width * 0.05,
            y: cardRect.midY - badgeSize * 0.52,
            width: badgeSize,
            height: badgeSize
        )
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.24).cgColor)
        cg.setFillColor(NSColor(red: 0.85, green: 0.56, blue: 0.23, alpha: 1.0).cgColor)
        cg.fillEllipse(in: badgeRect)
        cg.restoreGState()

        // 在徽标内绘制上下双向箭头
        cg.saveGState()
        cg.setStrokeColor(NSColor.white.cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(max(1.2, badgeSize * 0.11))

        let cx = badgeRect.midX
        let cy = badgeRect.midY
        let arrowDX = badgeSize * 0.14
        let arrowH = badgeSize * 0.24
        let head = badgeSize * 0.11

        // 左上箭头
        let ux = cx - arrowDX
        cg.move(to: CGPoint(x: ux, y: cy - arrowH * 0.65))
        cg.addLine(to: CGPoint(x: ux, y: cy + arrowH))
        cg.move(to: CGPoint(x: ux - head, y: cy + arrowH - head))
        cg.addLine(to: CGPoint(x: ux, y: cy + arrowH))
        cg.addLine(to: CGPoint(x: ux + head, y: cy + arrowH - head))

        // 右下箭头
        let dx = cx + arrowDX
        cg.move(to: CGPoint(x: dx, y: cy + arrowH * 0.65))
        cg.addLine(to: CGPoint(x: dx, y: cy - arrowH))
        cg.move(to: CGPoint(x: dx - head, y: cy - arrowH + head))
        cg.addLine(to: CGPoint(x: dx, y: cy - arrowH))
        cg.addLine(to: CGPoint(x: dx + head, y: cy - arrowH + head))
        cg.strokePath()
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
