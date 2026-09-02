# Mirasim 遥测 · 跨平台版（Windows / Linux / macOS）

macOS 原生版的另一种形态：一个 **零依赖的 Node 脚本**在后台算数据，面板是本机网页
（`http://127.0.0.1:5990/`），可以用浏览器的应用窗口模式开成一个独立小窗。
口径、算法与 macOS 版完全一致：百分比取 `/v1/limits` 原始额度点，美元按 Mirasim 逐调用计量 ×
官方价目，整窗 = 实花 ÷ 百分比，等价行按实测的扣点公式，速度按请求号精确配对（含子代理）。

只读、只绑 127.0.0.1，不注入 Mirasim、不开调试端口、不改 Mirasim 的任何文件。

> **Windows 上没有实机验证过。** 通用逻辑（帧、账本、速度、面板）在 macOS 上用同一份脚本跑通并与原生版对过数；
> Windows 特有的三处——找 Mirasim 进程、读会话令牌、开机自启——照 Windows 的接口写的，没机器跑。
> 装好先执行 `--doctor`，它会逐层告诉你哪一步没通、该怎么补；不通的地方在 `mirasim-telemetry.mjs` 里都有注释标出，改起来不难。

## 要求

- Node.js **22 或更新**（`fetch` 与 `WebSocket` 自 22 起内置，不用 npm install）
- Mirasim 桌面版在本机运行（读它的本地接口）
- 想要「精确」口径（原始点数、五位小数）需要有一个活跃的 Claude Code 会话，令牌从会话进程里取；
  没有会话时退回 Mirasim 帧的 0.1% 百分比

## 跑起来

```powershell
node mirasim-telemetry.mjs --doctor      # 先自检：Mirasim 进程 → 端口 → 帧 → 会话令牌 → /v1/limits → 流水 → 账本
node mirasim-telemetry.mjs               # 起服务并在浏览器打开面板
node mirasim-telemetry.mjs --app         # 用 Edge/Chrome 的应用窗口模式打开（无地址栏，像独立小窗）
```

开机自启（放一个隐藏窗口的快捷方式到「启动」文件夹，不需要管理员）：

```powershell
powershell -ExecutionPolicy Bypass -File install-windows.ps1
powershell -ExecutionPolicy Bypass -File uninstall-windows.ps1 [-Purge]
```

Linux / macOS 直接 `node mirasim-telemetry.mjs`，常驻用 systemd user unit 或 LaunchAgent；macOS 上建议用仓库主体的原生版。

## Windows 上会话令牌怎么拿

`/v1/limits` 挂在 Mirasim 给每个会话开的回环端口上，要带该会话的令牌；令牌不落盘，只在会话进程的环境变量里。
脚本按两步自动找：

1. `Get-CimInstance Win32_Process`：Mirasim 拉起会话时若把 `--settings` JSON 放在命令行上，直接从中取 `ANTHROPIC_BASE_URL` 与 `ANTHROPIC_AUTH_TOKEN`
2. 读 node / claude 进程的**环境块**（PowerShell 内嵌一段 C#：`NtQueryInformationProcess` → PEB → `ProcessParameters` → `Environment`，同用户进程不需要管理员；x64 偏移 `0x20 / 0x80 / 0x3F0`）

两步都空时 `--doctor` 会提示手工给：在 Claude Code 会话里执行

```powershell
echo $env:ANTHROPIC_BASE_URL
echo $env:ANTHROPIC_AUTH_TOKEN
node mirasim-telemetry.mjs --router-base http://127.0.0.1:端口/密钥 --router-token 令牌
```

基址必须整段保留（新版 URL 带路径密钥，只给端口是 401）。令牌随会话存亡，会话重开要换。

## 面板

与 macOS 版同一版面：每个额度窗口一张卡（百分比、走势、进度条与匀速游标、点数、已花/整窗/余、
7 天卡的等价行、倒计时与耗尽时刻），累计卡（周/月/日均/月底外推/近 14 天柱状），速度栏（逐模型 tok/s、每轮耗时、首字≈，今日花费）。
跟随系统深浅色。数据一变即由 SSE 推到页面，倒计时逐秒本地走。

钉在最前：浏览器窗口做不到，用 [PowerToys](https://learn.microsoft.com/windows/powertoys/) 的
「Always On Top」（默认 Win+Ctrl+T）把那个应用窗口钉住即可。

其它接口：`/quota.json`（全部结论）、`/events`（SSE）、`POST /refresh`（让 Mirasim 绕过缓存重问一次）。

## 数据与落盘

读：`%USERPROFILE%\.mirasim\insights\usage-*.ndjson`（流水）、`%USERPROFILE%\.mirasim\models-dev-cache.json`（价目）、
`%USERPROFILE%\.claude\projects\**\*.jsonl`（速度配对）。写：只有 `%USERPROFILE%\.mirasim-telemetry\`
下的百分比采样（24 小时）与等价单价缓存。

## 可能要自己改的地方

| 现象 | 看哪 |
|---|---|
| `--doctor` 第 1 步找不到 Mirasim 进程 | `mirasimProcesses()`：按命令行含 `server.cjs` 找。Windows 版 Mirasim 若换了入口文件名，把那串改掉 |
| 第 4 步 0 条会话路由 | `sessionRoutes()`：进程名白名单 `node|claude|bun|cmd|pwsh|powershell`；32 位 PowerShell 读 64 位进程偏移不对，用 64 位 PowerShell 跑；实在不行按上文手工给 |
| `--app` 没开出应用窗口 | `openPanel()`：依次试 msedge、chrome，都没有就用默认浏览器开普通标签页 |
| 控制台中文乱码 | `chcp 65001`，或用 Windows Terminal |
| 端口 5990 被占 | 自动顺延到 5999；或 `--port N` |
| 提示脚本被策略拦截 | `powershell -ExecutionPolicy Bypass -File …` |
