# Mirasim 遥测 · Windows 安装：登录时自动在后台起常驻脚本，并以应用窗口打开面板。
#
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1
#
# 做三件事：① 检查 Node ≥ 22；② 在「启动」文件夹放一个快捷方式（经 wscript 隐藏黑窗）；③ 立刻启动一次。
# 不写注册表、不需要管理员。卸载用 uninstall-windows.ps1。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'mirasim-telemetry.mjs'
if (-not (Test-Path $script)) { throw "找不到 $script" }

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw '没有 node。装 Node.js 22 或更新：https://nodejs.org' }
$ver = (& node -v) -replace '^v', ''
if ([int]($ver.Split('.')[0]) -lt 22) { throw "Node $ver 太旧，需要 22 或更新（fetch 与 WebSocket 自 22 起内置）" }

# 隐藏窗口启动器：直接放 node 到启动项会常驻一个黑色控制台窗
$vbs = Join-Path $here 'start-hidden.vbs'
@"
Set sh = CreateObject("WScript.Shell")
sh.Run "cmd /c ""node """"$script"""" --app""", 0, False
"@ | Set-Content -Path $vbs -Encoding ASCII

$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'Mirasim 遥测.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $here
$sc.Description = 'Mirasim 遥测（后台常驻 + 面板）'
$sc.Save()

# 先停掉已在跑的，再起一份
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*mirasim-telemetry.mjs*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $here

Write-Host "已安装：登录自启快捷方式 $lnk"
Write-Host '面板几秒后在浏览器应用窗口打开；关掉窗口不影响后台采集，重开访问 http://127.0.0.1:5990/'
Write-Host '想钉在最前：PowerToys 的「Always On Top」（Win+Ctrl+T）。'
Write-Host '有问题先跑：node mirasim-telemetry.mjs --doctor'
