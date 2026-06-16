#!/bin/bash
# install.sh — 一键构建 + 覆盖安装到 /Applications + 启动
#
# 跟 build.sh / make-dmg.sh 的关系：
#   build.sh       仅构建到 ~/Desktop/HermesPet/HermesPet.app（Developer ID + Hardened Runtime 签名）
#   make-dmg.sh    打 Developer ID 签名 + Apple 公证的 DMG 给别人分发（接收方双击直接打开）
#   install.sh ← 你用：本地构建 + 覆盖装到 /Applications + 启动新版
#
# build.sh 跟 make-dmg.sh 用一样的签名方式（Developer ID + Hardened Runtime + 同一份 entitlements），
# 所以"本地装的 == 用户下载的"：权限授权稳定（TeamID 不变不会丢），
# 且能在本机提前发现"缺 entitlement"这类只在 Hardened Runtime 下才暴露的坑。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
DISPLAY_NAME="Hermes 桌宠"
SOURCE="$SCRIPT_DIR/$APP_NAME.app"
TARGET="/Applications/$DISPLAY_NAME.app"

# 1. 构建（build.sh 内部已经会用 Developer ID + Hardened Runtime 签名）
# 本地只编当前机器架构（arm64），省掉 Intel 那一遍 ≈ 一半构建时间。
# 发版给别人的双架构 universal 由 make-dmg.sh 负责，跟这里无关。
# ⚠️ swift build 的编译报错走 stdout —— 以前直接 > /dev/null 会把报错整个吞掉，
# 失败时只看到一行"构建中"就没了（2026-06-10 踩坑）。改成落日志、失败回显尾部。
echo "🏗️  构建中（仅 arm64，本地提速）..."
BUILD_LOG="$(mktemp -t hermespet-build)"
if ! BUILD_ARCHS=arm64 ./build.sh > "$BUILD_LOG" 2>&1; then
    echo "❌ 构建失败，日志尾部（完整日志: ${BUILD_LOG}）："
    tail -40 "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

# 2. 退出在跑的版本（如果有）
# 注意：用精确进程名匹配 ($APP_NAME)，不要用 .app 路径，
# 因为 /Applications 下的 bundle 是 "Hermes 桌宠.app"（中文），跟 source 端 "HermesPet.app" 不一样。
# 之前用 -f pattern 匹配 .app 路径会漏杀 → 旧进程残留 → install 完成但用户跑的还是旧代码。
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "🛑 退出当前运行的 $DISPLAY_NAME..."
    pkill -x "$APP_NAME" || true
    # 等一下让进程完全退出，避免覆盖时占用
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
fi

# v1.2.0+：HermesPet 退出后，bundled opencode server 子进程可能仍在跑
# （SIGTERM 主进程时 applicationWillTerminate 不一定被 OS 派发够时间完成 cleanup）。
# 显式清理一下，避免旧 server + 新 server 同时跑导致端口和 SQLite 写冲突。
# 注意：只清理跑在 HermesPet bundled 路径下的 opencode，不杀用户手动装的 ~/.opencode/
if pgrep -af "Application Support/HermesPet/bin/opencode" >/dev/null 2>&1; then
    echo "🧹 清理旧 opencode server 子进程..."
    pkill -f "Application Support/HermesPet/bin/opencode" || true
    sleep 0.4
fi

# 3. 覆盖安装到 /Applications
echo "📦 安装到 $TARGET..."
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

# 4. 启动新版
echo "🚀 启动新版..."
open "$TARGET"

echo ""
echo "✅ 完成。$DISPLAY_NAME 已安装到 /Applications 并启动"
echo ""
echo "   签名身份: $(codesign -dvvv "$TARGET" 2>&1 | grep -E 'Authority=(Developer ID Application|Apple Development)' | head -1 | sed 's/.*Authority=//' || echo 'ad-hoc')"
echo ""
echo "   💡 因签名身份稳定（Developer ID + Hardened Runtime），以后再跑 install.sh 权限不会丢"
echo "   ⚠️  首次跑可能需要重新授权（从旧版本切过来）"
