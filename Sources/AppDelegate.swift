import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    /// 完整面板。
    private var floater: NSPanel?
    private var host: NSHostingView<ScaledPanelRoot>?
    /// 「自然尺寸变了→改窗」的合并节拍：SwiftUI 偶有一帧的过渡排版（文字换行、
    /// 行进出），每帧都跟着改窗，肉眼就是一下抽动；合并 0.12 秒再动窗。
    private var sizeSyncWork: DispatchWorkItem?
    /// 面板内容的自然尺寸（逻辑宽 344、未缩放），由 ScaledPanelRoot 量了回调。
    /// 窗口尺寸 = 自然尺寸 × 缩放系数。
    private var naturalSize = NSSize(width: Theme.panelWidth, height: 520)
    /// 极小胶囊。与面板互斥显示。
    private var capsule: NSPanel?
    private var capsuleHost: NSHostingView<CapsuleView>?
    /// 胶囊是否收在顶边（不可见，等鼠标顶到顶部唤出）。
    private var tucked = false
    /// 鼠标在顶部热区里驻留的起点，驻留够 0.3 秒才滑出——路过不算。
    private var hotSince: Date?
    /// 鼠标离开胶囊的起点，离开够 1.5 秒才收回——手抖出去一下不收。
    private var awaySince: Date?
    /// 本次胶囊显示是不是「临时唤出」。只有临时的会在鼠标离开后自动缩回；
    /// 常驻胶囊（菜单切出来的那种）一直亮着，点它的小 ✕ 才收。
    private var capsuleTransient = false

    private let store = Store()
    private var bag = Set<AnyCancellable>()

    /// 悬停提示：独立小窗、贴鼠标屏幕坐标弹出，可伸出面板边界。
    /// 在面板里画气泡返工过两轮（盖内容/贴边挪窝），而且面板内容经
    /// NSScrollView 缩放，逻辑坐标对物理像素还要换算——屏幕坐标一步到位。
    let tips = TipBox()
    private var tipWindow: NSPanel?
    private var tipSub: AnyCancellable?
    /// 气泡保险丝：SwiftUI 在缩放视图里会丢「鼠标离开」事件，气泡就卡在屏幕上
    /// （用户抓的「鼠标都走了它还指着」）。开一条 0.2s 的看门狗，
    /// 真实鼠标一离开弹出点 40pt 立即自灭，不指望悬停离开一定送达。
    private var tipTimer: Timer?
    private var tipAnchorPoint = NSPoint.zero
    private var iconTimer: Timer?
    /// 0.12s 一拍：热区驻留、离开收回、跟随 Mirasim 窗口挪动。
    private var capsuleTimer: Timer?
    private var savePositionWork: DispatchWorkItem?
    private var hovering = false

    private let posKey = "floaterOrigin"
    private let miraBundleId = "ai.mirofish.mirasim"
    /// dockOrigin 的缓存。0.12s 的节拍里每拍做一次 CGWindowList 全窗口枚举太费，
    /// 位置这种东西 0.8 秒刷一次绰绰有余。
    private var dockCache: (at: Date, origin: NSPoint, size: NSSize)?
    /// 「只在 Mirasim 里显示」的一次性豁免。被它藏着时点菜单栏图标＝「我现在就要看」，
    /// 于是临时放行；下次切换前台应用时豁免自动失效，规则照旧。
    private var frontAppOverride = false

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.placeholder()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateIcon()
                    self?.syncSize(animated: false)
                    self?.syncCapsuleSize()
                }
            }
            .store(in: &bag)

        store.$alwaysOnTop
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                DispatchQueue.main.async { self?.floater?.level = on ? .floating : .normal }
            }
            .store(in: &bag)

        store.$opacity
            .receive(on: RunLoop.main)
            .sink { [weak self] v in
                DispatchQueue.main.async {
                    guard let self, let p = self.floater, p.isVisible else { return }
                    p.alphaValue = self.hovering && self.store.clearOnHover ? 1.0 : v
                }
            }
            .store(in: &bag)

        // 形态或「只在 Mirasim」开关一变，重排显隐
        store.$floatMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyPresentation(tuckCapsule: false) } }
            .store(in: &bag)
        // 鼠标穿透开关（设置页/菜单都可能改）：立即生效，悬停气泡一并收掉
        store.$clickThrough
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.tips.text = nil
                    self?.penetrationTick()
                }
            }
            .store(in: &bag)

        // 内嵌开关：一开就切回面板态并粘到 Mirasim 窗口；一关立刻松开，面板留在原地
        store.$embedInMirasim
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if on { self.store.floatMode = .panel }
                    self.applyVisibility()
                    if on, let p = self.floater, p.isVisible {
                        p.setFrameOrigin(self.embedOrigin(for: p.frame.size))
                    }
                }
            }
            .store(in: &bag)
        store.$panelScale
            .receive(on: RunLoop.main)
            .sink { [weak self] sc in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // 缩放本体由 ScaledPanelRoot 里的 scaleEffect 直接吃 store 值，
                    // 这里只需把窗口尺寸跟上
                    _ = sc
                    self.syncSize(animated: false)
                }
            }
            .store(in: &bag)

        // 外观强制深/浅色。挂在 NSApp 上一处管全部窗口（面板/胶囊/提示小窗/菜单）。
        store.$appearanceOverride
            .receive(on: RunLoop.main)
            .sink { [weak self] v in DispatchQueue.main.async { self?.applyAppearance(v) } }
            .store(in: &bag)

        // 额度警报：越线弹面板 + 提示音（Store 保证每窗口周期只触发一次）
        store.onAlert = { [weak self] name in
            DispatchQueue.main.async {
                NSSound(named: "Glass")?.play()
                self?.revealForAlert()
                _ = name
            }
        }
        store.$onlyInMirasim
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyVisibility() } }
            .store(in: &bag)

        // 前台应用切换：「只在 Mirasim 里出现」靠它生效
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.updateIcon()
            self?.host?.needsLayout = true
        }
        RunLoop.main.add(t, forMode: .common)
        iconTimer = t

        // 胶囊节拍：热区驻留检测 + 离开收回 + 跟随 Mirasim 窗口
        let ct = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.capsuleTick() }
        RunLoop.main.add(ct, forMode: .common)
        capsuleTimer = ct

        updateIcon()
        if store.floatingVisible { applyPresentation(tuckCapsule: false) }
    }

    /// 双击桌面启动器（或再次打开本应用）：把完整面板叫出来。
    /// 已经在跑时系统不会起第二个进程，而是送来这个「重新打开」事件。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store.floatingVisible = true
        tucked = false
        if !allowedByFrontApp() { frontAppOverride = true }
        // 启动器的意图是「打开看看」，给完整面板，哪怕之前收成了胶囊
        store.floatMode = .panel
        applyPresentation(tuckCapsule: false)
        updateIcon()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()   // 没落盘的采样补上，走势线重启后不断档
    }

    // MARK: 菜单栏图标

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        guard let w = store.focusWindow, store.snapshot != nil else {
            button.image = StatusIcon.placeholder()
            button.title = ""
            button.toolTip = L("Mirasim 遥测 — 暂时读不到额度")
            return
        }
        let stale = !store.isFresh
        button.image = StatusIcon.make(fraction: w.usedPercent / 100,
                                       severity: w.severity,
                                       stale: stale)
        if store.showPercentInMenuBar {
            button.title = " \(Int(w.usedPercent.rounded()))%"
            button.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        } else {
            button.title = ""
        }
        var tip = L("\(w.displayName)：已用 \(Fmt.percent(w.usedPercent, precision: w.precision))", "\(w.displayName): \(Fmt.percent(w.usedPercent, precision: w.precision)) used")
        tip += L("\n\(Fmt.duration(w.resetAt.timeIntervalSinceNow)) 后重置", "\nresets in \(Fmt.duration(w.resetAt.timeIntervalSinceNow))")
        tip += L("\n数据 \(Fmt.ago(store.snapshot?.age ?? 0))", "\ndata \(Fmt.ago(store.snapshot?.age ?? 0))")
        tip += L("\n\n点一下：", "\n\nClick: ") + (store.floatingVisible ? L("收起") : L("显示"))
        button.toolTip = tip
    }

    // MARK: 点击与菜单

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRight { showContextMenu() } else { toggleMaster() }
    }

    /// 菜单栏左键。语义是「看不见就给我看，看得见就收起」——
    /// 不是盲目翻转开关：面板被「只在 Mirasim」压着时开关明明是开的，
    /// 翻转会变成关，越点越打不开。
    private func toggleMaster() {
        let actuallyVisible = (floater?.isVisible ?? false) || (capsule?.isVisible ?? false)
        if actuallyVisible {
            store.floatingVisible = false
            hidePanel()
            hideCapsule()
        } else {
            store.floatingVisible = true
            tucked = false   // 收在顶边的胶囊也算「看不见」，一并唤出
            if !allowedByFrontApp() { frontAppOverride = true }
            applyPresentation(tuckCapsule: false)
        }
        updateIcon()
    }

    private func showContextMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func popUpMenuOnPanel(_ event: NSEvent) {
        guard let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: view)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let show = NSMenuItem(title: L("显示悬浮窗"), action: #selector(toggleMasterMenu), keyEquivalent: "")
        show.target = self
        show.state = store.floatingVisible ? .on : .off
        menu.addItem(show)

        let modeItem = NSMenuItem(title: L("显示为胶囊"), action: #selector(toggleMode), keyEquivalent: "")
        modeItem.target = self
        modeItem.state = store.floatMode == .capsule ? .on : .off
        menu.addItem(modeItem)

        let pierce = NSMenuItem(title: L("鼠标穿透（停留 1 秒可操作）"), action: #selector(toggleClickThrough), keyEquivalent: "")
        pierce.target = self
        pierce.state = store.clickThrough ? .on : .off
        menu.addItem(pierce)

        let only = NSMenuItem(title: L("只在 Mirasim 前台时显示"), action: #selector(toggleOnlyInApp), keyEquivalent: "")
        only.target = self
        only.state = store.onlyInMirasim ? .on : .off
        menu.addItem(only)

        let top = NSMenuItem(title: L("钉在最前"), action: #selector(toggleTop), keyEquivalent: "")
        top.target = self
        top.state = store.alwaysOnTop ? .on : .off
        menu.addItem(top)

        let reset = NSMenuItem(title: L("把悬浮窗移回右上角"), action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let pct = NSMenuItem(title: L("菜单栏显示百分比"), action: #selector(togglePercent), keyEquivalent: "")
        pct.target = self
        pct.state = store.showPercentInMenuBar ? .on : .off
        menu.addItem(pct)

        let follow = NSMenu()
        let auto = NSMenuItem(title: L("自动（剩得最少的）"), action: #selector(pinWindow(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = store.pinnedWindow == nil ? .on : .off
        follow.addItem(auto)
        if let ws = store.snapshot?.windows, !ws.isEmpty {
            follow.addItem(.separator())
            for w in ws {
                let mi = NSMenuItem(title: w.displayName, action: #selector(pinWindow(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = w.name
                mi.state = store.pinnedWindow == w.name ? .on : .off
                follow.addItem(mi)
            }
        }
        let followItem = NSMenuItem(title: L("主要盯哪个窗口"), action: nil, keyEquivalent: "")
        menu.setSubmenu(follow, for: followItem)
        menu.addItem(followItem)

        let sizeMenu = NSMenu()
        for sz in PanelSize.allCases {
            let mi = NSMenuItem(title: sz.label, action: #selector(setSize(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sz.rawValue
            mi.state = store.size == sz ? .on : .off
            sizeMenu.addItem(mi)
        }
        let sizeItem = NSMenuItem(title: L("悬浮窗大小"), action: nil, keyEquivalent: "")
        menu.setSubmenu(sizeMenu, for: sizeItem)
        menu.addItem(sizeItem)

        let zoomMenu = NSMenu()
        for (label, v) in [("80%", 0.8), ("90%", 0.9), ("100%", 1.0),
                           ("115%", 1.15), ("130%", 1.3), ("150%", 1.5)] {
            let mi = NSMenuItem(title: label, action: #selector(setZoom(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = v
            mi.state = abs(store.panelScale - v) < 0.03 ? .on : .off
            zoomMenu.addItem(mi)
        }
        zoomMenu.addItem(.separator())
        let zoomHint = NSMenuItem(title: L("也可直接拖窗口边缘/角落"), action: nil, keyEquivalent: "")
        zoomHint.isEnabled = false
        zoomMenu.addItem(zoomHint)
        let zoomItem = NSMenuItem(title: L("窗口缩放"), action: nil, keyEquivalent: "")
        menu.setSubmenu(zoomMenu, for: zoomItem)
        menu.addItem(zoomItem)

        let opMenu = NSMenu()
        for (label, v) in [(L("不透明"), 1.0), (L("轻微透 85%"), 0.85), (L("半透明 70%"), 0.7),
                           (L("很透 55%"), 0.55), (L("几乎隐形 40%"), 0.4)] {
            let mi = NSMenuItem(title: label, action: #selector(setOpacity(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = v
            mi.state = abs(store.opacity - v) < 0.01 ? .on : .off
            opMenu.addItem(mi)
        }
        opMenu.addItem(.separator())
        let hov = NSMenuItem(title: L("鼠标移上去时变清晰"), action: #selector(toggleClearOnHover), keyEquivalent: "")
        hov.target = self
        hov.state = store.clearOnHover ? .on : .off
        opMenu.addItem(hov)
        let opItem = NSMenuItem(title: L("透明度"), action: nil, keyEquivalent: "")
        menu.setSubmenu(opMenu, for: opItem)
        menu.addItem(opItem)

        menu.addItem(.separator())

        let login = NSMenuItem(title: L("开机自动启动"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)

        let refresh = NSMenuItem(title: L("立即刷新"), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 Mirasim 遥测"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleMasterMenu() { toggleMaster() }

    @objc private func toggleMode() {
        store.floatMode = store.floatMode == .capsule ? .panel : .capsule
    }

    @objc private func toggleOnlyInApp() { store.onlyInMirasim.toggle() }

    @objc private func toggleClickThrough() {
        store.clickThrough.toggle()
        // 立即生效，不等下一拍；开穿透时悬停态已经死了，把气泡一并收掉
        if store.clickThrough { tips.text = nil }
        penetrationTick()
    }

    @objc private func toggleTop() {
        store.alwaysOnTop.toggle()
        floater?.level = store.alwaysOnTop ? .floating : .normal
    }

    @objc private func togglePercent() {
        store.showPercentInMenuBar.toggle()
        updateIcon()
    }

    @objc private func pinWindow(_ sender: NSMenuItem) {
        store.pinnedWindow = (sender.representedObject as? String).flatMap { $0.isEmpty ? nil : $0 }
        updateIcon()
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sz = PanelSize(rawValue: raw) else { return }
        store.size = sz
    }

    @objc private func setZoom(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        store.panelScale = min(1.8, max(0.7, v))
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        store.opacity = min(1, max(0.3, v))
    }

    @objc private func toggleClearOnHover() {
        store.clearOnHover.toggle()
        applyOpacity(hovering: hovering)
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 缩放宿主

    /// 面板的缩放宿主。缩放必须发生在 SwiftUI **内部**（scaleEffect 参与
    /// 命中区变换）。曾走 NSScrollView.magnification：像素确实缩了，
    /// 但 SwiftUI 全程不知道有这层变换，悬停/点击仍按 1:1 坐标命中——
    /// 缩放一不是 1 就「鼠标指这颗、亮的是那颗」，三轮气泡返工的总根子。
    /// 自然尺寸在缩放**前**量好回调给 AppKit 定窗口大小；测量只依赖内容
    /// （宽恒 344），与窗口尺寸无关，不构成布局回环——上次 scaleEffect
    /// 之败在于「测高→改窗→再测」互相驱动，这里把环剪断了。
    struct ScaledPanelRoot: View {
        @ObservedObject var store: Store
        let content: PanelView
        var onNaturalSize: (CGSize) -> Void

        var body: some View {
            ZStack(alignment: .topLeading) {
                content
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: PanelNaturalSizeKey.self, value: g.size)
                        }
                    )
                    .scaleEffect(store.panelScale, anchor: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onPreferenceChange(PanelNaturalSizeKey.self) { onNaturalSize($0) }
        }
    }

    struct PanelNaturalSizeKey: PreferenceKey {
        static var defaultValue = CGSize.zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let n = nextValue()
            if n != .zero { value = n }
        }
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: posKey)
        // 胶囊的自定义位置一并清掉，恢复贴 Mirasim 窗口的自动吸附
        UserDefaults.standard.removeObject(forKey: capsulePosKey)
        dockCache = nil
        store.floatMode = .panel
        if let p = floater {
            let sc = store.panelScale
            let size = cappedSize(NSSize(width: naturalSize.width * sc,
                                         height: naturalSize.height * sc))
            p.setFrameOrigin(defaultOrigin(for: size))
        }
        if !store.floatingVisible { store.floatingVisible = true }
        applyPresentation(tuckCapsule: false)
    }

    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }

    // MARK: 前台跟随

    @objc private func frontAppChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 切了前台，豁免失效，回到「只在 Mirasim」的正常规则
            self.frontAppOverride = false
            self.applyVisibility()
        }
    }

    /// 「只在 Mirasim 里出现」的判定。自己也算——点自己面板不该把自己藏了。
    private func allowedByFrontApp() -> Bool {
        // 内嵌＝长在 Mirasim 窗口里，它不在前台面板就该藏（等同 onlyInMirasim）
        guard store.onlyInMirasim || store.embedInMirasim else { return true }
        if frontAppOverride { return true }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front == miraBundleId || front == Bundle.main.bundleIdentifier
    }

    /// 只处理显隐，不换形态。
    private func applyVisibility() {
        guard store.floatingVisible else { hidePanel(); hideCapsule(); return }
        if allowedByFrontApp() {
            applyPresentation(tuckCapsule: tucked)
        } else {
            floater?.orderOut(nil)
            capsule?.orderOut(nil)
        }
    }

    /// 按当前形态摆正窗口。
    private func applyPresentation(tuckCapsule: Bool) {
        guard store.floatingVisible, allowedByFrontApp() else {
            floater?.orderOut(nil); capsule?.orderOut(nil); return
        }
        switch store.floatMode {
        case .panel:
            hideCapsule()
            showPanel()
        case .capsule:
            hidePanel()
            if tuckCapsule {
                tuck()
            } else if capsule?.isVisible != true {
                // 已经亮着就别重进场——重复 show 会把临时态覆盖成常驻
                showCapsule(transient: false)
            }
        }
        updateIcon()
    }

    // MARK: 面板

    private func showPanel() {
        if let p = floater { p.orderFrontRegardless(); return }

        if tipSub == nil {
            tipSub = tips.$text
                .receive(on: DispatchQueue.main)
                .sink { [weak self] t in self?.showTip(t) }
        }

        let view = PanelView(store: store,
                             tip: tips,
                             onRefresh: { [weak self] in self?.store.refresh() },
                             onClose: { [weak self] in self?.collapseToCapsule() },
                             onToggleTop: { [weak self] in self?.toggleTop() },
                             onToggleOnlyInApp: { [weak self] in self?.toggleOnlyInApp() },
                             onHover: { [weak self] inside in self?.applyOpacity(hovering: inside) },
                             onRightClick: { [weak self] ev in self?.popUpMenuOnPanel(ev) },
                             onResetPosition: { [weak self] in self?.resetPosition() },
                             onQuit: { NSApp.terminate(nil) })
        // 先用素宿主量一次自然尺寸（纯排版、无缩放），首帧窗口就是对的；
        // 此后内容增减行时由 ScaledPanelRoot 的测量回调持续刷新。
        naturalSize = NSHostingView(rootView: view).fittingSize

        let hosting = NSHostingView(rootView: ScaledPanelRoot(store: store, content: view) { [weak self] sz in
            guard let self, sz.width > 1, sz.height > 1 else { return }
            guard abs(sz.width - self.naturalSize.width) >= 1
                    || abs(sz.height - self.naturalSize.height) >= 1 else { return }
            self.naturalSize = NSSize(width: sz.width, height: sz.height)
            self.sizeSyncWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.syncSize(animated: false) }
            self.sizeSyncWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        })
        // 抖动总根子：NSHostingView 默认把 SwiftUI 内容的最小/固有尺寸挂成窗口约束，
        // 而内容按逻辑宽 344 排版、scaleEffect 不改布局尺寸——缩放系数一小于 1，
        // syncSize 刚把窗口设成缩放后的 301×584，约束下一拍就把它撑回 344×667
        // （实测窗口从来没小过 344×667，缩小的内容旁边是一圈透明空白），内嵌跟随
        // 再按 344 宽重算锚点：X 在 2570/2612 之间每隔一两秒来回一次。
        // 窗口尺寸只归 syncSize 管，宿主不许再插手。
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        host = hosting

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: cappedSize(naturalSize)),
                        // .resizable：无边框窗口也能拖边缘/角落改大小，
                        // 拖出来的宽度换算成内容缩放系数
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.minSize = NSSize(width: Theme.panelWidth * 0.7, height: 120)
        p.maxSize = NSSize(width: Theme.panelWidth * 1.8, height: 4000)
        p.level = store.alwaysOnTop ? .floating : .normal
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.contentView = hosting
        p.delegate = self
        floater = p

        let size = cappedSize(NSSize(width: naturalSize.width * store.panelScale,
                                     height: naturalSize.height * store.panelScale))
        // 内嵌模式首帧就落到 Mirasim 窗口内角，之后由跟随节拍粘住
        let origin = store.embedInMirasim ? embedOrigin(for: size)
                                          : (savedOrigin(for: size) ?? defaultOrigin(for: size))
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = store.opacity
        }
    }

    private func hidePanel() {
        // 面板一藏，提示必须跟着走：点 ✕ 收胶囊时鼠标不会再触发悬停离开，
        // 不清的话气泡会孤零零留在屏幕上。
        tips.text = nil
        floater?.orderOut(nil)
    }

    private func applyAppearance(_ v: String) {
        NSApp.appearance = v == "dark" ? NSAppearance(named: .darkAqua)
                         : v == "light" ? NSAppearance(named: .aqua)
                         : nil
        updateIcon()
    }

    /// 额度越线：把面板亮出来让人看见。一次性无视「只在 Mirasim」门——
    /// 警报的意义就是打断你正在干的事。
    private func revealForAlert() {
        frontAppOverride = true
        if !store.floatingVisible { store.floatingVisible = true }
        if store.floatMode != .panel { store.floatMode = .panel }
        if floater == nil { showPanel() }
        floater?.orderFrontRegardless()
    }

    // MARK: 悬停提示小窗

    /// 量字出框：圆体 11.5 号，最宽 276（气泡左右内边距共 20）。
    private func tipSize(for text: String) -> NSSize {
        let base = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11.5) } ?? base
        // 行距与气泡视图的 lineSpacing(2) 保持一致，多行说明才量得准
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: 276, height: 900),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: para])
        // 圆体度量比测量字体略宽，给 6pt 富余，宁可框大一圈不可掐字
        return NSSize(width: ceil(bound.width) + 26, height: ceil(bound.height) + 16)
    }

    private func showTip(_ text: String?) {
        guard let text, !text.isEmpty, floater?.isVisible == true else {
            tipTimer?.invalidate(); tipTimer = nil
            if let w = tipWindow, w.isVisible {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    w.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    // 淡出期间又有新提示顶上来的话别把它关了
                    if self?.tips.text == nil { w.orderOut(nil) }
                })
            }
            return
        }
        if tipWindow == nil {
            let w = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false            // 气泡视图自带投影
            w.ignoresMouseEvents = true    // 绝不能抢走按钮的悬停
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            tipWindow = w
        }
        guard let w = tipWindow, let anchor = floater else { return }
        // 永远压在面板上一层，面板钉最前时也要能看见提示
        w.level = NSWindow.Level(rawValue: anchor.level.rawValue + 1)

        let body = tipSize(for: text)
        let total = NSSize(width: body.width, height: body.height + 6)   // 顶/底加箭头

        // 位置：鼠标正下方居中（屏幕坐标，跟面板缩放系数无关），
        // 贴屏幕边就收拢，贴底就翻到鼠标上方（箭头跟着翻）。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var x = mouse.x - total.width / 2
        var y = mouse.y - 16 - total.height
        var flipped = false
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 4), vis.maxX - total.width - 4)
            if y < vis.minY + 4 { flipped = true; y = mouse.y + 16 }
        }
        // 箭头永远咬住鼠标的横坐标（收拢后气泡可能不在鼠标正下方了）
        let caretX = min(max(mouse.x - x, 14), total.width - 14)

        let dark = anchor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        w.contentView = NSHostingView(rootView:
            TipBubble(text: text, dark: dark, caretX: caretX, caretOnTop: !flipped)
                .frame(width: total.width, height: total.height))

        let target = NSRect(x: x, y: y, width: total.width, height: total.height)
        if w.isVisible, w.alphaValue > 0.5 {
            // 已在显示：滑到新按钮下面换内容，比闪没再闪出连贯
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().setFrame(target, display: true)
                w.animator().alphaValue = 1
            }
        } else {
            // 初次出现：从下方 4pt 处浮现
            var start = target
            start.origin.y += flipped ? -4 : 4
            w.setFrame(start, display: true)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().setFrame(target, display: true)
                w.animator().alphaValue = 1
            }
        }

        tipAnchorPoint = mouse
        startTipWatchdog()
    }

    private func startTipWatchdog() {
        tipTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.tips.text != nil, self.floater?.isVisible == true else {
                self.tipTimer?.invalidate(); self.tipTimer = nil
                self.tipWindow?.orderOut(nil)
                return
            }
            let m = NSEvent.mouseLocation
            if hypot(m.x - self.tipAnchorPoint.x, m.y - self.tipAnchorPoint.y) > 48 {
                // 悬停离开事件多半已经丢了，别等它——直接收
                self.tips.text = nil
                self.tipTimer?.invalidate(); self.tipTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tipTimer = t
    }

    /// 面板 ✕：收入顶部。先以临时态亮一下让人看见它去了哪，随即自动缩回顶边。
    private func collapseToCapsule() {
        hidePanel()   // sink 里也会藏，但那是下一拍——别让面板和胶囊同屏闪一下
        showCapsule(transient: true)
        store.floatMode = .capsule   // sink 的 applyPresentation 看到已可见，不会覆盖临时态
    }

    // MARK: 胶囊

    private func ensureCapsule() {
        guard capsule == nil else { return }
        let view = CapsuleView(store: store,
                               onExpand: { [weak self] in
                                   guard let self else { return }
                                   self.tucked = false
                                   self.capsuleTransient = false
                                   self.store.floatMode = .panel
                               },
                               onTuck: { [weak self] in self?.tuck() },
                               onRightClick: { [weak self] ev in self?.popUpMenuOnPanel(ev) },
                               onDragEnd: { [weak self] in self?.capsuleDragEnded() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        capsuleHost = hosting

        let p = NSPanel(contentRect: hosting.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 胶囊贴在 Mirasim 窗口顶部，要能盖住它
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        // 不开 isMovableByWindowBackground：鼠标层自己挪窗口，
        // 系统再来一手就是双重移动
        p.contentView = hosting
        capsule = p
    }

    private func showCapsule(transient: Bool) {
        ensureCapsule()
        guard let p = capsule, let h = capsuleHost else { return }
        tucked = false
        awaySince = nil
        capsuleTransient = transient
        h.frame = NSRect(origin: .zero, size: h.fittingSize)
        let size = h.fittingSize
        let target = dockOrigin(for: size)
        // 从顶边滑下来
        p.setFrame(NSRect(origin: NSPoint(x: target.x, y: target.y + 14), size: size), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: target, size: size), display: true)
        }
    }

    private func hideCapsule() {
        capsule?.orderOut(nil)
        tucked = false
    }

    /// 收进顶边：胶囊消失，只留一个看不见的热区等鼠标来顶。
    private func tuck() {
        guard let p = capsule else { tucked = true; return }
        tucked = true
        hotSince = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            var f = p.frame
            f.origin.y += 14
            p.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in
            self?.capsule?.orderOut(nil)
        })
    }

    private let capsulePosKey = "capsuleOrigin"
    /// 胶囊拖拽的跟随让路宽限：手按过之后这段时间内节拍不吸附。
    private var capsuleGraceUntil = Date.distantPast

    /// 停靠位：用户拖过就用记住的位置（夹回屏内），从此不吸附；
    /// 否则贴 Mirasim 主窗口顶边中央，找不到它用主屏可视区顶部中央。
    /// CGWindowList 的坐标 y 向下、NSWindow 向上，按主屏高度换算。
    private func dockOrigin(for size: NSSize) -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: capsulePosKey) {
            var pt = NSPointFromString(s)
            let mid = NSPoint(x: pt.x + size.width / 2, y: pt.y + size.height / 2)
            let vis = (NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main)?.visibleFrame
            if let v = vis {
                pt.x = min(max(pt.x, v.minX), v.maxX - size.width)
                pt.y = min(max(pt.y, v.minY), v.maxY - size.height)
            }
            return pt
        }
        if let c = dockCache, c.size == size, Date().timeIntervalSince(c.at) < 0.8 {
            return c.origin
        }
        let origin = computeDockOrigin(for: size)
        dockCache = (Date(), origin, size)
        return origin
    }

    /// 胶囊内容一变（主角窗口切换、百分比位数变化）窗框跟着变——
    /// 不然「7 天 · Fable」挤进「7 天」的旧框里，字被压成省略号。
    /// 以中心为锚伸缩，贴着停靠中线不跑偏。
    private func syncCapsuleSize() {
        guard let p = capsule, p.isVisible, let h = capsuleHost else { return }
        let want = h.fittingSize
        guard want.width > 10, want.height > 10,
              abs(want.width - p.frame.width) > 1 || abs(want.height - p.frame.height) > 1 else { return }
        var f = p.frame
        f.origin.x += (f.width - want.width) / 2
        f.origin.y += (f.height - want.height) / 2
        f.size = want
        p.setFrame(f, display: true)
    }

    /// 用户拖完胶囊：落点离自动停靠位很近＝想挂回去，磁吸并恢复跟随；
    /// 拖远了＝记住这个位置，从此不再自动吸附（重置窗口位置可清）。
    private func capsuleDragEnded() {
        guard let p = capsule else { return }
        // 亲手安放过＝要它常驻。临时态（从 ✕ 收出来的）拖完自动转正，
        // 不然鼠标一走 1.5s 它自己缩回顶边，像凭空消失。
        capsuleTransient = false
        capsuleGraceUntil = Date().addingTimeInterval(0.6)
        let auto = computeDockOrigin(for: p.frame.size)
        dockCache = nil
        if hypot(p.frame.origin.x - auto.x, p.frame.origin.y - auto.y) < 36 {
            UserDefaults.standard.removeObject(forKey: capsulePosKey)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrameOrigin(auto)
            }
        } else {
            UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: capsulePosKey)
        }
    }

    /// Mirasim 主窗口的位置（NS 坐标：原点左下、y 向上），找不到时 nil。
    /// dock（贴顶）和 embed（内嵌一角）共用这一处窗口查找。
    /// CGWindowList 的 y 向下，按主屏高度换算成 NS 的窗口底边。
    /// miraFrame 的短缓存：内嵌跟随每 0.12s 一拍，每拍都做 CGWindowList 全窗口枚举太费。
    private var miraFrameCache: (at: Date, frame: NSRect?)?

    private func miraFrame() -> NSRect? {
        if let c = miraFrameCache, Date().timeIntervalSince(c.at) < 0.25 { return c.frame }
        let f = computeMiraFrame()
        miraFrameCache = (Date(), f)
        return f
    }

    private func computeMiraFrame() -> NSRect? {
        let screenH = NSScreen.screens.first?.frame.height ?? 1080
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: NSRect?
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "Mirasim",
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let ww = b["Width"] as? Double, let hh = b["Height"] as? Double,
                  ww > 300, hh > 200 else { continue }
            let r = NSRect(x: x, y: screenH - y - hh, width: ww, height: hh)  // 底边 = 屏高 − 上边 − 高
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    private func computeDockOrigin(for size: NSSize) -> NSPoint {
        if let m = miraFrame() {
            return NSPoint(x: m.midX - size.width / 2, y: m.maxY - size.height - 10)
        }
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vis.midX - size.width / 2, y: vis.maxY - size.height - 8)
    }

    /// 内嵌位：所选角 + 用户偏移（拖动面板可调，见 saveEmbedOffsets）。
    /// 顶角默认让出 108pt——14pt 顶死会盖住 Mirasim 自家工具栏（用户抓的）。
    /// 找不到 Mirasim 窗时退回主屏对应角，面板不至于消失。
    private func embedOrigin(for size: NSSize) -> NSPoint {
        let frame = miraFrame() ?? (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let ox = CGFloat(max(0, store.embedOffX))
        let oy = CGFloat(max(0, store.embedOffY))
        var pt: NSPoint
        switch store.embedCorner {
        case "topLeft":     pt = NSPoint(x: frame.minX + ox, y: frame.maxY - size.height - oy)
        case "bottomRight": pt = NSPoint(x: frame.maxX - size.width - ox, y: frame.minY + oy)
        case "bottomLeft":  pt = NSPoint(x: frame.minX + ox, y: frame.minY + oy)
        default:            pt = NSPoint(x: frame.maxX - size.width - ox, y: frame.maxY - size.height - oy)
        }
        // 无论偏移多离谱都夹回 Mirasim 窗口内
        pt.x = min(max(pt.x, frame.minX + 4), max(frame.minX + 4, frame.maxX - size.width - 4))
        pt.y = min(max(pt.y, frame.minY + 4), max(frame.minY + 4, frame.maxY - size.height - 4))
        return pt
    }

    /// 内嵌时拖完面板：把落点换算成「相对所选角的偏移」记住，
    /// 以后跟随都按调好的位置贴——不再顶死在角上。
    private func saveEmbedOffsets(frame f: NSRect, in m: NSRect) {
        let x: Double, y: Double
        switch store.embedCorner {
        case "topLeft":     x = f.minX - m.minX;  y = m.maxY - f.maxY
        case "bottomRight": x = m.maxX - f.maxX;  y = f.minY - m.minY
        case "bottomLeft":  x = f.minX - m.minX;  y = f.minY - m.minY
        default:            x = m.maxX - f.maxX;  y = m.maxY - f.maxY
        }
        store.embedOffX = max(0, x)
        store.embedOffY = max(0, y)
    }

    private func mouseInsideCapsule() -> Bool {
        guard let p = capsule, p.isVisible else { return false }
        return p.frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
    }

    /// 内嵌拖动中：按下时的面板框，用于松手时判断「拖过没有」。
    private var embedPress: NSRect?

    /// 内嵌粘附：面板模式且开了内嵌时，每拍把面板吸到调好的内嵌位。
    /// 用户手上按着就让路；松手时若真拖动过，把新落点记成偏移而不是吸回去。
    private func embedFollowTick() {
        guard store.embedInMirasim, store.floatMode == .panel,
              let p = floater, p.isVisible else { embedPress = nil; return }

        let pressed = NSEvent.pressedMouseButtons & 1 == 1
        if pressed, embedPress != nil || p.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
            if embedPress == nil { embedPress = p.frame }
            return
        }
        if let was = embedPress {
            embedPress = nil
            if abs(p.frame.origin.x - was.origin.x) > 3 || abs(p.frame.origin.y - was.origin.y) > 3,
               let m = miraFrame() {
                saveEmbedOffsets(frame: p.frame, in: m)
                return   // 落点即新家，这一拍不吸
            }
        }
        let target = embedOrigin(for: p.frame.size)
        if abs(target.x - p.frame.origin.x) > 1 || abs(target.y - p.frame.origin.y) > 1 {
            p.setFrameOrigin(target)
        }
    }

    /// 穿透解锁的驻留计时：鼠标进入面板的时刻。
    private var pierceDwellSince: Date?

    /// 鼠标穿透的执行者。开着时面板不吃任何鼠标事件，点击直落后面。
    /// 解锁＝鼠标停在面板上驻留 1 秒（几何检测，穿透中收不到悬停事件），
    /// 解锁期间可正常操作（含点按钮彻底关）；移开面板立即恢复穿透。
    /// ⌥ Option 按住也解锁，留给不想等一秒的手。
    private func penetrationTick() {
        guard let p = floater, p.isVisible else { pierceDwellSince = nil; return }
        guard store.clickThrough else {
            pierceDwellSince = nil
            if p.ignoresMouseEvents { p.ignoresMouseEvents = false }
            if store.pierceUnlocked { store.pierceUnlocked = false }
            return
        }
        let inside = p.frame.contains(NSEvent.mouseLocation)
        if !inside {
            pierceDwellSince = nil
        } else if pierceDwellSince == nil {
            pierceDwellSince = Date()
        }
        let dwelled = inside && pierceDwellSince.map { Date().timeIntervalSince($0) >= 1.0 } == true
        let unlocked = dwelled || NSEvent.modifierFlags.contains(.option)
        if store.pierceUnlocked != unlocked { store.pierceUnlocked = unlocked }
        let want = !unlocked
        if p.ignoresMouseEvents != want { p.ignoresMouseEvents = want }
    }

    /// 每拍跟随。先处理穿透与面板的内嵌粘附，再处理胶囊。
    private func capsuleTick() {
        penetrationTick()
        embedFollowTick()
        guard store.floatingVisible, store.floatMode == .capsule, allowedByFrontApp() else { return }
        let mouse = NSEvent.mouseLocation

        if tucked {
            // 热区：停靠位正上方、屏幕最顶 3px。鼠标顶到天花板并驻留 0.3s 才唤出。
            guard let size = capsuleHost?.fittingSize else { return }
            let dock = dockOrigin(for: size)
            // 热区贴停靠点所在屏幕的顶边——多屏时主屏的顶不是这块屏的顶
            let dockScreen = NSScreen.screens.first {
                $0.frame.contains(NSPoint(x: dock.x + size.width / 2, y: $0.frame.midY))
            } ?? NSScreen.main
            let screenTop = dockScreen?.frame.maxY ?? 0
            let hot = NSRect(x: dock.x - 24, y: screenTop - 3,
                             width: size.width + 48, height: 3.5)
            if hot.contains(mouse) {
                if hotSince == nil { hotSince = Date() }
                if Date().timeIntervalSince(hotSince!) >= 0.3 {
                    hotSince = nil
                    // 顶部唤出的是临时态：看完鼠标一走就自己缩回去
                    showCapsule(transient: true)
                }
            } else {
                hotSince = nil
            }
        } else if let p = capsule, p.isVisible {
            // 跟随 Mirasim 窗口挪动。手在胶囊上按着、以及按过之后 0.6s 的
            // 宽限期内都让路——物理松手到 mouseUp 落位写盘之间有条毫秒缝，
            // 只挡「按住时」的话节拍会钻缝把刚拖好的胶囊吸回停靠位，
            // 实测就是「有时跟手有时不跟手」的时有时无。
            if NSEvent.pressedMouseButtons & 1 == 1, mouseInsideCapsule() {
                capsuleGraceUntil = Date().addingTimeInterval(0.6)
            }
            let size = p.frame.size
            let dock = dockOrigin(for: size)
            if Date() > capsuleGraceUntil,
               abs(dock.x - p.frame.origin.x) > 2 || abs(dock.y - p.frame.origin.y) > 2 {
                p.setFrameOrigin(dock)
            }
            // 只有临时唤出的才自动缩回；常驻胶囊一直亮着
            if capsuleTransient {
                if mouseInsideCapsule() {
                    awaySince = nil
                } else {
                    if awaySince == nil { awaySince = Date() }
                    if Date().timeIntervalSince(awaySince!) >= 1.5 {
                        awaySince = nil
                        tuck()
                    }
                }
            }
        }
    }

    // MARK: 透明度

    private func applyOpacity(hovering inside: Bool) {
        hovering = inside
        guard let p = floater, p.isVisible else { return }
        let target = (inside && store.clearOnHover) ? 1.0 : store.opacity
        guard abs(p.alphaValue - target) > 0.001 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = target
        }
    }

    // MARK: 面板位置与尺寸

    private func savedOrigin(for size: NSSize) -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: posKey) else { return nil }
        let p = NSPointFromString(s)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(NSRect(origin: p, size: size)) }
        return visible ? p : nil
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vis.maxX - size.width - 18, y: vis.maxY - size.height - 12)
    }

    /// 拖边缘/角落的实时跟随：宽度即缩放系数（内容按逻辑宽 344 排版）。
    /// 高度不由用户定——内容多高窗口就多高，松手后 syncSize 校正。
    func windowDidResize(_ notification: Notification) {
        guard let p = notification.object as? NSPanel, p === floater, p.inLiveResize else { return }
        var scale = min(1.8, max(0.7, p.frame.width / Theme.panelWidth))
        // 吸附回 1.0：矢量字在非整比下会发虚，±5% 内直接贴回最脆的原始比例
        if abs(scale - 1) < 0.05 { scale = 1 }
        if abs(scale - store.panelScale) > 0.005 {
            store.panelScale = scale   // ScaledPanelRoot 观察着它，实时重画
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let p = notification.object as? NSPanel, p === floater else { return }
        // 拖角落时高度被用户抻过，按内容的真实高度收回去
        syncSize(animated: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard let p = floater, p.isVisible,
              (notification.object as? NSPanel) === p else { return }
        savePositionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.floater else { return }
            UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: self.posKey)
        }
        savePositionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cappedSize(_ size: NSSize) -> NSSize {
        guard let vis = (floater?.screen ?? NSScreen.main)?.visibleFrame else { return size }
        return NSSize(width: size.width, height: min(size.height, vis.height - 24))
    }

    private func syncSize(animated: Bool) {
        guard let p = floater, p.isVisible else { return }
        // 用户正拖着边缘时别抢方向盘，松手后 windowDidEndLiveResize 来校正
        guard !p.inLiveResize else { return }
        let natural = naturalSize
        let sc = store.panelScale
        let fit = cappedSize(NSSize(width: natural.width * sc, height: natural.height * sc))
        // 亚像素级差别不动窗（两套测量偶有 0.5pt 抖差，跟着改窗就是肉眼可见的抽动）
        guard fit.height > 1,
              abs(fit.height - p.frame.height) >= 1 || abs(fit.width - p.frame.width) >= 1 else { return }

        var f = p.frame
        f.size = fit
        if store.embedInMirasim && store.floatMode == .panel {
            // 内嵌时定位权归内嵌锚点：这里若按「顶边不动+贴屏夹取」摆，
            // 下一拍跟随节拍再挪回去，一高一低两下就是抖动
            f.origin = embedOrigin(for: fit)
        } else {
            let top = p.frame.maxY
            f.origin.y = top - fit.height
            if let vis = (p.screen ?? NSScreen.main)?.visibleFrame {
                if f.minY < vis.minY + 8 { f.origin.y = vis.minY + 8 }
                f.origin.x = min(max(f.origin.x, vis.minX + 8), vis.maxX - fit.width - 8)
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(f, display: true)
            }
        } else {
            p.setFrame(f, display: true)
        }
    }
}
