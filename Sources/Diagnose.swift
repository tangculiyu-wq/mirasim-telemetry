import Foundation
import AppKit

/// 自检。逐层报告每个数据来源通不通，用来把「读不到」定位到具体某一环，
/// 而不是笼统地显示一个「连接失败」。
enum Diagnose {

    static func run(seconds: TimeInterval) {
        var out: [String] = []
        func say(_ s: String) { out.append(s); print(s) }

        say("── Mirasim 遥测 自检 ──")

        let raw = SessionScanner.debugLineCount()
        say("进程表：\(raw.lines) 行，含 Mirasim \(raw.mira) 行，含令牌 \(raw.token) 行")
        if raw.lines == 0 {
            // 扫不到进程时才把底层情况摊开，平时不占版面
            say("   ⚠️ \(SessionScanner.debugRawPS())")
        }

        // 1. 进程层
        let running = SessionScanner.mirasimRunning()
        say("Mirasim 进程：\(running ? "在运行" : "未发现")")

        let hostPort = SessionScanner.discoverHostPort()
        say("主服务端口：\(hostPort.map(String.init) ?? "未发现")")

        let routes = SessionScanner.routes()
        say("会话路由：\(routes.count) 条" + (routes.isEmpty
            ? "（没有活跃会话，精确口径不可用，将走 0.1% 帧口径）"
            : "（端口 " + routes.map { String($0.port) }.joined(separator: ", ") + "）"))

        // 2. 精确源
        let limits = LimitsClient()
        if let payload = limits.fetch(expectedUserId: nil) {
            say("/v1/limits：可读，账号 \(payload.subject)")
            for w in payload.windows {
                let pct = (w.usedPoints ?? 0) / (w.budgetPoints ?? 1) * 100
                say(String(format: "   %-9@ %.4f%%  (%@ / %@ 点)  重置 %@",
                           w.name as NSString, pct,
                           Fmt.points(w.usedPoints ?? 0), Fmt.points(w.budgetPoints ?? 0),
                           Fmt.clock(w.resetAt)))
            }
        } else {
            say("/v1/limits：读不到" + (routes.isEmpty ? "（无会话，属正常）" : "（有会话却读不到，值得注意）"))
        }

        // 3. 帧源
        say("mirachannel：连接中…")
        let relay = RelayClient()
        var got: QuotaSnapshot?
        var lastError: String?
        relay.onEvent = { ev in
            switch ev {
            case .snapshot(let s): if got == nil { got = s }
            case .unreachable(let e): lastError = e
            case .noMirasim: lastError = "Mirasim 未运行"
            case .mismatch(let e): lastError = "帧看不懂：" + e
            }
        }
        relay.start()
        let deadline = Date().addingTimeInterval(seconds)
        while got == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        }
        relay.stop()

        if let s = got {
            say("mirachannel：可读，上游采集于 \(Fmt.clock(s.capturedAt))")
            for w in s.windows {
                say(String(format: "   %-9@ %.1f%%  重置 %@",
                           w.name as NSString, w.usedPercent, Fmt.clock(w.resetAt)))
            }
            say("账号：\(s.account.name ?? "?") · 套餐 \((s.account.plan ?? "?").uppercased())"
                + (s.account.planExpiry.map { " · 到期 \(Fmt.day($0))" } ?? ""))
        } else {
            say("mirachannel：读不到 — \(lastError ?? "超时")")
        }

        // 4. 交叉校验。两路都在时，差值应当只来自帧口径的四舍五入。
        if let s = got, let payload = limits.fetch(expectedUserId: s.account.userId) {
            var worst = 0.0
            var worstName = ""
            for e in payload.windows {
                guard let c = s.windows.first(where: { $0.name == e.name }) else { continue }
                // 用超的窗口先对齐：帧把 usedPercent 封顶在 100，精确源如实给 100.86%
                let d = abs(min(c.usedPercent, 100) - min(e.usedPercent, 100))
                if d > worst { worst = d; worstName = e.name }
            }
            let verdict = worst <= 0.35 ? "一致" : "偏差偏大，需留意"
            say(String(format: "交叉校验：最大差 %.3f 个百分点（%@）— %@", worst, worstName as NSString, verdict))
            if payload.subject != s.account.userId {
                say("⚠️ 两路账号不一致：limits=\(payload.subject) frame=\(s.account.userId ?? "?")")
            }
        }

