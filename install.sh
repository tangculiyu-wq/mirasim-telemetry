#!/bin/bash
# 安装「额度环」到 ~/Applications 并启动。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mirasim 遥测"
DEST="$HOME/Applications"

./build.sh build

echo "▸ 停掉正在运行的旧实例…"
pkill -f "$DEST/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "$PWD/build/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "build/$APP_NAME.app" "$DEST/"

echo "▸ 启动…"
open "$DEST/$APP_NAME.app"
sleep 2

if pgrep -f "$DEST/$APP_NAME.app" >/dev/null; then
  echo "✓ 已在菜单栏运行：$DEST/$APP_NAME.app"
  echo "  左键点图标看面板，右键出菜单（可开「开机自动启动」）。"
else
  echo "✗ 未能启动，用下面的命令看原因："
  echo "  \"$DEST/$APP_NAME.app/Contents/MacOS/$APP_NAME\" --diag"
  exit 1
fi
