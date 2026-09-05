import Foundation

/// 账号库里的一条：在 Mirasim 里登录过的一个云端账号。
///
/// `authJSON` 是 `~/.mirasim/setting.json` 里 `auth` 块的原文。Mirasim 写出来的
/// token 已经过设备密钥封装，本程序不解析、不解密、不外发，只在切换时原样写回。
struct SavedAccount: Codable, Identifiable, Equatable {
    var userId: String
    var name: String?
    var plan: String?
    var planExpiry: Date?
    var authJSON: String
    /// 凭据块最近一次更新的时刻（Mirasim 大约每小时刷新一次 token）。
    var capturedAt: Date
    /// 最近一次作为当前账号被看到的时刻。
    var lastSeenAt: Date
    /// 最近一次看到的各窗口用量，切换前先看一眼那边还剩多少。
    var lastWindows: [SavedWindow]

    var id: String { userId }

    /// 凭据块里的到期时刻（access token 的 exp，秒）。过期不等于不能用：Mirasim 会拿 refreshToken 续。
    var tokenExpiry: Date? {
        guard let data = authJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (obj["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp > 1e11 ? exp / 1000 : exp)
    }

    var displayName: String { name ?? String(userId.prefix(12)) }
}

struct SavedWindow: Codable, Equatable {
    var name: String
    var usedPercent: Double
    var resetAt: Date
}

/// 切换进度，面板与菜单都照它显示。
enum SwitchState: Equatable {
    case idle
    case switching(target: String, since: Date, phase: String)
    case done(target: String, at: Date)
    case failed(target: String, message: String, backup: URL?)
    /// 已写入，但限时内没拿到 Mirasim 用上新账号的证据（没有活跃会话时读不到 /v1/limits，帧又可能滞后）。
    case unconfirmed(target: String, backup: URL)

    var busy: Bool { if case .switching = self { return true }; return false }
}

/// 账号库：记住登录过的账号，切换时把选中账号的 `auth` 块写回 setting.json。
///
/// 只做文件这一层：备份 → 原子替换。让 Mirasim 吃到新凭据、以及事后核对，由 Store 负责。
final class AccountVault {
    static let settingURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mirasim/setting.json")

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EduHuan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private static let fileURL = dir.appendingPathComponent("accounts.json")
    private static let backupDir = dir.appendingPathComponent("setting-backups", isDirectory: true)

    private(set) var accounts: [SavedAccount] = []
    private var stamp: (size: UInt64, mtime: Date)?
    private var lastSaveAt = Date.distantPast
    private let lock = NSLock()

    init() { load() }

    // MARK: 读写库文件

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder.iso.decode([SavedAccount].self, from: data) else { return }
        accounts = list
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(accounts) else { return }
        // 凭据文件只许本人读：与 Mirasim 自己的 setting.json 同一保护级别。
        FileManager.default.createFile(atPath: Self.fileURL.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
        lastSaveAt = Date()
    }

    // MARK: 采集

    /// 3 秒一次：setting.json 变了就把当前 auth 块记进库。快照用来补名字、套餐与各窗口用量。
    /// 返回值＝库有没有变化（用于刷新界面）。
    @discardableResult
    func captureIfChanged(snapshot: QuotaSnapshot?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.settingURL.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return false }
        let fileChanged = !(stamp.map { $0.size == size && $0.mtime == mtime } ?? false)
        var changed = false
        if fileChanged {
            stamp = (size, mtime)
            if let auth = Self.readAuth(), let uid = auth["userId"] as? String, !uid.isEmpty,
               let tok = auth["token"] as? String, !tok.isEmpty,
               let json = Self.canonical(auth) {
                let now = Date()
                if let i = accounts.firstIndex(where: { $0.userId == uid }) {
                    if accounts[i].authJSON != json { accounts[i].authJSON = json; accounts[i].capturedAt = now }
                    accounts[i].lastSeenAt = now
                    if let n = auth["name"] as? String, !n.isEmpty { accounts[i].name = n }
                } else {
                    accounts.append(SavedAccount(userId: uid, name: auth["name"] as? String, plan: nil, planExpiry: nil,
                                                 authJSON: json, capturedAt: now, lastSeenAt: now, lastWindows: []))
                }
                changed = true
            }
        }
        // 当前账号的套餐与窗口用量：来自快照，最多一分钟落一次盘
        if let snap = snapshot, let uid = snap.account.userId,
           let i = accounts.firstIndex(where: { $0.userId == uid }) {
            var a = accounts[i]
            if let p = snap.account.plan { a.plan = p }
            if let e = snap.account.planExpiry { a.planExpiry = e }
            if let n = snap.account.name, !n.isEmpty { a.name = n }
            a.lastWindows = snap.windows.map { SavedWindow(name: $0.name, usedPercent: $0.usedPercent, resetAt: $0.resetAt) }
            a.lastSeenAt = Date()
            if a != accounts[i] {
                accounts[i] = a
                if changed || Date().timeIntervalSince(lastSaveAt) > 60 { changed = true }
            }
        }
        if changed { save() }
        return changed
    }

    func remove(userId: String) {
        lock.lock(); defer { lock.unlock() }
        accounts.removeAll { $0.userId == userId }
        save()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        accounts = []
        save()
    }

    /// setting.json 里现在是谁。
    static func currentUserIdOnDisk() -> String? { readAuth()?["userId"] as? String }

    // MARK: 切换（文件层）

    enum SwitchError: LocalizedError {
        case unknownAccount, alreadyCurrent, unreadable, unwritable(String)
        var errorDescription: String? {
            switch self {
            case .unknownAccount: return L("账号库里没有这个账号", "This account is not in the vault")
            case .alreadyCurrent: return L("已经是当前账号", "Already the current account")
            case .unreadable: return L("读不到 ~/.mirasim/setting.json", "Cannot read ~/.mirasim/setting.json")
            case .unwritable(let m): return L("写入 setting.json 失败：", "Failed to write setting.json: ") + m
            }
        }
    }

    /// 把某账号的 auth 块写进 setting.json：先备份整份文件，再原子替换。返回备份路径。
    func writeAuth(of userId: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let target = accounts.first(where: { $0.userId == userId }) else { throw SwitchError.unknownAccount }
        guard let raw = try? Data(contentsOf: Self.settingURL),
              var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { throw SwitchError.unreadable }
        if (root["auth"] as? [String: Any])?["userId"] as? String == userId { throw SwitchError.alreadyCurrent }
        guard let authData = target.authJSON.data(using: .utf8),
              let auth = (try? JSONSerialization.jsonObject(with: authData)) as? [String: Any] else { throw SwitchError.unknownAccount }

        let backup = try Self.backup(raw, from: (root["auth"] as? [String: Any])?["userId"] as? String)
        root["auth"] = auth
        do {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            let tmp = Self.settingURL.deletingLastPathComponent().appendingPathComponent(".setting.json.eduhuan-tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) else {
                throw SwitchError.unwritable("createFile")
            }
            // rename(2) 同目录原子替换：Mirasim 任何时刻读到的都是完整的一份
            guard rename(tmp.path, Self.settingURL.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                throw SwitchError.unwritable(String(cString: strerror(errno)))
            }
        } catch let e as SwitchError { throw e } catch { throw SwitchError.unwritable(error.localizedDescription) }
        // 自己刚写的不算「外部变化」，下一拍别再把它当新采集
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.settingURL.path),
           let size = (attrs[.size] as? NSNumber)?.uint64Value, let mtime = attrs[.modificationDate] as? Date {
            stamp = (size, mtime)
        }
        return backup
    }

