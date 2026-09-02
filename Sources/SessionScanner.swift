import Foundation

/// Mirasim 为每个受管会话分配的回环路由：基址 + 该基址的令牌。
/// 基址必须整段保留——新版 Mirasim 在 URL 里带路径密钥
/// （`http://127.0.0.1:<端口>/<密钥>`），只抠端口去打 `/v1/limits` 是 401。
struct SessionRoute: Equatable, Hashable {
    /// `ANTHROPIC_BASE_URL` 原样（已去尾部斜杠），含路径密钥（若有）。
    let base: String
    let token: String

    /// 端口，仅用于自检展示。
    var port: Int {
        guard let r = base.range(of: "127.0.0.1:") else { return 0 }
        return Int(base[r.upperBound...].prefix(while: \.isNumber)) ?? 0
    }
}

/// 从进程表里捞出会话路由。
///
/// `/v1/limits` 挂在 Mirasim 给每个会话开的回环端口上，令牌不落盘，
/// 只存在于会话进程的环境里。同一进程的 `ANTHROPIC_BASE_URL` 指向哪个端口，
/// `ANTHROPIC_AUTH_TOKEN` 就是该端口的令牌——按进程配对，不能跨进程拼。
enum SessionScanner {

    /// 必须显式给 `-U`：不给用户选择符时，`ps` 只列「同用户且同控制终端」的进程，
    /// 而 LaunchAgent 没有控制终端，结果会是空的。实测无 `-U` 只见 1 个进程、
    /// 带 `-U` 见到 5 个。
    private static func processLines() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["eww", "-U", String(getuid()), "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }

        // 先读干净再 wait：ps 的输出可能撑满管道缓冲，先 wait 会双方僵住。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        // 必须宽松解码。进程表里只要有**任何一个**进程的命令行带非 UTF-8 字节
        // （别家程序的参数里塞了 Latin-1 之类），`String(data:encoding:.utf8)`
        // 就整份返回 nil，扫描结果变空，界面于是显示「Mirasim 未运行」——
        // 而 Mirasim 明明开着。实测同一个二进制反复运行时好时坏，
        // 取决于当时碰巧有什么别的进程在跑，极难复现。
        // `String(decoding:as:)` 把坏字节换成 U+FFFD，其余行照常可用。
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    /// 环境变量与 `--settings` JSON 两种写法都要认：Mirasim 拉起会话时，
    /// 同一组取值既出现在进程环境里（`K=V`），也出现在命令行的 JSON 里（`"K":"V"`）。
    private static func value(of key: String, in line: String) -> String? {
        // 形如  KEY=value  （到空白为止）
        if let r = line.range(of: "\(key)=") {
            let rest = line[r.upperBound...]
            let v = rest.prefix(while: { !$0.isWhitespace })
            if !v.isEmpty { return String(v) }
        }
        // 形如  "KEY":"value"
        if let r = line.range(of: "\"\(key)\":\"") {
            let rest = line[r.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                let v = rest[rest.startIndex..<end]
                if !v.isEmpty { return String(v) }
            }
        }
        return nil
    }

    private static func port(fromBaseURL s: String) -> Int? {
        guard let r = s.range(of: "127.0.0.1:") else { return nil }
        let digits = s[r.upperBound...].prefix(while: \.isNumber)
        return Int(digits)
    }

    /// 当前所有可用的会话路由，按进程配对。
    static func routes() -> [SessionRoute] {
        var seen = Set<SessionRoute>()
        var out: [SessionRoute] = []
        for line in processLines() {
            guard var base = value(of: "ANTHROPIC_BASE_URL", in: line),
                  let token = value(of: "ANTHROPIC_AUTH_TOKEN", in: line),
                  !token.isEmpty,
                  base.hasPrefix("http"), port(fromBaseURL: base) != nil else { continue }
            while base.hasSuffix("/") { base.removeLast() }
            let r = SessionRoute(base: base, token: token)
            if seen.insert(r).inserted { out.append(r) }
        }
        return out
    }

    /// Mirasim 主服务端口（mirachannel 挂在这儿）。
    /// 会话进程的环境里带 `MIRASIM_EVAL_VIEWER=http://127.0.0.1:<port>`，
    /// 据此自动发现，避免把 4970 写死——用户改过端口就再也连不上。
    static func discoverHostPort() -> Int? {
        for line in processLines() {
            if let v = value(of: "MIRASIM_EVAL_VIEWER", in: line), let p = port(fromBaseURL: v) {
                return p
            }
        }
        // 退路：命令行里的 `server.cjs serve --port <n>`
        for line in processLines() where line.contains("server.cjs") {
            if let r = line.range(of: "--port ") {
                let digits = line[r.upperBound...].prefix(while: \.isNumber)
                if let p = Int(digits) { return p }
            }
        }
        return nil
    }

    /// 自检用：报告进程表扫描的原始规模。
    static func debugLineCount() -> (lines: Int, mira: Int, token: Int) {
        let l = processLines()
        return (l.count,
                l.filter { $0.contains("/Applications/Mirasim.app/") }.count,
                l.filter { $0.contains("ANTHROPIC_AUTH_TOKEN") }.count)
    }

    /// 自检用：把 ps 的退出码与 stderr 原样报出来，区分「exec 被拦」与「读取被拦」。
    static func debugRawPS() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["eww", "-U", String(getuid()), "-o", "command="]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return "run 抛错: \(error)" }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let etxt = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return "退出码 \(p.terminationStatus), stdout \(o.count) 字节, stderr: \(etxt.isEmpty ? "(空)" : etxt)"
    }

    /// Mirasim 是否在运行。用于把「Mirasim 没开」与「开着但读不到」分开报。
    static func mirasimRunning() -> Bool {
        processLines().contains { $0.contains("/Applications/Mirasim.app/") || $0.contains("server.cjs") }
    }
}
