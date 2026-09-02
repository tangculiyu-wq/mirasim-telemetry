# Mirasim 遥测 · Windows 卸载：停掉常驻脚本、删掉启动项。数据目录 ~\.mirasim-telemetry 加 -Purge 一并删。
#
#   powershell -ExecutionPolicy Bypass -File uninstall-windows.ps1 [-Purge]
param([switch]$Purge)
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*mirasim-telemetry.mjs*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Mirasim 遥测.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "已删启动项 $lnk" }
$vbs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'start-hidden.vbs'
if (Test-Path $vbs) { Remove-Item $vbs -Force }
if ($Purge) { $d = Join-Path $HOME '.mirasim-telemetry'; if (Test-Path $d) { Remove-Item $d -Recurse -Force; Write-Host "已删数据 $d" } }
Write-Host '已卸载。'
