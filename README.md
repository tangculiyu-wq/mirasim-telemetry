# Mirasim 遥测

macOS 上的 Mirasim 额度仪表：一块常驻桌面、可贴进 Mirasim 窗口角落的悬浮面板，
加一枚跟着额度变色的菜单栏小环。只读本机回环接口与本机流水文件，**不往 Mirasim 里注入任何东西**，
不开调试端口，不改 Mirasim 的任何文件。

<p align="center">
<img src="docs/images/panel-dark.png" width="360" alt="深色面板">
&nbsp;&nbsp;
<img src="docs/images/panel-light.png" width="360" alt="浅色面板">
</p>

> An unofficial quota dashboard for the Mirasim desktop client on macOS. It reads the client's
> local loopback endpoints and local usage logs only — no CDP injection, no debug port, no file
> patching. Shows 5h / 7d / 7d·Fable windows with raw points, USD equivalents, burn rate,
> per-model speed, and weekly/monthly spend. Not affiliated with Mirasim or Anthropic.
> Documentation is in Chinese.

## 面板上有什么

每个额度窗口一张卡（5 小时 / 7 天 / 7 天 · Fable 5.1）：

- **百分比**：上游原始额度点 `used ÷ budget`，直接相除，五位小数；右侧「剩」多少
- **走势线**：近 1 / 2 / 6 小时的用量曲线（设置里切）
- **进度条**：带匀速游标，用量条越过它＝比匀速快
- **点数行**：`已用 / 预算 余多少 点`
- **钱行**：`≈已花 / ≈整窗 余≈多少 · 窗口内调用次数`
- **等价行**（7 天两张卡）：`560,000 点 ≈ 普通模型 $5,589 / Fable 5.1 $1,922`，见下文「额度点的扣法」
- **时间行**：逐秒跳的重置倒计时、每小时消耗速率、快慢于匀速多少、按当前速率几点用尽

其下「累计」卡：本周（周一起）/ 本月（1 号起）的本机花费、近 14 天逐日柱状（指到柱上看单日）、
日均、月底外推。再下一条速度栏：**近期在跑的每个模型各一行**——tok/s、每轮中位耗时、首字≈，
子代理的调用也算在内；今日花费与次数在右下角。

<p align="center">
<img src="docs/images/panel-dark-detail.png" width="360" alt="展开明细：耗尽预演与口径">
&nbsp;&nbsp;
<img src="docs/images/capsule-dark.png" width="200" alt="胶囊形态">
</p>

「大」尺寸再展开明细：耗尽预演（各窗口几点用尽）、口径（数据来源、分辨率、上游采集时刻、预算口径）、账号与套餐。
收成胶囊后只剩一枚小环与主窗口百分比，可存进屏幕顶边，点一下展开。

## 三条准确性规矩

**1. 百分比是真值，美元是估算，两者分开标。**
百分比来自 `/v1/limits` 的原始额度点。美元一律带 `≈`：按 **Mirasim 自己的逐调用计量**
（`~/.mirasim/insights/usage-*.ndjson`，含 relay 回填的 token）× 本地价目表折算，
与 Mirasim 流量监控页同口径；断流重试等 Claude Code 账本记不到的调用也计入。
整窗值 = 本窗实花 ÷ 已用百分比逆推，所以已花、整窗、余量与卡上的百分比永远互相咬合。

**2. 读不到就说读不到，绝不外推。**
Mirasim 没开、令牌拿不到时显示空态，不拿旧锚点推算一个和真值长得一样的数字。

**3. 数据一律附真实年龄。**
面板底部常驻「精确 · 刚刚」这类标记，超过 90 秒变色；速度行超过 90 秒没新请求就压暗，
并标出「N 分钟前」。菜单栏那枚环在数据陈旧时整枚去色。

所有金额与统计**只算当前登录的账号**：换号后面板自动跟随，其他账号的流水不混进来。

## 额度点的扣法（实测）

额度以「点」计，点不是钱。逐小时把点数增量与同期流水按官方价目算的美元对齐，
只取单一模型在跑的「纯净小时」，得到：

| 模型 | 每 $1 官方标价扣多少点 | 每点折合 | 备注 |
|---|---|---|---|
| Opus / Sonnet 等普通模型 | 100 点 | $0.0100 | 纯 Opus 小时实测 96–101 |
| Fable 5 | 200 点（按 Fable 5 标价） | $0.0050 | 纯 Fable 5 小时实测 197–201 |
| Fable 5.1 | 200 点（**仍按 Fable 5 标价**） | ≈$0.0034 | 用 Fable 5 权重预测整个 Fable 窗偏差 −0.2% |

三条推论：

