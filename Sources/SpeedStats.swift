import Foundation

/// 一次请求的实测记录。
struct Turn {
    let at: Date
    let model: String
    /// 端到端耗时。取自 Mirasim 自己记的 `durationMs`，不是估的。
    let durationMs: Double
    /// 发起方：claude＝对话代理；gui 等＝Mirasim 的后台自动化。
    let agent: String
    /// 上游请求号，与 Claude Code 账本的 requestId 同值——精确配对的钥匙。
    let requestId: String?
}

/// 一个模型的速度统计。
///
/// 全部来自本机日志的实测值：耗时是 Mirasim 记的，token 是 Claude Code 记的。
/// 配不上对的就不给数，不拿平均值凑一个看着像实测的数字。
struct Speed {
    /// 原始模型 id（列表 identity 用——两个 id 可能映出同一个显示名）。
    let id: String
    let model: String
    /// 端到端耗时中位数（秒）。
    let medianSeconds: Double
    /// 输出速度（token/秒）。配不到 token 时为 nil。
    let tokensPerSecond: Double?
    /// 首字≈（秒）：请求发出 → 该回复第一个内容块落盘，中位数。
    /// 是真实首字延迟的上界（思考型模型第一块是整段思考）。配不上时 nil。
    let firstSeconds: Double?
    let count: Int
    let lastAt: Date
    /// 全组都不是对话代理发的（Mirasim 后台自动化，比如 gui）。
    /// 曾有一晚 41 条 gui 的 gpt 调用把速度行主角劫成 GPT——用户：「我没用过 GPT」。
    let background: Bool
}

enum SpeedStats {

    /// 读文件尾部若干字节。账本动辄几十 MB，整份读进来既慢又没必要。
    private static func tail(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        // 起点多半落在半行中间，宽松解码后丢掉首行残片
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = iso.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Mirasim 的请求流水：模型 + 端到端耗时 + 发起方 + 请求号。
    /// userId 给了就只看该账号（速度也要分账号，别把别人号的样本混进来）。
    private static func recentTurns(limit: Int, userId: String? = nil) -> [Turn] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mirasim/insights", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let usage = files.filter { $0.lastPathComponent.hasPrefix("usage-") && $0.pathExtension == "ndjson" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
        guard let newest = usage.first, let text = tail(newest, bytes: 220_000) else { return [] }

        var out: [Turn] = []
        for line in text.split(separator: "\n").reversed() {
            guard out.count < limit else { break }
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            guard (o["status"] as? Int) == 200,
                  let model = o["model"] as? String,
                  let ms = (o["durationMs"] as? Double) ?? (o["durationMs"] as? Int).map(Double.init),
                  ms > 0,
                  let at = parseDate(o["ts"] as? String) else { continue }
            if let uid = userId, (o["userId"] as? String) != uid { continue }
            out.append(Turn(at: at, model: model, durationMs: ms,
                            agent: (o["agent"] as? String) ?? "?",
                            requestId: o["providerCallId"] as? String))
        }
        return out
    }

    /// Claude Code 账本索引：
    /// - byReq：requestId → (该回复第一个内容块的落盘时刻, 输出 token)。
    ///   与中转流水的 providerCallId 同值，精确配对——首字≈ 和 tok/s 都靠它。
    /// - byTime：按时刻的输出 token 序列，给没有请求号可配的老路兜底。
    struct LedgerIndex {
        var byReq: [String: (first: Date, out: Double)] = [:]
        var byTime: [(Date, Double)] = []
    }

    private static func ledgerIndex(limit: Int) -> LedgerIndex {
        var idx = LedgerIndex()
        for (at, outTok, req) in ledgerLines(limit: limit * 3) {
            if let req {
                var e = idx.byReq[req] ?? (first: at, out: 0)
                if at < e.first { e.first = at }
                if let outTok, outTok > e.out { e.out = outTok }
                idx.byReq[req] = e
            }
            if let outTok, outTok > 0 { idx.byTime.append((at, outTok)) }
        }
        idx.byTime = Array(idx.byTime.sorted { $0.0 > $1.0 }.prefix(limit))
        return idx
    }

