import SwiftUI

/// 一个窗口一张卡，极客密度版。
///
/// 结构：标题行（名字 · 走势线 · 大号 5 位百分比）、进度条（带匀速刻度）、
/// 两行等宽数据（钱 · 余量 · 请求数 / 逐秒倒计时 · 消耗速率 · 相对匀速 · 耗尽预告）。
/// 数据行全用等宽字：几十个数字对不齐就是灾难。
struct WindowCard: View {
    let window: QuotaWindow
    let cost: WindowCost?
    let burn: Burn?
    /// 最近两小时的用量走势，画迷你走势线。
    let history: [(Date, Double)]
    let dark: Bool
    /// 精简模式只留标题行与进度条。
    var terse: Bool = false
    /// 提示文字盒（自绘气泡）。nil 时各行说明不出气泡（离屏渲染等）。
    var tips: TipBox? = nil
    /// 静默悬停：穿透模式下鼠标扫过不亮底——纯仪表盘不该一闪一闪（用户点名）。
    var quietHover: Bool = false

    @StateObject private var hover = Flag()

    private var fraction: Double { min(1, max(0, window.usedPercent / 100)) }
    private var accent: Color { Theme.accent(window.severity, dark: dark).0 }
    private var lit: Bool { hover.on && !quietHover }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow
            bar
            if !terse {
                pointsRow
                moneyRow
                if showsEquiv { equivRow }
                timeRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(dark ? (lit ? 0.075 : 0.055)
                                                 : (lit ? 0.06 : 0.042)))
        )
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }

    // MARK: 标题行

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            // （行高在末尾锁 20：走势线/百分比字号不同，别让它随内容起伏）
            Text(window.displayName)
                .font(Theme.label(13, .semibold))
                .fixedSize()

            // 迷你走势线：本机采样的最近两小时。上游不提供历史，
            // 这是应用自己攒的，刚启动时会短，属正常。
            if history.count >= 4 {
                Sparkline(points: history, color: accent)
                    .frame(height: 14)
                    .frame(maxWidth: 72)
                    .hoverTip(tips, "近段用量走势（本机采样 \(history.count) 点，跨度在设置里调）")
            }

            Spacer(minLength: 2)

            // 把语义标死。只给一个裸数字，没人知道它是「已用」还是「剩余」——
            // 用户就是这么被绕进去的。超过 100% 时如实标「超」，
            // 那不是 bug：上游先记账后限流，Mirasim 的中继会兜底放行。
            if window.usedPercent > 100.05 {
                Text(String(format: "超%.1f%%", window.usedPercent - 100))
                    .fixedSize()
                    .font(Theme.mono(10))
                    .foregroundStyle(accent)
            } else {
                Text(String(format: "剩%.1f%%", window.remainingPercent))
                    .fixedSize()
                    .font(Theme.mono(10))
                    .foregroundStyle(.secondary)
            }

            Text(Fmt.percent(window.usedPercent, precision: window.precision))
                .font(Theme.mono(16.5, .bold))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize()
                .hoverTip(tips, "已用占预算的百分比＝上游 used ÷ budget 原始值。可以超过 100%——上游先记账后限流，超出部分由 Mirasim 中继兜底放行。")
        }
        .frame(height: 20)
    }

    // MARK: 进度条

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 轨道用强调色的暗版：整条读起来是一个量的两段，
                // 而不是「一条彩条压在一条灰条上」。
                Capsule()
                    .fill(accent.opacity(dark ? 0.20 : 0.16))

                Capsule()
                    .fill(Theme.accentGradient(window.severity, dark: dark))
                    .frame(width: max(fraction > 0 ? 9 : 0, geo.size.width * fraction))
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)

                // 匀速刻度：按窗口流逝的时间，匀速用该走到这里
                if let pace = window.pacePercent, pace > 0.5, pace < 99.5 {
                    Rectangle()
                        .fill(Color.white.opacity(dark ? 0.75 : 0.9))
                        .frame(width: 2, height: 11)
                        .offset(x: min(geo.size.width - 2, geo.size.width * pace / 100))
                        .animation(.easeInOut(duration: 0.4), value: pace)
                }
            }
        }
        .frame(height: 11)
    }

    // MARK: 数据行零：点数

    /// 官方额度的真身。美元都是由它折算的，把原始值摆出来——
    /// 与下一行的钱**同位对应**：已用点↔已花、预算点↔整窗、余点↔余钱，
    /// 上下两行一眼读出「多少点＝多少刀」（用户点名要总量对应，不要每点单价）。
    /// 行高一律锁死（下同）：这些行开着 minimumScaleFactor，数字一变宽就整行缩字，
    /// 缩了字行就矮两三点，面板高度随之跳——窗口看起来「自己抽搐」（用户抓的）。
    /// 精确口径一时读不到时也保留占位，不让整行消失把面板抽矮 54pt。
    private var pointsRow: some View {
        HStack(spacing: 0) {
            if let used = window.usedPoints, let budget = window.budgetPoints {
                Text(Fmt.points(used))
                    .foregroundStyle(.secondary)
                Text(" / \(Fmt.points(budget))")
                    .foregroundStyle(.tertiary)
                Text("  余\(Fmt.points(max(0, budget - used)))")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("点")
                    .foregroundStyle(.tertiary)
            } else {
                Text("点数待精确口径")
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 4)
            }
        }
        .font(Theme.mono(10.5))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .frame(height: 14)
        .hoverTip(tips, "已用点 / 预算点 · 剩余点＝上游 /v1/limits 的原始额度点，官方额度的真身。与下一行逐位对应：这些点折成美刀就是下面的 已花 / 整窗 / 余——点数预算固定不变，折出的美元随用法呼吸。")
    }

    // MARK: 数据行一：钱

    private var moneyRow: some View {
        HStack(spacing: 0) {
            if let c = cost, c.spentUSD > 0 || c.fullUSD != nil {
                Text(Fmt.usd(c.spentUSD))
                    .foregroundStyle(.secondary)
                if let f = c.fullUSD {
                    Text(" / \(Fmt.usd(f))")
                        .foregroundStyle(.tertiary)
                    Text("  余\(Fmt.usd(max(0, f - c.spentUSD)))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if c.requests > 0 {
                    Text("\(c.requests) 次")
                        .foregroundStyle(.tertiary)
                }
            } else if let c = cost, c.spentUSD > 0 {
                // 单价标定还没收敛：已花是真账照给，整窗值宁缺勿假
                Text(Fmt.usd(c.spentUSD)).foregroundStyle(.secondary)
                Text("  额度标定中").foregroundStyle(.quaternary)
                Spacer(minLength: 4)
                if c.requests > 0 { Text("\(c.requests) 次").foregroundStyle(.tertiary) }
            } else {
                // 没有活跃会话时读不到点数，钱算不出——如实说，不留空行
                Text("金额待精确口径")
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 4)
            }
        }
        .font(Theme.mono(10.5))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .frame(height: 14)
        .hoverTip(tips, "已花 / 整窗约值 · 剩余可用 · 窗口内调用数。花费＝当前账号经中转的逐调用计量 × 本地价目表（与 Mirasim 流量监控页同源同价，断流重试也计）。整窗值＝本窗实花 ÷ 已用百分比逆推——已花、整窗、余量与卡上的百分比永远互相咬合。用法一变（模型混比、缓存读占比）单价就漂，整窗值跟着呼吸：它回答「照这个窗口里的用法，整窗能干多少活」。窗口早于本机计量起点、或已用还不足 12,000 点时，退按 7 天窗口均价 × 预算点折算。本机只见本机的调用——这个号若在别的电脑也在用，那边的花费不在账上，已花与整窗为下界。")
    }

    // MARK: 数据行一点五：整窗额度的等价美元

    /// 只在 7 天系窗口给（用户点名 7 天；5 小时同一单位，要看再开）。
    private var showsEquiv: Bool {
        window.name.hasPrefix("7d") && window.budgetPoints != nil
            && (cost?.fullRegularUSD != nil || cost?.fullFableUSD != nil)
    }

    /// 用户 09-02：「额度还是有点不清楚，在 7 天加一行小字：相当于普通模型多少刀、
    /// 相当于 Fable 5.1 多少刀」。整窗值随混比呼吸，这两个是固定参照。
    private var equivRow: some View {
        HStack(spacing: 0) {
            if let b = window.budgetPoints {
                Text("\(Fmt.points(b)) 点 ≈ ").foregroundStyle(.quaternary)
            }
            if let r = cost?.fullRegularUSD {
                Text("普通模型 ").foregroundStyle(.tertiary)
                Text(Fmt.usdPlain(r)).foregroundStyle(.secondary)
                if cost?.fullFableUSD != nil { Text(" / ").foregroundStyle(.quaternary) }
            }
            if let f = cost?.fullFableUSD {
                Text("Fable 5.1 ").foregroundStyle(.tertiary)
                Text(Fmt.usdPlain(f)).foregroundStyle(.secondary)
                // 用户 09-02：「5.1 不是便宜了吗，为什么还和 5 一样只能用一千来刀」——
                // 同样的点、同样的活，按 Fable 5 标价是多少并排给出，一眼看出差的只是标价
                if let f5 = cost?.fullFableAtF5USD {
                    Text("（按 Fable 5 价 \(Fmt.usdPlain(f5))）").foregroundStyle(.quaternary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.mono(9.5))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 14)
        .hoverTip(tips, equivTip)
    }

    private var equivTip: String {
        var s = "整窗额度换成钱的两个固定参照：全花在普通模型（Opus/Sonnet 等非 Fable）上值多少，全花在 Fable 5.1 上值多少。"
        if let b = window.budgetPoints, b > 0 {
            var parts: [String] = []
            if let r = cost?.fullRegularUSD { parts.append(String(format: "普通模型每点 ≈ $%.4f", r / b)) }
            if let f = cost?.fullFableUSD { parts.append(String(format: "Fable 5.1 每点 ≈ $%.4f", f / b)) }
            if !parts.isEmpty { s += "本窗口实测：" + parts.joined(separator: "，") + "。" }
        }
        s += "点的扣法（09-02 实测）：普通模型每 $1 标价扣 100 点；Fable 每 $1 Fable 5 标价扣 200 点，5.1 也按 5 的价目扣，不因标价便宜而少扣。所以 5.1 的美元数比 5 小，是同样的活按 5.1 标价更便宜，不是额度变少——同样的点在 5.1 上能跑的 token 与 5 一样多。Fable 调用同时扣 7 天窗与 Fable 窗，普通模型只扣 7 天窗，据此拆开各配各的钱；历史 Fable 5 调用已按 5.1 价目重算（以后只用 5.1）。"
        return s
    }

    // MARK: 数据行二：时间

    /// 逐秒跳的倒计时。TimelineView 只重画这一行，不惊动整张卡。
    private var timeRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 0) {
                // 用符号图不用「↻」字符——等宽字体没这个字形，回退渲染会歪
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(" ")
                Text(Fmt.tick(window.resetAt.timeIntervalSince(ctx.date)))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))

                if let b = burn, b.trustworthy, b.percentPerHour > 0.005 {
                    Text("  \(String(format: "%.2f%%/h", b.percentPerHour))")
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                if let delta = window.paceDelta {
                    // 用词避开「落后」这种要在心里绕一圈的说法：比匀速慢就是「省」
                    Text(String(format: "匀速%@%.0f%%", delta <= 0 ? "省" : "快", abs(delta)))
                        .foregroundStyle(delta <= 0 ? Color.secondary
                                                    : Theme.accent(min(1, 0.62 + abs(delta) / 120), dark: dark).0)
                }

                if let b = burn, let eta = b.exhaustAt, eta < window.resetAt, !window.isExhausted {
                    Text("  \(Fmt.clockTight(eta))尽")
                        .foregroundStyle(Theme.accent(0.95, dark: dark).0)
                }
            }
            .font(Theme.mono(10.5))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(height: 14)
        }
        .hoverTip(tips, "重置倒计时 · 每小时消耗（近 6 小时实测斜率）· 相对匀速线 · 耗尽预告（速率不可信时不给）")
    }
}