    /// 出事时整份还原。
    func restore(backup: URL) throws {
        let data = try Data(contentsOf: backup)
        let tmp = Self.settingURL.deletingLastPathComponent().appendingPathComponent(".setting.json.eduhuan-tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, Self.settingURL.path) == 0 else { throw SwitchError.unwritable("restore") }
    }

    func latestBackup() -> URL? { Self.backups().first }

    static func backups() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backupDir.path) else { return [] }
        return names.filter { $0.hasPrefix("setting-") && $0.hasSuffix(".json") }.sorted(by: >)
            .map { backupDir.appendingPathComponent($0) }
    }

    private static func backup(_ data: Data, from userId: String?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = backupDir.appendingPathComponent("setting-\(f.string(from: Date()))-\((userId ?? "unknown").prefix(12)).json")
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SwitchError.unwritable("backup")
        }
        // 只留最近 12 份
        for old in backups().dropFirst(12) { try? fm.removeItem(at: old) }
        return url
    }

    // MARK: 工具

    private static func readAuth() -> [String: Any]? {
        guard let raw = try? Data(contentsOf: settingURL),
              let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        return root["auth"] as? [String: Any]
    }

    /// 键排序后的紧凑 JSON，便于比较「凭据块有没有变」。
    private static func canonical(_ obj: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
