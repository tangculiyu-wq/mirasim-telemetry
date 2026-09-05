import Foundation

/// 界面英文文案表：键是源码里的中文原文（含格式串），值是英文。
/// `L("中文")` 在英文界面下查这张表；查不到就照中文显示，不会出空白。
/// 带插值的句子用双参数 `L(zh, en)` 直接写在调用处，不进这张表。
enum EnglishStrings {
    static let table: [String: String] = [
        // 通用
        "Mirasim 遥测": "Mirasim Telemetry",
        "精确": "Exact",
        "0.1% 口径": "0.1% frame",
        "刚刚": "just now",
        "点": "pts",
        "快": "over",
        "省": "under",
        "后台": "background",
        "限流": "429",
        "小": "S", "中": "M", "大": "L",
        "5 小时": "5 hours", "7 天": "7 days", "7 天 · Fable 5.1": "7 days · Fable 5.1",
        "1 小时": "1 hour", "2 小时": "2 hours", "6 小时": "6 hours",
        "自动": "Auto", "跟随系统": "System", "中文": "中文",

        // 窗口卡
        "剩%.1f%%": "%.1f%% left",
        "超%.1f%%": "%.1f%% over",
        "匀速%@%.0f%%": "%2$.0f%% %1$@ pace",
        "  额度标定中": "  calibrating",
        "金额待精确口径": "USD needs exact source",
        "点数待精确口径": "points need exact source",
        "普通模型 ": "Regular ",
        "普通模型每点 ≈ $%.4f": "regular ≈ $%.4f/pt",
        "Fable 5.1 每点 ≈ $%.4f": "Fable 5.1 ≈ $%.4f/pt",
        "本窗口实测：": "Measured in this window: ",
        "整窗额度换成钱的两个固定参照：全花在普通模型（Opus/Sonnet 等非 Fable）上值多少，全花在 Fable 5.1 上值多少。":
            "Two fixed references for the whole window in USD: spent entirely on regular models (Opus/Sonnet, non-Fable) vs. entirely on Fable 5.1. ",
        "已用点 / 预算点 · 剩余点＝上游 /v1/limits 的原始额度点，官方额度的真身。与下一行逐位对应：这些点折成美刀就是下面的 已花 / 整窗 / 余——点数预算固定不变，折出的美元随用法呼吸。":
            "Used / budget · remaining points = raw quota points from the upstream /v1/limits. They line up with the row below: these points converted to USD are spent / whole window / remaining. The point budget is fixed; the USD figure moves with your model mix.",
        "已用占预算的百分比＝上游 used ÷ budget 原始值。可以超过 100%——上游先记账后限流，超出部分由 Mirasim 中继兜底放行。":
            "Used ÷ budget from the upstream raw values. It can exceed 100%: the upstream books first and throttles later.",
        "重置倒计时 · 每小时消耗（近 6 小时实测斜率）· 相对匀速线 · 耗尽预告（速率不可信时不给）":
            "Reset countdown · percent per hour (slope over the last 6 h) · relative to even pace · projected exhaustion (omitted when the rate is unreliable)",
        "累计": "Totals",
        "本账号 · 经 Mirasim": "this account · via Mirasim",
        "本月": "Month",
        "周 ": "Week ",
        "月 ": "Month ",
        "花费只统计当前账号经中转的调用，金额＝Mirasim 逐调用计量 × 本地价目表（与流量监控页同口径），非实付；周＝周一起，月＝1 号起。「额度」是等效折算：官方只有滚动窗口、没有固定周/月总额——周额度＝7 天窗口整窗估值，月额度＝它 ÷7 × 当月天数，都带 ≈。":
            "Spend counts only this account's calls relayed through Mirasim: per-call metering × local price list (same basis as the traffic page), not a bill. Week starts Monday, month on the 1st. \"Budget\" is a conversion: the 7-day window's whole-window estimate for the week, ÷7 × days in month for the month.",
        "只算当前登录账号（顶栏那个名字）经 Mirasim 中转的调用；切换账号后这里自动跟随，别的账号的流水不混进来；其他电脑、直连 API 的用量不在内。":
            "Only calls relayed through Mirasim for the signed-in account shown at the top. Switching accounts switches this card; other accounts, other machines and direct API usage are excluded.",

        // 面板
        "今日 ": "Today ",
        "/轮": "/turn",
        " · 首字": " · TTFT ",
        "会话": "Sessions",
        "近 6 小时活跃 · 整个会话累计": "active in last 6 h · whole-session totals",
        "正在连接": "Connecting",
        "正在连接 Mirasim": "Connecting to Mirasim",
        "Mirasim 未运行": "Mirasim is not running",
        "读不懂额度帧": "Cannot parse quota frame",
        "暂时读不到额度": "Quota unavailable",
        "正在读取 Mirasim 的额度通道": "Reading Mirasim's quota channel",
        "可操作 · 移开恢复穿透": "Interactive · move away to resume click-through",
        "穿透中 · 停留 1 秒可操作": "Click-through · hover 1 s to interact",
        "立即刷新": "Refresh now",
        "收成胶囊，存进屏幕顶边": "Collapse to a capsule at the top edge",
        "关闭设置，回到额度": "Close settings",
        "设置：透明度、缩放、额度警报、外观、开机自启……操作说明也在里面": "Settings: opacity, zoom, quota alerts, appearance, launch at login, and the how-to",
        "只在 Mirasim 里显示：关（点击开启）": "Show only in Mirasim: off (click to turn on)",
        "只在 Mirasim 里显示：开（切走会藏起）": "Show only in Mirasim: on (hides when you switch away)",
        "鼠标穿透：关（点击开启）——开后点击穿过面板直达后面的东西": "Click-through: off (click to turn on). When on, clicks pass through to what is behind.",
        "鼠标穿透：开——点击直接落到面板后面。想操作面板：鼠标停在上面 1 秒自动解锁，移开恢复穿透；解锁时点这里彻底关。":
            "Click-through: on. Clicks land behind the panel. Hover 1 s to interact; move away to resume. Click here while unlocked to turn it off.",
        "当前 Mirasim 登录账号——面板上所有数字都只属于它，切号自动跟随": "The Mirasim account signed in. Every number on the panel belongs to it; switching accounts switches the panel.",
        "按住空白处拖动移窗；拖边缘/角落缩放。位置和大小都会记住": "Drag empty space to move; drag an edge or corner to zoom. Position and size are remembered.",

        // 设置
        "窗口": "Window", "菜单栏": "Menu bar", "提醒": "Alerts", "走势": "Trend", "系统": "System",
        "透明度": "Opacity",
        "悬停时变清晰": "Clear on hover",
        "半透明状态下把鼠标移上面板即临时恢复不透明，移开还原": "When translucent, hovering restores full opacity; moving away restores it.",
        "内容缩放": "Zoom",
        "1.00×（原比）": "1.00× (original)",
        "钉在最前": "Always on top",
        "盖住其他窗口，浏览器全屏也压得住": "Stays above other windows, including full-screen browsers.",
        "只在 Mirasim 里显示": "Show only in Mirasim",
        "切到别的应用时面板与胶囊自动藏起，切回来自动现身": "Hides the panel and capsule when you switch to another app; shows again when you come back.",
        "嵌入 Mirasim 窗口": "Embed in Mirasim window",
        "面板吸附在 Mirasim 窗口内、跟着它移动，它切到后台就藏——看着像长在里面。嵌着时直接拖面板可微调停靠位置（会记住）；换角落即恢复默认位。零侵入、不影响会话。":
            "Docks the panel inside the Mirasim window and follows it; hides when Mirasim goes to the background. Drag the panel while embedded to adjust the offset (remembered); changing the corner restores the default. Nothing is injected.",
        "嵌入位置": "Embed corner",
        "右上": "Top right", "左上": "Top left", "右下": "Bottom right", "左下": "Bottom left",
        "鼠标穿透": "Click-through",
        "点击直接落到面板后面的东西上，面板变成纯仪表盘（配嵌入模式最顺手）。要操作面板：鼠标停在上面 1 秒自动解锁（或按住 ⌥），移开即恢复穿透；标题栏光标按钮和菜单栏右键都能彻底关。":
            "Clicks pass through to what is behind; the panel becomes a pure gauge (best with embed). To interact: hover 1 s (or hold ⌥); move away to resume. The cursor button in the title bar and the menu bar menu turn it off.",
        "外观": "Appearance", "深色": "Dark", "浅色": "Light",
        "语言": "Language",
        "会话卡": "Sessions card",
        "近 6 小时活跃的每个 Claude Code 会话各一行：整个会话累计的 token、美元、调用次数": "One row per Claude Code session active in the last 6 hours: whole-session tokens, USD and calls.",
        "图标旁显示百分比": "Show percent next to icon",
        "跟随哪个窗口": "Which window to follow",
        "自动＝永远盯剩余最少的那个窗口": "Auto = always the window with the least left",
        "额度警报": "Quota alert",
        "任一窗口用量越过警戒线：弹出面板 + 提示音。每个窗口周期只响一次，窗口重置后重新武装": "When any window crosses the threshold: show the panel and play a sound. Once per window period; re-armed after reset.",
        "警戒线": "Threshold",
        "走势线跨度": "Trend span",
        "卡片标题旁那根迷你走势线回看多久（本机采样）": "How far back the mini trend line next to each card title looks (local samples).",
        "开机自启": "Launch at login",
        "经系统「登录项」注册；首次开启可能需要在 系统设置 › 通用 › 登录项 里批准": "Registered as a Login Item; the first time may need approval in System Settings › General › Login Items.",
        "重置窗口位置": "Reset position",
        "重扫账本": "Rescan ledger",
        "退出": "Quit",
        "切换账号": "Switch account",
        "记住登录过的账号": "Remember signed-in accounts",
        "清空账号库": "Clear account vault",
        "在 Mirasim 里登录过的账号自动记进本机账号库（~/Library/Application Support/EduHuan/accounts.json，仅本人可读），之后点面板顶上的账号名即可一键切换。凭据是 Mirasim 写出的加密块，本程序不解析、不外发。": "Accounts you sign in to in Mirasim are remembered in a local vault (~/Library/Application Support/EduHuan/accounts.json, readable only by you); click the account name at the top of the panel to switch with one click. The credentials are the encrypted block Mirasim writes; this program neither parses nor sends them anywhere.",
        "当前 Mirasim 登录账号——面板上所有数字都只属于它。点开可一键切到登录过的其他账号": "The Mirasim account signed in. Every number on the panel belongs to it. Open to switch to another account you have signed in to.",
        "怎么用": "How to use",

        // 明细
        "耗尽预演": "PROJECTION",
        "样本不足，暂不预测": "Not enough samples yet",
        "每小时 %.2f%%": "%.2f%% per hour",
        "每小时 %.2f%%，重置前用不完": "%.2f%% per hour, will not run out before reset",
        "每小时 %.2f%%，约 %@ 后用尽（%@）": "%.2f%% per hour, runs out in about %@ (%@)",
        "最近调用": "RECENT CALLS",
        "待回填": "pending",
        "口径": "SOURCE",
        "来源": "Source",
        "会话回环 /v1/limits 的原始额度点": "Raw quota points from the session's loopback /v1/limits",
        "Mirasim mirachannel 帧（与 limits 同源）": "Mirasim mirachannel frame (same origin as limits)",
        "分辨率": "Resolution",
        "完整小数": "Full decimals",
        "0.1 个百分点": "0.1 percentage point",
        "上游采集": "Captured",
        "预算口径": "Budget basis",
        "Mirasim 中继套餐的记账，非 Anthropic 官方直连标称": "Mirasim relay plan accounting, not Anthropic's direct-plan figure",
        "中继": "Relay",
        "百分比＝已用点 ÷ 预算点，直接取自上游，不做折算，也不按历史速率外推。读不到时显示「读不到」而非估算值。":
            "Percent = used ÷ budget points, taken from the upstream as is, never converted or extrapolated. When unavailable the panel says so instead of estimating.",
        "当前没有活跃的 Mirasim 会话，读到的是 0.1% 分辨率的帧口径。数值仍是上游真值，只是小数位被上游四舍五入掉了。":
            "No active Mirasim session, so the values come from the 0.1%-resolution frame. Still upstream values, only rounded.",
        "账号": "ACCOUNT",
        "登录": "Signed in",
        "套餐": "Plan",
        "（已付费）": " (paid)",
        "到期": "Expires",
        "中继状态": "Relay status",
        "正常": "ok",

        // 菜单
        "显示悬浮窗": "Show panel",
        "显示": "Show", "收起": "Hide",
        "显示为胶囊": "Show as capsule",
        "鼠标穿透（停留 1 秒可操作）": "Click-through (hover 1 s to interact)",
        "只在 Mirasim 前台时显示": "Show only when Mirasim is in front",
        "把悬浮窗移回右上角": "Move panel to top right",
        "菜单栏显示百分比": "Percent in menu bar",
        "自动（剩得最少的）": "Auto (least remaining)",
        "主要盯哪个窗口": "Primary window",
        "悬浮窗大小": "Panel size",
        "也可直接拖窗口边缘/角落": "You can also drag the window edge or corner",
        "窗口缩放": "Zoom",
        "鼠标移上去时变清晰": "Clear on hover",
        "不透明": "Opaque",
        "轻微透 85%": "Slightly translucent 85%",
        "半透明 70%": "Translucent 70%",
        "很透 55%": "Very translucent 55%",
        "几乎隐形 40%": "Nearly invisible 40%",
        "开机自动启动": "Launch at login",
        "退出 Mirasim 遥测": "Quit Mirasim Telemetry",
        "Mirasim 遥测 — 暂时读不到额度": "Mirasim Telemetry — quota unavailable",

        // 胶囊
        "收进顶边——鼠标顶到屏幕顶部停一下会再滑出来": "Tucked at the top edge; hold the mouse at the top of the screen to slide it out",
        "点一下展开完整面板；按住拖到哪都行（位置会记住，拖回 Mirasim 窗口顶边即恢复自动吸附）；右键出菜单":
            "Click to expand the panel; drag anywhere (remembered; drag back to the top of the Mirasim window to re-dock); right-click for the menu",

        // Store
        "某窗口": "a window",
    ]
}
