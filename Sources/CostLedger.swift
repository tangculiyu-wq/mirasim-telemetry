import Foundation

/// 一次真实调用的等价花费。按中转流水的行 id 唯一——一行就是一次
/// 真实计费调用，不存在 jsonl 那种「一条消息多块多行」的重复问题。
struct CostEntry: Equatable {
    let id: String
    let at: Date
    let usd: Double
    /// 模型名。`7d_fable` 这类窗口只统计特定档位的用量，算它的钱时必须按同一档位过滤。
    var model: String = ""
    /// 这笔钱花在哪个账号上。中转每行自带 userId，精确归属。
    var user: String? = nil
    /// 四类 token 原数。留给「这段调用若全换成某款模型值多少钱」的重算（等价额度）。
    var input: Double = 0, output: Double = 0, read: Double = 0, write: Double = 0
    /// 归属的 Claude Code 会话与工作区（Mirasim 流水自带），给按会话汇总用。
    var session: String? = nil
    var workspace: String? = nil
}

/// 近 24 小时每一次调用的轻量记录，含失败与尚未回填用量的。
/// 失败统计、限流标记、最近调用列表、请求活动条都从它来。
struct CallRecord: Identifiable, Equatable {
    let id: String
    let at: Date
    let model: String
    let status: Int
    let durationMs: Double
    /// 四类 token 之和；未回填为 0。
    let tokens: Double
    let usd: Double
    let session: String?
    let workspace: String?
    let user: String?
    let agent: String
    var ok: Bool { status == 200 }
}

/// 一个 Claude Code 会话的累计消耗。
struct SessionUse: Identifiable, Equatable {
    let id: String
    let workspace: String?
    /// 会话文件里第一句用户消息，取不到为 nil。
    var title: String?
    let usd: Double
    let calls: Int
    /// 成功但用量还没回填的调用数，这部分钱还没算进 usd。
    let pending: Int
    let input: Double, output: Double, read: Double, write: Double
    let firstAt: Date
    let lastAt: Date
    /// 用过的模型与各自的调用数。
    let models: [String: Int]
    var tokens: Double { input + output + read + write }
}

/// 一段时间内的请求成败统计。
struct RequestStats: Equatable {
    var ok = 0
    var failed = 0
    /// 失败状态码 → 次数。
    var codes: [Int: Int] = [:]
    /// 近 10 分钟出过 429 的模型。
    var rateLimited: [String] = []
    /// 按时间格的成败数，最旧在前。
    var buckets: [(ok: Int, failed: Int)] = []
    var total: Int { ok + failed }
    static let empty = RequestStats()
    static func == (a: RequestStats, b: RequestStats) -> Bool {
        a.ok == b.ok && a.failed == b.failed && a.codes == b.codes && a.rateLimited == b.rateLimited
            && a.buckets.count == b.buckets.count && zip(a.buckets, b.buckets).allSatisfy { $0.ok == $1.ok && $0.failed == $1.failed }
    }
}

/// Mirasim 花费账本（v9，「按照他的来」——用户拍板对齐 Mirasim 流量监控页）。
///
/// 数据源＝中转自己的逐调用流水 `~/.mirasim/insights/usage-*.ndjson`。
/// 一次调用一行；token 用量由 Mirasim 拿「计量凭据」（relayCallId）从云端
/// **回填**进同一行。于是断流重试、绕开 Claude Code 的调用也都在账上。
///
/// 单价＝Mirasim 同款价目：`~/.mirasim/models-dev-cache.json`（models.dev 目录），
/// 目录里查不到才退内置官方牌价。缓存写按目录单一价（5 分钟档）——与流量页口径一致。
///
/// 回填是**原地改写**历史行（0 → 真值），增量游标必然漏改——按文件重扫，
/// 但文件的 (大小, 修改时间) 没变就复用上次的解析结果：闲置时零开销，
/// 活跃时每分钟只重解析正在写的那个月度文件。不落盘，内存即状态。
final class CostLedger {

    /// 命令行渲染/自检进程置位。本账本已无本地持久化，此位由 Calibrator 沿用。
    static var readOnly = false

