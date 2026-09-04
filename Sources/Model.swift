import Foundation

/// 取值的来源与分辨率。两者都是上游真值，差别只在小数位，
/// 故不设「推算」一档：拿不到真值时整份快照不存在，而不是猜一个。
enum Precision: String {
    /// `/v1/limits` 的原始额度点，`used` 带小数位。
    case exact
    /// mirachannel relay 帧，与 `/v1/limits` 同源（帧内 `source: relay-limits`），
    /// 但百分比被四舍五入到 0.1%。
    case coarse

    var label: String { self == .exact ? L("精确") : "0.1%" }
}

/// 单个额度窗口。
struct QuotaWindow: Identifiable, Equatable {
    /// 上游窗口名，如 `5h` / `7d` / `7d_fable`。
    let name: String
    /// 已用额度点。仅 `/v1/limits` 可读时有值。
    var usedPoints: Double?
    /// 预算额度点。同上。
    var budgetPoints: Double?
    /// 已用百分比，0–100。两个来源都能给。
    var usedPercent: Double
    /// 窗口重置时刻。
    var resetAt: Date
    /// 是否只统计特定模型档位（实测 `7d_fable`）。
    var modelScoped: Bool
    /// 上游给的状态位：allowed / warning / limit_reached。
    var upstreamStatus: String?
    var precision: Precision

    var id: String { name }

    /// 窗口总时长。用于算匀速线——上游不给窗口起点，由 `重置时刻 − 时长` 反推。
    /// 名字解析不出来时返回 nil，匀速线一并不显示，不硬凑一个数。
    var span: TimeInterval? {
        // 形如 5h / 7d / 7d_fable，取下划线之前的部分
        let head = name.split(separator: "_").first.map(String.init) ?? name
        guard let unit = head.last, let n = Double(head.dropLast()) else { return nil }
        switch unit {
        case "h": return n * 3600
        case "d": return n * 86400
        case "m": return n * 60
        case "w": return n * 604800
        default: return nil
        }
    }

    var windowStart: Date? {
        guard let span else { return nil }
        return resetAt.addingTimeInterval(-span)
    }

    /// 匀速线：窗口已流逝的时间占比（0–100）。
    /// 「按这个速度用满整个窗口」的参照线，用量低于它即为省着用。
    var pacePercent: Double? {
        guard let span, let start = windowStart else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        return min(100, max(0, elapsed / span * 100))
    }

    /// 用量相对匀速线的偏离。正数=超前消耗，负数=落后（省）。
    var paceDelta: Double? {
        guard let pace = pacePercent else { return nil }
        return usedPercent - pace
    }

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    var remainingPoints: Double? {
        guard let used = usedPoints, let budget = budgetPoints else { return nil }
        return max(0, budget - used)
    }

    var isExhausted: Bool { usedPercent >= 100 }

    /// 显示名。上游窗口名不适合直接摆在面板上。
    var displayName: String {
        switch name {
        case "5h": return L("5 小时")
        case "7d": return L("7 天")
        case "7d_fable": return L("7 天 · Fable 5.1")
        default:
            // 未知窗口也要能显示——上游加窗口时自动出现，不用改代码
            let head = name.split(separator: "_").first.map(String.init) ?? name
            let suffix = name.contains("_") ? " · " + name.split(separator: "_").dropFirst().joined(separator: " ") : ""
            guard let unit = head.last, let n = Int(head.dropLast()) else { return name }
            switch unit {
            case "h": return L("\(n) 小时", n == 1 ? "1 hour" : "\(n) hours") + suffix
            case "d": return L("\(n) 天", n == 1 ? "1 day" : "\(n) days") + suffix
            case "m": return L("\(n) 分钟", "\(n) min") + suffix
            case "w": return L("\(n) 周", n == 1 ? "1 week" : "\(n) weeks") + suffix
            default: return name
            }
        }
    }

    /// 模型档位组名，取窗口名下划线之后的部分（`7d_fable` → `fable`）。
    /// 算这类窗口的等价花费时用它过滤账本。
    var modelGroup: String? {
        guard modelScoped else { return nil }
        let parts = name.split(separator: "_")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "_") : nil
    }

    /// 紧迫度：0 充裕 → 1 耗尽。驱动配色。
    var severity: Double { min(1, max(0, usedPercent / 100)) }
}

