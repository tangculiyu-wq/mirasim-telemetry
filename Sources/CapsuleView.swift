import SwiftUI

/// 极小胶囊。
///
/// 只放三样：一枚随额度变色的点、最吃紧窗口的百分比、它的名字。
/// 面板上的一切明细都不进来——胶囊的职责是「扫一眼就走」，
/// 点一下它就回到完整面板。
struct CapsuleView: View {
    @ObservedObject var store: Store
    @Environment(\.colorScheme) private var scheme
    /// 点击 → 展开回面板。
    var onExpand: () -> Void
    /// 点小 ✕ → 收进顶边（鼠标顶到屏幕顶部停一下会再滑出来）。
    var onTuck: () -> Void = {}
    var onRightClick: ((NSEvent) -> Void)? = nil
    /// 拖动结束 → 外面决定记住位置还是磁吸回停靠位。
    var onDragEnd: (() -> Void)? = nil

    @StateObject private var hover = Flag()

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: 7) {
            if let w = store.focusWindow {
                let accent = Theme.accent(w.severity, dark: dark).0
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(0.7), radius: 2.5)

                Text(Fmt.percentShort(w.usedPercent, precision: w.precision))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
                    // 窗框重设有一拍延迟，这一拍里也绝不许把数字压成省略号
                    .fixedSize()

                Text(w.displayName)
                    .font(Theme.label(10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Circle().fill(.tertiary).frame(width: 7, height: 7)
                Text("— —").font(Theme.mono(12, .bold)).foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
                .opacity(hover.on ? 1 : 0.4)

            // 悬停才亮出来的收纳钮。位置恒定占着，只切透明度——
            // 用 if 增删视图会让胶囊宽度跳一下，贴靠居中就跟着抖。
            Button {
                onTuck()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .opacity(hover.on ? 1 : 0)
            .allowsHitTesting(hover.on)
            .help("收进顶边——鼠标顶到屏幕顶部停一下会再滑出来")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                Color.white.opacity(dark ? 0 : 0.34)
                // 鼠标层在背景：左键分辨「点一下展开」与「按住拖走」，右键出菜单。
                // ✕ 按钮在上层，不受影响。
                CapsuleMouseCatcher(onClick: onExpand,
                                    onDragEnd: onDragEnd,
                                    onRightClick: onRightClick)
            }
        )
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(.white.opacity(dark ? 0.10 : 0.5), lineWidth: 0.5))
        .scaleEffect(hover.on ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hover.on)
        .onHover { hover.on = $0 }
        .contentShape(Capsule())
        .help("点一下展开完整面板；按住拖到哪都行（位置会记住，拖回 Mirasim 窗口顶边即恢复自动吸附）；右键出菜单")
    }
}

/// 胶囊的鼠标层。
///
/// 左键在这儿就地分辨「点击」与「拖动」：按下后 3pt 内抬手＝点击（展开），
/// 拖出 3pt＝把窗口交给系统 `performDrag`，拖完回调外面记位置。
/// 不能用 SwiftUI 的 onTapGesture——它一接手，performDrag 就没有入场时机了。
struct CapsuleMouseCatcher: NSViewRepresentable {
    var onClick: () -> Void = {}
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let v = CapsuleMouseView()
        v.onClick = onClick; v.onDragEnd = onDragEnd; v.onRightClick = onRightClick
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let m = v as? CapsuleMouseView else { return }
        m.onClick = onClick; m.onDragEnd = onDragEnd; m.onRightClick = onRightClick
    }
}

final class CapsuleMouseView: NSView {
    var onClick: () -> Void = {}
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    private var downAtScreen = NSPoint.zero
    private var originAtDown = NSPoint.zero
    private var dragging = false

    // 手动拖：mouseDragged 按屏幕坐标差直接挪窗口。
    // 两条系统路都在这种小窗上翻过车：nextEvent 循环收不到后续事件，
    // performDrag 立即返回不跟踪（位移恒零→按下瞬间被误判成点击，
    // 用户实测「按一下直接变大框」）。手动路不依赖任何窗口类型特性。
    override func mouseDown(with event: NSEvent) {
        downAtScreen = NSEvent.mouseLocation   // 用屏幕坐标——窗口在动，窗内坐标不动
        originAtDown = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - downAtScreen.x, dy = m.y - downAtScreen.y
        if !dragging, hypot(dx, dy) > 3 { dragging = true }
        if dragging {
            w.setFrameOrigin(NSPoint(x: originAtDown.x + dx, y: originAtDown.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            onDragEnd?()
        } else {
            onClick()
        }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }
}
