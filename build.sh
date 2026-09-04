#!/bin/bash
# 构建「Mirasim 遥测」为一个 .app 包。
#
# 本机只有 Command Line Tools（无完整 Xcode），故不走 xcodebuild，
# 直接 swiftc 编译后手工装配 bundle。SwiftUI 的 @State 在当前 SDK 上是宏、
# 而 CLT 缺 SwiftUIMacros 插件，源码里一律不用它（本地状态走 ObservableObject）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mirasim 遥测"
# bundle id 保持不变：UserDefaults 按它存，改了会丢掉用户调好的位置/透明度/大小
BUNDLE_ID="local.eduhuan.ring"
VERSION="1.3.0"
OUT="${1:-build}"
APP="$OUT/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译…"
xcrun swiftc \
  -swift-version 5 \
  -O \
  -whole-module-optimization \
  -target "$(uname -m)-apple-macosx14.0" \
  Sources/Model.swift \
  Sources/SessionScanner.swift \
  Sources/LimitsClient.swift \
  Sources/RelayClient.swift \
  Sources/SpeedStats.swift \
  Sources/CostLedger.swift \
  Sources/Calibrator.swift \
  Sources/Store.swift \
  Sources/Theme.swift \
  Sources/EnglishStrings.swift \
  Sources/StatusIcon.swift \
  Sources/WindowCard.swift \
  Sources/CapsuleView.swift \
  Sources/PanelView.swift \
  Sources/SettingsView.swift \
  Sources/DetailSection.swift \
  Sources/AppDelegate.swift \
  Sources/Preview.swift \
  Sources/Diagnose.swift \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

# 应用图标(桌面启动器/访达里显示)
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <!-- 菜单栏常驻程序：不进 Dock、不进 ⌘Tab -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# 临时签名。不签的话 SMAppService（开机自启）注册会失败，
# 且每次改动后 Gatekeeper 都要重新放行。
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  （临时签名跳过）"

echo "▸ 完成：$APP"
