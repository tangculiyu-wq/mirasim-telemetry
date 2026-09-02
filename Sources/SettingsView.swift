import SwiftUI
import ServiceManagement

/// 面板内嵌设置页。标题栏齿轮进入（顶替原来的问号），
/// 所有开关直接绑 Store 的 @Published——各处 sink 早就挂好，改了即生效。
/// 原问号里的操作说明搬到页底，不丢。
struct SettingsView: View {
    @ObservedObject var store: Store
    let dark: Bool
    var tips: TipBox? = nil
    var onResetPosition: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            group("窗口") {
                sliderRow("透明度", value: $store.opacity, in: 0.3...1.0,
                          label: String(format: "%.0f%%", store.opacity * 100))
                toggleRow("悬停时变清晰", isOn: $store.clearOnHover,
                          tip: "半透明状态下把鼠标移上面板即临时恢复不透明，移开还原")
                sliderRow("内容缩放", value: scaleBinding, in: 0.7...1.8,
                          label: store.panelScale == 1 ? "1.00×（原比）"
                                                       : String(format: "%.2f×", store.panelScale))
                toggleRow("钉在最前", isOn: $store.alwaysOnTop,
                          tip: "盖住其他窗口，浏览器全屏也压得住")
                toggleRow("只在 Mirasim 里显示", isOn: $store.onlyInMirasim,
                          tip: "切到别的应用时面板与胶囊自动藏起，切回来自动现身")
                toggleRow("嵌入 Mirasim 窗口", isOn: $store.embedInMirasim,
                          tip: "面板吸附在 Mirasim 窗口内、跟着它移动，它切到后台就藏——看着像长在里面。嵌着时直接拖面板可微调停靠位置（会记住）；换角落即恢复默认位。零侵入、不影响会话。")
                if store.embedInMirasim {
                    pickerRow("嵌入位置", selection: $store.embedCorner,
                              options: [("topRight", "右上"), ("topLeft", "左上"),
                                        ("bottomRight", "右下"), ("bottomLeft", "左下")])
                }
                toggleRow("鼠标穿透", isOn: $store.clickThrough,
                          tip: "点击直接落到面板后面的东西上，面板变成纯仪表盘（配嵌入模式最顺手）。要操作面板：鼠标停在上面 1 秒自动解锁（或按住 ⌥），移开即恢复穿透；标题栏光标按钮和菜单栏右键都能彻底关。")
                pickerRow("外观", selection: $store.appearanceOverride,
                          options: [("auto", "跟随系统"), ("dark", "深色"), ("light", "浅色")])
            }

            group("菜单栏") {
                toggleRow("图标旁显示百分比", isOn: $store.showPercentInMenuBar)
                pickerRow("跟随哪个窗口", selection: pinnedBinding,
                          options: [("auto", "自动"), ("5h", "5 小时"), ("7d", "7 天"), ("7d_fable", "Fable 5.1")],
                          tip: "自动＝永远盯剩余最少的那个窗口")
            }

            group("提醒") {
                toggleRow("额度警报", isOn: $store.alertEnabled,
                          tip: "任一窗口用量越过警戒线：弹出面板 + 提示音。每个窗口周期只响一次，窗口重置后重新武装")
                if store.alertEnabled {
                    sliderRow("警戒线", value: $store.alertThreshold, in: 0.5...0.99,
                              label: String(format: "%.0f%%", store.alertThreshold * 100))
                }
            }

            group("走势") {
                pickerRow("走势线跨度", selection: trendBinding,
                          options: [("3600", "1 小时"), ("7200", "2 小时"), ("21600", "6 小时")],
                          tip: "卡片标题旁那根迷你走势线回看多久（本机采样）")
            }

            group("系统") {
                toggleRow("开机自启", isOn: loginBinding,
                          tip: "经系统「登录项」注册；首次开启可能需要在 系统设置 › 通用 › 登录项 里批准")
                HStack(spacing: 8) {
                    SettingsButton(title: "重置窗口位置", action: onResetPosition)
                    SettingsButton(title: "重扫账本", action: { store.refresh() })
                    Spacer(minLength: 4)
                    SettingsButton(title: "退出", destructive: true, action: onQuit)
                }
            }

            help
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: 绑定

    /// 缩放滑块：±5% 内吸附回 1.0，非整比矢量字会发虚。
    private var scaleBinding: Binding<Double> {
        Binding(get: { store.panelScale },
                set: { store.panelScale = abs($0 - 1) < 0.05 ? 1 : $0 })
    }

    private var pinnedBinding: Binding<String> {
        Binding(get: { store.pinnedWindow ?? "auto" },
                set: { store.pinnedWindow = $0 == "auto" ? nil : $0 })
    }

    private var trendBinding: Binding<String> {
        Binding(get: { String(Int(store.trendBack)) },
                set: { store.trendBack = Double($0) ?? 7200 })
    }

    /// 开机自启直读系统「登录项」的注册状态，不自己另存一份真相。
    private var loginBinding: Binding<Bool> {
        Binding(get: { SMAppService.mainApp.status == .enabled },
                set: { on in
                    let svc = SMAppService.mainApp
                    do { if on { try svc.register() } else if svc.status == .enabled { try svc.unregister() } }
                    catch {}
                    store.objectWillChange.send()   // 让开关立即回读真实状态
                })
    }

    // MARK: 行件

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.label(11, .semibold))
                .foregroundStyle(.tertiary)
                .textCase(nil)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(dark ? 0.055 : 0.042))
        )
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, tip: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.label(12, .medium))
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .hoverTip(tips, tip ?? "", delay: 0.8)
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           in range: ClosedRange<Double>, label current: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(Theme.label(12, .medium))
                Spacer(minLength: 4)
                Text(current)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func pickerRow(_ label: String, selection: Binding<String>,
                           options: [(String, String)], tip: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Theme.label(12, .medium))
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .hoverTip(tips, tip ?? "", delay: 0.8)
    }

    /// 原问号按钮的操作说明，原文迁入。
    private var help: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("怎么用")
                .font(Theme.label(11, .semibold))
                .foregroundStyle(.tertiary)
            Text("""
            · 双击桌面图标 / 点菜单栏小环 → 唤出或收起
            · ✕ → 收成胶囊，存进屏幕顶边；鼠标顶到最顶停半秒滑出，点它回面板
            · 拖任意空白处移动、拖边缘缩放，位置和大小都会记住
            · 右键（面板 / 胶囊 / 菜单栏）→ 同样一份设置菜单
            · 百分比与点数＝上游真值；美元带 ≈＝按官方牌价折算
            """)
            .font(Theme.label(10.5))
            .foregroundStyle(.secondary)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }
}

/// 小号按钮，配面板气质：实心浅面、无边框。
struct SettingsButton: View {
    let title: String
    var destructive: Bool = false
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label(11, .semibold))
                .foregroundStyle(destructive ? Color(red: 1, green: 0.36, blue: 0.32) : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    Capsule().fill(Color.primary.opacity(hover.on ? 0.13 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}
