import Foundation

/// 每点单价的在线标定，按账号各一份。**角色＝回退口径**：
/// 窗口完整落在本机服役期内时，Store 直接用「本窗实花 ÷ 已用百分比」逆推
/// 整窗（用户口径，天生自洽），不经这里；只有窗口里混着本机没见过的
/// 存量点（切号初期、装机早期）才用这里的单价。
///
/// 用户发现的病根：整窗美元曾无条件用「窗口累计花费 ÷ 窗口累计点数」——
/// 切到新账号后，窗口里的存量 used 点稀释分母（那些点对应的钱不在本机账本里），
/// 单价被压低好几倍，整窗额度跟着虚低（5 小时窗口一度显示 ≈$83，真值 ≈$300+）。
///
/// 这里的打法＝**增量反推**：从「本机第一次读到该账号精确点数」那一刻立锚，
/// 单价 = 锚点以来本机真实成本 ÷ 锚点以来点数增量。锚点前的存量一概不碰。
/// 窗口滚动（重置时刻变了）就结算旧段进累计、在新窗口重新立锚，跨窗累加，
/// 越用越准。只用 7d 窗口做标定：点数最多、噪声最小，且不是模型档位窗口。
///
/// 点是全窗口统一的计量单位（每点美元是价目属性，不随窗口变——
/// 5h/7d/Fable 的点同单位），所以一份单价配所有窗口的预算点。
final class Calibrator {

    struct Obs: Codable {
        let t: Date
        let p: Double
    }

    struct AccountCalib: Codable {
        /// 近 6 小时的点数观测序列。单价优先按它的首尾差算——
        /// 「按当前用法」的口径（用户拍板）：会话形态一变（缓存占比、模型），
        /// 每点等效美元跟着漂（实测 44 分钟能漂 23%），全历史平均会拖尾。
        var recent: [Obs] = []
        /// 已结算窗口段的累计（点数增量、对应成本）。
        var cumPoints: Double = 0
        var cumUSD: Double = 0
        /// 当前窗口段的锚：立锚时的点数、时刻、以及窗口的重置时刻（识别滚动）。
        var anchorPoints: Double?
        var anchorAt: Date?
        var anchorReset: Date?
        /// 当前窗口段最后一次看到的点数（滚动时用它结算）。
        var lastPoints: Double?
        var lastAt: Date?
    }

    private var states: [String: AccountCalib] = [:]

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EduHuan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("calib.json")
    }()

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        states = (try? dec.decode([String: AccountCalib].self, from: data)) ?? [:]
    }

    private func save() {
        guard !CostLedger.readOnly else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(states) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// 每次拿到精确口径的快照喂进来。主线程调用。
    func observe(userId: String, sevenDayUsedPoints used: Double,
                 resetAt: Date, windowStart: Date?, ledger: CostLedger) {
        var st = states[userId] ?? AccountCalib()
        let now = Date()

        let rolled = st.anchorReset.map { abs($0.timeIntervalSince(resetAt)) > 1 } ?? true
        let wentBackwards = st.lastPoints.map { used + 1 < $0 } ?? false

        if rolled || wentBackwards {
            // 结算旧窗口段：最后读数 − 锚点 ＝ 本段点增量；同时段本机成本进累计
            if let ap = st.anchorPoints, let at = st.anchorAt,
               let lp = st.lastPoints, let la = st.lastAt, lp > ap {
                let (usd, _) = ledger.spent(since: at, until: la.addingTimeInterval(60), userId: userId)
                if usd > 0 {
                    st.cumPoints += lp - ap
                    st.cumUSD += usd
                }
            }
            // 立锚。窗口起点若晚于 Mirasim 在本机的服役起点，整个窗口的
            // 用量都产生在本机眼皮底下——锚直接立在窗口起点（0 点），
            // 把这段干净历史整段收编，新账号装上即收敛，不必从零重攒。
            if let ws = windowStart, let ss = ledger.serviceStart, ws >= ss {
                st.anchorPoints = 0
                st.anchorAt = ws
            } else {
                st.anchorPoints = used
                st.anchorAt = now
            }
            st.anchorReset = resetAt
            st.recent = []   // 窗口滚动，旧窗口的点数不可续用
        }
        // 锚升级：之前因时序没拿到服役起点、把锚立在了当时读数上，
        // 而这个窗口起点明明晚于服役起点（整窗数据都干净）——一次性
        // 把锚搬回窗口起点，把锚点前那段白白跳过的历史收编回来。幂等。
        if let ap = st.anchorPoints, ap > 0,
           let ws = windowStart, let ss = ledger.serviceStart, ws >= ss,
           st.anchorReset.map({ abs($0.timeIntervalSince(resetAt)) <= 1 }) == true {
            st.anchorPoints = 0
            st.anchorAt = ws
        }

        st.lastPoints = used
        st.lastAt = now
        // 近期观测入列，只留 6 小时、封顶 600 条
        st.recent.append(Obs(t: now, p: used))
        let cutoff = now.addingTimeInterval(-6 * 3600)
        if st.recent.first.map({ $0.t < cutoff }) == true {
            st.recent.removeAll { $0.t < cutoff }
        }
        if st.recent.count > 600 { st.recent.removeFirst(st.recent.count - 600) }
        states[userId] = st
        save()
    }

    /// 该账号的每点单价。累计增量不足 12,000 点时不给数——
    /// 成本入账滞后于点数记账（请求完成才落盘），小样本上滞后占比
    /// 能到几成，单价被系统性压低；1.2 万点起误差压到 ~10% 以内，
    /// 且随累计继续收敛。宁缺勿假。
    func perPointUSD(userId: String, ledger: CostLedger) -> Double? {
        guard let st = states[userId] else { return nil }

        // 首选「按当前用法」：近 6 小时观测的首尾差。整窗值会随用法呼吸，
        // 这正是想要的——它回答的是「照现在这么用，还能干多少活」。
        if let f = st.recent.first, let l = st.recent.last, l.p - f.p >= 12_000 {
            let usd = ledger.spent(since: f.t, userId: userId).usd
            if usd > 0 { return usd / (l.p - f.p) }
        }

        // 近期量不足（轻度使用）退回长基线：锚点以来的全历史累计
        var points = st.cumPoints
        var usd = st.cumUSD
        if let ap = st.anchorPoints, let at = st.anchorAt, let lp = st.lastPoints, lp > ap {
            points += lp - ap
            usd += ledger.spent(since: at, userId: userId).usd
        }
        guard points >= 12_000, usd > 0 else { return nil }
        return usd / points
    }

    /// 标定进度（给界面提示「标定中」用）：0–1。
    func progress(userId: String) -> Double {
        guard let st = states[userId] else { return 0 }
        var points = st.cumPoints
        if let ap = st.anchorPoints, let lp = st.lastPoints, lp > ap { points += lp - ap }
        return min(1, points / 12_000)
    }
}
