#!/bin/bash
# make-dmg.sh — 打包一个可分发给别人的 DMG
#
# 跟 build.sh 的区别：
# - build.sh：日常本地构建，用 Apple Development 证书签名（权限稳定，但别的电脑用不了）
# - make-dmg.sh：分发场景，用 ad-hoc 签名（任何 Mac 都能跑，但接收方第一次需要右键打开）
#
# 用法：./make-dmg.sh
# 产物：dist/HermesPet-<版本>.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
DISPLAY_NAME="Hermes 桌宠"
VERSION="1.0"
BUILD_DIR="$SCRIPT_DIR/.build"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
TMP_DMG="$DIST_DIR/${APP_NAME}-${VERSION}.tmp.dmg"

# 清理上次的产物
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "🏗️  Release 构建（universal: arm64 + x86_64，Intel Mac 也能跑）..."
# issue #6：原来只编当前架构（开发机是 Apple Silicon → 只产出 arm64），
# Intel Mac 装上后报 "Bad CPU type in executable"。改 universal 一份通杀。
swift build -c release --disable-sandbox --arch arm64 --arch x86_64

echo "📦 组装 .app bundle..."
BINARY="$BUILD_DIR/apple/Products/Release/$APP_NAME"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "🔐 ad-hoc 签名（分发用，任何 Mac 都能跑）..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "💿 组装 DMG 内容..."
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/$DISPLAY_NAME.app"
# 给一个 /Applications 的快捷方式，让用户能直接拖进去安装
ln -s /Applications "$STAGING_DIR/应用程序"

# 在 DMG 根目录放一份简明说明，避免接收方第一次打开被 Gatekeeper 拦下不知所措
cat > "$STAGING_DIR/⚠️ 第一次打开请看我.txt" <<'EOF'
首次打开 Hermes 桌宠的步骤
================================

由于这是开发版（未经 Apple 官方公证），macOS 会默认阻止运行。
你需要做以下一次性操作：

1. 把「Hermes 桌宠」拖到旁边的「应用程序」文件夹

2. 在 启动台 / Spotlight 找到「Hermes 桌宠」
   → 右键点击 → 选「打开」
   → 弹出警告时再点「打开」

3. 如果右键打开还是被拦截：
   - 打开「系统设置 → 隐私与安全性」
   - 在底部「安全」区域找到 "Hermes 桌宠 已被阻止"
   - 点「仍要打开」

完成以上一次操作后，以后就能正常双击打开了。

————————————————

【全局快捷键】
  Cmd+Shift+H  → 呼出 / 收回聊天窗口
  Cmd+Shift+J  → 截当前屏幕并附加到聊天（首次会请求"屏幕录制"权限）
  Cmd+Shift+V  → 按住说话（push-to-talk），松开后自动发送
                  首次会请求"麦克风" + "语音识别"两个权限

授权完任一权限后，建议完全退出 Hermes 桌宠（菜单栏右键 → 退出）
再重新打开一次，让新权限对进程生效。

【最快上手 · 不需要装任何命令行工具】

  打开 Hermes 桌宠 → 点齿轮 ⚙️ 进设置 → "AI 后端" → 服务商下拉
  里面已经内置了 DeepSeek / 智谱 GLM / Moonshot Kimi / OpenAI 预设
  选一家 → 粘贴 API Key → 关闭设置 → 就能开始聊了

  各家获取 API Key 的入口：
    DeepSeek   https://platform.deepseek.com/api_keys
    智谱 GLM   https://open.bigmodel.cn/usercenter/apikeys
    Moonshot   https://platform.moonshot.cn/console/api-keys
    OpenAI     https://platform.openai.com/api-keys

【进阶：本地 CLI 模式（可选）】
  如果你的机器装了 claude / codex 命令行工具，
  点聊天窗顶部的模式图标就能切到对应模式 ——
  可以让 AI 读写文件、跑命令、生成图片。
  没装的话切了会自动回退到 Hermes，不会卡住。
EOF

echo "💿 hdiutil 制作 DMG..."
hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

# 清理临时目录
rm -rf "$STAGING_DIR"
rm -rf "$APP_BUNDLE"

# 显示最终大小
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo "✅ 打包完成"
echo "    路径：$DMG_PATH"
echo "    大小：$DMG_SIZE"
echo ""
echo "📤 分发说明："
echo "    1. 直接把 .dmg 文件发给朋友（微信 / 网盘 / AirDrop 都行）"
echo "    2. 朋友双击 .dmg 挂载后，照 \"⚠️ 第一次打开请看我.txt\" 操作"
echo "    3. 注意：ad-hoc 签名的应用，朋友每次升级新版本"
echo "       都需要重新授权一次屏幕录制（这是 macOS 的限制，"
echo "       绕不开。要彻底解决得办 Apple Developer Program）"