- Fable 调用同时扣 7 天窗与 Fable 窗，两窗增量 1:1；普通模型只扣 7 天窗，Fable 窗纹丝不动。
- Fable 5.1 的官方标价便宜了（缓存读 $1 → $0.25），但扣点仍按 Fable 5 的价目。
  同样的点在 5.1 上能跑的 token 与 5 一样多；面板上 5.1 的美元数比 5 小，是同样的活标价更低，不是额度变少。
- 1 点 ≈ 1 分钱普通模型标价 ≈ 半分钱 Fable 标价，Fable 每 token 扣的点约为 Opus 的 4 倍。

等价行就按这个算：普通模型的每点美元由本窗口内非 Fable 的实花 ÷ 非 Fable 占的点实测，
Fable 5.1 的每点美元把窗口内全部 Fable 调用按 5.1 价目重算后 ÷ Fable 窗已用点。
样本不足时退回上表的公式。审计脚本在 [`scripts/points-audit/`](scripts/points-audit/)：

```bash
perl scripts/points-audit/ptsfit.pl  usr_xxx   # 逐小时对账：点增量 vs 各模型美元
perl scripts/points-audit/ptsfit2.pl usr_xxx   # 每类模型的点 ÷ 各价目美元
perl scripts/points-audit/ptsfit3.pl usr_xxx   # Fable 5.1 按哪套权重扣点的三个假设检验
```

`usr_xxx` 是 Mirasim 流水里的 `userId`，`--diag` 会打印出来。脚本读的是本机
`~/Library/Application Support/EduHuan/samples.json`（本应用落盘的百分比采样）与 Mirasim 流水。

## 数据来源

| 数据 | 来源 | 说明 |
|---|---|---|
| 已用点、预算点、重置时刻 | `http://127.0.0.1:<会话端口>/v1/limits` | 完整小数；令牌只在会话进程环境里，按进程从 `ps eww` 配对，读到的账号与帧不一致时整份弃用 |
| 百分比、重置时刻（退路） | `ws://127.0.0.1:<port>/mirachannel/ws` 的 relay 帧 | 与 Mirasim 界面同源，0.1% 分辨率；只需 Mirasim 开着 |
| 花费 | `~/.mirasim/insights/usage-*.ndjson` | relay 逐调用计量，token 由云端回填并原地改写，故按文件 (大小, 修改时间) 重解析而非游标 |
| 价目表 | `~/.mirasim/models-dev-cache.json` | 只抽四项价格成紧凑表；缺失或零价时用内置官方价目 |
| 速度 | insights 的 `durationMs` + Claude Code 账本 `~/.claude/projects/**/*.jsonl` | 按 `providerCallId == requestId` 精确配对；首字≈ 为第一个内容块落盘时刻，是真实首字的上界 |

两路额度源同源（帧里 `usage.source` 为 `relay-limits`），两路都在时做交叉校验，差值超过 0.35 个百分点在明细里告警。
预算点是 **Mirasim 中继侧套餐的记账**，与 Anthropic 官方直连套餐的标称不是一回事。

不接触任何凭证，不发起对外网络请求，不写入 Mirasim 的任何文件；只读本机回环端口与本机文件。
落盘只有 `~/Library/Application Support/EduHuan/` 下的采样（保留 24 小时）与标定文件，以及 UserDefaults 里的偏好。

## 用

- **拖**面板空白处移动；拖**边缘或角落**缩放（0.7×–1.8×，内容整体缩放，命中区跟着变）
- 标题栏按钮：嵌入 Mirasim · 鼠标穿透 · 刷新 · 大小（小 / 中 / 大）· 收成胶囊 · 设置
- **嵌入 Mirasim**：面板贴在 Mirasim 窗口的某个角（四角可选），跟着窗口移动缩放；
  顶部默认让出工具栏的高度，拖动后记住偏移；Mirasim 不在前台时自动隐藏
- **鼠标穿透**：面板不接鼠标，直接操作下面的东西；鼠标在面板上**停留 1 秒**（或按住 ⌥）临时可操作，移开恢复
- **右键**面板或菜单栏图标：显示 / 胶囊 / 穿透 / 只在 Mirasim 前台时显示 / 钉在最前 / 移回右上角 /
  菜单栏百分比 / 主要盯哪个窗口 / 大小 / 缩放 / 透明度 / 开机自启 / 刷新 / 退出
- **设置**（齿轮）：内容缩放、钉在最前、只在 Mirasim 里显示、嵌入位置、鼠标穿透、外观（跟随系统 / 深 / 浅）、
  菜单栏百分比与跟随哪个窗口、额度警报与警戒线（50%–99%）、走势线跨度、开机自启、重置窗口位置、重扫账本
- **菜单栏**那枚环跟的是剩余最少的窗口（可改），左键开合面板

速度行、花费与点数在 Mirasim 流水文件一变就刷新（1.2–5 秒），额度点每 20 秒读一次，帧到即更新。

## Windows / Linux：跨平台版

