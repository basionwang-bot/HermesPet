#!/bin/bash
# build.sh — Build HermesPet.app and install it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
BUNDLE_ID="com.nousresearch.hermespet"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

# Universal build 需要完整 Xcode（xcbuild）。如果当前 xcode-select 指向 CLT
# 而 Xcode.app 装在标准位置，临时通过 DEVELOPER_DIR 切过去，避免要求用户改全局
if ! [ -d "$(xcode-select -p)/SharedFrameworks/XCBuild.framework" ] \
   && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "ℹ️  使用 Xcode.app 编译 universal（xcode-select 当前指向 CLT，缺 xcbuild）"
fi

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

# === Bundle opencode binary（在线 AI 引擎）===
# opencode (MIT, anomalyco/opencode) 是开源 AI coding agent CLI。
# bundle 进 .app 让在线 AI 模式无需任何外部 CLI 依赖。
# 本机首次构建会下载 ~33MB zip 到 .opencode-cache/<VERSION>/，
# 之后反复 build 不重下。OPENCODE_VERSION 锁版本，避免 release 不兼容时炸链路。
OPENCODE_VERSION="${OPENCODE_VERSION:-v1.15.1}"
OPENCODE_ARCH="darwin-arm64"   # Phase 1 仅 arm64；universal 见 TODO Phase 2
OPENCODE_CACHE_DIR="$SCRIPT_DIR/.opencode-cache/$OPENCODE_VERSION"
OPENCODE_BINARY="$OPENCODE_CACHE_DIR/opencode"

if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "📥 下载 opencode $OPENCODE_VERSION ($OPENCODE_ARCH)..."
    mkdir -p "$OPENCODE_CACHE_DIR"
    OPENCODE_URL="https://github.com/anomalyco/opencode/releases/download/$OPENCODE_VERSION/opencode-$OPENCODE_ARCH.zip"
    curl -fL --progress-bar -o "$OPENCODE_CACHE_DIR/opencode.zip" "$OPENCODE_URL"
    unzip -q -o "$OPENCODE_CACHE_DIR/opencode.zip" -d "$OPENCODE_CACHE_DIR"
    chmod +x "$OPENCODE_BINARY"
    rm "$OPENCODE_CACHE_DIR/opencode.zip"
fi

OPENCODE_SIZE="$(du -h "$OPENCODE_BINARY" | cut -f1)"
echo "📦 嵌入 opencode $OPENCODE_VERSION ($OPENCODE_SIZE)"
cp "$OPENCODE_BINARY" "$APP_BUNDLE/Contents/Resources/opencode"
chmod +x "$APP_BUNDLE/Contents/Resources/opencode"

# Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 清理扩展属性（防止 codesign 报 "resource fork / Finder information not allowed"）
# 注意：Desktop 在 iCloud Drive 同步范围内时，.app 根目录会被自动加上
# com.apple.FinderInfo + com.apple.fileprovider.fpfs#P 这些 system 属性，
# 普通 `xattr -cr` 递归不会处理根 dir 的 system 属性。要显式 `find -exec xattr -c`
# 把每个文件单独清，再补 -d 删根目录的 system 属性。
find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
xattr -d "com.apple.fileprovider.fpfs#P" "$APP_BUNDLE" 2>/dev/null || true

# 用本地 Apple Development 证书签名 —— 让 TCC 权限稳定，
# 不会因为重新构建（CDHash 变化）就丢失屏幕录制等授权。
# 如果证书不可用（被撤销 / 过期），自动 fallback 到 ad-hoc。
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Apple Development|Developer ID Application/{print $2; exit}')"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔐 使用证书签名: $SIGN_IDENTITY"
    # iCloud Drive 同步的目录下，com.apple.FinderInfo + com.apple.fileprovider.fpfs#P
    # 会在清理后被 fileproviderd 守护进程几百毫秒内重新写回。最多重试 3 次，
    # 每次清完立刻 sign，赌 daemon 还没追上。
    sign_ok=0
    for attempt in 1 2 3; do
        find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
        xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
        xattr -d "com.apple.fileprovider.fpfs#P" "$APP_BUNDLE" 2>/dev/null || true
        if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null; then
            sign_ok=1
            break
        fi
        sleep 0.2
    done
    if [ $sign_ok -eq 0 ]; then
        echo "❌ codesign 失败（iCloud daemon 反复写回 xattr？）"
        exit 1
    fi
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
