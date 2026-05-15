#!/bin/bash
# build.sh — Build HermesPet.app and install it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
BUNDLE_ID="com.nousresearch.hermespet"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "🏗️  Building $APP_NAME (universal: arm64 + x86_64)..."
# 双架构 universal binary —— Intel Mac 也能跑（issue #6）
# 多架构构建产物路径变为 .build/apple/Products/Release/
swift build -c release --disable-sandbox --arch arm64 --arch x86_64

echo "📦 Creating .app bundle..."
BINARY="$BUILD_DIR/apple/Products/Release/$APP_NAME"

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create standard macOS app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist and apply app-specific values
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy app icon (.icns) —— 需配合 Info.plist 里的 CFBundleIconFile = AppIcon
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "🎨 已复制 AppIcon.icns"
fi

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 清理扩展属性（防止 codesign 报 "resource fork / Finder information not allowed"）
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# 用本地 Apple Development 证书签名 —— 让 TCC 权限稳定，
# 不会因为重新构建（CDHash 变化）就丢失屏幕录制等授权。
# 如果证书不可用（被撤销 / 过期），自动 fallback 到 ad-hoc。
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Apple Development|Developer ID Application/{print $2; exit}')"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔐 使用证书签名: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "🔐 未找到可用证书，退回到 ad-hoc 签名（每次构建后可能需重新授权）"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "✅ 构建完成: $APP_BUNDLE"
echo ""
echo "使用方法:"
echo "  双击 $APP_NAME.app 即可启动"
echo "  或者运行: open $APP_NAME.app"
echo ""
echo "⚠️  首次运行可能需要右键 → 打开 来绕过 Gatekeeper"
echo ""
echo "启动后的操作:"
echo "  1. 点击菜单栏 🐇 图标"
echo "  2. 点击齿轮 ⚙️ 进入设置"
echo "  3. 配置 Hermes API 地址和密钥"
echo "  4. 开始聊天!"
echo ""
echo "需要 Hermes API Server 正在运行:"
echo "  hermes config set API_SERVER_ENABLED true"
echo "  hermes config set API_SERVER_KEY your-secret-key"
echo "  hermes gateway"