// MARK: - 周月累计卡

/// 周 / 月累计。
///
/// 上游只有 5h / 7d / 7d·Fable 三个额度窗口，没有周月——旧控件那个
/// 「30 天窗口」的分母是它自己编的。这里不编：只给本机账本的真实累计
/// （按官方价目表折算的 API 等价额），月底一栏按近 7 个完整日的日均外推。
struct LedgerCard: View {
    let week: WindowCost?
    let month: WindowCost?
    /// 周的等效总额度＝7 天滚动窗口的整窗估值（时长相同，量纲一致）。
    /// 官方没有固定的周/月总额——窗口是滚动的、额度是动态的，这是折算，带 ≈。
    var weekBudget: Double? = nil
    /// 月的等效总额度＝周额度 ÷ 7 × 当月天数。
    var monthBudget: Double? = nil
    /// 近 14 天逐日花费，柱状。
    let daily: [(day: Date, usd: Double, count: Int)]
    let dark: Bool
    var terse: Bool = false
    var tips: TipBox? = nil
    /// 静默悬停：穿透模式下不亮底。
    var quietHover: Bool = false

    @StateObject private var hover = Flag()
    /// 鼠标正指着第几根柱。指着时右侧大数字换成那一天的明细。
    @StateObject private var barHover = IdxBox()

