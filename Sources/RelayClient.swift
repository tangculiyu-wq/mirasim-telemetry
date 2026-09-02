import Foundation

enum RelayEvent {
    case snapshot(QuotaSnapshot)
    /// 连不上，附原因。等着重连即可。
    case unreachable(String)
    /// Mirasim 进程不在。与「连不上」分开报：这一路已在后台队列查过进程表，
    /// 主线程不必再起一次 ps。
    case noMirasim
    /// 连上了但帧看不懂。说明上游可能改了协议，得让人看见，
    /// 而不是静默滑向「没有数据」。
    case mismatch(String)
}

/// Mirasim 本地通道客户端。
///
/// 额度百分比不落盘、只在 Mirasim 进程内存里，但它的 mirachannel WebSocket
/// 对本机连接放行读操作：`{type:"host", payload:{type:"getRelay"}}` 帧回传 relay 状态，
/// 其中 `usage.windows` 就是界面上那几个百分比，`source` 实测为 `relay-limits`
/// ——与 `/v1/limits` 同源，只是被四舍五入到 0.1%。故这一路同样是**真值**，
/// 不是推算，只是分辨率低一档。
///
/// 相对 `/v1/limits` 的好处是免认证、且挂在常驻的主服务端口上：
/// 没有任何活跃会话时它照样可读。
final class RelayClient: NSObject {
    private let queue = DispatchQueue(label: "eduhuan.relay")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pollTimer: DispatchSourceTimer?
    private var reconnectDelay: TimeInterval = 1
    private var stopped = false
    private var port: Int
    private let portLock = NSLock()
    /// 连着但连续几轮解析不出快照的计数，用来上报静默的协议变化。
    private var pollsSinceSnapshot = 0
    private var mismatchReported = false

    var onEvent: ((RelayEvent) -> Void)?

    /// 最近一帧里的账号标识，交给 LimitsClient 做同账号校验。
    private(set) var lastUserId: String?

    var currentPort: Int {
        portLock.lock(); defer { portLock.unlock() }
        return port
    }

