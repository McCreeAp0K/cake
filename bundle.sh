#!/usr/bin/env bash
# 把 Cake 可执行文件打包成可双击运行的 macOS .app bundle。
#
# 用法：./bundle.sh           生成 dist/Cake.app
#       ./bundle.sh --install 生成后复制到 /Applications
#
# 无 Developer ID 签名身份时使用 ad-hoc 签名（-）：本机可运行，
# 首次启动可能需在"系统设置 > 隐私与安全性"点"仍要打开"。

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Cake"
BUNDLE_ID="com.cake.app"
DIST="$REPO_DIR/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 构建 release…"
( cd "$REPO_DIR" && swift build -c release )
BIN="$REPO_DIR/.build/release/$APP_NAME"
VERSION="$(cd "$REPO_DIR" && git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> 组装 .app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# 应用图标（🍰）
ICON_SRC="$REPO_DIR/Resources/AppIcon.icns"
ICON_KEY=""
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

# 各 agent 的 logo（下拉栏第一行用）。
if [ -d "$REPO_DIR/Resources/agent-logos" ]; then
    mkdir -p "$APP/Contents/Resources/agent-logos"
    cp "$REPO_DIR/Resources/agent-logos/"*.png "$APP/Contents/Resources/agent-logos/" 2>/dev/null || true
fi

# 内嵌审批 hook 脚本 + 配置脚本，让下载版用户无需 Xcode/源码也能启用权限审批。
mkdir -p "$APP/Contents/Resources/hooks"
cp "$REPO_DIR/hooks/approve.sh" "$APP/Contents/Resources/hooks/approve.sh"
cp "$REPO_DIR/hooks/register.sh" "$APP/Contents/Resources/hooks/register.sh"
chmod +x "$APP/Contents/Resources/hooks/approve.sh" "$APP/Contents/Resources/hooks/register.sh"
if [ -f "$REPO_DIR/install-hooks.sh" ]; then
    cp "$REPO_DIR/install-hooks.sh" "$APP/Contents/Resources/install-hooks.sh"
    chmod +x "$APP/Contents/Resources/install-hooks.sh"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    $ICON_KEY
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Agent 型 App：无 Dock 图标，常驻刘海 -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 终端跳转需通过 Apple Events 控制 Terminal/iTerm，首次会请求"自动化"授权 -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Cake 需要控制终端 App，以便点击会话时跳转到对应的终端窗口。</string>
</dict>
</plist>
PLIST

echo "PEW" > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign 跳过)"

echo
echo "✅ 已生成：$APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> 复制到 /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/"
    echo "✅ 已安装到 /Applications/$APP_NAME.app（可在启动台/访达双击运行）"
fi
