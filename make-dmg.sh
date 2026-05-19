#!/bin/bash
# make-dmg.sh — 打包可分发的 DMG（一键出两份：AppleSilicon + Intel）
#
# 跟 build.sh 的区别：
# - build.sh：日常本地构建，用 Apple Development 证书签名（权限稳定，但别人 Mac 用不了）
# - make-dmg.sh：分发场景，ad-hoc 签名（任何 Mac 都能跑，首次需要右键打开）
#
# 两份产物：
# - dist/HermesPet-<版本>-AppleSilicon.dmg —— 内嵌 opencode darwin-arm64
# - dist/HermesPet-<版本>-Intel.dmg        —— 内嵌 opencode darwin-x64
#
# 主二进制本身已经是 universal，所以两份只差内嵌的 opencode 二进制；
# 分开打而不是 lipo 合成 universal opencode 的原因是后者会让 DMG 翻倍到 200MB+，
# 99% 的用户只需要其中一份。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="HermesPet"
DISPLAY_NAME="Hermes 桌宠"

# 版本号从 Info.plist 自动读，避免脚本和 plist 漂移
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
echo "📌 版本：${VERSION}（从 Info.plist 读取）"

BUILD_DIR="$SCRIPT_DIR/.build"
DIST_DIR="$SCRIPT_DIR/dist"

# 清理上次产物
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Universal build 需要完整 Xcode（xcbuild）。xcode-select 指向 CLT 时临时切到 Xcode.app
if ! [ -d "$(xcode-select -p)/SharedFrameworks/XCBuild.framework" ] \
   && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "ℹ️  使用 Xcode.app 编译 universal（xcode-select 当前指向 CLT，缺 xcbuild）"
fi

echo "🏗️  Release 构建 universal 主二进制（arm64 + x86_64）..."
# 主二进制是 universal，两份 DMG 共用同一份；只有内嵌的 opencode 是 arch-specific
swift build -c release --disable-sandbox --arch arm64 --arch x86_64

BINARY="$BUILD_DIR/apple/Products/Release/$APP_NAME"

# 内嵌的 opencode runtime 版本
OPENCODE_VERSION="${OPENCODE_VERSION:-v1.15.1}"

# 下载对应架构 opencode 到缓存（首次跑会下载，之后复用）
download_opencode() {
    local arch="$1"
    local cache_dir="$SCRIPT_DIR/.opencode-cache/$OPENCODE_VERSION"
    local binary="$cache_dir/opencode-$arch"

    # 所有进度日志走 stderr —— 函数 stdout 只输出 binary 路径，
    # 否则 `$(download_opencode ...)` 命令替换会把日志当成路径，下游 du/cp 全乱
    if [ ! -f "$binary" ]; then
        echo "📥 下载 opencode ${OPENCODE_VERSION} (${arch})..." >&2
        mkdir -p "$cache_dir"
        local url="https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/opencode-${arch}.zip"
        local zip="$cache_dir/opencode-$arch.zip"
        curl -fL --progress-bar -o "$zip" "$url" >&2
        # zip 里就一个 `opencode` 文件，解出来后改名以区分两个架构
        local tmp_dir="$cache_dir/tmp-$arch"
        rm -rf "$tmp_dir"
        unzip -q -o "$zip" -d "$tmp_dir" >&2
        mv "$tmp_dir/opencode" "$binary"
        rm -rf "$tmp_dir" "$zip"
        chmod +x "$binary"
    fi
    echo "$binary"
}