    init(port: Int? = nil) {
        self.port = port ?? 4970
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    func start() { queue.async { [weak self] in self?.attach() } }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pollTimer?.cancel(); self.pollTimer = nil
            self.task?.cancel(with: .goingAway, reason: nil); self.task = nil
        }
    }

    /// 立刻要一次新数据。`fresh` 让 Mirasim 绕过自己的缓存重新问 relay。
    func poll(fresh: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.task == nil { self.attach() } else { self.requestRelay(fresh: fresh) }
        }
    }

    // MARK: 连接

    private func attach() {
        guard !stopped else { return }
        // 已有连接就不再建。退避期内用户点开面板会走 poll() 立刻 attach，
        // 之前调度的延时 attach 随后到达；不挡住会叠出第二条连接，且旧的永不取消。
        guard task == nil else { return }

        guard SessionScanner.mirasimRunning() else {
            onEvent?(.noMirasim)
            scheduleReconnect()
            return
        }
        if let found = SessionScanner.discoverHostPort() {
            portLock.lock(); port = found; portLock.unlock()
        }
        connect()
    }

    private func connect() {
        guard !stopped, let url = URL(string: "ws://127.0.0.1:\(currentPort)/mirachannel/ws") else { return }
        let t = session.webSocketTask(with: url)
        task = t
        pollsSinceSnapshot = 0
        t.resume()
        send(["type": "hello", "v": 1, "client": ["name": "eduhuan", "platform": "macos"]])
        requestRelay()
        listen()
        startPolling()
    }

    private func startPolling() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self, self.task != nil else { return }
            self.requestRelay()
            // 连接活着、也一直在要数据，却始终解析不出快照——多半是帧类型或键名
            // 整体改了名。不上报就会静默滑向「没有数据」，界面上看不出原因。
            self.pollsSinceSnapshot += 1
            if self.pollsSinceSnapshot >= 4, !self.mismatchReported {
                self.mismatchReported = true
                self.onEvent?(.mismatch("已连上 Mirasim，但读不懂额度帧（上游协议可能已变）"))
            }
        }
        t.resume()
        pollTimer = t
    }

    private func requestRelay(fresh: Bool = false) {
        var payload: [String: Any] = ["type": "getRelay"]
        if fresh { payload["fresh"] = true }
        send(["type": "host", "payload": payload])
    }

    private func send(_ obj: [String: Any]) {
        guard let t = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        t.send(.string(s)) { [weak self] err in
            guard let self, err != nil else { return }
            self.queue.async { self.dropAndReconnect() }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure:
                    self.dropAndReconnect()
                case .success(let msg):
                    switch msg {
                    case .string(let s): self.handle(s)
                    case .data(let d): self.handle(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: break
                    }
                    guard !self.stopped else { return }
                    self.listen()
                }
            }
        }
    }

    private func dropAndReconnect() {
        pollTimer?.cancel(); pollTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard !stopped else { return }
        onEvent?(.unreachable("与 Mirasim 的连接已断开"))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.attach() }
    }

    // MARK: 解析

    /// 解析刻意宽松：键名按候选逐个试，数值接受 Double/Int/String。
    /// 上游小幅调整字段命名不至于整份失效。
    private func handle(_ text: String) {
        guard text.contains("usage") || text.contains("relay") else { return }
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        // 帧形状：{type:"host", payload:{type:"relay", relay:{...}}}
        let payload = (root["payload"] as? [String: Any]) ?? root
        guard let relay = (payload["relay"] as? [String: Any]) ?? (root["relay"] as? [String: Any]) else { return }

        let login = relay["login"] as? [String: Any]
        let userId = login?["userId"] as? String
        if let userId { lastUserId = userId }

        guard let usage = relay["usage"] as? [String: Any],
              let rawWindows = usage["windows"] as? [[String: Any]], !rawWindows.isEmpty else { return }

        var windows: [QuotaWindow] = []
        for w in rawWindows {
            guard let label = (w["label"] as? String) ?? (w["name"] as? String) else { continue }
            guard let used = num(w["usedPercent"]) ?? num(w["used_percent"]) else { continue }
            let reset = date(w["resetAt"]) ?? date(w["reset_at"])
                ?? num(w["resetAfterSeconds"]).map { Date().addingTimeInterval($0) }
            guard let reset else { continue }
            windows.append(QuotaWindow(
                name: label,
                usedPoints: nil,
                budgetPoints: nil,
                usedPercent: used,
                resetAt: reset,
                modelScoped: (w["modelScoped"] as? Bool) ?? (w["model_scoped"] as? Bool) ?? false,
                upstreamStatus: w["status"] as? String,
                precision: .coarse
            ))
        }
        guard !windows.isEmpty else { return }

        let referral = relay["referral"] as? [String: Any]
        let account = AccountInfo(
            userId: userId,
            name: login?["name"] as? String,
            email: login?["email"] as? String,
            plan: (login?["plan"] as? String) ?? (referral?["currentPlan"] as? String),
            planExpiry: num(login?["planExp"]).map { Date(timeIntervalSince1970: $0) },
            paid: relay["paid"] as? Bool,
            relayStatus: relay["relayStatus"] as? String,
            host: relay["host"] as? String
        )

        let captured = date(usage["capturedAt"]) ?? Date()
        pollsSinceSnapshot = 0
        mismatchReported = false
        reconnectDelay = 1

        onEvent?(.snapshot(QuotaSnapshot(
            windows: windows,
            account: account,
            capturedAt: captured,
            receivedAt: Date(),
            precision: .coarse
        )))
    }

    private func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// ISO8601（带或不带小数秒）与 unix 秒两种写法都认。
    private func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
        }
        if let n = num(v) {
            // 毫秒与秒都可能，按量级判
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        return nil
    }
}