    private var entries: [CostEntry] = []
    /// 成功但用量还没回填（token 全零）的调用。云端计量有延迟；缺口持续
    /// 存在说明凭据缺失或回填断了——那部分钱面板看不见，已花为下界。
    private var unmetered: [(at: Date, user: String?, session: String?)] = []
    /// 近 24 小时全部调用（含失败），见 CallRecord。
    private var recent: [CallRecord] = []
    private let lock = NSLock()

    init() {
        // v8 以前的本地账本文件已无人读，留着白占 1.2MB，顺手清掉
        if !Self.readOnly {
            let stale = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EduHuan/ledger.json")
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: 价目

    private struct Rate { let input, output, read, write: Double }

    /// 内置兜底价（美元/百万 token：输入、输出、缓存读、缓存写），官方牌价 2026-09。
    /// 只有 models.dev 目录缺该模型时才用。**顺序即优先级**（前缀匹配，先长后短）。
    /// Fable/Mythos 5.1 的缓存读是 0.025×（$0.25），不是 5 代的 0.1×——
    /// 曾靠 `claude-fable-5` 前缀兜住 5.1，缓存读按 $1 算，整段虚高 21%。
    private static let builtin: [(String, Rate)] = [
        ("claude-fable-5-1",  Rate(input: 10,  output: 50,  read: 0.25, write: 12.5)),
        ("claude-mythos-5-1", Rate(input: 10,  output: 50,  read: 0.25, write: 12.5)),
        ("claude-fable-5",    Rate(input: 10,  output: 50,  read: 1,    write: 12.5)),
        ("claude-mythos-5",   Rate(input: 10,  output: 50,  read: 1,    write: 12.5)),
        ("claude-opus-5",     Rate(input: 5,   output: 25,  read: 0.5,  write: 6.25)),
        ("claude-opus-4-5",   Rate(input: 5,   output: 25,  read: 0.5,  write: 6.25)),
        ("claude-opus-4-6",   Rate(input: 5,   output: 25,  read: 0.5,  write: 6.25)),
        ("claude-opus-4-7",   Rate(input: 5,   output: 25,  read: 0.5,  write: 6.25)),
        ("claude-opus-4-8",   Rate(input: 5,   output: 25,  read: 0.5,  write: 6.25)),
        ("claude-opus-4-9",   Rate(input: 5,   output: 25,  read: 0.5,  write: 6.25)),
        ("claude-opus-4",     Rate(input: 15,  output: 75,  read: 1.5,  write: 18.75)),
        ("claude-sonnet-5",   Rate(input: 2,   output: 10,  read: 0.2,  write: 2.5)),
        ("claude-sonnet-4",   Rate(input: 3,   output: 15,  read: 0.3,  write: 3.75)),
        ("claude-haiku-4-5",  Rate(input: 1,   output: 5,   read: 0.1,  write: 1.25)),
        ("claude-haiku",      Rate(input: 0.8, output: 4,   read: 0.08, write: 1)),
        ("gpt-5.6-luna",      Rate(input: 0.2, output: 1.2, read: 0.02, write: 0.25)),
        ("gpt-5.6-terra",     Rate(input: 2,   output: 12,  read: 0.2,  write: 2.5)),
        ("gpt-5.6",           Rate(input: 4,   output: 20,  read: 0.4,  write: 5)),
    ]

    /// 目录里优先信任的一方厂商（按序）。别家聚合站的同名条目带加价，只作最后手段。
    private static let firstParty = ["anthropic", "openai", "google", "deepseek", "xai", "moonshotai", "zai", "alibaba", "mistral"]

    /// models.dev 目录的紧凑版：provider → model → 四价。原始 JSON 4.4MB、
    /// 7 千多款模型，整棵 NSDictionary 树常驻要几十 MB——只抽四价留着，其余当场释放。
    private var catalog: [String: [String: Rate]] = [:]
    private var catalogStamp: (size: UInt64, mtime: Date)?
    private var rateCache: [String: Rate] = [:]

    private static let catalogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mirasim/models-dev-cache.json")

    /// 目录文件变了才重读。返回是否重读了（重读后价目可能变，账本要整本重算）。
    private func loadCatalogIfChanged() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.catalogURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return false }
        if let s = catalogStamp, s.size == size, s.mtime == mtime { return false }
        catalogStamp = (size, mtime)
        rateCache.removeAll()
        var out: [String: [String: Rate]] = [:]
        autoreleasepool {
            guard let data = try? Data(contentsOf: Self.catalogURL),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let providers = root["data"] as? [String: Any] else { return }
            for (prov, pv) in providers {
                guard let models = (pv as? [String: Any])?["models"] as? [String: Any] else { continue }
                var table: [String: Rate] = [:]
                for (mid, mv) in models {
                    guard let cost = (mv as? [String: Any])?["cost"] as? [String: Any],
                          let i = Self.num(cost["input"]), let o = Self.num(cost["output"]),
                          i > 0 || o > 0 else { continue }   // 零价条目是占位，不能当真
                    table[mid] = Rate(input: i, output: o,
                                      read: Self.num(cost["cache_read"]) ?? i * 0.1,
                                      write: Self.num(cost["cache_write"]) ?? i * 1.25)
                }
                if !table.isEmpty { out[prov.lowercased()] = table }
            }
        }
        catalog = out
        return true
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? NSNumber)?.doubleValue
    }

    /// 流水里的 provider 是「协议」口径（openai-responses / openai-chat），
    /// 目录里的是厂商口径（openai）。去掉协议后缀再查——
    /// 曾原样拿去查、查不到落兜底价（Fable 价），GPT 调用被虚高 5–50 倍。
    private static func canonical(_ provider: String) -> String {
        var s = provider.lowercased()
        for suf in ["-responses", "-chat", "-completions", "-compat", "-messages"] where s.hasSuffix(suf) {
            s.removeLast(suf.count)
            break
        }
        return s
    }

    private func rate(provider rawProvider: String, model: String) -> Rate {
        let key = rawProvider + "/" + model
        if let r = rateCache[key] { return r }

        var found: Rate?
        // 1. 流水标的厂商（去协议后缀）
        found = catalog[Self.canonical(rawProvider)]?[model] ?? catalog[rawProvider.lowercased()]?[model]
        // 2. 一方厂商目录
        if found == nil { for p in Self.firstParty { if let r = catalog[p]?[model] { found = r; break } } }
        // 3. 内置官方牌价（新型号目录还没收录时靠它）
        if found == nil, let b = Self.builtin.first(where: { model.hasPrefix($0.0) }) { found = b.1 }
        // 4. 别家目录里的同名或带厂商前缀的条目（如 hpc-ai 的 deepseek/deepseek-v4-flash）
        if found == nil {
            let suffixed = "/" + model
            for p in catalog.keys.sorted() {
                guard let t = catalog[p] else { continue }
                if let r = t[model] { found = r; break }
                if let k = t.keys.first(where: { $0.hasSuffix(suffixed) }) { found = t[k]; break }
            }
        }
        // 5. 全不认识：按最贵档计，宁可高估也不装作没花钱
        let r = found ?? Rate(input: 10, output: 50, read: 1, write: 12.5)
        rateCache[key] = r
        return r
    }

    // MARK: 服役起点

    /// 中转计量的起点＝流水第一行。窗口起点早于它的窗口，
    /// 本机没有完整底账，逆推口径据此让位给标定单价。
    private var _serviceStart: Date?
    var serviceStart: Date? {
        if _serviceStart == nil { resolveServiceStart() }
        return _serviceStart
    }

    private func resolveServiceStart() {
        guard _serviceStart == nil else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mirasim/insights", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        // 文件名含年月，字典序即时间序
        guard let first = files.filter({ $0.hasPrefix("usage-") && $0.hasSuffix(".ndjson") }).sorted().first,
              let h = FileHandle(forReadingAtPath: dir.appendingPathComponent(first).path) else { return }
        let head = h.readData(ofLength: 16384)
        try? h.close()
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            if let d = line.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let ts = o["ts"] as? String, let at = parseDate(ts) {
                _serviceStart = at
                return
            }
        }
    }

    // MARK: 扫描

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseDate(_ s: String) -> Date? {
        if let d = Self.iso.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// 单个月度文件的解析结果，连同解析时的 (大小, 修改时间)。
    private struct FileCache {
        var size: UInt64
        var mtime: Date
        var entries: [CostEntry]
        var unmetered: [(at: Date, user: String?, session: String?)]
        var recent: [CallRecord]
    }
    private var files: [String: FileCache] = [:]

    /// 重扫中转流水。耗时操作，只在后台队列调用。
    func refresh() {
        // 价目变了，所有缓存的解析结果都是按旧价算的，整本重来
        if loadCatalogIfChanged() { files.removeAll() }

        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".mirasim/insights", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        // 先筛再取：只认月度流水，最近 3 个月（35 天保留期最多跨 3 个月份）。
        // 原先先取后筛，session-usage-* 排在前面会挤掉真正的月度文件。
        let wanted = Array(names.filter { $0.hasPrefix("usage-") && $0.hasSuffix(".ndjson") }.sorted().suffix(3))
        let horizon = Date().addingTimeInterval(-35 * 86400)
        let recentHorizon = Date().addingTimeInterval(-86400)
        var changed = false

        for name in wanted {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if let c = files[name], c.size == size, c.mtime == mtime { continue }   // 没变，复用
            guard let h = FileHandle(forReadingAtPath: path), let data = try? h.readToEnd() else { continue }
            try? h.close()

            var es: [CostEntry] = []
            var um: [(at: Date, user: String?, session: String?)] = []
            var rc: [CallRecord] = []
            // 宽松解码：任何一个坏字节都不能让整月账作废
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      o["leg"] as? String == "relay",
                      let id = o["id"] as? String,
                      let ts = o["ts"] as? String, let at = parseDate(ts),
                      at >= horizon else { continue }
                func n(_ k: String) -> Double { Self.num(o[k]) ?? 0 }
                let input = n("input"), output = n("output")
                let read = n("cacheRead"), write = n("cacheWrite")
                let user = o["userId"] as? String
                let session = o["sessionId"] as? String
                let workspace = o["workspace"] as? String
                let model = (o["model"] as? String) ?? ""
                let status = (o["status"] as? Int) ?? 0
                let tokens = input + output + read + write
                var usd = 0.0
                if tokens > 0 {
                    let r = rate(provider: (o["provider"] as? String) ?? "anthropic", model: model)
                    usd = (input * r.input + output * r.output + read * r.read + write * r.write) / 1_000_000
                }
                // 近 24 小时的每一条都留一份轻量记录（含失败与未回填）
                if at >= recentHorizon {
                    rc.append(CallRecord(id: id, at: at, model: model, status: status,
                                         durationMs: n("durationMs"), tokens: tokens, usd: usd,
                                         session: session, workspace: workspace, user: user,
                                         agent: (o["agent"] as? String) ?? "?"))
                }
                if tokens <= 0 {
                    // 成功了却还没回填：记进缺口；失败的调用不计费也不算缺口
                    if status == 200 { um.append((at, user, session)) }
                    continue
                }
                guard usd > 0 else { continue }
                es.append(CostEntry(id: id, at: at, usd: usd, model: model, user: user,
                                    input: input, output: output, read: read, write: write,
                                    session: session, workspace: workspace))
            }
            files[name] = FileCache(size: size, mtime: mtime, entries: es, unmetered: um, recent: rc)
            changed = true
        }
        // 已滚出保留范围的旧月份丢掉
        for k in files.keys where !wanted.contains(k) { files.removeValue(forKey: k); changed = true }
        guard changed else { return }

        let all = wanted.flatMap { files[$0]?.entries ?? [] }
        let allUm = wanted.flatMap { files[$0]?.unmetered ?? [] }
        let allRc = wanted.flatMap { files[$0]?.recent ?? [] }
        lock.lock()
        entries = all
        unmetered = allUm
        recent = allRc
        lock.unlock()
    }

    // MARK: 自检

    /// 自检用：某模型按当前目录/内置表会取到哪一档价。
    func debugRate(provider: String, model: String) -> String {
        _ = loadCatalogIfChanged()
        let r = rate(provider: provider, model: model)
        return String(format: L("in %.2f / out %.2f / 读 %.3f / 写 %.3f"), r.input, r.output, r.read, r.write)
    }

    // MARK: 查询

    /// 某时段内：已计价的调用数 与 成功但用量未回填的调用数。
    /// 近期活跃的会话各自的累计消耗（整个会话生命期内、账本保留范围之内），
    /// 按最近活跃排序。activeSince 之后没有调用的会话不列。
    func sessions(activeSince: Date, userId: String?, limit: Int) -> [SessionUse] {
        lock.lock(); defer { lock.unlock() }
        struct Acc { var ws: String?; var usd = 0.0; var calls = 0; var pending = 0
                     var i = 0.0, o = 0.0, r = 0.0, w = 0.0; var first = Date.distantFuture; var last = Date.distantPast
                     var models: [String: Int] = [:] }
        var acc: [String: Acc] = [:]
        for e in entries {
            guard let s = e.session, userId == nil || e.user == userId else { continue }
            var a = acc[s] ?? Acc()
            a.ws = a.ws ?? e.workspace
            a.usd += e.usd; a.calls += 1
            a.i += e.input; a.o += e.output; a.r += e.read; a.w += e.write
            if e.at < a.first { a.first = e.at }
            if e.at > a.last { a.last = e.at }
            a.models[e.model, default: 0] += 1
            acc[s] = a
        }
        for u in unmetered {
            guard let s = u.session, userId == nil || u.user == userId else { continue }
            var a = acc[s] ?? Acc()
            a.pending += 1; a.calls += 1
            if u.at > a.last { a.last = u.at }
            if u.at < a.first { a.first = u.at }
            acc[s] = a
        }
        return acc.filter { $0.value.last >= activeSince }
            .sorted { $0.value.last > $1.value.last }
            .prefix(limit)
            .map { SessionUse(id: $0.key, workspace: $0.value.ws, title: nil, usd: $0.value.usd, calls: $0.value.calls,
                              pending: $0.value.pending, input: $0.value.i, output: $0.value.o, read: $0.value.r, write: $0.value.w,
                              firstAt: $0.value.first, lastAt: $0.value.last, models: $0.value.models) }
    }

    /// 一段时间内的请求成败：总数、失败码分布、近 10 分钟被 429 的模型、按格的活动。
    func requestStats(since: Date, userId: String?, buckets: Int = 12) -> RequestStats {
        lock.lock(); defer { lock.unlock() }
        var st = RequestStats()
        let now = Date()
        let span = now.timeIntervalSince(since)
        st.buckets = Array(repeating: (ok: 0, failed: 0), count: max(1, buckets))
        var limited: Set<String> = []
        for c in recent where c.at >= since && (userId == nil || c.user == userId) {
            let idx = min(buckets - 1, max(0, Int(c.at.timeIntervalSince(since) / span * Double(buckets))))
            if c.ok { st.ok += 1; st.buckets[idx].ok += 1 }
            else {
                st.failed += 1; st.buckets[idx].failed += 1
                st.codes[c.status, default: 0] += 1
                if c.status == 429, now.timeIntervalSince(c.at) < 600 { limited.insert(c.model) }
            }
        }
        st.rateLimited = limited.sorted()
        return st
    }

    /// 最近 N 次调用，新的在前。
    func recentCalls(limit: Int, userId: String?) -> [CallRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(recent.filter { userId == nil || $0.user == userId }
            .sorted { $0.at > $1.at }.prefix(limit))
    }

    func backfillGap(since: Date, userId: String?) -> (metered: Int, unmetered: Int) {
        lock.lock(); defer { lock.unlock() }
        let m = entries.lazy.filter { $0.at >= since && (userId == nil || $0.user == userId) }.count
        let u = unmetered.lazy.filter { $0.at >= since && (userId == nil || $0.user == userId) }.count
        return (m, u)
    }

    /// 某个时间段内经中转的花费与调用数。
    /// - Parameter modelGroup: 只统计模型名含该子串的调用（模型档位窗口用），nil 表示不过滤。
    /// - Parameter userId: 只统计该账号的调用；nil 表示不分账号。
    func spent(since: Date, until: Date? = nil, modelGroup: String? = nil, userId: String? = nil) -> (usd: Double, count: Int) {
        lock.lock(); defer { lock.unlock() }
        var sum = 0.0, n = 0
        for e in entries where e.at >= since {
            if let u = until, e.at >= u { continue }
            if let g = modelGroup, !e.model.lowercased().contains(g.lowercased()) { continue }
            if let uid = userId, e.user != uid { continue }
            sum += e.usd; n += 1
        }
        return (sum, n)
    }

    /// 同一段调用「若全换成某款模型」值多少钱：token 原数不动，按目标价目重算。
    /// 用户 09-02 拍板：Fable 5 一律按 5.1 处理、参数跟 5.1 定价走（以后不用 5，
    /// 5.1 更便宜）。Fable 窗口的等价额度用它算——历史 Fable 5 调用也按 5.1 价目重算，
    /// 不然缓存读 $1 对 $0.25 的旧价目把「相当于 Fable 5.1 多少刀」拖高五成。
    func spentRepriced(since: Date, until: Date? = nil, modelGroup: String? = nil,
                       userId: String? = nil, as target: String) -> (usd: Double, count: Int) {
        let r = rate(provider: "anthropic", model: target)
        lock.lock(); defer { lock.unlock() }
        var sum = 0.0, n = 0
        for e in entries where e.at >= since {
            if let u = until, e.at >= u { continue }
            if let g = modelGroup, !e.model.lowercased().contains(g.lowercased()) { continue }
            if let uid = userId, e.user != uid { continue }
            sum += (e.input * r.input + e.output * r.output + e.read * r.read + e.write * r.write) / 1_000_000
            n += 1
        }
        return (sum, n)
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.isEmpty
    }

    /// 按自然日聚合（本地时区），给月度柱状走势。升序，含调用数。
    func daily(days: Int, userId: String? = nil) -> [(day: Date, usd: Double, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date().addingTimeInterval(-Double(days - 1) * 86400))
        var acc: [Date: (Double, Int)] = [:]
        for e in entries where e.at >= from {
            if let uid = userId, e.user != uid { continue }
            let k = cal.startOfDay(for: e.at)
            let cur = acc[k] ?? (0, 0)
            acc[k] = (cur.0 + e.usd, cur.1 + 1)
        }
        return acc.sorted { $0.key < $1.key }.map { ($0.key, $0.value.0, $0.value.1) }
    }
}

