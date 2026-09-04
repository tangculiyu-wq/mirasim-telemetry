import SwiftUI
import AppKit

/// 设计系统。
///
/// 配色只有一条主线：一个强调色随「用了多少」从充裕滑到耗尽。
/// 不给每个窗口分配各自的颜色——那样三条彩色进度条摆在一起，颜色就不再表意，
/// 只剩装饰。这里颜色始终只说一件事：还剩多少。
enum Theme {

    // MARK: 强调色

    /// 色标。取自 Apple 系统色，深浅两套各自调过明度，
    /// 保证在毛玻璃背景上都够亮但不刺眼。
    private struct Stop {
        let light: (Double, Double, Double)
        let dark: (Double, Double, Double)
    }

    private static let calm  = Stop(light: (0.16, 0.72, 0.32), dark: (0.19, 0.84, 0.29))  // 绿
    private static let mint  = Stop(light: (0.00, 0.78, 0.60), dark: (0.10, 0.88, 0.70))  // 青，作绿的高光
    private static let amber = Stop(light: (0.93, 0.55, 0.03), dark: (1.00, 0.63, 0.07))  // 琥珀（偏橙）
    private static let gold  = Stop(light: (1.00, 0.70, 0.12), dark: (1.00, 0.77, 0.22))  // 金，作琥珀的高光
    private static let alarm = Stop(light: (0.90, 0.22, 0.20), dark: (1.00, 0.31, 0.26))  // 红
    private static let coral = Stop(light: (1.00, 0.36, 0.38), dark: (1.00, 0.48, 0.46))  // 珊瑚，作红的高光

    private static func rgb(_ s: Stop, _ dark: Bool) -> (Double, Double, Double) {
        dark ? s.dark : s.light
    }

