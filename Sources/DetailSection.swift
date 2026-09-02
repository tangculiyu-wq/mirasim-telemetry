import SwiftUI

/// 明细。有的仪表把它拆成「耗尽预演 / 口径说明」两个标签页；
/// 在一个 344pt 宽的弹窗里，标签页的切换成本高于它省下的高度，
/// 这里改成一段可展开的内容，读完即收。
struct DetailSection: View {
    @ObservedObject var store: Store
    let snapshot: QuotaSnapshot
    let dark: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 13) {
                if let warn = store.integrityWarning {
                    Notice(text: warn, tone: .warn, dark: dark)
                }
                if let warn = store.coverageWarning {
                    Notice(text: warn, tone: .warn, dark: dark)
                }

                forecast

                if snapshot.windows.contains(where: { $0.usedPoints != nil }) == false {
                    Notice(text: "当前没有活跃的 Mirasim 会话，读到的是 0.1% 分辨率的帧口径。数值仍是上游真值，只是小数位被上游四舍五入掉了。",
                           tone: .info, dark: dark)
                }

                caliber
                account
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 15)
        }
    }

    // MARK: 耗尽预演

    private var forecast: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle("耗尽预演")

            let rows = snapshot.windows.sorted { $0.usedPercent > $1.usedPercent }
            ForEach(rows) { w in
                let burn = store.burns[w.name]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(w.displayName)
                        .font(Theme.label(11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .leading)
                    Text(line(for: w, burn: burn))
                        .font(Theme.label(11.5))
                        .foregroundStyle(color(for: w, burn: burn))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 预演文案。速率不可信时明说「样本不足」，不硬给一个时刻——
    /// 一个凭两三分钟斜率外推出的耗尽时间，比不给更糟。
    private func line(for w: QuotaWindow, burn: Burn?) -> String {
        if w.isExhausted {
            return "已用满，\(Fmt.duration(w.resetAt.timeIntervalSinceNow)) 后恢复"
        }
        guard let b = burn, b.trustworthy else {
            return "样本不足，暂不预测"
        }
        if b.percentPerHour <= 0.01 {
            return "近 \(Fmt.duration(b.span)) 几乎没消耗"
        }
        guard let eta = b.exhaustAt else {
            return String(format: "每小时 %.2f%%", b.percentPerHour)
        }
        if eta > w.resetAt {
            return String(format: "每小时 %.2f%%，重置前用不完", b.percentPerHour)
        }
        return String(format: "每小时 %.2f%%，约 %@ 后用尽（%@）",
                      b.percentPerHour,
                      Fmt.duration(eta.timeIntervalSinceNow),
                      Fmt.clock(eta))
    }

    private func color(for w: QuotaWindow, burn: Burn?) -> Color {
        guard let b = burn, b.trustworthy, !w.isExhausted else { return .secondary }
        if let eta = b.exhaustAt, eta < w.resetAt {
            return Theme.accent(0.92, dark: dark).0
        }
        return .secondary
    }

    // MARK: 口径

    private var caliber: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("口径")

            KV("来源", snapshot.precision == .exact
               ? "会话回环 /v1/limits 的原始额度点"
               : "Mirasim mirachannel 帧（与 limits 同源）")
            KV("分辨率", snapshot.precision == .exact ? "完整小数" : "0.1 个百分点")
            KV("上游采集", Fmt.clock(snapshot.capturedAt))
            KV("预算口径", "Mirasim 中继套餐的记账，非 Anthropic 官方直连标称")
            if let host = snapshot.account.host { KV("中继", host) }

            Text("百分比＝已用点 ÷ 预算点，直接取自上游，不做折算，也不按历史速率外推。读不到时显示「读不到」而非估算值。")
                .font(Theme.label(10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
    }

    // MARK: 账号

    private var account: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("账号")
            if let n = snapshot.account.name { KV("登录", n) }
            if let p = snapshot.account.plan {
                KV("套餐", p.uppercased() + (snapshot.account.paid == true ? "（已付费）" : ""))
            }
            if let e = snapshot.account.planExpiry {
                KV("到期", "\(Fmt.day(e))（还有 \(Fmt.duration(e.timeIntervalSinceNow))）")
            }
            if let r = snapshot.account.relayStatus { KV("中继状态", r == "ok" ? "正常" : r) }
        }
    }
}

// MARK: - 小件

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}

struct KV: View {
    let k: String
    let v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(k)
                .font(Theme.label(11.5))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(v)
                .font(Theme.label(11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Notice: View {
    enum Tone { case info, warn }
    let text: String
    let tone: Tone
    let dark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: tone == .warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(tone == .warn
                                 ? Theme.accent(0.95, dark: dark).0
                                 : Color.secondary)
                .padding(.top, 1)
            Text(text)
                .font(Theme.label(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(dark ? 0.06 : 0.045))
        )
    }
}