/// 一个窗口的钱。
struct WindowCost: Equatable {
    /// 窗口开始至今经中转的花费。按 Mirasim 逐调用计量 × 本地价目表折算，
    /// 含断流重试等 Claude Code 记不到的调用；仍是估算，界面带 ≈。
    let spentUSD: Double
    let requests: Int
    /// 每额度点折合多少美元 = 本机花费 ÷ 该窗口已用点数。只有精确口径（读得到点数）时才有。
    let perPointUSD: Double?
    /// 整个窗口的额度折合多少美元。
    let fullUSD: Double?
    /// 整窗额度若全花在普通模型（Opus/Sonnet 等非 Fable）上值多少美元。
    /// 每点单价＝本窗口内非 Fable 的 Claude 实花 ÷ 非 Fable 占的点，实测得来。
    var fullRegularUSD: Double? = nil
    /// 整窗额度若全花在 Fable 5.1 上值多少美元（历史 Fable 5 调用按 5.1 价目重算）。
    var fullFableUSD: Double? = nil
    /// Fable 窗口按 Fable 5 标价的整窗值（＝预算点 ÷ 200）。与 5.1 那个数是同样的活量，
    /// 只是标价不同——两个并排给，免得「5.1 值的钱少」被读成「5.1 额度少」。
    var fullFableAtF5USD: Double? = nil
}
