import Foundation

/// `/v1/limits` 的返回。这是**上游权威值**：`used` / `budget` 是原始额度点，
/// 百分比即两者相除，不经任何折算或标定。面板上「精确」一档就是它。
struct LimitsPayload {
    let subject: String
    let windows: [QuotaWindow]
    let suspended: Bool
    let unmetered: Bool
    let degraded: Bool
    let paid: Bool
}

/// 读取会话回环端口上的 `/v1/limits`。
///
/// 该端点未公开文档化，早期版本对本机连接免认证，现行版本按普通 API 请求鉴权，
/// 缺 `x-api-key` 回 401。令牌由 `SessionScanner` 按进程配对取得。
final class LimitsClient {
    private let session: URLSession
    /// 上一次成功的路由。会话通常不变，先试它，省掉每轮全量扫进程。
    private var cachedRoute: SessionRoute?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        // 额度是每次都要新的，任何一层缓存都会让面板显示过期数字
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: cfg)
    }

    /// 取一次精确额度。
    ///
    /// - Parameter expectedUserId: relay 帧里的 `login.userId`。同时跑着开发实例时，
    ///   端口枚举可能读到另一个账号的额度；`subject` 与它不一致的结果一律弃用，
    ///   宁可降级到 0.1% 的帧口径，也不能把别人的额度显示成你的。
    func fetch(expectedUserId: String?) -> LimitsPayload? {
        var candidates = SessionScanner.routes()
        if let c = cachedRoute, let i = candidates.firstIndex(of: c) {
            candidates.remove(at: i)
            candidates.insert(c, at: 0)
        }
        for route in candidates {
            guard let payload = request(route) else { continue }
            if let want = expectedUserId, !want.isEmpty, payload.subject != want {
                continue   // 读到别的账号了，换下一个候选
            }
            cachedRoute = route
            return payload
        }
        cachedRoute = nil
        return nil
    }

    private func request(_ route: SessionRoute) -> LimitsPayload? {
        guard let url = URL(string: "\(route.base)/v1/limits") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(route.token, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "accept")

        var out: Data?
        var code = 0
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, _ in
            out = data
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        // 不能无限等：会话正在退出时端口可能连得上却不回话
        guard sem.wait(timeout: .now() + 8) == .success, code == 200, let data = out else { return nil }
        return parse(data)
    }

    private func parse(_ data: Data) -> LimitsPayload? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let subject = root["subject"] as? String,
              let raw = root["windows"] as? [[String: Any]] else { return nil }

        let now = Date()
        var windows: [QuotaWindow] = []
        for w in raw {
            guard let name = w["name"] as? String else { continue }
            let used = num(w["used"])
            let budget = num(w["budget"])
            // 预算为 0 的窗口算不出百分比，直接跳过，不落一个 NaN 到界面上
            guard let used, let budget, budget > 0 else { continue }
            let resetAt = (num(w["reset_at"])).map { Date(timeIntervalSince1970: $0) } ?? now
            windows.append(QuotaWindow(
                name: name,
                usedPoints: used,
                budgetPoints: budget,
                // 上游可以超发（实测 7d_fable 到过 100.05%），这里不夹到 100，
                // 让面板如实显示「已超」，但进度条渲染时另行夹取
                usedPercent: used / budget * 100,
                resetAt: resetAt,
                modelScoped: (w["model_scoped"] as? Bool) ?? false,
                upstreamStatus: w["status"] as? String,
                precision: .exact
            ))
        }
        guard !windows.isEmpty else { return nil }
        return LimitsPayload(
            subject: subject,
            windows: windows,
            suspended: (root["suspended"] as? Bool) ?? false,
            unmetered: (root["unmetered"] as? Bool) ?? false,
            degraded: (root["degraded"] as? Bool) ?? false,
            paid: (root["paid"] as? Bool) ?? false
        )
    }

    /// 数值解析放宽到 Double/Int/String 三种写法，上游换类型不至于整份失效。
    private func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