/// 账号与套餐。取自 relay 帧的 `login` / `referral`。
struct AccountInfo: Equatable {
    var userId: String?
    var name: String?
    var email: String?
    /// 档位，实测取值 plus / max。
    var plan: String?
    /// 套餐到期时刻，帧内 `login.planExp`。
    var planExpiry: Date?
    var paid: Bool?
    /// relay 侧健康位。
    var relayStatus: String?
    var host: String?
}

/// 一次完整的额度快照。整份要么有、要么没有——
/// 半份数据（比如只剩陈旧的窗口值）不构成快照，界面据此显示「未连接」。
struct QuotaSnapshot: Equatable {
    var windows: [QuotaWindow]
    var account: AccountInfo
    /// 数据在上游的采集时刻（relay 帧自带 `capturedAt`），非本机收到的时刻。
    var capturedAt: Date
    /// 本机取得该快照的时刻，用于算「多久前」。
    var receivedAt: Date
    var precision: Precision

    /// 主角窗口：剩余最少的那个。面板与菜单栏都以它为准。
    var headline: QuotaWindow? {
        windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    var age: TimeInterval { Date().timeIntervalSince(receivedAt) }
}

/// 连接状态。刻意把「没连上」与「连上但数据看不懂」分开：
/// 前者等就是了，后者说明上游改了协议，得让人看见。
enum LinkState: Equatable {
    case connecting
    case live(Precision)
    case noMirasim
    /// 连上了 Mirasim，但读不到会话令牌，只能走 0.1% 的帧口径。
    case coarseOnly(String)
    case protocolMismatch(String)

    var isLive: Bool { if case .live = self { return true }; return false }
}

/// 悬浮窗档位。只给一个固定尺寸的话，盯久了嫌占地方，
/// 但缩到只剩一个数字又不够用，故给三档。
enum PanelSize: String, CaseIterable {
    /// 渲染/自检进程用：定死档位，不读也不写偏好（正式实例与渲染进程共用同一份 UserDefaults）。
    static var renderOverride: PanelSize?
    /// 只留主角环与钱：最省地方，适合长期挂在角落。
    case compact
    /// 加上其余窗口和速度。默认。
    case standard
    /// 再加耗尽预演、口径与账号明细。
    case full

    var next: PanelSize {
        switch self {
        case .compact: return .standard
        case .standard: return .full
        case .full: return .compact
        }
    }

    var label: String {
        switch self {
        case .compact: return L("小")
        case .standard: return L("中")
        case .full: return L("大")
        }
    }

    /// 按钮图标表达「点下去会怎样」：前两档会变大，最后一档绕回最小。
    var symbol: String {
        self == .full ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right"
    }
}

/// 悬浮体形态：完整面板，或极小胶囊。
/// 胶囊另有「收进顶边」子状态（tucked），由 AppDelegate 管——它是窗口行为不是数据。
enum FloatMode: String {
    case panel
    case capsule
}

// MARK: - 采样与速率

/// 一次用量采样。落盘后用于算真实消耗速率与耗尽预演。
struct Sample: Codable, Equatable {
    let at: Date
    let window: String
    let percent: Double
    /// 采样时的重置时刻。窗口滚动后旧样本不可续用，靠它识别。
    let resetAt: Date
    /// 采样时登录的账号。多账号切换后，别家账号的样本画进走势线、
    /// 算进速率都是张冠李戴。旧档没有这个字段的样本解码为 nil，
    /// 按「归属不明」处理，一律不用。
    var user: String? = nil
}

/// 消耗速率与耗尽预演。全部由实际采样算出，不含任何标定或折算。
struct Burn: Equatable {
    /// 每小时消耗的百分点。
    let percentPerHour: Double
    /// 预计耗尽时刻。速率非正或窗口先重置时为 nil。
    let exhaustAt: Date?
    /// 参与计算的样本数。
    let samples: Int
    /// 样本覆盖的时间跨度。
    let span: TimeInterval

    /// 跨度太短的速率没有意义，据此决定显不显示。
    var trustworthy: Bool { samples >= 3 && span >= 300 }

    /// 会不会在窗口重置前用完。
    func exhaustsBefore(_ reset: Date) -> Bool {
        guard let e = exhaustAt else { return false }
        return e < reset
    }
}