    /// Claude Code 账本近期行：(时刻, 输出 token, requestId)。
    private static func ledgerLines(limit: Int) -> [(Date, Double?, String?)] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        // 只看最近改动过的几个项目，避免遍历整棵目录树
        let recent = dirs.compactMap { u -> (URL, Date)? in
            guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (u, d)
        }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)

        // 每个项目取近 6 小时内改动过的会话文件、最多 6 个——用户常同时开 4–7 个
        // 会话，原先每项目只看最新 2 个文件，配对率从 12/12 掉到 5/12
        let active = Date().addingTimeInterval(-6 * 3600)
        var out: [(Date, Double?, String?)] = []
        for dir in recent {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
                .compactMap { u -> (URL, Date)? in
                    guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                    return (u, d)
                }.filter { $0.1 > active }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
            for f in jsonl {
                out.append(contentsOf: cachedLines(of: f))
                // 子代理账本：<会话id>/subagents/agent-*.jsonl。Agent 工具跑的每个子代理
                // 各记一份，它们的请求号不进主账本——用户一个会话能开十几个子代理，
                // 只扫主账本时配对率从 12/12 掉到 2/12（09-02 实测）。只看活跃会话的。
                let sub = dir.appendingPathComponent(f.deletingPathExtension().lastPathComponent, isDirectory: true)
                    .appendingPathComponent("subagents", isDirectory: true)
                guard let subs = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                let agents = subs.filter { $0.pathExtension == "jsonl" }
                    .compactMap { u -> (URL, Date)? in
                        guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                        return (u, d)
                    }.filter { $0.1 > active }.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
                for a in agents { out.append(contentsOf: cachedLines(of: a)) }
            }
        }
        return out
    }

    /// 单文件解析缓存：(大小, 修改时间) 没变就复用。用户常同时开好几个会话，
    /// 每次刷新把十几个文件的尾部全重新 JSON 解析一遍，活跃时能吃掉 5% CPU；
    /// 实际每轮只有正在写的那一两个文件变了。
    private static var lineCache: [String: (size: UInt64, mtime: Date, lines: [(Date, Double?, String?)])] = [:]
    private static let cacheLock = NSLock()

    private static func cachedLines(of f: URL) -> [(Date, Double?, String?)] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return [] }
        cacheLock.lock()
        if let c = lineCache[f.path], c.size == size, c.mtime == mtime {
            cacheLock.unlock()
            return c.lines
        }
        cacheLock.unlock()

        var lines: [(Date, Double?, String?)] = []
        // 尾部取 1.2MB：活跃会话一行工具输出就几十 KB，300KB 只够回看两三分钟，
        // 最近 12 次请求有一半配不上。只有带 usage 的行才值得 JSON 解析（其余是
        // 用户消息/工具结果，占九成体积），先用子串筛一遍。
        if let text = tail(f, bytes: 1_200_000) {
            // 尾部全收：曾在这儿「满 limit 就 break」，行序是旧→新，
            // 于是丢的恰好是最新的行——首字/吐字配不上最近的请求
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let msg = o["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let at = parseDate(o["timestamp"] as? String) else { continue }
                let outTok = (usage["output_tokens"] as? Double)
                    ?? (usage["output_tokens"] as? Int).map(Double.init)
                lines.append((at, outTok, o["requestId"] as? String))
            }
        }
        cacheLock.lock()
        lineCache[f.path] = (size, mtime, lines)
        if lineCache.count > 120 { lineCache.removeAll() }   // 会话换代多了别无限长（含子代理文件）
        cacheLock.unlock()
        return lines
    }

    /// 自检用：把两个账本的规模与配对结果摊开。
    static func debug() -> String {
        let turns = recentTurns(limit: 40)
        let idx = ledgerIndex(limit: 240)
        var lines = ["insights 记录 \(turns.count) 条",
                     "账本索引 请求号 \(idx.byReq.count) 个 / 时刻 \(idx.byTime.count) 条"]
        if let t = turns.first { lines.append("最近请求 \(t.model)(\(t.agent)) @ \(t.at) 耗时 \(Int(t.durationMs))ms") }
        var matched = 0
        for t in turns.prefix(12) where t.requestId.map({ idx.byReq[$0] != nil }) == true { matched += 1 }
        lines.append("请求号配上对的 \(matched)/12")
        for s in recentAll().prefix(4) {
            lines.append("\(s.model)\(s.background ? "(后台)" : ""): \(String(format: "%.1fs/轮", s.medianSeconds))"
                + (s.tokensPerSecond.map { String(format: " %.0ftok/s", $0) } ?? "")
                + (s.firstSeconds.map { String(format: " 首字%.1fs", $0) } ?? ""))
        }
        return lines.joined(separator: "\n   ")
    }

    /// 近期在跑的**每个**模型各一份速度（用户点名：多模型要全列出来）。
    /// 排序：对话模型在前、后台自动化在后，各按最近活跃降序。
    static func recentAll(userId: String? = nil) -> [Speed] {
        let turns = recentTurns(limit: 60, userId: userId)
        guard !turns.isEmpty else { return [] }
        let idx = ledgerIndex(limit: 240)

        var byModel: [String: [Turn]] = [:]
        for t in turns { byModel[t.model, default: []].append(t) }

        func median(_ a: [Double]) -> Double? {
            guard a.count >= 3 else { return nil }
            let s = a.sorted()
            return s[s.count / 2]
        }

        var out: [Speed] = []
        for (model, group) in byModel {
            guard let newestAt = group.map(\.at).max() else { continue }
            // 只认与最新一次同一波（45 分钟内）的请求——不然上午一波、
            // 下午一波会被中位到一起，得出一个谁都没跑出来过的速度
            let sample = Array(group.filter { newestAt.timeIntervalSince($0.at) < 45 * 60 }.prefix(12))
            guard !sample.isEmpty else { continue }

            let durations = sample.map { $0.durationMs / 1000 }.sorted()
            var tpsArr: [Double] = []
            var firstArr: [Double] = []
            for t in sample {
                var outTok: Double?
                if let r = t.requestId, let e = idx.byReq[r] {
                    // 精确配对：两边同一个请求号
                    if e.out > 0 { outTok = e.out }
                    let f = e.first.timeIntervalSince(t.at)
                    if f > 0.05, f < t.durationMs / 1000 + 30 { firstArr.append(f) }
                } else {
                    // 老路兜底：按时刻贴——Mirasim 记发出，Claude Code 记落盘，
                    // 按「发出」和「发出＋耗时」两头各试一次
                    let endAt = t.at.addingTimeInterval(t.durationMs / 1000)
                    let hit = idx.byTime.first { abs($0.0.timeIntervalSince(endAt)) < 12 }
                        ?? idx.byTime.first { abs($0.0.timeIntervalSince(t.at)) < 12 }
                    outTok = hit?.1
                }
                if let ot = outTok {
                    let sec = t.durationMs / 1000
                    if sec > 0.2 { tpsArr.append(ot / sec) }
                }
            }

            out.append(Speed(id: model, model: prettyModel(model),
                             medianSeconds: durations[durations.count / 2],
                             tokensPerSecond: median(tpsArr),
                             firstSeconds: median(firstArr),
                             count: sample.count,
                             lastAt: newestAt,
                             background: !sample.contains { $0.agent == "claude" }))
        }
        return out.sorted {
            if $0.background != $1.background { return !$0.background }
            return $0.lastAt > $1.lastAt
        }
    }

    /// 主力模型（对话优先里最近活跃的那个）。
    static func recent(userId: String? = nil) -> Speed? { recentAll(userId: userId).first }

    /// 模型 id 转可读名。厂商与型号名保持英文，中文里混着 `claude-opus-5` 更难读。
    /// 通用解析：`claude-<系列>-<主版本>[-<次版本>][-日期]` → 「系列 主.次」，
    /// 新型号（Fable 5.1、Opus 4.8……）自动认，不必每出一款改一次表——
    /// 曾按前缀硬编码，5.1 被显示成「Fable 5」、4.8 成「Opus 4」。
    private static func prettyModel(_ id: String) -> String {
        var s = id
        let base = id.replacingOccurrences(of: "[1m]", with: "")
        let parts = base.split(separator: "-").map(String.init)
        if parts.first == "claude", parts.count >= 3 {
            let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
            // 只收 1–2 位的纯数字段作版本号；8 位日期戳一律丢掉
            let nums = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }
            if !nums.isEmpty { s = family + " " + nums.joined(separator: ".") }
        } else if base.hasPrefix("gpt-") {
            s = "GPT-" + base.dropFirst(4)
        }
        // 形如 claude-opus-5[1m] 的上下文后缀保留下来，它影响用量
        if id.contains("[1m]"), !s.contains("1M") { s += " · 1M" }
        return s
    }
}
