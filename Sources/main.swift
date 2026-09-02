import AppKit
import ServiceManagement

// 命令行模式（渲染/自检）不落盘：防与正在跑的正式实例并发写账本
if CommandLine.arguments.contains(where: { ["--render", "--render-capsule", "--render-icons", "--diag"].contains($0) }) {
    CostLedger.readOnly = true
}

// 离屏渲染模式：--render <路径> [--light] [--detail] [--wait 秒]
// 用于在没有屏幕录制权限的机器上核对版面，走的是与运行时同一份视图与数据。
if let i = CommandLine.arguments.firstIndex(of: "--render"),
   i + 1 < CommandLine.arguments.count {
    let args = CommandLine.arguments
    let path = args[i + 1]
    let wait = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 12
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Preview.render(to: path,
                   dark: !args.contains("--light"),
                   expandDetail: args.contains("--detail"),
                   waitForData: wait)
    exit(0)
}

// 菜单栏图标预览：--render-icons <路径> [--light]
if let i = CommandLine.arguments.firstIndex(of: "--render-icons"),
   i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Preview.renderIcons(to: CommandLine.arguments[i + 1],
                        dark: !CommandLine.arguments.contains("--light"))
    exit(0)
}

// 开机自启开关：--login on|off|status
if let i = CommandLine.arguments.firstIndex(of: "--login") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
    if #available(macOS 13.0, *) {
        let svc = SMAppService.mainApp
        do {
            switch arg {
            case "on":  if svc.status != .enabled { try svc.register() }
            case "off": if svc.status == .enabled { try svc.unregister() }
            default: break
            }
        } catch {
            print("开机自启设置失败：\(error.localizedDescription)")
            exit(1)
        }
        let label: String
        switch svc.status {
        case .enabled: label = "已开启"
        case .requiresApproval: label = "待在「系统设置 › 通用 › 登录项」中批准"
        case .notFound: label = "未注册"
        default: label = "未开启"
        }
        print("开机自启：\(label)")
    } else {
        print("需要 macOS 13 及以上")
    }
    exit(0)
}

// 胶囊预览：--render-capsule <路径>
if let i = CommandLine.arguments.firstIndex(of: "--render-capsule"),
   i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Preview.renderCapsule(to: CommandLine.arguments[i + 1],
                          dark: !CommandLine.arguments.contains("--light"),
                          waitForData: 12)
    exit(0)
}

// 自检模式：--diag
if CommandLine.arguments.contains("--diag") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Diagnose.run(seconds: 12)
    exit(0)
}

// 单实例：菜单栏上出现两枚一样的环，既难看也会让两份采样互相打架。
let bundleId = Bundle.main.bundleIdentifier ?? "local.eduhuan"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    // 已经有一个在跑，把它叫到前台后自己退出
    others.first?.activate(options: [])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