    private var neutral: Color { dark ? Color(red: 0.62, green: 0.74, blue: 1.0)
                                      : Color(red: 0.28, green: 0.42, blue: 0.85) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text("累计")
                    .font(Theme.label(13, .semibold))
                    .fixedSize()
                // 用户看着「周 5,628 次」问「这个就显示当前账号的就行了吧」——数据一直是
                // 只算当前账号的，但卡上只写了「仅经 Mirasim」，看不出账号范围。把范围写明。
                Text("本账号 · 经 Mirasim")
                    .font(Theme.mono(9))
                    .foregroundStyle(.quaternary)
                    .fixedSize()
                    .hoverTip(tips, "只算当前登录账号（顶栏那个名字）经 Mirasim 中转的调用；切换账号后这里自动跟随，别的账号的流水不混进来；其他电脑、直连 API 的用量不在内。")

                if daily.count >= 3 {
                    SparkBars(values: daily.map(\.usd), color: neutral,
                              highlight: quietHover ? nil : barHover.idx,
                              onHover: quietHover ? nil : { barHover.idx = $0 })
                        .frame(height: 15)
                        .frame(maxWidth: 104)
                        .hoverTip(tips, "近 \(daily.count) 天逐日花费，指到柱上看单日明细")
                }

                Spacer(minLength: 2)

                // 平时显示本月总额；鼠标指着某根柱时，就地换成那一天的明细——
                // 悬停信息不另开浮层，图小，浮层盖住图反而看不见指的是哪根。
                if let i = barHover.idx, i < daily.count {
                    let d = daily[i]
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(Fmt.monthDay(d.day)) · \(d.count)次")
                            .font(Theme.mono(8.5))
                            .foregroundStyle(.tertiary)
                        Text(Fmt.usd(d.usd))
                            .font(Theme.mono(14, .bold))
                            .foregroundStyle(neutral)
                    }
                    .fixedSize()
                } else if let m = month {
                    Text("本月")
                        .font(Theme.mono(10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(Fmt.usd(m.spentUSD))
                        .font(Theme.mono(16.5, .bold))
                        .foregroundStyle(neutral)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: 26)

            if !terse {
                HStack(spacing: 0) {
                    Text("周 ").foregroundStyle(.tertiary)
                    Text(Fmt.usd(week?.spentUSD ?? 0)).foregroundStyle(.secondary)
                    if let b = weekBudget {
                        Text(" / 额度\(Fmt.usd(b))").foregroundStyle(.tertiary)
                    }
                    Text(" · \(week?.requests ?? 0)次").foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if let w = week, let avg = dayAverage(of: w, since: .week) {
                        Text("日均\(Fmt.usd(avg))").foregroundStyle(.tertiary)
                    }
                }
                .font(Theme.mono(10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(height: 14)

                HStack(spacing: 0) {
                    Text("月 ").foregroundStyle(.tertiary)
                    Text(Fmt.usd(month?.spentUSD ?? 0)).foregroundStyle(.secondary)
                    if let b = monthBudget {
                        Text(" / 额度\(Fmt.usd(b))").foregroundStyle(.tertiary)
                    }
                    Text(" · \(month?.requests ?? 0)次").foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if let proj = monthProjection() {
                        Text("月底≈\(Fmt.usdPlain(proj))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(Theme.mono(10.5))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(height: 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(dark ? (hover.on && !quietHover ? 0.075 : 0.055)
                                                 : (hover.on && !quietHover ? 0.06 : 0.042)))
        )
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .hoverTip(tips, "花费只统计当前账号经中转的调用，金额＝Mirasim 逐调用计量 × 本地价目表（与流量监控页同口径），非实付；周＝周一起，月＝1 号起。「额度」是等效折算：官方只有滚动窗口、没有固定周/月总额——周额度＝7 天窗口整窗估值，月额度＝它 ÷7 × 当月天数，都带 ≈。")
    }

    private enum Span { case week }

    /// 周的日均：按已流逝的天数（当天算一天）。
    private func dayAverage(of c: WindowCost, since span: Span) -> Double? {
        guard c.spentUSD > 0 else { return nil }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = Calendar.current.timeZone
        guard let start = iso.dateInterval(of: .weekOfYear, for: Date())?.start else { return nil }
        let days = max(1.0, ceil(Date().timeIntervalSince(start) / 86400))
        return c.spentUSD / days
    }

    /// 月底外推＝本月已花 + 近 7 个完整日的日均 × 剩余天数。
    /// 完整日不含今天——今天还没过完，计入会把日均压低。
    private func monthProjection() -> Double? {
        guard let m = month, m.spentUSD > 0, daily.count >= 3 else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let full = daily.filter { $0.day < today }.suffix(7)
        guard !full.isEmpty,
              let interval = cal.dateInterval(of: .month, for: Date()) else { return nil }
        let avg = full.map(\.usd).reduce(0, +) / Double(full.count)
        let remainingDays = max(0, interval.end.timeIntervalSince(Date()) / 86400)
        return m.spentUSD + avg * remainingDays
    }
}

/// 悬停索引盒。`@State` 在本机 SDK 上是宏用不了，本地状态走 ObservableObject。
final class IdxBox: ObservableObject {
    @Published var idx: Int?
}

/// 迷你柱状，可悬停。指着哪根，哪根全亮、其余压暗，并把序号报给外面。
struct SparkBars: View {
    let values: [Double]
    let color: Color
    var highlight: Int? = nil
    var onHover: ((Int?) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let n = values.count
            let top = max(values.max() ?? 1, 0.0001)
            let gap: CGFloat = 1.5
            let bw = max(1.5, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.8)
                        .fill(color.opacity(opacity(of: i, total: n)))
                        .frame(width: bw, height: max(1.5, geo.size.height * values[i] / top))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            // 命中按整个图的横坐标算，不要求正好指在柱身上——
            // 柱子只有几像素宽，矮柱几乎点不中，按列命中才用得起来
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    let i = Int(pt.x / (bw + gap))
                    onHover?(min(max(0, i), n - 1))
                case .ended:
                    onHover?(nil)
                }
            }
        }
    }

    private func opacity(of i: Int, total n: Int) -> Double {
        if let h = highlight { return i == h ? 1.0 : 0.30 }
        return i == n - 1 ? 0.95 : 0.55
    }
}

// MARK: - 迷你走势线

struct Sparkline: View {
    let points: [(Date, Double)]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                guard points.count >= 2 else { return }
                let t0 = points.first!.0.timeIntervalSince1970
                let t1 = points.last!.0.timeIntervalSince1970
                let dt = max(1, t1 - t0)
                let vals = points.map(\.1)
                let lo = vals.min()!, hi = vals.max()!
                let span = hi - lo
                for (i, pt) in points.enumerated() {
                    let x = (pt.0.timeIntervalSince1970 - t0) / dt * w
                    // 走势平到没变化时画中线，而不是贴着底边
                    let y = span < 1e-9 ? h / 2
                        : h - CGFloat((pt.1 - lo) / span) * (h - 2) - 1
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(0.8),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