    private static func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double)
        -> (Double, Double, Double) {
        let t = min(1, max(0, t))
        return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    /// 由紧迫度取一对渐变色（主色 + 高光）。
    /// 分段插值而非硬切：85% 与 86% 不该是两种截然不同的颜色。
    static func accent(_ severity: Double, dark: Bool) -> (Color, Color) {
        let s = min(1, max(0, severity))
        let base: (Double, Double, Double)
        // 高光色只作为色相参照，实际取值由 base 提亮而来——
        // 两端各自独立插值会在中途穿过第三种颜色：绿的高光（青）插到
        // 琥珀的高光（金）之间是黄绿，于是 80% 那档看着发黄绿而不是琥珀。
        let hint: (Double, Double, Double)
        if s < 0.55 {
            base = rgb(calm, dark);  hint = rgb(mint, dark)
        } else if s < 0.85 {
            // 加速离开绿区：线性插值下 70% 落在绿与琥珀正中，得到的是黄绿；
            // 提前把色相推向金黄，读起来才是「该留意了」而不是「还很绿」。
            let t = pow((s - 0.55) / 0.30, 0.62)
            base = lerp(rgb(calm, dark),  rgb(amber, dark), t)
            hint = rgb(gold, dark)
        } else {
            let t = (s - 0.85) / 0.15
            base = lerp(rgb(amber, dark), rgb(alarm, dark), t)
            hint = rgb(coral, dark)
        }
        // 提亮为主、掺一分同档高光定色相，渐变始终待在一个色系里
        let high = lerp((min(1, base.0 * 1.05 + 0.09),
                         min(1, base.1 * 1.05 + 0.09),
                         min(1, base.2 * 1.05 + 0.07)), hint, 0.22)
        return (Color(red: base.0, green: base.1, blue: base.2),
                Color(red: high.0, green: high.1, blue: high.2))
    }

    static func accentGradient(_ severity: Double, dark: Bool) -> LinearGradient {
        let (a, b) = accent(severity, dark: dark)
        return LinearGradient(colors: [b, a], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: 字体

    /// 大数字。圆体 + 等宽数字：读数跳动时字宽不变，整块不会左右抖。
    static func numeral(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func label(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// 等宽。数据行全用它——一屏几十个数字对不齐就是灾难。
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: 版式常量

    static let panelWidth: CGFloat = 344
    static let corner: CGFloat = 20
    static let cardCorner: CGFloat = 14
}

// MARK: - 格式化

enum Fmt {
    /// 百分比，精确到小数点后 5 位。
    /// 帧口径本来就只有 0.1 的分辨率，给它印 5 位是假精度，故仍只给 1 位。
    static func percent(_ v: Double, precision: Precision) -> String {
        precision == .exact ? String(format: "%.5f%%", v) : String(format: "%.1f%%", v)
    }

    /// 短版百分比，给菜单栏和空间紧张处用。
    static func percentShort(_ v: Double, precision: Precision) -> String {
        precision == .exact ? String(format: "%.2f%%", v) : String(format: "%.1f%%", v)
    }

    /// 美元。始终带 ≈——它是按官方价目表 × 本机账本算的，
    /// 且只覆盖走 Claude Code 的请求，不是上游账单。
    static func usd(_ v: Double) -> String { "≈" + usdPlain(v) }

    static func usdPlain(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = v >= 100 ? 0 : (v >= 10 ? 1 : 2)
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v))
    }

    /// 额度点。整数部分加千分位，小数丢掉——点数本身是几十万量级，
    /// 小数位在面板上只是噪声（明细里另给）。
    static func points(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(Int(v))
    }

    /// 「16:20:05」，给最近调用列表。
    static func clockSec(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    /// token 数：1.2M / 345k / 980。
    static func tokens(_ v: Double) -> String {
        if v >= 1e9 { return String(format: "%.2fB", v / 1e9) }
        if v >= 1e6 { return String(format: v >= 1e7 ? "%.0fM" : "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: v >= 1e5 ? "%.0fk" : "%.1fk", v / 1e3) }
        return String(Int(v))
    }

    /// 时长。「4 天 1 小时」这种读法，最多两级，够用且不啰嗦。
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if Lang.english {
            if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
            if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
            if m > 0 { return "\(m) min" }
            return "\(s) s"
        }
        if d > 0 { return h > 0 ? "\(d) 天 \(h) 小时" : "\(d) 天" }
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        if m > 0 { return "\(m) 分钟" }
        return "\(s) 秒"
    }

    /// 紧凑版「多久前」：53秒前 / 19分前 / 3时前，给一行放不下的地方。
    static func agoShort(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if Lang.english {
            if s < 5 { return "now" }
            if s < 60 { return "\(s)s" }
            if s < 3600 { return "\(s / 60)m" }
            if s < 86400 { return "\(s / 3600)h" }
            return "\(s / 86400)d"
        }
        if s < 5 { return "刚刚" }
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s / 60)分前" }
        if s < 86400 { return "\(s / 3600)时前" }
        return "\(s / 86400)天前"
    }

    /// 「多久前」。数据年龄要让人一眼看出新旧，这是准确性的一部分。
    static func ago(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if Lang.english {
            if s < 5 { return "just now" }
            if s < 60 { return "\(s) s ago" }
            if s < 3600 { return "\(s / 60) min ago" }
            if s < 86400 { return "\(s / 3600) h ago" }
            return "\(s / 86400) d ago"
        }
        if s < 5 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    /// 逐秒倒计时：「3天 19:04:22」。窗口快重置时看着它跳，比「3 小时后」踏实。
    static func tick(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: Lang.english ? "%dd %02d:%02d:%02d" : "%d天 %02d:%02d:%02d", d, h, m, sec) }
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    /// 紧凑时刻，给卡片上的数据行：「8/31 16:10」，当天只留「16:10」。
    static func clockTight(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    /// 「8/26」。柱状图悬停标签用。
    static func monthDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f.string(from: d)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: d)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - 视图工具

/// 悬浮态。`@State` 在本机 SDK 上是宏、而 Command Line Tools 缺
/// SwiftUIMacros 插件，故本地状态一律走 ObservableObject。
final class Flag: ObservableObject {
    @Published var on = false
}

/// 拖动把手。
///
/// 无边框窗口没有标题栏可拖。`isMovableByWindowBackground` 在内容被
/// NSScrollView 接管后经常失灵，故铺一层自己处理 mouseDown 的视图，
/// 交给 `performDrag` —— 这条路不受上层视图层级影响。
/// 它垫在所有内容之下，按钮与悬浮态照常工作。
struct WindowDragHandle: NSViewRepresentable {
    var onRightClick: ((NSEvent) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let v = DragCatcher()
        v.onRightClick = onRightClick
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? DragCatcher)?.onRightClick = onRightClick
    }
}

final class DragCatcher: NSView {
    var onRightClick: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        // 贴边一圈留给系统的缩放手柄（窗口是 resizable 的），
        // 在这儿抢下来会把「拖边缘缩放」变成「移动窗口」。
        if let w = window, w.styleMask.contains(.resizable) {
            let p = convert(event.locationInWindow, from: nil)
            let m: CGFloat = 10
            if p.x < m || p.x > bounds.width - m || p.y < m || p.y > bounds.height - m {
                super.mouseDown(with: event)
                return
            }
        }
        window?.performDrag(with: event)
    }

    /// 在面板上右键直接出菜单——调透明度不必再跑去点菜单栏那枚小图标。
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }
}

/// 毛玻璃底。NSVisualEffectView 的材质比 SwiftUI 的 `.ultraThinMaterial`
/// 更贴菜单栏弹窗的观感，且会跟随桌面壁纸。
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// 界面语言。auto 跟系统首选语言：中文系统显示中文，其余显示英文。
enum Lang {
    private(set) static var english = false
    static func apply(_ setting: String) {
        // 渲染与自检可用环境变量强制语言：MT_LANG=en ./遥测 --render …
        if let env = ProcessInfo.processInfo.environment["MT_LANG"], ["zh", "en"].contains(env) {
            english = env == "en"; return
        }
        switch setting {
        case "zh": english = false
        case "en": english = true
        default: english = !(Locale.preferredLanguages.first ?? "zh").hasPrefix("zh")
        }
    }
}

/// 双语文案：按当前界面语言取中文或英文。语言一变，面板根视图按 language 重建，所有文案随之刷新。
@inline(__always) func L(_ zh: String, _ en: String) -> String { Lang.english ? en : zh }

/// 查表版：中文原文作键，英文在 EnglishStrings.table 里；查不到照原文显示，不会出空。
@inline(__always) func L(_ zh: String) -> String {
    Lang.english ? (EnglishStrings.table[zh] ?? zh) : zh
}
