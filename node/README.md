# Mirasim 遥测 · 跨平台版（Windows / Linux / macOS）

这是 macOS 原生版的跨平台实现：一个没有外部依赖的 Node 脚本在后台计算数据，面板是本机网页
（`http://127.0.0.1:5990/`），可以用浏览器的应用窗口模式打开成独立窗口。
口径和算法与 macOS 版相同：百分比取 `/v1/limits` 的原始额度点，美元按 Mirasim 逐调用计量乘以官方价目，
整窗金额 = 已花金额 ÷ 已用百分比，等价行按实测的扣点公式计算，速度按请求号配对（包含子代理）。

程序只读取数据，只绑定 127.0.0.1，不向 Mirasim 注入代码，不需要调试端口，不修改 Mirasim 的任何文件。

> **没有在 Windows 上测试过。** 通用部分（帧、账本、速度、面板）在 macOS 上用同一份脚本运行通过，数字与原生版一致。
> Windows 特有的三部分（查找 Mirasim 进程、读取会话令牌、开机自启）按 Windows 的接口编写，没有 Windows 机器可以测试。
> 安装后先运行 `--doctor`，它会逐步报告哪一步失败和如何处理。相关代码在 `mirasim-telemetry.mjs` 里有注释标出。

## 要求

- Node.js 22 或更新。`fetch` 与 `WebSocket` 从 22 起内置，不需要 npm install。
- Mirasim 桌面版在本机运行。
- 要显示原始点数和五位小数的百分比，需要有一个活跃的 Claude Code 会话，令牌从会话进程读取。
  没有会话时使用 Mirasim 帧数据，分辩率 0.1%。

## 使用

```powershell
node mirasim-telemetry.mjs --doctor      # 自检：Mirasim 进程、端口、帧、会话令牌、/v1/limits、日志、账本
node mirasim-telemetry.mjs               # 启动服务并在浏览器打开面板
node mirasim-telemetry.mjs --app         # 用 Edge 或 Chrome 的应用窗口模式打开，没有地址栏
```

开机自启会在「启动」文件夹放一个快捷方式，通过隐藏窗口启动脚本，不需要管理员权限：

```powershell
powershell -ExecutionPolicy Bypass -File install-windows.ps1
powershell -ExecutionPolicy Bypass -File uninstall-windows.ps1 [-Purge]
```

Linux 和 macOS 直接运行 `node mirasim-telemetry.mjs`。常驻可以用 systemd user unit 或 LaunchAgent。macOS 上建议使用仓库主体的原生版。

## Windows 上如何获取会话令牌

`/v1/limits` 挂在 Mirasim 为每个会话开的回环端口上，请求需要带该会话的令牌。令牌不写入磁盘，只存在于会话进程的环境变量里。
脚本按两步自动查找：

1. `Get-CimInstance Win32_Process`：如果 Mirasim 启动会话时把 `--settings` JSON 放在命令行上，直接从中读取 `ANTHROPIC_BASE_URL` 与 `ANTHROPIC_AUTH_TOKEN`。
2. 读取 node / claude 进程的环境块。PowerShell 内嵌一段 C#，通过 `NtQueryInformationProcess` 读取 PEB、`ProcessParameters`、`Environment`。
   同用户的进程不需要管理员权限。x64 偏移为 `0x20 / 0x80 / 0x3F0`。

两步都没有结果时，`--doctor` 会提示手工传入。在 Claude Code 会话里执行：

```powershell
echo $env:ANTHROPIC_BASE_URL
echo $env:ANTHROPIC_AUTH_TOKEN
node mirasim-telemetry.mjs --router-base http://127.0.0.1:端口/密钥 --router-token 令牌
```

基址要完整保留。新版 URL 带路径密钥，只给端口会返回 401。令牌与会话绑定，会话重启后需要重新获取。

## 面板

版面与 macOS 版相同：每个额度窗口一张卡（百分比、走势、进度条与匀速线、点数、已花 / 整窗 / 余量、
7 天卡的等价行、倒计时与用尽时刻），累计卡（周、月、日均、月底预估、近 14 天柱状图），
速度栏（每个模型的 tok/s、每轮耗时、首字时间，今日花费）。跟随系统的深浅色。
数据变化时通过 SSE 推送到页面，倒计时在页面内每秒更新。

浏览器窗口不能置顶。需要置顶时可以用 [PowerToys](https://learn.microsoft.com/windows/powertoys/) 的
「Always On Top」功能（默认快捷键 Win+Ctrl+T）。

其它接口：`/quota.json`（全部数据）、`/events`（SSE）、`POST /refresh`（让 Mirasim 忽略缓存重新查询一次）。

## 数据与写入的文件

读取：`%USERPROFILE%\.mirasim\insights\usage-*.ndjson`（调用日志）、`%USERPROFILE%\.mirasim\models-dev-cache.json`（价目）、
`%USERPROFILE%\.claude\projects\**\*.jsonl`（速度配对）。写入：只有 `%USERPROFILE%\.mirasim-telemetry\`
下的百分比采样（保留 24 小时）与等价单价缓存。

## 可能需要修改的地方

| 现象 | 位置 |
|---|---|
| `--doctor` 第 1 步找不到 Mirasim 进程 | `mirasimProcesses()` 按命令行包含 `server.cjs` 查找。如果 Windows 版 Mirasim 的入口文件名不同，修改这个字符串 |
| 第 4 步会话路由为 0 条 | `sessionRoutes()` 的进程名白名单是 `node|claude|bun|cmd|pwsh|powershell`。32 位 PowerShell 读取 64 位进程时偏移不对，请用 64 位 PowerShell。仍然失败时按上文手工传入 |
| `--app` 没有打开应用窗口 | `openPanel()` 依次尝试 msedge、chrome，都没有时用默认浏览器打开普通标签页 |
| 控制台中文乱码 | 运行 `chcp 65001`，或使用 Windows Terminal |
| 端口 5990 被占用 | 自动改用 5991 到 5999，或用 `--port N` 指定 |
| 脚本被执行策略拦截 | 用 `powershell -ExecutionPolicy Bypass -File …` 运行 |