# 打一份 .app + DMG。$1 = 显示后缀（"AppleSilicon" / "Intel"），$2 = opencode arch 标识
build_one_dmg() {
    local suffix="$1"
    local opencode_arch="$2"
    local app_bundle="$DIST_DIR/$APP_NAME-$suffix.app"
    local staging="$DIST_DIR/dmg-staging-$suffix"
    local dmg_path="$DIST_DIR/${APP_NAME}-${VERSION}-${suffix}.dmg"

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📦 构建 ${suffix} 版（opencode-${opencode_arch}）"
    echo "═══════════════════════════════════════════════"

    # 1) 组装 .app bundle
    rm -rf "$app_bundle"
    mkdir -p "$app_bundle/Contents/MacOS"
    mkdir -p "$app_bundle/Contents/Resources"
    cp "$BINARY" "$app_bundle/Contents/MacOS/$APP_NAME"
    cp "$SCRIPT_DIR/Info.plist" "$app_bundle/Contents/"
    echo "APPL????" > "$app_bundle/Contents/PkgInfo"

    if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
        cp "$SCRIPT_DIR/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
    fi

    # 2) 内嵌对应架构的 opencode
    local opencode_binary
    opencode_binary="$(download_opencode "$opencode_arch")"
    local opencode_size
    opencode_size="$(du -h "$opencode_binary" | cut -f1)"
    echo "📦 嵌入 opencode $OPENCODE_VERSION ($opencode_arch, $opencode_size)"
    cp "$opencode_binary" "$app_bundle/Contents/Resources/opencode"
    chmod +x "$app_bundle/Contents/Resources/opencode"

    # 3) ad-hoc 签名（清 xattr 防 "resource fork / Finder information" 报错）
    echo "🔐 ad-hoc 签名..."
    local sign_ok=0
    for attempt in 1 2 3; do
        find "$app_bundle" -exec xattr -c {} + 2>/dev/null || true
        xattr -d com.apple.FinderInfo "$app_bundle" 2>/dev/null || true
        xattr -d "com.apple.fileprovider.fpfs#P" "$app_bundle" 2>/dev/null || true
        if codesign --force --deep --sign - "$app_bundle" 2>/dev/null; then
            sign_ok=1
            break
        fi
        sleep 0.2
    done
    if [ $sign_ok -eq 0 ]; then
        echo "❌ codesign 失败（${suffix} 版）"
        exit 1
    fi

    # 4) 组装 DMG staging（拖拽到 /Applications 的快捷方式 + 首次打开说明）
    echo "💿 组装 DMG..."
    rm -rf "$staging"
    mkdir -p "$staging"
    cp -R "$app_bundle" "$staging/$DISPLAY_NAME.app"
    ln -s /Applications "$staging/应用程序"
    write_readme "$staging" "$suffix"

    # 5) hdiutil 打成 DMG
    hdiutil create \
        -volname "$DISPLAY_NAME" \
        -srcfolder "$staging" \
        -ov \
        -format UDZO \
        "$dmg_path" >/dev/null

    # 6) 清临时目录（DMG 已经打好就不再需要）
    rm -rf "$staging" "$app_bundle"

    local dmg_size
    dmg_size=$(du -h "$dmg_path" | cut -f1)
    echo "✅ ${suffix} 版完成：${dmg_path} (${dmg_size})"
}

