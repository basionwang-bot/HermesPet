#!/bin/bash
# install.sh — 一键构建 + 覆盖安装到 /Applications + 启动
#
# 跟 build.sh / make-dmg.sh 的关系：
#   build.sh       仅构建到 ~/Desktop/HermesPet/HermesPet.app（用 Apple Development 证书）
#   make-dmg.sh    打 ad-hoc 签名 DMG 给别人分发（接收方需手动右键打开）
#   install.sh ← 你用：本地构建 + 覆盖装到 /Applications + 启动新版
#
# 由于用 Apple Development 证书签名，权限授权是稳定的：
# 第一次跑可能要重新授权（从旧的 ad-hoc 版本切过来），之后再跑 install.sh
# 任意次，屏幕录制 / 麦克风 / 语音识别权限都不会丢。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
DISPLAY_NAME="Hermes 桌宠"
SOURCE="$SCRIPT_DIR/$APP_NAME.app"
TARGET="/Applications/$DISPLAY_NAME.app"

# 1. 构建（build.sh 内部已经会用本地 Apple Development 证书签名）
echo "🏗️  构建中..."
./build.sh > /dev/null

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
echo "   签名身份: $(codesign -dvvv "$TARGET" 2>&1 | grep 'Authority=Apple Development' | head -1 | sed 's/Authority=//' || echo 'ad-hoc')"
echo ""
echo "   💡 因签名身份稳定，以后再跑 install.sh 权限不会丢"
echo "   ⚠️  首次跑可能需要重新授权（从旧 ad-hoc 版本切过来）"
