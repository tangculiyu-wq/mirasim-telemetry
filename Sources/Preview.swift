import AppKit
import SwiftUI

/// 离屏渲染面板为 PNG。
///
/// 本机没有屏幕录制权限，`screencapture` 取不到画面，故走这条纯离屏的路
/// 来核对版面。用的是与运行时同一份视图代码和同一份真实数据，
/// 不是另画一张示意图。
enum Preview {

    /// 把菜单栏图标按几档用量并排画出来，核对配色与可读性。
    /// 菜单栏本身截不到（无屏幕录制权限），只能这样看。
    static func renderIcons(to path: String, dark: Bool) {
        let samples: [(Double, Bool)] = [(0.01, false), (0.25, false), (0.5, false),
                                         (0.7, false), (0.85, false), (1.0, false), (0.6, true)]
        let cell = NSSize(width: 62, height: 30)
        let canvas = NSView(frame: NSRect(x: 0, y: 0,
                                          width: cell.width * CGFloat(samples.count),
                                          height: cell.height))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = dark
            ? NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
            : NSColor(calibratedWhite: 0.93, alpha: 1).cgColor
        canvas.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        for (i, s) in samples.enumerated() {
            let iv = NSImageView(frame: NSRect(x: CGFloat(i) * cell.width + 6, y: 7,
                                               width: 16, height: 16))
            iv.image = StatusIcon.make(fraction: s.0, severity: s.0, stale: s.1)
            canvas.addSubview(iv)
            let label = NSTextField(labelWithString: s.1 ? "旧" : "\(Int(s.0 * 100))%")
            label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            label.textColor = dark ? .white : .black
            label.frame = NSRect(x: CGFloat(i) * cell.width + 24, y: 7, width: 36, height: 16)
            canvas.addSubview(label)
        }
        canvas.layoutSubtreeIfNeeded()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("已渲染菜单栏图标 \(path)")
    }

    /// 离屏渲染胶囊。
    static func renderCapsule(to path: String, dark: Bool, waitForData: TimeInterval) {
        let store = Store()
        let deadline = Date().addingTimeInterval(waitForData)
        while store.snapshot == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        let settle = Date().addingTimeInterval(store.snapshot != nil ? 2.0 : 0.3)
        while Date() < settle {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        let host = NSHostingView(rootView: CapsuleView(store: store, onExpand: {}))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        let pad: CGFloat = 18
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: host.frame.width + pad*2, height: host.frame.height + pad*2))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = (dark ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.15, alpha: 1)
                                              : NSColor(calibratedWhite: 0.9, alpha: 1)).cgColor
        host.setFrameOrigin(NSPoint(x: pad, y: pad))
        canvas.addSubview(host)
        canvas.layoutSubtreeIfNeeded()
        for _ in 0..<2 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("已渲染胶囊 \(path)")
    }

    /// - Parameter waitForData: 最多等多久让真实额度到位。0 表示不等。
    static func render(to path: String, dark: Bool, expandDetail: Bool, waitForData: TimeInterval) {
        // 三档大小由偏好 panelSize 决定；--detail 等价临时切到大档。
        // 渲染进程与正式实例共用同一份偏好，改完必须还原，否则一次渲染
        // 会把用户的档位永久改掉。
        let savedSize = UserDefaults.standard.string(forKey: "panelSize")
        if expandDetail { UserDefaults.standard.set(PanelSize.full.rawValue, forKey: "panelSize") }
        defer {
            if expandDetail {
                if let v = savedSize { UserDefaults.standard.set(v, forKey: "panelSize") }
                else { UserDefaults.standard.removeObject(forKey: "panelSize") }
            }
        }
        let store = Store()

        // 等真实数据。等不到就渲染空态——那本身也是要核对的一屏。
        let deadline = Date().addingTimeInterval(waitForData)
        while store.snapshot == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        // 数据到了再多跑几拍，让精确值合并进来、动画落定
        let settle = Date().addingTimeInterval(store.snapshot != nil ? 2.5 : 0.3)
        while Date() < settle {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        // --settings：渲染设置页核对版式
        if CommandLine.arguments.contains("--settings") { store.settingsOpen = true }
        let view = PanelView(store: store, onRefresh: {}, onClose: {}, onToggleTop: {})
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        // 让 SwiftUI 完成一轮布局与绘制
        for _ in 0..<3 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.12))
        }
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        // 面板是半透明的，底下垫一层模拟桌面，否则毛玻璃处渲染成全黑看不出效果
        let pad: CGFloat = 26
        let canvas = NSView(frame: NSRect(x: 0, y: 0,
                                          width: host.frame.width + pad * 2,
                                          height: host.frame.height + pad * 2))
        canvas.wantsLayer = true
        let bg = CAGradientLayer()
        bg.frame = canvas.bounds
        bg.colors = dark
            ? [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor,
               NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.20, alpha: 1).cgColor]
            : [NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.94, alpha: 1).cgColor,
               NSColor(calibratedRed: 0.84, green: 0.86, blue: 0.91, alpha: 1).cgColor]
        bg.startPoint = CGPoint(x: 0, y: 0)
        bg.endPoint = CGPoint(x: 1, y: 1)
        canvas.layer?.addSublayer(bg)
        host.setFrameOrigin(NSPoint(x: pad, y: pad))
        canvas.addSubview(host)
        canvas.layoutSubtreeIfNeeded()

        for _ in 0..<3 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.12))
        }

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            FileHandle.standardError.write("无法建立离屏位图\n".data(using: .utf8)!)
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))

        let state = store.snapshot.map {
            "窗口 \($0.windows.count) 个，口径 \($0.precision.label)"
        } ?? "无数据（空态）"
        print("已渲染 \(path)（\(dark ? "深色" : "浅色")\(expandDetail ? " · 展开明细" : "")）— \(state)")
    }
}