# DMG 里附带的"首次打开说明.txt"。$1 = staging 目录，$2 = arch suffix
write_readme() {
    local staging="$1"
    local suffix="$2"

    # 顶部根据架构写一行明确提示
    local arch_hint
    if [ "$suffix" = "AppleSilicon" ]; then
        arch_hint="本版本是 Apple Silicon 专版（M1/M2/M3/M4 系列芯片），如果你的 Mac 是 Intel 芯片请改下 Intel 版"
    else
        arch_hint="本版本是 Intel 芯片专版，如果你的 Mac 是 Apple Silicon（M1/M2/M3/M4）请改下 AppleSilicon 版"
    fi

    cat > "$staging/⚠️ 第一次打开请看我.txt" <<EOF
首次打开 Hermes 桌宠
================================

${arch_hint}

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

【v1.2.9 主要更新】

  ▍新功能
  · 接入 OpenClaw —— 第 5 个 AI 模式，npm 装的本地 AI gateway，
    HermesPet 启动会自动连接，不用填密钥
  · 新桌宠 fomo 🦊 —— OpenClaw 模式的白色小狐狸（耳朵会灵动地抖）
  · 装了什么就自动启用什么 —— OpenClaw / Hermes / Claude / Codex
    装着就自动出现在 mode 切换，没装的不显示
  · 关于页加官方版本验证 —— 显示 codesign Team ID，能识别盗版

  ▍体验优化
  · 设置面板 AI 模式段重做：5 行 toggle + 实时检测状态
  · OpenClaw / Hermes 设置改成"已连接 / 连接中 / 未安装"等小白文案，
    不再显技术词（daemon / endpoint / port）
  · 在线 AI 配置页砍掉 opencode 引擎诊断卡片，更简洁
  · OpenClaw 桌宠加桌面漫步 + 朝向修复

【v1.2.4 沿用】

  · 工具权限确认 UI —— AI 调工具前在灵动岛下方弹卡片让你
    允许 / 总是允许 / 拒绝；三个 mode 都支持
  · CLI 检测改三层兜底（zsh → bash → 14 个常见路径）

【v1.2.3 沿用】

  · 在线 AI 切换到 opencode HTTP API —— 启动延迟从 800ms 降到 50ms，
    彻底根治"(没有响应)" bug
  · vision 模型自动切换：拖图时按 provider 自动 override 到 vision 模型
  · 云朵桌宠 vision 模式戴眼镜动画 / 长任务情绪气泡
  · 错误态友好化：7 种关键词分类成可操作 hint

【在线 AI 是 agent · 不需要装外部命令行工具】

  内置 opencode (MIT 开源 agent runtime) 让"在线 AI"模式能真的读
  你的本地文件、跑命令、联网搜索、看图，跟 Claude Code / Codex
  同档能力。

【最快上手】

  打开 Hermes 桌宠 → 点齿轮 ⚙️ → "在线 AI" → 选服务商 → 粘 API Key

  推荐：Moonshot Kimi K2.6 中文体验好，agent 工具调用稳定。

  各家 API Key 入口：
    DeepSeek   https://platform.deepseek.com/api_keys
    智谱 GLM   https://open.bigmodel.cn/usercenter/apikeys
    Moonshot   https://platform.moonshot.cn/console/api-keys
    OpenAI     https://platform.openai.com/api-keys

【试试看 AI 的本地能力】

  配好 Key 后试这几个问题感受一下：
    - "看一下我桌面上有什么文件"
    - "帮我把 ~/Downloads 里的截图按日期归类到文件夹"
    - "搜一下今天 macOS 26 的更新"
    - 拖一张图片：「这张图里有什么？」
    - 拖一份 PDF：「帮我总结一下这份文档」

【进阶：还能装 Claude Code / Codex】
  如果机器另外装了 claude / codex 命令行工具，
  点聊天窗顶部模式图标就能切到对应模式 —— 享受更强的 agent。
  没装也不影响在线 AI 模式正常用。
EOF
}

# 跑两次：AppleSilicon 用 darwin-arm64，Intel 用 darwin-x64
build_one_dmg "AppleSilicon" "darwin-arm64"
build_one_dmg "Intel"        "darwin-x64"

echo ""
echo "═══════════════════════════════════════════════"
echo "✅ 两份 DMG 全部打包完成"
echo "═══════════════════════════════════════════════"
ls -lh "$DIST_DIR"/*.dmg | awk '{print "    "$9"  "$5}'
echo ""
echo "📤 分发提示："
echo "    · 朋友是 Apple Silicon (M1/M2/M3/M4) → 发 -AppleSilicon.dmg"
echo "    · 朋友是 Intel 芯片                 → 发 -Intel.dmg"
echo "    · 不确定？让朋友看 苹果菜单 → 关于本机 → 芯片那一行"
echo ""
echo "    ad-hoc 签名的应用每次升级都需重新授权一次屏幕录制"
echo "    （macOS 限制，绕不开。要根治得办 Apple Developer Program）"
