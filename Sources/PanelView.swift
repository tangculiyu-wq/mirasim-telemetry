import SwiftUI

/// 按钮气泡的文字源。系统 tooltip 在无边框浮窗上时灵时不灵、还要等一秒多，
/// 改成悬停即弹的自绘气泡。
final class TipBox: ObservableObject {
    @Published var text: String?
}

// 气泡的呈现不在面板视图里做。面板窗口只有 344pt 宽，气泡关在里面
// 要么盖内容、要么贴边挪窝，两轮返工都被用户叫「错位」——正解是
// AppDelegate 里的独立提示小窗：贴鼠标弹、可伸出面板边界，行为同系统 tooltip。

/// 悬浮面板「Mirasim 遥测」。
/// 三张等大窗口卡 + 周月累计卡 + 遥测行，每张卡塞满数据：
/// 5 位百分比、走势线、钱、逐秒倒计时、消耗速率、匀速对比、耗尽预告。

struct PanelView: View {
    @ObservedObject var store: Store
    /// 提示文字盒。正式运行由 AppDelegate 注入（它用独立小窗呈现）；
    /// 离屏渲染等场合用默认实例，写了也没人显示，无害。
    @ObservedObject var tip: TipBox = TipBox()
    @Environment(\.colorScheme) private var scheme

    var onRefresh: () -> Void
    var onClose: () -> Void
    var onToggleTop: () -> Void
    var onToggleOnlyInApp: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onRightClick: ((NSEvent) -> Void)? = nil
    var onResetPosition: () -> Void = {}
    var onQuit: () -> Void = {}
    private var dark: Bool { scheme == .dark }