        // 5. 账本：价目探针 + 今日汇总（与独立脚本对数用）
        let ledger = CostLedger()
        ledger.refresh()
        say("价目探针：")
        for (p, m) in [("anthropic", "claude-fable-5-1"), ("anthropic", "claude-fable-5"),
                       ("anthropic", "claude-opus-4-8"), ("openai-responses", "gpt-5.6-luna"),
                       ("openai-responses", "gpt-5.6-terra"), ("openai-chat", "deepseek-v4-flash")] {
            say("   \(p)/\(m) → \(ledger.debugRate(provider: p, model: m))")
        }
        let uid = got?.account.userId
        let midnight = Calendar.current.startOfDay(for: Date())
        let today = ledger.spent(since: midnight, userId: uid)
        let gap = ledger.backfillGap(since: Date().addingTimeInterval(-86400), userId: uid)
        say(String(format: "账本：今日 $%.2f / %d 次（账号 %@）；近 24h 已计价 %d、未回填 %d",
                   today.usd, today.count, (uid ?? "全部") as NSString, gap.metered, gap.unmetered))
        // 等价换算要精确口径的点数，帧源没有，再拉一次 /v1/limits
        if let s = got, let payload = limits.fetch(expectedUserId: s.account.userId),
           let w7 = payload.windows.first(where: { $0.name == "7d" }), let b = w7.budgetPoints {
            let eq = Store.equivalentRates(windows: payload.windows, uid: uid, ledger: ledger, persist: false)
            func f(_ p: Double?) -> String { p.map { String(format: "$%.5f/点 → 全窗 $%.0f", $0, $0 * b) } ?? "样本不足" }
            say("等价换算（7d 预算 \(Int(b)) 点）：普通模型 \(f(eq.regular))；Fable 5.1 \(f(eq.fable))")
            for w in payload.windows where w.modelGroup == nil {
                let c = ledger.spent(since: w.windowStart ?? Date(), modelGroup: "claude", userId: uid).usd
                let a = ledger.spent(since: w.windowStart ?? Date(), userId: uid).usd
                say(String(format: "   %@ 窗内 Claude 系 $%.2f / 含 GPT 等全部 $%.2f", w.name as NSString, c, a))
            }
        }

        let sess = ledger.sessions(activeSince: Date().addingTimeInterval(-6 * 3600), userId: uid, limit: 5)
        let vault = AccountVault()
        say("账号库：\(vault.accounts.count) 个" + (vault.accounts.isEmpty ? "（在 Mirasim 里登录过的账号会自动记住）" : "")
            + " · setting.json 当前 \(AccountVault.currentUserIdOnDisk().map { String($0.prefix(12)) + "…" } ?? "?") · 备份 \(AccountVault.backups().count) 份")
        for a in vault.accounts {
            let wins = a.lastWindows.map { "\($0.name) \(String(format: "%.1f", $0.usedPercent))%" }.joined(separator: " ")
            say("  \(a.displayName) · \(a.userId.prefix(12))… · 套餐 \(a.plan ?? "?") · 凭据更新 \(Fmt.clock(a.capturedAt)) · token 到期 \(a.tokenExpiry.map(Fmt.clock) ?? "?") · 最近在线 \(Fmt.ago(Date().timeIntervalSince(a.lastSeenAt)))" + (wins.isEmpty ? "" : " · " + wins))
        }
        say("会话（近 6 小时活跃，整个会话累计）：\(sess.count) 个")
        for s in sess {
            let title = SessionTitles.title(session: s.id, workspace: s.workspace) ?? String(s.id.prefix(8))
            let repo = (s.workspace as NSString?)?.lastPathComponent ?? "?"
            let pend = s.pending > 0 ? "（\(s.pending) 待回填）" : ""
            say("   \(title) · \(repo) · \(Fmt.tokens(s.tokens)) tok · $\(String(format: "%.2f", s.usd)) · \(s.calls) 次\(pend)")
        }
        let rs = ledger.requestStats(since: Date().addingTimeInterval(-3600), userId: uid)
        let codes = rs.codes.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        say("近 1 小时请求：成功 \(rs.ok) · 失败 \(rs.failed)\(codes.isEmpty ? "" : "（\(codes)）")\(rs.rateLimited.isEmpty ? "" : " · 限流 " + rs.rateLimited.joined(separator: ","))")
        say("速度（本机实测）：\(SpeedStats.debug())")
        say("──────────────")
    }
}
