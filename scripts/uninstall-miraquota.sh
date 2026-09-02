#!/bin/bash
# 卸载旧的 MiraQuota 控件体系，换成「Mirasim 遥测」。
#
# 先备份再删：备份包留在 ~ 下，确认新的用着没问题再自行删除。
# 不动 Mirasim 本身，也不动 MiraQuota 的源码仓库。
set -euo pipefail

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$HOME/MiraQuota-备份-$STAMP.tar.gz"
UID_NUM=$(id -u)

echo "▸ 先确认「Mirasim 遥测」正在跑…"
if ! pgrep -f "Mirasim 遥测.app/Contents/MacOS/Mirasim 遥测" >/dev/null; then
  echo "✗ 「Mirasim 遥测」没在运行。先跑 ./install.sh，确认新的能用再卸旧的。"
  exit 1
fi
echo "  ✓ 在运行"

echo "▸ 备份到 $BACKUP …"
tar -czf "$BACKUP" \
  -C "$HOME" .miraquota \
  -C "$HOME/Library/LaunchAgents" \
    local.miraquota.plist \
    local.miraquota-keeper.plist \
    local.miraquota-node.plist.disabled \
  2>/dev/null || true
echo "  ✓ $(du -h "$BACKUP" 2>/dev/null | cut -f1)"

echo "▸ 停掉后台服务…"
for job in local.miraquota local.miraquota-keeper; do
  launchctl bootout "gui/$UID_NUM/$job" 2>/dev/null \
    || launchctl unload "$HOME/Library/LaunchAgents/$job.plist" 2>/dev/null \
    || true
  echo "  · $job 已停"
done
# 兜底：LaunchAgent 摘掉后仍在跑的残留进程
pkill -f "MiraQuotaHeadless" 2>/dev/null || true
pkill -f "route-keeper.mjs" 2>/dev/null || true
sleep 1

echo "▸ 移除开机项与数据…"
rm -f "$HOME/Library/LaunchAgents/local.miraquota.plist"
rm -f "$HOME/Library/LaunchAgents/local.miraquota-keeper.plist"
rm -f "$HOME/Library/LaunchAgents/local.miraquota-node.plist.disabled"
rm -rf "$HOME/.miraquota"
# 这个启动器的作用只是给 Mirasim 加 --remote-debugging-port，
# 供旧控件走 CDP 注入用。「Mirasim 遥测」不注入任何东西，不再需要它。
rm -rf "$HOME/Applications/Mirasim（带控件）.app"

echo "▸ 复核…"
# pgrep 找不到时退出码为 1，set -e 会在这里把脚本掐掉
LEFT=$(pgrep -f "MiraQuotaHeadless|route-keeper.mjs" 2>/dev/null | wc -l | tr -d ' ' || true)
echo "  残留进程：$LEFT"
echo "  LaunchAgents 里的 mira 项：$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -ci miraquota || true)"

echo
echo "✓ 旧控件已卸载。备份在 $BACKUP（确认新的没问题后可自行删除）"
echo "  注：Mirasim 里那个名为「MiraQuota 路由保活（勿删）」的会话现在没用了，可以自己删掉。"