    // 内容始终按逻辑宽 344 排版。缩放由 AppDelegate.ScaledPanelRoot 在外层
    // 用 scaleEffect 做——必须在 SwiftUI 内部缩放，命中区才跟着变换；
    // 曾走 NSScrollView.magnification，像素缩了、命中区没缩，「指这颗亮那颗」。
    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                // 浅色下 popover 材质偏灰，垫一层白提通透度；深色不需要
                Color.white.opacity(dark ? 0 : 0.34)
                // 空白处按下即可拖窗；按钮在它上层，不受影响
                WindowDragHandle(onRightClick: onRightClick)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        // 半透明时把指针移上去会变清晰，交给窗口层做真正的透明度
        .onHover { onHover($0) }
        .overlay(
            // 一道极淡的内描边，把毛玻璃从桌面上「切」出来。
            // 只此一处描边，别处一律实心面 + 投影。
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(.white.opacity(dark ? 0.08 : 0.5), lineWidth: 0.5)
        )
    }

    // MARK: 标题

    private var header: some View {
        VStack(spacing: 8) {
        HStack(spacing: 8) {
            Text("Mirasim 遥测")
                .font(Theme.label(15, .semibold))
                .hoverTip(tip, "按住空白处拖动移窗；拖边缘/角落缩放。位置和大小都会记住")

            Spacer(minLength: 4)

            // 钉住＝始终盖在其他窗口上面。这是悬浮窗最要紧的开关，放第一个。
            // 只在 Mirasim 前台时显示。开着时切去别的应用，面板/胶囊自动藏起。
            IconButton(symbol: "macwindow",
                       help: store.onlyInMirasim ? "只在 Mirasim 里显示：开（切走会藏起）"
                                                 : "只在 Mirasim 里显示：关（点击开启）",
                       tinted: store.onlyInMirasim,
                       tips: tip,
                       action: onToggleOnlyInApp)
            // 用户拍板：钉在最前没意义（默认常开、设置里还有），这个位置给穿透。
            IconButton(symbol: store.clickThrough ? "cursorarrow.slash" : "cursorarrow",
                       help: store.clickThrough
                           ? "鼠标穿透：开——点击直接落到面板后面。想操作面板：鼠标停在上面 1 秒自动解锁，移开恢复穿透；解锁时点这里彻底关。"
                           : "鼠标穿透：关（点击开启）——开后点击穿过面板直达后面的东西",
                       tinted: store.clickThrough,
                       tips: tip) {
                store.clickThrough.toggle()
            }
            IconButton(symbol: "arrow.clockwise", help: "立即刷新", tips: tip, action: onRefresh)
            IconButton(symbol: store.size.symbol,
                       help: "大小：\(store.size.label)（点击切换 小/中/大）",
                       tips: tip) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    store.size = store.size.next
                }
            }
            IconButton(symbol: "xmark", help: "收成胶囊，存进屏幕顶边", tips: tip, action: onClose)
            IconButton(symbol: store.settingsOpen ? "gearshape.fill" : "gearshape",
                       help: store.settingsOpen ? "关闭设置，回到额度"
                                                : "设置：透明度、缩放、额度警报、外观、开机自启……操作说明也在里面",
                       tinted: store.settingsOpen,
                       tips: tip) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    store.settingsOpen.toggle()
                }
            }
        }

        if store.snapshot?.account.plan != nil || store.snapshot?.account.planExpiry != nil {
            HStack(spacing: 8) {
                if let plan = store.snapshot?.account.plan { PlanBadge(plan: plan) }
                // 当前登录的账号。有好几个号的人切来切去，
                // 不写明是谁的额度，看仪表就是猜谜。
                if let who = store.snapshot?.account.name ?? store.snapshot?.account.email {
                    Text(who)
                        .font(Theme.label(11.5, .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .hoverTip(store.clickThrough ? nil : tip,
                                  "当前 Mirasim 登录账号——面板上所有数字都只属于它，切号自动跟随")
                }
                Spacer(minLength: 4)
                if let exp = store.snapshot?.account.planExpiry {
                    Text("套餐到期 \(Fmt.day(exp))")
                        .font(Theme.label(11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if store.settingsOpen {
            // 设置页比额度页高，套内部滚动、封顶 620——不然小屏或放大档
            // 直接顶破屏幕高度上限，页脚被裁掉。SwiftUI 自己的 ScrollView，
            // 命中区跟缩放同一套变换，没有 NSScrollView 那个坑。
            ScrollView(showsIndicators: false) {
                SettingsView(store: store, dark: dark, tips: tip,
                             onResetPosition: onResetPosition, onQuit: onQuit)
            }
            .frame(height: 620)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let snap = store.snapshot, !snap.windows.isEmpty {
            VStack(spacing: 0) {
                // 按窗口时长升序，短的在上。顺序固定，不随用量变化跳来跳去。
                let cards = snap.windows.sorted {
                    ($0.span ?? .greatestFiniteMagnitude, $0.name)
                        < ($1.span ?? .greatestFiniteMagnitude, $1.name)
                }
                VStack(spacing: 8) {
                    // 穿透模式＝纯仪表盘：卡片不亮底、行说明不弹泡（tips 传 nil）
                    ForEach(cards) { w in
                        WindowCard(window: w,
                                   cost: store.costs[w.name],
                                   burn: store.burns[w.name],
                                   history: store.history(for: w.name, back: store.trendBack),
                                   dark: dark,
                                   terse: store.size == .compact,
                                   tips: store.clickThrough ? nil : tip,
                                   quietHover: store.clickThrough)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                // 周月累计。上游没有这两个窗口，这张卡是本机账本的真实累计。
                if store.monthCost != nil || store.weekCost != nil {
                    // 周/月的等效总额度由 7 天窗口折算(官方额度是滚动动态的,没有固定周月总额)
                    let weekBudget = store.costs["7d"]?.fullUSD
                    let daysInMonth = Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30
                    LedgerCard(week: store.weekCost, month: store.monthCost,
                               weekBudget: weekBudget,
                               monthBudget: weekBudget.map { $0 / 7 * Double(daysInMonth) },
                               daily: store.dailySpend, dark: dark,
                               terse: store.size == .compact,
                               tips: store.clickThrough ? nil : tip,
                               quietHover: store.clickThrough)
                        .padding(.horizontal, 14)
                        .padding(.bottom, store.size == .compact ? 12 : 9)
                }

                if store.size != .compact, !store.speeds.isEmpty || store.todayCost != nil {
                    // 速度与今日花费一条遥测行，摆在主面板上——
                    // 这是每天都要瞄一眼的数，藏进明细里等于没有。
                    TelemetryBar(speeds: store.speeds, today: store.todayCost, dark: dark,
                                 tips: store.clickThrough ? nil : tip)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }

                if store.size == .full {
                    DetailSection(store: store, snapshot: snap, dark: dark)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else {
            EmptyState(link: store.link)
                .padding(.horizontal, 16)
                .padding(.vertical, 30)
        }
    }

    // MARK: 状态栏

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                SourceDot(link: store.link, fresh: store.isFresh)

                if let snap = store.snapshot {
                    // 口径与年龄并排。年龄是准确性的一部分：
                    // 同一个数字，3 秒前和 20 分钟前的可信度完全不同。
                    Text(snap.precision == .exact ? "精确" : "0.1% 口径")
                        .font(Theme.label(11, .semibold))
                    Text("·").font(Theme.label(11)).foregroundStyle(.tertiary)
                    Text(Fmt.ago(snap.age))
                        .font(Theme.label(11))
                        .foregroundStyle(store.isFresh ? .secondary : .primary)
                } else {
                    Text(statusText).font(Theme.label(11)).foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if store.clickThrough {
                    // 穿透状态要看得见：不然点面板没反应像死机
                    Text(store.pierceUnlocked ? "可操作 · 移开恢复穿透" : "穿透中 · 停留 1 秒可操作")
                        .font(Theme.label(10.5, .semibold))
                        .foregroundStyle(store.pierceUnlocked ? .secondary : .tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }

    private var statusText: String {
        switch store.link {
        case .connecting: return "正在连接 Mirasim"
        case .noMirasim: return "Mirasim 未运行"
        case .coarseOnly(let s): return s
        case .protocolMismatch(let s): return s
        case .live: return ""
        }
    }
}

/// 遥测行：模型吐字速度 + 今日花费。
/// 这两样是每天都要瞄一眼的数，把速度压在一张要切换才看得到的卡片里，等于没有。
struct TelemetryBar: View {
    let speeds: [Speed]
    let today: WindowCost?
    let dark: Bool
    var tips: TipBox? = nil

    /// 最后一次请求距今超过这个岁数，该行就不再装作「此刻」——
    /// 调暗、闪电熄灰、明写多久前。陈旧不是罪，把陈旧说成当下才是。
    private func staleAge(_ sp: Speed, now: Date) -> TimeInterval? {
        let age = now.timeIntervalSince(sp.lastAt)
        return age > 90 ? age : nil
    }

    var body: some View {
        // 逐秒重画：「x 分钟前」和变暗判定要跟着真实时间走，不能等下一次数据刷新
        // 才更新（用户：这些东西应该实时刷新）。数据本身由 Store 在流水文件一变就刷。
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                if speeds.isEmpty {
                    row(nil, showToday: true, now: ctx.date)
                } else {
                    // 逐模型各一行（用户点名多模型要全列）；最多四行防爆版面。
                    // 「今日」单独一行右对齐——挤在模型行里会把模型名压成零宽。
                    ForEach(speeds.prefix(4), id: \.id) { sp in
                        row(sp, showToday: false, now: ctx.date)
                    }
                    if let t = today, t.spentUSD > 0 {
                        HStack(spacing: 0) {
                            Spacer(minLength: 4)
                            Text("今日 ").foregroundStyle(.tertiary)
                            Text(Fmt.usd(t.spentUSD)).foregroundStyle(.primary.opacity(0.85))
                            Text("/\(t.requests)次").foregroundStyle(.tertiary)
                        }
                        .font(Theme.mono(10.5))
                        .lineLimit(1)
                        .frame(height: 14)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(dark ? 0.055 : 0.042))
        )
        .hoverTip(tips, """
        每个近期在跑的模型一行：吐字速度 · 每轮耗时 · 首字。全为本机实测中位数（耗时取 Mirasim 流水，token 与首字按请求号跟 Claude Code 账本精确配对）。
        首字≈＝请求发出到第一个内容块落盘，是真实首字延迟的上界。
        「后台」＝Mirasim 自动化（如 GUI 代理）自己调的模型，不是你的对话——计费照算，但别跟你聊的模型混为一谈。
        行变暗带「x 前」＝该模型 90 秒内没有新请求，显示的是上一波实测。
        今日＝本地零点起当前账号经 Mirasim 的估算花费。
        """)
    }

    @ViewBuilder
    private func row(_ sp: Speed?, showToday: Bool, now: Date) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) {
                let dim = sp.map { staleAge($0, now: now) != nil || $0.background } ?? true
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(dim ? Color.primary.opacity(0.25)
                                         : Theme.accent(0.2, dark: dark).0)
                if let sp {
                    Text(sp.model)
                        .font(Theme.label(11, .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // 最少留一个词的宽度：曾被右侧定宽的数字挤到只剩半个「O」，
                        // 渲染里 Opus 5 显示成一个「(」
                        .frame(minWidth: 44, alignment: .leading)
                    if sp.background {
                        Text("后台")
                            .font(Theme.mono(8.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .fixedSize()
                    }
                    HStack(spacing: 0) {
                        if let t = sp.tokensPerSecond {
                            Text(String(format: "%.0f", t)).foregroundStyle(.primary.opacity(0.85))
                            Text("tok/s · ").foregroundStyle(.tertiary)
                        }
                        Text(String(format: "%.1fs", sp.medianSeconds)).foregroundStyle(.primary.opacity(0.85))
                        Text("/轮").foregroundStyle(.tertiary)
                        // 首字与「多久前」二选一：一行放不下两样时模型名会被挤没。
                        // 行已过期时，多久前比一个旧的首字更要紧。
                        let age = staleAge(sp, now: now)
                        if let f = sp.firstSeconds, age == nil {
                            Text(" · 首字").foregroundStyle(.tertiary)
                            Text(String(format: "%.1fs", f)).foregroundStyle(.primary.opacity(0.85))
                        }
                        if let age {
                            Text(" · \(Fmt.ago(age))").foregroundStyle(.tertiary)
                        }
                    }
                    .font(Theme.mono(10.5))
                    // 数字优先：地方不够时截模型名，绝不把单位挤成省略号
                    .fixedSize()
                    .layoutPriority(1)
                }
            }
            .opacity(sp.map { staleAge($0, now: now) != nil ? 0.55 : ($0.background ? 0.7 : 1) } ?? 0.55)

            Spacer(minLength: 4)

            if showToday, let t = today, t.spentUSD > 0 {
                HStack(spacing: 0) {
                    Text("今日 ").foregroundStyle(.tertiary)
                    Text(Fmt.usd(t.spentUSD)).foregroundStyle(.primary.opacity(0.85))
                    Text("/\(t.requests)次").foregroundStyle(.tertiary)
                }
                .font(Theme.mono(10.5))
                .fixedSize()
                .layoutPriority(2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 14)   // 锁高：缩字不能改行高，否则面板随刷新上下抽动
    }
}

/// 提示气泡。系统 tooltip 在无边框浮窗上时灵时不灵还要干等，
/// 这里样式自绘，由 AppDelegate 的独立小窗承载。
/// 小箭头咬住鼠标横坐标，气泡翻到鼠标上方时箭头跟着翻到底边。
struct TipBubble: View {
    let text: String
    let dark: Bool
    /// 箭头的横坐标（气泡自身坐标系）。nil = 不画箭头。
    var caretX: CGFloat? = nil
    /// 箭头在顶边（气泡在鼠标下方）还是底边（气泡翻到了鼠标上方）。
    var caretOnTop: Bool = true

    private var ink: Color { dark ? Color(white: 0.92) : Color(white: 0.12) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cx = caretX, caretOnTop {
                TipCaret().fill(ink)
                    .frame(width: 12, height: 6)
                    .padding(.leading, max(8, cx - 6))
            }
            Text(text)
                .font(Theme.label(11.5, .medium))
                .foregroundStyle(dark ? Color.black.opacity(0.9) : .white)
                .lineSpacing(2)
                // 多行说明别掐成一行；定宽由外层管——写在背景里面会把
                // 短文案撑成整条横带，返工过
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ink)
                )
            if let cx = caretX, !caretOnTop {
                TipCaret().fill(ink)
                    .frame(width: 12, height: 6)
                    .rotationEffect(.degrees(180))
                    .padding(.leading, max(8, cx - 6))
            }
        }
        // 箭头与主体先合成一体再投影，否则接缝处两层阴影叠出一道黑线
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

/// 气泡上的小箭头（等腰三角，尖朝上）。
struct TipCaret: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 悬停延时提示：把整张面板上原本挂系统 tooltip 的长说明统一进自绘气泡。
/// 系统 tooltip 在无边框浮窗上时灵时不灵，且样式与按钮气泡两张皮。
/// 行类目标给 0.65s 的悬停确认（扫过不弹，停住才弹），按钮仍是即时。
struct HoverTip: ViewModifier {
    let tips: TipBox?
    let text: String
    var delay: Double = 0.65

    @StateObject private var pending = WorkBox()

    func body(content: Content) -> some View {
        content.onHover { on in
            guard let tips, !text.isEmpty else { return }
            pending.item?.cancel()
            if on {
                let it = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.12)) { tips.text = text }
                }
                pending.item = it
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: it)
            } else if tips.text == text {
                withAnimation(.easeOut(duration: 0.12)) { tips.text = nil }
            }
        }
    }
}

/// 延时任务盒。`@State` 在本机 SDK 上用不了（CLT 缺宏），走 ObservableObject。
final class WorkBox: ObservableObject {
    var item: DispatchWorkItem?
}

extension View {
    /// 悬停一会儿后在自绘气泡里显示说明。tips 为 nil（离屏渲染等）时不动作。
    func hoverTip(_ tips: TipBox?, _ text: String, delay: Double = 0.65) -> some View {
        modifier(HoverTip(tips: tips, text: text, delay: delay))
    }
}

// MARK: - 徽章与按钮

struct PlanBadge: View {
    let plan: String
    var body: some View {
        Text(plan.uppercased())
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.68, blue: 0.16),
                                            Color(red: 0.98, green: 0.51, blue: 0.09)],
                                   startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: .orange.opacity(0.35), radius: 3, y: 1)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tinted: Bool = false
    /// 传入标题栏的提示盒后，悬停立即在标题位置显示说明——
    /// 系统 tooltip 保留作双保险，但不再指望它。
    var tips: TipBox? = nil
    let action: () -> Void
    @StateObject private var hover = Flag()

    /// 高亮判据。有提示盒时以「当前气泡就是我的」为准——悬停离开事件在
    /// 缩放视图里会丢，本地 hover 态可能卡在 true；提示盒由看门狗兜底清零，
    /// 跟它走，气泡灭高亮圈同拍灭。没有提示盒的场合退回本地悬停态。
    private var lit: Bool {
        if let tips { return tips.text == help }
        return hover.on
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tinted ? Color.accentColor
                                        : (lit ? Color.primary : Color.secondary))
                .frame(width: 23, height: 23)
                .background(
                    Circle().fill(Color.primary.opacity(lit ? 0.10 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { on in
            hover.on = on
            guard let tips else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                if on {
                    tips.text = help
                } else if tips.text == help {
                    // 只清掉自己的提示，别把邻座刚写上的擦了
                    tips.text = nil
                }
            }
        }
        // 有自绘气泡时不再挂系统 tooltip：两套会先后各弹一个，两张皮
        .help(tips == nil ? help : "")
    }
}

/// 数据源指示点。绿=精确、黄=帧口径、灰=没有数据。
struct SourceDot: View {
    let link: LinkState
    let fresh: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.7), radius: 3)
    }

    private var color: Color {
        switch link {
        case .live(let p):
            if !fresh { return .gray }
            return p == .exact ? Color(red: 0.19, green: 0.84, blue: 0.29)
                               : Color(red: 1.0, green: 0.72, blue: 0.11)
        case .connecting: return .gray
        case .noMirasim, .coarseOnly: return .gray
        case .protocolMismatch: return Color(red: 1.0, green: 0.31, blue: 0.26)
        }
    }
}

// MARK: - 空态

/// 没有数据时的样子。
///
/// 这里刻意不显示任何数字。有的做法是读不到时拿旧锚点推算一个当前值，
/// 界面上和真值长得一模一样——那是「不准」的根源。读不到就说读不到。
struct EmptyState: View {
    let link: LinkState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.label(13, .semibold))
            Text(hint)
                .font(Theme.label(11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var icon: String {
        switch link {
        case .protocolMismatch: return "exclamationmark.triangle"
        case .connecting: return "antenna.radiowaves.left.and.right"
        default: return "moon.zzz"
        }
    }

    private var title: String {
        switch link {
        case .connecting: return "正在连接"
        case .noMirasim: return "Mirasim 未运行"
        case .protocolMismatch: return "读不懂额度帧"
        default: return "暂时读不到额度"
        }
    }

    private var hint: String {
        switch link {
        case .connecting: return "正在读取 Mirasim 的额度通道"
        case .noMirasim: return "启动 Mirasim 后会自动显示。\n额度只存在于 Mirasim 进程内，它不在就没有真值可读。"
        case .protocolMismatch(let s): return s
        case .coarseOnly(let s): return s
        case .live: return ""
        }
    }
}
