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
VERSION="1.2.3"
BUILD_DIR="$SCRIPT_DIR/.build"
DIST_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
TMP_DMG="$DIST_DIR/${APP_NAME}-${VERSION}.tmp.dmg"

# 清理上次的产物
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Universal build 需要完整 Xcode（xcbuild）。如果当前 xcode-select 指向 CLT
# 而 Xcode.app 装在标准位置，临时通过 DEVELOPER_DIR 切过去
if ! [ -d "$(xcode-select -p)/SharedFrameworks/XCBuild.framework" ] \
   && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "ℹ️  使用 Xcode.app 编译 universal（xcode-select 当前指向 CLT，缺 xcbuild）"
fi

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

# App 图标（跟 build.sh 一致）
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "🎨 已复制 AppIcon.icns"
fi

# v1.2.0+: 内嵌 opencode 二进制让在线 AI 模式开箱即用 agent runtime
# 跟 build.sh 用同一份缓存，首次跑会 curl 下载，之后复用
OPENCODE_VERSION="${OPENCODE_VERSION:-v1.15.1}"
OPENCODE_ARCH="darwin-arm64"
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

echo "🔐 ad-hoc 签名（分发用，任何 Mac 都能跑）..."
# 清 xattr 防 codesign 报 "resource fork / Finder information"（iCloud daemon 会反复写回，重试）
sign_ok=0
for attempt in 1 2 3; do
    find "$APP_BUNDLE" -exec xattr -c {} + 2>/dev/null || true
    xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
    xattr -d "com.apple.fileprovider.fpfs#P" "$APP_BUNDLE" 2>/dev/null || true
    if codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null; then
        sign_ok=1
        break
    fi
    sleep 0.2
done
if [ $sign_ok -eq 0 ]; then
    echo "❌ codesign 失败"
    exit 1
fi

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

【v1.2.3 主要更新】

  ▍架构升级
  · 在线 AI 切换到 opencode HTTP API（替代 subprocess 方案）—— 彻底根治
    v1.2.x 用户撞过的「(没有响应)」bug，启动延迟也从 800ms 降到 50ms
  · 工具权限默认全 allow，等价于之前 --dangerously-skip-permissions，
    用户朋友再也不会撞到工具调用 hang。下版本会做完整 permission UI

  ▍新功能
  · vision 模型自动切换 —— 拖图时自动 override 到 provider 的 vision 模型：
      Moonshot Kimi → moonshot-v1-128k-vision-preview
      智谱       → glm-4v-plus
      OpenAI     → gpt-4o
      DeepSeek   → 报清晰提示（DeepSeek 没 vision API）
  · 云朵桌宠 vision 模式戴眼镜动画 —— 拖图时从身后掏出眼镜飞到脸上戴稳，
    持续整个识图过程（1.4s 戴上 + 6s 保持 + 0.6s 摘下）
  · 云朵长任务情绪气泡 —— 30s「云端有点慢呢…」90s「这朵云有点大…」
    180s「这片云遮了好久…」失败「云飘走了 😢」
  · 错误态友好化 —— 7 种错误关键词分类成可操作 hint
    （「Key 不对去检查」/「切到 Kimi/GLM」/「云被堵在路上」等）

  ▍Bug 修复
  · 拖图到桌宠 prompt 误用文件版被 AI 当文件去找 → 改成「这张图里是什么」
  · 拖图比剪贴板粘贴慢 5 倍 → 不再无谓 NSImage decode/encode，直接读原 bytes
  · 图片 mime 错标 image/png → 按字节头检测真实格式

【v1.2.1 沿用】

  · 在线 AI 模式新增云朵小精灵 ☁️ —— 灵动岛左耳像素动画 + 桌面漫步
  · 灵动岛 hover 改造：触发区严格收紧到硬件刘海几何，水滴润下动效
  · 桌宠双击不再切换 AI 模式（行为更符合直觉）
  · 设置面板「桌宠」区合并 Clawd / 云朵统一管理
  · 内置自动更新检查：菜单栏 + 设置面板能看到新版本提示，一键下载
  · 设置「关于」加作者署名 + 社区贡献者致谢

【v1.2.0 沿用 · 在线 AI 是 agent 不只是聊天】

  内置 opencode (MIT 开源 agent runtime) 让「在线 AI」模式能真的读
  你的本地文件、跑命令、联网搜索、看图，跟 Claude Code / Codex
  同档能力，**完全不需要装任何外部命令行工具**。

  约 100MB，所以 DMG 比 v1.1 大了不少，一次装上免后顾之忧。

【最快上手 · 不需要装任何命令行工具】

  打开 Hermes 桌宠 → 点齿轮 ⚙️ 进设置 → "在线 AI" → 服务商下拉
  里面已经内置了 DeepSeek / 智谱 GLM / Moonshot Kimi / OpenAI 预设
  选一家 → 粘贴 API Key → 关闭设置 → 就能开始聊了

  推荐：Moonshot Kimi K2.6 中文体验好，agent 工具调用稳定。

  各家获取 API Key 的入口：
    DeepSeek   https://platform.deepseek.com/api_keys
    智谱 GLM   https://open.bigmodel.cn/usercenter/apikeys
    Moonshot   https://platform.moonshot.cn/console/api-keys
    OpenAI     https://platform.openai.com/api-keys

【试试看 AI 的本地能力】

  配好 Key 后试这几个问题感受一下：
    - "看一下我桌面上有什么文件"
    - "帮我把 ~/Downloads 里的截图按日期归类到文件夹"
    - "搜一下今天 macOS 26 的更新"
    - 拖一张图片进来：「这张图里有什么？」
    - 拖一份 PDF：「帮我总结一下这份文档」

【进阶：还能装 Claude Code / Codex】
  如果你的机器另外装了 claude / codex 命令行工具，
  点聊天窗顶部的模式图标就能切到对应模式 ——
  可以享受这些更强的 agent。没装也不影响在线 AI 模式正常用。
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