[`node/`](node/) 下是同一套口径的 **Node 22+ 零依赖脚本**：后台算数据，面板是本机网页
（`http://127.0.0.1:5990/`，可用 Edge/Chrome 应用窗口模式开成独立小窗），数据一变经 SSE 推到页面。
Windows 特有的三处（找 Mirasim 进程、读会话令牌、开机自启）照 Windows 接口写成，**没有实机验证**；
装好先跑 `--doctor`，哪一步没通它会说，怎么改见 [node/README.md](node/README.md)。

<p align="center">
<img src="docs/images/web-panel-dark.png" width="300" alt="网页面板 深色">
&nbsp;&nbsp;
<img src="docs/images/web-panel-light.png" width="300" alt="网页面板 浅色">
</p>

```powershell
node node\mirasim-telemetry.mjs --doctor                          # 先自检
node node\mirasim-telemetry.mjs --app                             # 起服务，应用窗口打开面板
powershell -ExecutionPolicy Bypass -File node\install-windows.ps1  # 登录自启
```

## 装 / 卸（macOS 原生版）

只需 **Command Line Tools**，不需要完整 Xcode（源码不用 `@State` 等宏，全部本地状态走 `ObservableObject`）。
macOS 14 或更新。

```bash
./install.sh                             # 构建 + 装到 ~/Applications + 启动
"~/Applications/Mirasim 遥测.app/Contents/MacOS/Mirasim 遥测" --login on|off|status   # 开机自启

./scripts/uninstall-miraquota.sh         # 从 MiraQuota 迁移过来时卸掉旧体系（先备份到 ~）
```

bundle id 为 `local.eduhuan.ring`，偏好按它存；改了会丢掉调好的位置与透明度。
临时签名（ad-hoc），不提供预编译包：未签名的下载包会被 Gatekeeper 隔离，本地构建没有这个问题。

## 排障

```bash
"~/Applications/Mirasim 遥测.app/Contents/MacOS/Mirasim 遥测" --diag
```

逐层报告：进程表 → Mirasim 是否在跑 → 会话路由与令牌 → `/v1/limits` 各窗口原始值 → mirachannel 帧 →
交叉校验 → 价目探针 → 今日账本与回填缺口 → 等价换算单价 → 速度配对率。

版面可以离屏渲染，不需要屏幕录制权限：

```bash
遥测 --render /tmp/p.png [--light] [--detail] [--wait 秒]
遥测 --render-capsule /tmp/c.png
遥测 --render-icons /tmp/i.png [--light]
```

## 与 MiraQuota 的关系

本项目替代 [MiraQuota](https://github.com/Heartcoolman/MiraQuota)。MiraQuota 把控件经 CDP 注入 Mirasim 的渲染进程，
要求 Mirasim 以 `--remote-debugging-port` 启动；本项目是独立窗口，靠 CGWindowList 跟着 Mirasim 的窗口贴角，
不需要调试端口，也不存在「本机任何进程都能在 Mirasim 里执行 JS」的代价。
口径上的差别见「三条准确性规矩」：不走满额回归标定，不在读不到时推算。

## 已知限制

- 原生面板只有 macOS；Windows / Linux 用 `node/` 下的跨平台版（网页面板，无法钉在最前，Windows 未实机验证）。
- 首字≈ 是上界：本机没有逐请求的首 token 时刻，取的是第一个内容块落盘的时刻（思考型模型的第一块是整段思考）。
- 本机只见本机的调用：同一账号在别的电脑上用，那边的花费不在账上，已花与整窗是下界。
- 美元是按官方价目折算的等价额，不是账单。
- `/v1/limits` 未公开，Mirasim 改动后可能失效，届时退回帧口径的 0.1% 百分比。

## 源码

```
Sources/
  Model.swift           数据模型：窗口、匀速线、耗尽速率、账号
  SessionScanner.swift  从进程表配对「会话端口 + 令牌」
  LimitsClient.swift    精确源 /v1/limits，含同账号校验
  RelayClient.swift     mirachannel WebSocket
  CostLedger.swift      花费账本（insights 逐调用 × 价目表），按目标模型重算
  Calibrator.swift      每点单价的回退标定（窗口早于本机计量起点时用）
  SpeedStats.swift      速度：耗时 × token 精确配对，含子代理账本
  Store.swift           两路合并、采样、花费、等价换算、警报
  Theme.swift           配色 / 字体 / 格式化
  StatusIcon.swift      菜单栏那枚环
  PanelView.swift       悬浮面板与速度栏
  WindowCard.swift      窗口卡 / 累计卡
  CapsuleView.swift     胶囊形态
  SettingsView.swift    设置面板
  DetailSection.swift   明细
  AppDelegate.swift     窗口、嵌入跟随、穿透、提示气泡、菜单
  Preview.swift         离屏渲染
  Diagnose.swift        --diag
  main.swift            入口、命令行参数、单实例
```

MIT License。非官方项目，与 Mirasim、Anthropic 无关。
