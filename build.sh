#!/bin/bash
# build.sh — Build HermesPet.app and install it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
BUNDLE_ID="com.basionwang.hermespet"
# ⚠️ 构建目录默认放 /tmp（非 iCloud）：项目在 ~/Desktop（开了 iCloud「桌面与文稿」同步），
# .build 放项目内会被 iCloud 不停同步 .o → 撞编译报 "input file … was modified during the build"
# （2026-06-13 根治）。可用 HERMES_BUILD_DIR 覆盖回项目内。详见 memory icloud_desktop_sync_build_race。
BUILD_DIR="${HERMES_BUILD_DIR:-/tmp/hermespet-build}"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
ENTITLEMENTS="$SCRIPT_DIR/HermesPet.entitlements"

# Universal build 需要完整 Xcode（xcbuild）。如果当前 xcode-select 指向 CLT
# 而 Xcode.app 装在标准位置，临时通过 DEVELOPER_DIR 切过去，避免要求用户改全局
if ! [ -d "$(xcode-select -p)/SharedFrameworks/XCBuild.framework" ] \
   && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "ℹ️  使用 Xcode.app 编译 universal（xcode-select 当前指向 CLT，缺 xcbuild）"
fi

# 构建架构：默认 universal（arm64 + x86_64），发版 / 直接跑 build.sh 用这个，Intel Mac 也能跑。
# 本地快速迭代可设 BUILD_ARCHS="arm64" 只编当前架构（install.sh 这么做，省掉 Intel 那遍 ≈ 一半时间）。
# 单架构不影响签名 / Hardened Runtime / entitlements 的本机复现（那些跟架构无关）。
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=""
for a in $BUILD_ARCHS; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done

echo "🏗️  Building $APP_NAME ($BUILD_ARCHS) → $BUILD_DIR ..."
swift build -c release --disable-sandbox --scratch-path "$BUILD_DIR" $ARCH_FLAGS

echo "📦 Creating .app bundle..."
# ⚠️ 不要硬编码产物路径！不同 swift 版本 / arch 组合落点不同：
#   - 单 arch (--arch arm64) 这版 swift 落在 .build/arm64-apple-macosx/release/
#   - 多 arch 通用 二进制 落在 .build/apple/Products/Release/
# 硬编码 .build/apple/... 会在单 arch 时拷到**昨天残留的旧二进制**（曾导致改动整天没生效）。
# 用 --show-bin-path 拿当前这套 flag 的权威产物目录，最稳。
BIN_DIR="$(swift build -c release --disable-sandbox --scratch-path "$BUILD_DIR" $ARCH_FLAGS --show-bin-path 2>/dev/null)"
BINARY="$BIN_DIR/$APP_NAME"
# 兜底候选（--show-bin-path 万一为空时）：通用 二进制 路径 → 标准单 arch 路径
[ -f "$BINARY" ] || BINARY="$BUILD_DIR/apple/Products/Release/$APP_NAME"
[ -f "$BINARY" ] || BINARY="$BUILD_DIR/release/$APP_NAME"
echo "   使用产物: $BINARY"

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

# 用 -s（存在且非空）而非 -f：防止上次下载中断留下的 0B 文件被当成"已缓存"跳过
if [ ! -s "$OPENCODE_BINARY" ]; then
    echo "📥 下载 opencode $OPENCODE_VERSION ($OPENCODE_ARCH)..."
    rm -f "$OPENCODE_BINARY"
    mkdir -p "$OPENCODE_CACHE_DIR"
    OPENCODE_URL="https://github.com/anomalyco/opencode/releases/download/$OPENCODE_VERSION/opencode-$OPENCODE_ARCH.zip"
    curl -fL --progress-bar -o "$OPENCODE_CACHE_DIR/opencode.zip" "$OPENCODE_URL"
    unzip -q -o "$OPENCODE_CACHE_DIR/opencode.zip" -d "$OPENCODE_CACHE_DIR"
    chmod +x "$OPENCODE_BINARY"
    rm "$OPENCODE_CACHE_DIR/opencode.zip"
    if [ ! -s "$OPENCODE_BINARY" ]; then
        echo "❌ opencode 下载失败或为空文件"
        exit 1
    fi
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

# 用 Developer ID（优先）/ Apple Development 证书签名 + Hardened Runtime + entitlements。
# 关键：跟分发版（make-dmg.sh）签名方式完全一致，让"本地装的 == 用户下载的"，
# 把麦克风那类"本地好好的、发出去才坏"的 Hardened Runtime 权限坑在本机就暴露出来。
# 这样既保持 TCC 权限稳定（证书 TeamID 不变），又能提前发现缺 entitlement。
# 没有可用证书时退回 ad-hoc（不开 Hardened Runtime）。
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/{print $2; exit}')"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F\" '/Apple Development/{print $2; exit}')"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔐 证书签名（Hardened Runtime + entitlements）: $SIGN_IDENTITY"
    # Desktop 在 iCloud 同步范围时，fileproviderd 会每隔几百毫秒往 .app 根目录写回
    # com.apple.FinderInfo / com.apple.fileprovider.fpfs#P → codesign 报
    # "resource fork ... detritus not allowed"。必须"清完 xattr 立刻签"，中间不能插耗时操作，
    # 否则 daemon 趁机写回。所以用单条 --deep 一次性签内嵌 opencode + 主 app
    # （--deep 会把同一份 entitlements 一并套到 opencode，而 opencode 本就需要 JIT 那几条，正合适）。
    # 最多重试 3 次抢在 daemon 写回前完成。本地构建用 --timestamp=none，离线也不卡。
    sign_ok=0
    for attempt in 1 2 3; do
        find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
        xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
        xattr -d "com.apple.fileprovider.fpfs#P" "$APP_BUNDLE" 2>/dev/null || true
        if codesign --force --deep --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" \
               --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null; then
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
    echo "🔐 未找到可用证书，退回到 ad-hoc 签名（不开 Hardened Runtime；每次构建后可能需重新授权）"
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
