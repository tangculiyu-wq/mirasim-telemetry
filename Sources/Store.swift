import Foundation
import Combine
import AppKit

/// 面板与菜单栏共用的数据源。
///
/// 准确性的全部规矩集中在这里，就三条：
/// 1. 只显示上游给过的真值。`/v1/limits` 的原始点为主，mirachannel 帧（同源、0.1%）为辅。
/// 2. 两个来源都拿不到时，**不外推**。宁可显示「读不到」，也不拿旧锚点算一个看着像
///    当前值的数字——那正是这类仪表「不准」的常见根源。
/// 3. 拿到的数据一律附真实年龄。陈旧不是罪，把陈旧说成当下才是。
final class Store: ObservableObject {

    // MARK: 对外状态

    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var link: LinkState = .connecting
    /// 双源交叉校验发现的异常。正常为 nil。
    @Published private(set) var integrityWarning: String?
    /// 回填缺口提示：成功调用里用量尚未从云端回填的占比过高时报——
    /// 那部分钱面板暂时看不见，已花与整窗都是下界。正常为 nil。
    @Published private(set) var coverageWarning: String?
    /// 各窗口的消耗速率与耗尽预演，键为窗口名。
    @Published private(set) var burns: [String: Burn] = [:]
    @Published private(set) var lastRefresh: Date?
    /// 本机实测的请求速度。读日志有开销，单独一条慢节拍。
    @Published private(set) var speeds: [Speed] = []
    /// 各窗口折合多少钱，键为窗口名。按官方价目表 × 本机账本算，带 ≈。
    @Published private(set) var costs: [String: WindowCost] = [:]
    /// 今天（本地零点起）的本机花费。
    @Published private(set) var todayCost: WindowCost?
    /// 本周（周一起）与本月（1 号起）的本机花费累计。
    /// 上游没有周/月额度窗口，这两个没有预算分母，只有真实累计。
    @Published private(set) var weekCost: WindowCost?
    @Published private(set) var monthCost: WindowCost?
    /// 近 14 天逐日花费（日期、金额、请求数），给月卡的柱状走势。
    @Published private(set) var dailySpend: [(day: Date, usd: Double, count: Int)] = []
    /// 悬浮窗档位：小 / 中 / 大。
    @Published var size: PanelSize {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: "panelSize") }
    }
    /// 菜单栏跟哪个窗口走。nil = 自动取最吃紧的那个。
    @Published var pinnedWindow: String? {
        didSet { UserDefaults.standard.set(pinnedWindow, forKey: "pinnedWindow") }
    }
    @Published var showPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }
    /// 悬浮窗是否钉在最前。钉住后盖在别的窗口上面，浏览器全屏也压得住。
    @Published var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }
    /// 悬浮窗是否常驻显示。关掉就只剩菜单栏那枚环。
    @Published var floatingVisible: Bool {
        didSet { UserDefaults.standard.set(floatingVisible, forKey: "floatingVisible") }
    }
    /// 窗口不透明度 0.3–1。钉在最前的窗口总会压住底下的东西，
    /// 调透一点就能既看得见额度、又不挡住后面在做的事。
    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }
    /// 鼠标移上去时临时变回不透明。半透明状态下小字不好认，
    /// 真要细看时把指针挪过去就清晰了，比来回改设置顺手。
    @Published var clearOnHover: Bool {
        didSet { UserDefaults.standard.set(clearOnHover, forKey: "clearOnHover") }
    }
    /// 面板内容缩放。拖窗口边缘改的就是它——内容整体等比放大缩小。
    @Published var panelScale: Double {
        didSet { UserDefaults.standard.set(panelScale, forKey: "panelScale") }
    }
    /// 面板还是胶囊。
    @Published var floatMode: FloatMode {
        didSet { UserDefaults.standard.set(floatMode.rawValue, forKey: "floatMode") }
    }
    /// 只在 Mirasim 前台时显示。开着时切到别的应用，面板/胶囊都自动藏起。
    @Published var onlyInMirasim: Bool {
        didSet { UserDefaults.standard.set(onlyInMirasim, forKey: "onlyInMirasim") }
    }
    /// 内嵌 Mirasim：面板吸附在 Mirasim 窗口内部一角、跟着它移动，
    /// 它切到后台就藏。视觉上像长在 Mirasim 里，但仍是独立窗口（零侵入）。
    @Published var embedInMirasim: Bool {
        didSet { UserDefaults.standard.set(embedInMirasim, forKey: "embedInMirasim") }
    }
    /// 内嵌角落：topRight / topLeft / bottomRight / bottomLeft。
    /// 换角时偏移量归位（顶部默认让出 Mirasim 工具栏的高度）。
    @Published var embedCorner: String {
        didSet {
            UserDefaults.standard.set(embedCorner, forKey: "embedCorner")
            embedOffX = 14
            embedOffY = embedCorner.hasPrefix("top") ? 108 : 14
        }
    }
    /// 鼠标穿透：点击直接落到面板后面的东西上，面板变纯仪表。
    /// 解锁＝鼠标停在面板上 1 秒（或按住 ⌥），移开自动恢复穿透；
    /// 标题栏按钮/设置/菜单栏右键可彻底关。
    @Published var clickThrough: Bool {
        didSet { UserDefaults.standard.set(clickThrough, forKey: "clickThrough") }
    }
    /// 穿透的临时解锁态（停留 1 秒后为 true）。会话内状态，界面提示用。
    @Published var pierceUnlocked = false
    /// 内嵌偏移：面板与所选角的水平/垂直距离。拖动内嵌面板即改写——
    /// 默认顶角让出 108pt（Mirasim 自家工具栏，曾被 14pt 顶死盖住功能键）。
    @Published var embedOffX: Double {
        didSet { UserDefaults.standard.set(embedOffX, forKey: "embedOffX") }
    }
    @Published var embedOffY: Double {
        didSet { UserDefaults.standard.set(embedOffY, forKey: "embedOffY") }
    }
    /// 面板内嵌设置页是否展开。会话内状态，不落盘。
    @Published var settingsOpen = false
    /// 外观：auto（跟随系统）/ dark / light。
    @Published var appearanceOverride: String {
        didSet { UserDefaults.standard.set(appearanceOverride, forKey: "appearanceOverride") }
    }
    /// 额度警报：任一窗口用量越过警戒线时弹出面板并响一声，
    /// 每个「窗口 × 重置周期」只响一次，窗口滚动后自动解锁。
    @Published var alertEnabled: Bool {
        didSet { UserDefaults.standard.set(alertEnabled, forKey: "alertEnabled") }
    }
    /// 警戒线，0–1。
    @Published var alertThreshold: Double {
        didSet { UserDefaults.standard.set(alertThreshold, forKey: "alertThreshold") }
    }
    /// 卡片走势线的回看跨度（秒）。
    @Published var trendBack: Double {
        didSet { UserDefaults.standard.set(trendBack, forKey: "trendBack") }
    }
    /// 越线回调（参数为窗口显示名）。AppDelegate 接：弹面板 + 提示音。
    /// 上一轮 costs 是按哪个账号算的。快照换了号、或还没算过，commit 时立刻补一轮，
    /// 不等 60 秒节拍——否则启动头一分钟三张卡全是「金额待精确口径」，切号后一分钟内
    /// 显示的还是上一个号的钱（审查渲染时抓到的）。
    private var costsUser: String?
    private var costsInFlight = false
    /// 在飞期间又来了请求（首帧恰好落在启动那一轮解析里）→ 完成后紧接着再跑一轮，
    /// 不能干等下一个 60 秒节拍。渲染实测：不补这一轮，三张卡整整一分钟没有钱。
    private var costsRerun = false
    var onAlert: ((String) -> Void)?
    /// 已响过的「账号｜窗口＠重置周期」键，落盘——不然每次启动都对着同一个 94% 的窗口再响一遍。
    private var alertFired = Set(UserDefaults.standard.stringArray(forKey: "alertFired") ?? [])

    // MARK: 内部

    private let relay = RelayClient()
    private let limits = LimitsClient()
    private let ledger = CostLedger()
    private let calibrator = Calibrator()
    private let work = DispatchQueue(label: "eduhuan.store")
    private var samples: [Sample] = []
    private var samplesDirty = false
    private var limitsTimer: Timer?
    private var speedTimer: Timer?
    /// 中转流水文件的变更探针：3 秒 stat 一次，变了就（防抖 1.2 秒后）刷速度与账本。
    private var watchTimer: Timer?
    private var insightsStamp: (size: UInt64, mtime: Date)?
    private var pendingSpeedRefresh: DispatchWorkItem?
    private var lastSpeedRefreshAt = Date.distantPast
    /// 上一次成功读到精确值的时刻，用于判断是否该退回帧口径。
    private var lastExactAt: Date?

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EduHuan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("samples.json")
    }()

    init() {
        let d = UserDefaults.standard
        pinnedWindow = d.string(forKey: "pinnedWindow")
        showPercentInMenuBar = d.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        alwaysOnTop = d.object(forKey: "alwaysOnTop") as? Bool ?? true
        size = PanelSize(rawValue: d.string(forKey: "panelSize") ?? "") ?? .standard
        let savedOpacity = d.object(forKey: "opacity") as? Double ?? 1.0
        // 存坏了也不能让窗口彻底看不见
        opacity = savedOpacity.isFinite ? min(1, max(0.3, savedOpacity)) : 1.0
        clearOnHover = d.object(forKey: "clearOnHover") as? Bool ?? true
        let savedScale = d.object(forKey: "panelScale") as? Double ?? 1.0
        panelScale = savedScale.isFinite ? min(1.8, max(0.7, savedScale)) : 1.0
        floatMode = FloatMode(rawValue: d.string(forKey: "floatMode") ?? "") ?? .panel
        onlyInMirasim = d.object(forKey: "onlyInMirasim") as? Bool ?? false
        embedInMirasim = d.object(forKey: "embedInMirasim") as? Bool ?? false
        clickThrough = d.object(forKey: "clickThrough") as? Bool ?? false
        let corner = ["topRight", "topLeft", "bottomRight", "bottomLeft"].contains(d.string(forKey: "embedCorner") ?? "")
            ? d.string(forKey: "embedCorner")! : "topRight"
        embedCorner = corner
        let ox = d.object(forKey: "embedOffX") as? Double ?? 14
        let oy = d.object(forKey: "embedOffY") as? Double ?? (corner.hasPrefix("top") ? 108 : 14)
        embedOffX = ox.isFinite ? max(0, ox) : 14
        embedOffY = oy.isFinite ? max(0, oy) : 108
        // 默认就浮在桌面上——额度要能一眼看见，不该每次都去点一下
        floatingVisible = d.object(forKey: "floatingVisible") as? Bool ?? true
        appearanceOverride = ["auto", "dark", "light"].contains(d.string(forKey: "appearanceOverride") ?? "")
            ? d.string(forKey: "appearanceOverride")! : "auto"
        alertEnabled = d.object(forKey: "alertEnabled") as? Bool ?? true
        let th = d.object(forKey: "alertThreshold") as? Double ?? 0.9
        alertThreshold = th.isFinite ? min(0.99, max(0.5, th)) : 0.9
        let tb = d.object(forKey: "trendBack") as? Double ?? 7200
        trendBack = [3600.0, 7200.0, 21600.0].contains(tb) ? tb : 7200
        loadSamples()

        relay.onEvent = { [weak self] ev in
            guard let self else { return }
            DispatchQueue.main.async { self.handle(ev) }
        }
        relay.start()

        // 精确值单独一条节拍：帧来了不一定要重扫进程表（ps 有开销），
        // 20 秒一次足够——额度本身的变化粒度远大于此。
        // 必须进后台队列：fetch 里有 ps 进程扫描和同步网络等待（会话正在退出时能卡 8 秒），
        // 曾直接在主线程跑，每 20 秒一次界面顿挫，极端时整个面板冻住
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.work.async { self?.refreshExact() }
        }
        RunLoop.main.add(t, forMode: .common)
        limitsTimer = t
        work.async { [weak self] in self?.refreshExact() }

        // 速度要翻本机日志，60 秒一次足够——它本就是个「最近怎么样」的量。
        let st = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshSpeed() }
        RunLoop.main.add(st, forMode: .common)
        speedTimer = st
        refreshSpeed()

        // 实时：中转流水一变（有调用完成、或云端用量回填到位）就刷速度与账本。
        // stat 一个文件是微秒级开销，3 秒探一次；1.2 秒防抖等同一轮的后续写入落定。
        // 60 秒定时器仍留作兜底（jsonl 侧的变化、以及陈旧判定的重算）。
        let wt = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollInsightsChange() }
        RunLoop.main.add(wt, forMode: .common)
        watchTimer = wt
    }

    deinit { relay.stop(); limitsTimer?.invalidate(); speedTimer?.invalidate(); watchTimer?.invalidate() }

    private func pollInsightsChange() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".mirasim/insights", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path),
              let newest = names.filter({ $0.hasPrefix("usage-") && $0.hasSuffix(".ndjson") }).sorted().last,
              let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(newest).path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return }
        if let s = insightsStamp, s.size == size, s.mtime == mtime { return }
        let isBaseline = insightsStamp == nil
        insightsStamp = (size, mtime)
        if isBaseline { return }   // 启动那一拍只记基线，init 已刷过一轮
        pendingSpeedRefresh?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshSpeed() }
        pendingSpeedRefresh = w
        // 防抖 1.2s，且两次刷新至少隔 5s：跑着好几个会话时流水每秒都在变，
        // 不限速会变成每秒重扫一遍日志——实时到位就好，别烫手
        let delay = max(1.2, 5 - Date().timeIntervalSince(lastSpeedRefreshAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func refreshSpeed() {
        // 快照只在主线程写；先在主线程拷一份再进后台，别让后台队列去读它
        guard Thread.isMainThread else { DispatchQueue.main.async { self.refreshSpeed() }; return }
        guard !costsInFlight else { costsRerun = true; return }
        costsInFlight = true
        lastSpeedRefreshAt = Date()
        let snap = snapshot
        let uid = snap?.account.userId
        // 还不知道是哪个号就别算钱：uid 为空时 spent(userId: nil) 是全部账号的总和，
        // 会把别的号的花费当成「本周/本月」亮出来一分钟
        let accountKnown = uid != nil
        work.async { [weak self] in
            guard let self else { return }
            // 逐模型、按当前账号取样——后台自动化(agent≠claude)会带「后台」标记
            let s = SpeedStats.recentAll(userId: uid)
            self.ledger.refresh()
            let c = self.computeCosts(snap: snap)
            let cal = Calendar.current
            let midnight = cal.startOfDay(for: Date())
            let (tUSD, tN) = self.ledger.spent(since: midnight, userId: uid)
            // 周一起算（ISO 周），别跟着系统地区把周日当周首
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = cal.timeZone
            let weekStart = iso.dateInterval(of: .weekOfYear, for: Date())?.start ?? midnight
            let monthStart = cal.dateInterval(of: .month, for: Date())?.start ?? midnight
            let (wUSD, wN) = self.ledger.spent(since: weekStart, userId: uid)
            let (mUSD, mN) = self.ledger.spent(since: monthStart, userId: uid)
            let bars = self.ledger.daily(days: 14, userId: uid)
            // 回填缺口：中转成功了、云端用量却还没回填到本机流水的调用。这部分钱
            // 面板看不见——已花、整窗都是下界。零星几条是正常延迟，占比过 5% 且
            // 超过 20 条才提。（旧判据拿 Claude Code 账本对中转流水数「绕开中转」，
            // 账本换源后两边同源，那套比较早已无意义，撤。）
            let dayAgo = Date().addingTimeInterval(-86400)
            let gap = self.ledger.backfillGap(since: dayAgo, userId: uid)
            let total = gap.metered + gap.unmetered
            let pct = total > 0 ? Int(Double(gap.unmetered) / Double(total) * 100) : 0
            let coverage: String? = (gap.unmetered >= 20 && Double(gap.unmetered) > Double(total) * 0.05)
                ? "近 24h 有 \(gap.unmetered) 次调用的用量还没从云端回填（占 \(pct)%），这部分花费面板暂看不见——已花与整窗为下界"
                : nil
            DispatchQueue.main.async {
                self.costsInFlight = false
                self.costsUser = uid
                self.speeds = s
                if accountKnown {
                    self.costs = c
                    self.todayCost = WindowCost(spentUSD: tUSD, requests: tN, perPointUSD: nil, fullUSD: nil)
                    self.weekCost = WindowCost(spentUSD: wUSD, requests: wN, perPointUSD: nil, fullUSD: nil)
                    self.monthCost = WindowCost(spentUSD: mUSD, requests: mN, perPointUSD: nil, fullUSD: nil)
                    self.dailySpend = bars
                    self.coverageWarning = coverage
                }
                if self.costsRerun || (!accountKnown && self.snapshot?.account.userId != nil) {
                    self.costsRerun = false
                    self.refreshSpeed()
                }
            }
        }
    }

    /// 把账本按窗口聚合成钱。
    ///
    /// 整窗值走逆推口径（用户拍板）：**整窗 ≈ 本窗实花 ÷ mir 已用百分比**。
    /// 它天生自洽——已花/整窗恒等于卡上的百分比，「余≈」就是按这个窗口里的
    /// 真实用法折算的剩余产能。曾试过「近 6 小时单价 × 预算」，整窗和实花
    /// 两套单价当面打架（24% 已用配出 9.7% 的比值），已废。
    ///
    /// 逆推的启用前提有两条，缺一即退回退口径：
    /// 1. 窗口从头到尾落在本机服役期内（窗口起点 ≥ 服役起点）。否则窗口里
    ///    混着本机没记到账的存量点，逆推会虚低好几倍——切号稀释，用户抓过的
    ///    原始病根，这一条就是防它复发的闸。
    /// 2. 已用点数 ≥ 12,000（成本入账滞后于点数记账，小样本单价系统性虚低）。
    /// 回退口径＝7d 本窗均价（量最大、最能代表当前用法）→ 标定器长基线。
    /// 回退时已花也按同一单价折算显示，保持卡面自洽。
    private func computeCosts(snap: QuotaSnapshot?) -> [String: WindowCost] {
        guard let snap else { return [:] }
        let uid = snap.account.userId

        // 逆推：窗口完整可见且样本够时给 (实花, 次数, 整窗, 单价)，否则 nil
        func inverted(_ w: QuotaWindow) -> (usd: Double, n: Int, full: Double, per: Double?)? {
            guard let start = w.windowStart,
                  let ss = ledger.serviceStart, start >= ss,
                  w.usedPercent > 0.01 else { return nil }
            // 点数门槛：读得到原始点直接比；帧口径读不到点，按已用 ≥3% 近似
            let enough = w.usedPoints.map { $0 >= 12_000 } ?? (w.usedPercent >= 3)
            guard enough else { return nil }
            // 非档位窗口只算 Claude 系模型：GPT/Kimi 经 Mirasim 走别家，不扣这里的点，
            // 曾把它们的钱也除进点数，单价虚高
            let (usd, n) = ledger.spent(since: start, modelGroup: w.modelGroup ?? "claude", userId: uid)
            guard usd > 0 else { return nil }
            let full = usd / (w.usedPercent / 100)
            let per = w.usedPoints.flatMap { $0 > 0 ? usd / $0 : nil }
            return (usd, n, full, per)
        }

        // 回退单价：7d 本窗均价优先（比如 5h 刚重置点数不够时，接的还是
        // 当前用法），存量窗口/装机初期再退标定器的锚点增量长基线。
        let per7 = snap.windows.first(where: { $0.name == "7d" }).flatMap { inverted($0)?.per }
        let perFallback = per7 ?? uid.flatMap { calibrator.perPointUSD(userId: $0, ledger: ledger) }

        var out: [String: WindowCost] = [:]
        for w in snap.windows {
            if let inv = inverted(w) {
                out[w.name] = WindowCost(spentUSD: inv.usd, requests: inv.n,
                                         perPointUSD: inv.per, fullUSD: inv.full)
                continue
            }
            let (usd, n) = w.windowStart.map { ledger.spent(since: $0, modelGroup: w.modelGroup ?? "claude", userId: uid) }
                ?? (usd: 0, count: 0)
            if let per = perFallback, let used = w.usedPoints, let budget = w.budgetPoints {
                // 回退口径下，已花＝单价 × 已用点。拿本机记到的部分实花配
                // 全窗预算，比值对不上卡面的百分比，看着就像错的。
                out[w.name] = WindowCost(spentUSD: per * used, requests: n,
                                         perPointUSD: per, fullUSD: per * budget)
            } else {
                out[w.name] = WindowCost(spentUSD: usd, requests: n, perPointUSD: nil, fullUSD: nil)
            }
        }

        // 等价换算（用户 09-02：「额度还是不清楚，7 天加一行小字：相当于普通模型多少刀、
        // 相当于 Fable 5.1 多少刀」）。整窗值随模型混比呼吸，这两个是固定参照。
        let eq = Self.equivalentRates(windows: snap.windows, uid: uid, ledger: ledger)
        for w in snap.windows {
            guard let budget = w.budgetPoints else { continue }
            if w.modelGroup == nil { out[w.name]?.fullRegularUSD = eq.regular.map { $0 * budget } }
            if w.modelGroup == nil || w.modelGroup == "fable" {
                out[w.name]?.fullFableUSD = eq.fable.map { $0 * budget }
            }
            // Fable 窗另给「按 Fable 5 标价」的整窗值＝预算 ÷ 200：与 5.1 的活量相同，
            // 摆在一起看，5.1 的美元数小是标价低、不是额度少
            if w.modelGroup == "fable", eq.fable != nil {
                out[w.name]?.fullFableAtF5USD = budget / Self.pointsPerFable5Dollar
            }
        }
        return out
    }

    /// 额度点的扣法（09-02 逐小时对账实测，MAX 档）：
    ///   普通模型（Opus/Sonnet）每 $1 **标价**扣 100 点（纯 Opus 小时 96–101）；
    ///   Fable 每 $1 **Fable 5 标价**扣 200 点（纯 Fable 5 小时 197–201）——
    ///   Fable 5.1 标价便宜了（缓存读 $1→$0.25），扣点却仍按 Fable 5 的价目：
    ///   拿 Fable 5 权重预测整个 Fable 窗的点，偏差 −0.2%；按 5.1 自己的标价×300 偏 +7.8%，
    ///   「5.1 点也便宜」偏 −28%。用户问「5.1 不是便宜了吗，为什么额度还只值一千来刀」——
    ///   答案就在这：便宜的只是 API 标价，同样的点在 5.1 上能跑的 token 与 5 一样多。
    static let pointsPerRegularDollar = 100.0
    static let pointsPerFable5Dollar = 200.0

    /// 两个每点单价：普通模型、Fable 5.1。
    ///
    /// 点是统一计量，但不同模型每点折合的美元不同。09-02 逐小时对账实测：
    /// Fable 调用同时扣 7d 窗与 Fable 窗（两窗增量 1:1），普通模型只扣 7d 窗
    /// （Fable 窗纹丝不动）。据此把 7d 窗的点拆成两份、各配各的钱：
    ///   Fable 5.1 每点 ＝ Fable 窗内全部 Fable 调用按 5.1 价目重算 ÷ Fable 窗已用点
    ///   普通模型每点 ＝ 7d 窗内非 Fable 的 Claude 实花 ÷（7d 已用点 − Fable 占的点）
    /// 实测 09-02：普通 ≈$0.0100/点、Fable 5.1 ≈$0.0033/点、Fable 5 ≈$0.0050/点——
    /// 同样的点买 Fable 5.1 的美元只有普通模型的三分之一。
    /// 样本不足（该份 <12,000 点）退回该账号上次算出的值，再没有就 nil，界面上那半句不显示。
    static func equivalentRates(windows: [QuotaWindow], uid: String?, ledger: CostLedger,
                                persist: Bool = true) -> (regular: Double?, fable: Double?) {
        var regular: Double? = nil, fable: Double? = nil
        if let w7 = windows.first(where: { $0.name == "7d" }),
           let wf = windows.first(where: { $0.modelGroup == "fable" }),
           let s7 = w7.windowStart, let sf = wf.windowStart,
           let used7 = w7.usedPoints, let usedF = wf.usedPoints,
           let ss = ledger.serviceStart, s7 >= ss, sf >= ss {
            let fableActual = ledger.spent(since: sf, modelGroup: "fable", userId: uid).usd
            if usedF >= 12_000, fableActual > 0 {
                let as51 = ledger.spentRepriced(since: sf, modelGroup: "fable", userId: uid,
                                                as: "claude-fable-5-1").usd
                if as51 > 0 { fable = as51 / usedF }
            }
            // Fable 在 7d 窗里占的点：两窗同起点时就是 Fable 窗已用点；起点不同按钱折
            let fableIn7d: Double = (abs(s7.timeIntervalSince(sf)) < 120 || fableActual <= 0 || usedF <= 0)
                ? usedF
                : ledger.spent(since: s7, modelGroup: "fable", userId: uid).usd / (fableActual / usedF)
            let regPts = used7 - fableIn7d
            let regUSD = ledger.spent(since: s7, modelGroup: "claude", userId: uid).usd
                       - ledger.spent(since: s7, modelGroup: "fable", userId: uid).usd
            if regPts >= 12_000, regUSD > 0 { regular = regUSD / regPts }
        }
        // 合理区间外视为算错（窗口刚滚动的瞬时脏值等），不用也不存
        func sane(_ p: Double?) -> Double? { p.flatMap { (0.0005...0.1).contains($0) ? $0 : nil } }
        regular = sane(regular); fable = sane(fable)
        // 实测点数不够（新窗口、新账号）退「扣点公式」，不留空：
        //   普通模型每点 = 1 ÷ 100；Fable 5.1 每点 = 5.1 标价 ÷ Fable 5 标价 ÷ 200，
        //   标价比取本窗口 Fable 调用的真实 token 构成（缓存读占比决定它）。
        if regular == nil { regular = 1 / Self.pointsPerRegularDollar }
        if fable == nil, let wf = windows.first(where: { $0.modelGroup == "fable" }), let sf = wf.windowStart {
            let at51 = ledger.spentRepriced(since: sf, modelGroup: "fable", userId: uid, as: "claude-fable-5-1").usd
            let at5 = ledger.spentRepriced(since: sf, modelGroup: "fable", userId: uid, as: "claude-fable-5").usd
            if at5 > 1, at51 > 0 { fable = sane(at51 / at5 / Self.pointsPerFable5Dollar) }
        }
        guard let uid else { return (regular, fable) }
        let key = "quotaEquiv.\(uid)"
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        if persist {
            if let r = regular { saved["regular"] = r }
            if let f = fable { saved["fable"] = f }
            if regular != nil || fable != nil { UserDefaults.standard.set(saved, forKey: key) }
        }
        return (regular ?? saved["regular"], fable ?? saved["fable"])
    }

    /// 标定进度，给界面提示「额度标定中」。
    var calibrationProgress: Double {
        guard let uid = snapshot?.account.userId else { return 0 }
        return calibrator.progress(userId: uid)
    }

    /// 某窗口最近一段时间的用量走势，给卡片上的迷你走势线。
    /// 稀释到 64 点以内——走势线只有几十像素宽，更多点是浪费。
    func history(for window: String, back: TimeInterval = 7200) -> [(Date, Double)] {
        let cutoff = Date().addingTimeInterval(-back)
        let uid = snapshot?.account.userId
        let pts = samples.filter { $0.window == window && $0.at >= cutoff && $0.user == uid && uid != nil }
        guard pts.count > 64 else { return pts.map { ($0.at, $0.percent) } }
        let step = pts.count / 64 + 1
        return pts.enumerated().compactMap { i, s in i % step == 0 ? (s.at, s.percent) : nil }
    }

    /// 手动刷新。用户点刷新时两条路一起催。
    func refresh() {
        relay.poll(fresh: true)
        work.async { [weak self] in self?.refreshExact() }
        refreshSpeed()
    }

    // MARK: 事件处理

    private func handle(_ ev: RelayEvent) {
        switch ev {
        case .snapshot(let s):
            merge(coarse: s)
        case .unreachable(let why):
            // 连不上不清空既有快照——它仍是真实采集过的值，界面会如实标注年龄。
            // 进程在不在由 RelayClient 在它自己的队列上查过了，这里（主线程）不再起 ps。
            link = .coarseOnly(why)
        case .noMirasim:
            link = .noMirasim
        case .mismatch(let why):
            link = .protocolMismatch(why)
        }
    }

    /// 帧口径快照到达。若手上有新鲜的精确值，用精确值覆盖对应窗口。
    private func merge(coarse: QuotaSnapshot) {
        var merged = coarse
        if let exact = pendingExact, Date().timeIntervalSince(exact.receivedAt) < 45 {
            merged = apply(exact: exact, onto: coarse)
        }
        commit(merged)
    }

    /// 最近一次读到的精确快照。帧与精确值各有节拍，靠它对齐。
    private var pendingExact: QuotaSnapshot?

    private func refreshExact() {
        let expected = relay.lastUserId
        guard let payload = limits.fetch(expectedUserId: expected) else {
            // 读不到精确值不是错误：没有活跃会话时本就如此，帧口径照常工作。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let last = self.lastExactAt, Date().timeIntervalSince(last) > 120 {
                    self.pendingExact = nil
                }
            }
            return
        }
        let snap = QuotaSnapshot(
            windows: payload.windows,
            account: AccountInfo(userId: payload.subject, name: nil, email: nil,
                                 plan: nil, planExpiry: nil, paid: payload.paid,
                                 relayStatus: nil, host: nil),
            capturedAt: Date(), receivedAt: Date(), precision: .exact
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingExact = snap
            self.lastExactAt = Date()
            // 喂标定器：用 7d 窗口的原始点做增量单价反推
            if let w7 = snap.windows.first(where: { $0.name == "7d" }),
               let used = w7.usedPoints {
                self.calibrator.observe(userId: payload.subject,
                                        sevenDayUsedPoints: used,
                                        resetAt: w7.resetAt,
                                        windowStart: w7.windowStart,
                                        ledger: self.ledger)
            }
            // 帧可能还要等十几秒才来，先把精确值合到现有快照上，面板立刻变精确。
            if let cur = self.snapshot {
                self.commit(self.apply(exact: snap, onto: cur))
            } else {
                self.commit(snap)
            }
        }
    }

    /// 精确值覆盖帧值。以窗口名配对，帧里有而精确源没有的窗口原样保留。
    private func apply(exact: QuotaSnapshot, onto base: QuotaSnapshot) -> QuotaSnapshot {
        var out = base
        var drift: Double = 0
        var driftWindow: String?
        for e in exact.windows {
            guard let i = out.windows.firstIndex(where: { $0.name == e.name }) else {
                out.windows.append(e); continue
            }
            let coarsePct = out.windows[i].usedPercent
            // 帧被四舍五入到 0.1%，两者相差不应超过半格再加一点余量。
            // 超出说明两路读到的不是同一份东西——多半是端口枚举读到了另一个实例。
            //
            // 但用超的窗口要先对齐：帧把 usedPercent 封顶在 100，
            // 而精确源如实给 100.86%，直接相减会凭空得出 0.86 的「偏差」并误报。
            let d = abs(min(coarsePct, 100) - min(e.usedPercent, 100))
            if d > drift { drift = d; driftWindow = e.name }
            out.windows[i].usedPoints = e.usedPoints
            out.windows[i].budgetPoints = e.budgetPoints
            out.windows[i].usedPercent = e.usedPercent
            out.windows[i].precision = .exact
            if out.windows[i].upstreamStatus == nil { out.windows[i].upstreamStatus = e.upstreamStatus }
        }
        out.precision = .exact
        out.receivedAt = min(base.receivedAt, exact.receivedAt)
        integrityWarning = drift > 0.35
            ? "两路口径对 \(driftWindow ?? "某窗口") 的读数差 \(String(format: "%.2f", drift)) 个百分点，已按精确源显示"
            : nil
        return out
    }

    private func commit(_ s: QuotaSnapshot) {
        snapshot = s
        link = .live(s.precision)
        lastRefresh = Date()
        record(s)
        recomputeBurns()
        checkAlerts(s)
        // 第一帧到了 / 换了账号：钱要马上按这个号重算
        if costs.isEmpty || costsUser != s.account.userId { refreshSpeed() }
    }

    /// 越线警报。每个「窗口 × 重置周期」只响一次——重置时刻变了 key 就变，
    /// 新周期自动重新武装；容量兜底清空后至多重复响一次，无妨。
    private func checkAlerts(_ s: QuotaSnapshot) {
        guard alertEnabled else { return }
        var changed = false
        for w in s.windows where w.usedPercent >= alertThreshold * 100 {
            // 按分钟取整：帧与 limits 两路给的 resetAt 差几百毫秒，按秒取整会被当成两个周期响两次；
            // 带账号：几个号的窗口同名，不带会互相压掉
            let key = "\(s.account.userId ?? "?")|\(w.name)@\(Int(w.resetAt.timeIntervalSince1970 / 60))"
            guard !alertFired.contains(key) else { continue }
            alertFired.insert(key); changed = true
            onAlert?(w.displayName)
        }
        if alertFired.count > 64 { alertFired.removeAll(); changed = true }
        if changed { UserDefaults.standard.set(Array(alertFired), forKey: "alertFired") }
    }

    // MARK: 采样与速率

    private func record(_ s: QuotaSnapshot) {
        let now = Date()
        for w in s.windows {
            // 同窗口 30 秒内不重复落样本，避免文件无谓地长
            if let last = samples.last(where: { $0.window == w.name }),
               now.timeIntervalSince(last.at) < 30,
               abs(last.percent - w.usedPercent) < 0.001 { continue }
            samples.append(Sample(at: now, window: w.name, percent: w.usedPercent,
                                  resetAt: w.resetAt, user: s.account.userId))
        }
        // 只留 24 小时：走势线最长回看 6 小时、速率只看 6 小时，8 天留着没人读，
        // 却把 samples.json 撑到 2.6MB、每 20 秒整份重写一遍——白磨 SSD
        let cutoff = now.addingTimeInterval(-86400)
        if samples.contains(where: { $0.at < cutoff }) {
            samples.removeAll { $0.at < cutoff }
        }
        samplesDirty = true
        scheduleSave()
    }

    private var saveScheduled = false
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        // 60 秒攒一批再落盘（原 10 秒）；退出时 flush() 补最后一笔
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.saveSamples()
        }
    }

    /// 退出前把没落盘的样本写掉。主线程调用。
    func flush() { saveSamples(sync: true) }

    private func loadSamples() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        samples = (try? dec.decode([Sample].self, from: data)) ?? []
    }

    /// 在主线程把样本编码好（samples 只在主线程改，别跨线程读它——
    /// 原先在后台队列直接拷 samples，与主线程的写是一场数据竞争），写盘丢后台。
    private func saveSamples(sync: Bool = false) {
        guard samplesDirty else { return }
        samplesDirty = false
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(samples) else { return }
        let url = Self.storeURL
        if sync {
            try? data.write(to: url, options: .atomic)
        } else {
            work.async { try? data.write(to: url, options: .atomic) }
        }
    }

    /// 由真实采样算消耗速率。只用同一个 `resetAt` 内的样本——
    /// 窗口一滚动，用量归零，跨断点算出来的速率是负的、毫无意义。
    private func recomputeBurns() {
        guard let s = snapshot else { return }
        var out: [String: Burn] = [:]
        let now = Date()
        for w in s.windows {
            let uid = s.account.userId
            let pts = samples.filter {
                $0.window == w.name
                && $0.user == uid && uid != nil                       // 只用当前账号的样本
                && abs($0.resetAt.timeIntervalSince(w.resetAt)) < 1   // 同一个窗口周期
                && now.timeIntervalSince($0.at) < 6 * 3600            // 只看最近 6 小时的斜率
            }.sorted { $0.at < $1.at }

            guard let first = pts.first, let last = pts.last, pts.count >= 3 else { continue }
            let span = last.at.timeIntervalSince(first.at)
            guard span >= 60 else { continue }
            let rate = (last.percent - first.percent) / (span / 3600)
            var eta: Date?
            if rate > 0.01 {
                let hoursLeft = (100 - w.usedPercent) / rate
                if hoursLeft.isFinite, hoursLeft >= 0, hoursLeft < 24 * 30 {
                    eta = now.addingTimeInterval(hoursLeft * 3600)
                }
            }
            out[w.name] = Burn(percentPerHour: rate, exhaustAt: eta, samples: pts.count, span: span)
        }
        burns = out
    }

    // MARK: 派生

    /// 菜单栏与面板主角所指的窗口。
    var focusWindow: QuotaWindow? {
        guard let s = snapshot else { return nil }
        if let pinned = pinnedWindow, let w = s.windows.first(where: { $0.name == pinned }) { return w }
        return s.headline
    }

    /// 数据是否新鲜到可以当作「此刻」。超过这个岁数，界面要显式提示。
    var isFresh: Bool {
        guard let s = snapshot else { return false }
        return s.age < 90
    }
}
