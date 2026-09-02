import AppKit
import SwiftUI

/// 菜单栏图标：一枚跟着额度走的迷你环。
///
/// 不用 SF Symbol 的原因是要连续表达「还剩多少」——符号只能给几个离散档位，
/// 而这枚环从 0 到 100 是连着变的，扫一眼就知道紧不紧张，不必点开。
enum StatusIcon {

    /// - Parameters:
    ///   - fraction: 已用比例 0–1。
    ///   - severity: 紧迫度，决定颜色。
    ///   - stale: 数据是否已陈旧。陈旧时整枚环去色，避免一个旧数字看着像当前状态。
    static func make(fraction: Double, severity: Double, stale: Bool) -> NSImage {
        let d: CGFloat = 16          // 菜单栏视觉高度
        let lw: CGFloat = 2.4
        let size = NSSize(width: d, height: d)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            let center = CGPoint(x: d / 2, y: d / 2)
            let radius = (d - lw) / 2 - 0.5

            // 轨道
            ctx.setLineWidth(lw)
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.22).cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()

            // 进度弧：12 点方向起，顺时针
            let f = min(1, max(0, fraction))
            if f > 0.001 {
                let color: NSColor = stale
                    ? NSColor.labelColor.withAlphaComponent(0.55)
                    : nsAccent(severity)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineCap(.round)
                let start = CGFloat.pi / 2
                ctx.addArc(center: center, radius: radius,
                           startAngle: start, endAngle: start - .pi * 2 * f,
                           clockwise: true)
                ctx.strokePath()
            }
            return true
        }
        // 不设 isTemplate：模板图会被系统抹成单色，状态色就没了。
        image.isTemplate = false
        return image
    }

    /// 完全没有数据时的图标：一枚空心虚环，与「用了 0%」区分开。
    static func placeholder() -> NSImage {
        let d: CGFloat = 16
        let lw: CGFloat = 2.4
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setLineWidth(lw)
            ctx.setLineDash(phase: 0, lengths: [2.2, 2.2])
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.35).cgColor)
            ctx.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: (d - lw) / 2 - 0.5,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 与面板同一套色标，换成 NSColor。
    private static func nsAccent(_ severity: Double) -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (base, _) = Theme.accent(severity, dark: dark)
        return NSColor(base)
    }
}
