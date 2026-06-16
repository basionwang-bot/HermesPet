#!/bin/bash
# make-dmg.sh — 打包可分发的 DMG（一键出两份：AppleSilicon + Intel）
#
# 跟 build.sh 的区别：
# - build.sh：日常本地构建，用 Apple Development 证书签名（权限稳定，但别人 Mac 用不了）
# - make-dmg.sh：分发场景，Developer ID Application 签名 + hardened runtime + Apple 公证 + staple，
#                别人下载双击直接打开（不再需要右键，也不会被 Gatekeeper 拦）
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

# === 正式签名 + 公证配置 ===
# Developer ID Application 证书（分发用，别人 Mac 信任 + 可公证）
DEV_ID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/{print $2; exit}')"
# 公证凭据 profile（先用 xcrun notarytool store-credentials 存好）
NOTARY_PROFILE="HermesPetNotary"
# hardened runtime entitlements（内嵌 opencode 是 bun 二进制，需 JIT）
ENTITLEMENTS="$SCRIPT_DIR/HermesPet.entitlements"

if [ -z "$DEV_ID_IDENTITY" ]; then
    echo "❌ 没找到 Developer ID Application 证书。先在 Xcode 创建，再跑本脚本。"
    exit 1
fi
echo "🔐 签名身份：$DEV_ID_IDENTITY"
echo "📋 公证 profile：${NOTARY_PROFILE}（若未配置，公证步骤会报错并提示）"

# 版本号从 Info.plist 自动读，避免脚本和 plist 漂移
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
echo "📌 版本：${VERSION}（从 Info.plist 读取）"

BUILD_DIR="$SCRIPT_DIR/.build"
DIST_DIR="$SCRIPT_DIR/dist"
# 打包工作目录放在 iCloud Drive 同步范围外（/tmp）。
# 否则 Desktop 在 iCloud 同步时，fileproviderd 会在 codesign 后把 com.apple.FinderInfo
# 写回 .app 根目录 → 签名验证 / 公证失败（CLAUDE.md 决策 #12）。成品 DMG 最后再拷回 dist。
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermespet-dmg.XXXXXX")"
# 失败时**保留**工作目录（含已签名/已公证的 app/DMG），便于复查或续传；
# 只有完整成功（BUILD_OK=1）才清理。避免一次网络抖动把几十分钟的成果全删掉。
BUILD_OK=0
cleanup_workdir() {
    if [ "${BUILD_OK}" = "1" ]; then
        rm -rf "$WORK_DIR"
    else
        echo ""
        echo "⚠️  构建未正常完成，已保留工作目录便于复查/续传："
        echo "      $WORK_DIR"
    fi
}
trap cleanup_workdir EXIT

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

# ⭐ xcbuild 的 universal 产物在 .build/apple/Products/Release（.noindex 临时区），
#    第一份 DMG 公证等待的几分钟里会被系统清掉 → 第二个 arch 的 build_one_dmg cp 时
#    报 "No such file"。编译完立即复制到 .build 持久位置，两个 arch 都用这份副本。
cp "$BUILD_DIR/apple/Products/Release/$APP_NAME" "$BUILD_DIR/$APP_NAME-universal"
BINARY="$BUILD_DIR/$APP_NAME-universal"

# 内嵌的 opencode runtime 版本
OPENCODE_VERSION="${OPENCODE_VERSION:-v1.15.1}"

# 下载对应架构 opencode 到缓存（首次跑会下载，之后复用）
download_opencode() {
    local arch="$1"
    local cache_dir="$SCRIPT_DIR/.opencode-cache/$OPENCODE_VERSION"
    local binary="$cache_dir/opencode-$arch"

    # 所有进度日志走 stderr —— 函数 stdout 只输出 binary 路径，
    # 否则 `$(download_opencode ...)` 命令替换会把日志当成路径，下游 du/cp 全乱
    # 用 -s（存在且非空）而非 -f：防止上次下载中断留下的 0B 文件被当成"已缓存"跳过
    if [ ! -s "$binary" ]; then
        echo "📥 下载 opencode ${OPENCODE_VERSION} (${arch})..." >&2
        rm -f "$binary"
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
        # 下载校验：空文件直接报错，避免拖到签名 / 公证阶段才暴露
        if [ ! -s "$binary" ]; then
            echo "❌ opencode (${arch}) 下载失败或为空文件" >&2
            exit 1
        fi
    fi
    echo "$binary"
}

# 提交公证 + 抗断网轮询。
# notarytool 自带的 --wait 一遇网络抖动（合盖睡眠 / Wi-Fi 闪断 → -1009）就报错退出，
# 整个脚本随之 exit，几十分钟的成果全废。这里改成：submit 拿到 id 后自己轮询，
# 网络错误只警告、不退出（Apple 端公证不受本地网络影响，醒来接着查即可拿结果）。
# $1 = 待公证文件   $2 = 人类可读标签。Accepted 返回 0，其余返回 1。
notarize_resilient() {
    local file="$1"
    local label="$2"

    # --- 提交（不 --wait），拿 submission id；提交本身遇网络错也重试 ---
    local submit_json submit_id tries=0
    while :; do
        if submit_json="$(xcrun notarytool submit "$file" \
                --keychain-profile "$NOTARY_PROFILE" \
                --output-format json 2>/dev/null)"; then
            submit_id="$(printf '%s' "$submit_json" \
                | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
            [ -n "$submit_id" ] && break
        fi
        tries=$((tries + 1))
        echo "   ⏳ ${label} 公证提交未成功（网络？），10s 后重试（第 ${tries} 次）"
        sleep 10
    done
    echo "   📋 ${label} 已提交，公证 id: ${submit_id}"

    # --- 轮询：网络错误只警告不退出，直到 Apple 给出终态 ---
    local info_json status
    while :; do
        if info_json="$(xcrun notarytool info "$submit_id" \
                --keychain-profile "$NOTARY_PROFILE" \
                --output-format json 2>/dev/null)"; then
            status="$(printf '%s' "$info_json" \
                | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"
            case "$status" in
                Accepted)
                    echo "   ✅ ${label} 公证通过"
                    return 0 ;;
                "In Progress" | "")
                    echo "   ⏳ ${label} 公证处理中…（30s 后再查；此时合盖/断网都不影响）" ;;
                *)
                    echo "   ❌ ${label} 公证未通过，状态：${status}"
                    echo "   —— 详细日志 ——"
                    xcrun notarytool log "$submit_id" \
                        --keychain-profile "$NOTARY_PROFILE" 2>/dev/null | head -50
                    return 1 ;;
            esac
        else
            echo "   ⏳ ${label} 查询公证状态失败（网络断/合盖？）—— 不退出，30s 后重试"
        fi
        sleep 30
    done
}

# 打一份 .app + DMG。$1 = 显示后缀（"AppleSilicon" / "Intel"），$2 = opencode arch 标识
build_one_dmg() {
    local suffix="$1"
    local opencode_arch="$2"
    local app_bundle="$WORK_DIR/$APP_NAME-$suffix.app"
    local staging="$WORK_DIR/dmg-staging-$suffix"
    local dmg_path="$WORK_DIR/${APP_NAME}-${VERSION}-${suffix}.dmg"
    local final_dmg="$DIST_DIR/${APP_NAME}-${VERSION}-${suffix}.dmg"

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

    # 3) Developer ID 签名（从内到外：先内嵌 opencode，再主 app）+ hardened runtime
    #    不要用 --deep：Apple 已弃用，且会用同一份 entitlements/签名覆盖内嵌项。手动逐个签最稳。
    #    工作目录在 /tmp（iCloud 范围外），不会被 fileproviderd 写回 FinderInfo，单次签名即可。
    echo "🔐 Developer ID 签名（opencode → app）..."
    find "$app_bundle" -exec xattr -c {} + 2>/dev/null || true
    # 先签内嵌 opencode（bun，需 hardened runtime + JIT entitlements）
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEV_ID_IDENTITY" \
        "$app_bundle/Contents/Resources/opencode"
    # 再签主 app（最外层）
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEV_ID_IDENTITY" \
        "$app_bundle"
    codesign --verify --strict --verbose=2 "$app_bundle"

    # 3.5) 公证 app（zip 上传 → 等结果 → staple 票据到 .app）
    #      在复制进 DMG staging 之前做，这样 DMG 里的 app 已自带公证票据，离线也放行
    echo "📤 公证 app（${suffix}）..."
    local app_zip="$WORK_DIR/${APP_NAME}-${suffix}-notarize.zip"
    ditto -c -k --keepParent "$app_bundle" "$app_zip"
    if ! notarize_resilient "$app_zip" "app/${suffix}"; then
        echo "❌ app 公证失败（${suffix}）。已签名的 app 保留在 $app_bundle 可复查。"
        rm -f "$app_zip"
        exit 1
    fi
    rm -f "$app_zip"
    xcrun stapler staple "$app_bundle" || { echo "❌ staple 失败（${suffix}）"; exit 1; }

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

    # 5.5) 签名 + 公证 + staple DMG（让下载者双击挂载也不被 Gatekeeper 拦）
    echo "🔐 签名 + 公证 DMG（${suffix}）..."
    codesign --force --timestamp --sign "$DEV_ID_IDENTITY" "$dmg_path"
    if ! notarize_resilient "$dmg_path" "DMG/${suffix}"; then
        echo "❌ DMG 公证失败（${suffix}）。DMG 保留在 $dmg_path 可复查。"
        exit 1
    fi
    xcrun stapler staple "$dmg_path" || { echo "❌ DMG staple 失败（${suffix}）"; exit 1; }

    # 6) 成品 DMG 从工作目录搬回 dist。DMG 已签名 + 公证 + staple 完成，
    #    即便 dist 在 iCloud 范围、之后被加 FinderInfo 也不影响：下载传输会丢 xattr，
    #    stapled 票据在 DMG 内部。
    mv "$dmg_path" "$final_dmg"
    rm -rf "$staging" "$app_bundle"

    local dmg_size
    dmg_size=$(du -h "$final_dmg" | cut -f1)
    echo "✅ ${suffix} 版完成：${final_dmg} (${dmg_size})"
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

本应用已通过 Apple 官方公证（Developer ID 签名），可以直接打开：

1. 把「Hermes 桌宠」拖到旁边的「应用程序」文件夹
2. 在 启动台 / Spotlight 打开「Hermes 桌宠」即可

（极少数情况下如果系统仍提示，去「系统设置 → 隐私与安全性」点一次「仍要打开」。）

————————————————

【全局快捷键】
  Cmd+Shift+H  → 呼出 / 收回聊天窗口
  Cmd+Shift+J  → 截当前屏幕并附加到聊天（首次会请求"屏幕录制"权限）
  Cmd+Shift+V  → 按住说话（push-to-talk），松开后自动发送
                  首次会请求"麦克风" + "语音识别"两个权限

授权完任一权限后，建议完全退出 Hermes 桌宠（菜单栏右键 → 退出）
再重新打开一次，让新权限对进程生效。

【v1.4.6 更新】

  · 继续收口同族崩溃 —— 在较新 macOS（26.5+）上，打开「舰队 / 工作流面板 / 博物馆 / AI 网页 / 竞技场 /
    头像裁剪」等功能时可能闪退，这版把这些窗口的承载方式全部换成更稳的实现，点开不再崩
  · 修好了上一版（v1.4.5）的一个位置偏移 —— 悬停灵动岛弹出的系统卡片、以及工作台里的内容位置往下偏了一截，现已回正
  · 一批小修复 —— 工作台多标签状态不再被别处的 AI 活动干扰；英文界面下某个工作流不再卡住重试；
    会议诊断信息不再被误报成「错误」；屏幕自动回复在目标窗口已关闭时不再误报「已回复」

【v1.4.5 更新】

  · 紧急修复 —— 部分用户升级后「打不开 / 一开就崩」：曾用 ⌘⇧P 钉过回答、或钉过系统状态卡的用户，
    在较新 macOS（26.5+）上一启动就闪退。这版根治了这族崩溃（Pin 卡片 / 系统状态卡 / 工作台 / 权限确认卡
    的窗口承载方式全部换成更稳的实现），启动与缩放都不再崩

【v1.4.4 更新】

  · 全新「工作台」（菜单栏 🐇 → 🛠 工作台）—— 普通人也会用的图形化 AI 工作空间：
    左边真实文件树、中间真实预览（Markdown / 代码高亮 / 图片，新增 HTML 渲染成网页 + PDF 原生预览）、
    右边像聊天一样指挥 AI 干活；多标签页，每个标签一个文件夹环境，可分别选在线 AI / Claude Code / Codex
  · AI 学校（工作台顶栏 → 学校）—— 陈列 AgentForge 上百门课程，挑一门点「让 AI 学这门课」，
    AI 真去读课实操、把本事沉淀成技能卡，下次干活就会用
  · 工作台记忆 —— 对话历史 / 打开的文件夹 / 标签页写入磁盘，关窗甚至退出 App 重开都还在，
    重启后还能接上之前的上下文继续干
  · 一批稳定性与体验优化

【v1.4.1 更新】

  · 灵动岛系统信息 —— 刘海右耳实时显示 CPU / 内存 / 温度；
    鼠标悬停灵动岛会展开一张仪表盘看全部系统状态，还能钉成桌面常驻卡片
  · 灵动岛控制中心 + 应用启动器 —— 展开面板里直接搜索、一键打开常用 App
  · 桌宠养成（地基上线）—— 桌宠开始有等级 / 经验 / 心情，陪你用 AI 越久越成长，
    更多养成玩法陆续就来
  · 全量模式（Beta 尝鲜）—— 让桌宠当队长，按"先调研、再分析、后成稿"的顺序
    并行开多支 AI 同时干活，最后汇总成一篇；这版大幅提速、更省后端、过程更透明。
    实验功能、还在打磨，欢迎反馈
  · 新增 QwenCode 模式（青色戴眼镜的小怪兽），装了对应命令行工具即可切换
  · 一批稳定性修复

【v1.4.0 更新】

  · AI 笔记（⌘⇧N）—— 桌宠陪你写的本地 Markdown 笔记本，想法随手记
  · 写作模式 + 实时预览 —— 边写边看排版，适合长文
  · 账号中心（设置 → 账号）—— 设头像（可裁剪）、昵称；一键反馈 / 报 bug；
    聊天里也显示你的头像（官方在线 AI、跨设备同步即将上线）
  · 新功能尝鲜：工作流 / 会议纪要 / 工作流竞技场（打磨中，欢迎反馈）
  · 修复拖文件进对话框偶发闪退；聊天滚动更顺、流式不再抖动；一批稳定性修复

【v1.3.2 更新】

  · 新增「静止模式」（设置 → 桌宠）—— 把桌宠固定在你放的位置，不漫步、
    不追鼠标、不巡视，只保留呼吸眨眼；拖一下换地方会记住位置
  · 在线 AI 桌宠走动时也换成红色小怪兽，跟灵动岛形象统一
  · 修复一批偶发崩溃 / 卡顿（语音、设置隐私页、知识云图、检查更新）
  · 下载更新时进度条正常显示；打开知识云图时更省电

【v1.3.1 沿用】

  · 新增「实验性」开关（设置 → 实验性，默认关）—— 屏幕接管 / 让 AI 替你
    操作软件：打开后能让 AI 看某个窗口（如微信）、帮你拟回复并发出，
    还会自动学你的说话语气。默认关，不开完全不影响日常使用
  · 颜值升级（借鉴 Win 版）—— 灵动岛渐变发光 + 全新红色小怪兽形象
  · 修复在线 AI 偶尔把「思考过程」当正文输出；回答更干净
  · 修复聊天文字偶发抖动、流式时翻不动历史；长回复渲染更顺
  · 跨对话记忆更准，不再把你上传的图片角色当成你本人
  · 快捷键设置独立成栏，支持自定义 + 冲突提示 + 恢复默认

【v1.3.0 沿用】

  · 对话永久保存 + 知识云图（Cmd+Shift+G）+ 越聊越懂你
  · 加星置顶 + 自动归档；多显示器更顺手，切屏不再卡死

【v1.2.15 沿用】

  · 在线 AI 能读 PDF —— 拖进聊天框就能读懂、总结、问答（扫描版也认）
  · 桌宠新增小表演（打盹、偷偷玩电脑）
  · 修复聊天偶尔卡住 / 一直转圈的问题

【v1.2.13 沿用】

  · 整个界面支持中英双语 —— 设置里一键切换中文 / English，
    即时生效不用重启；AI 的聊天回复也会跟着你选的语言走
  · 桌宠更懂你、更会陪你 —— 会在合适的时候温温地陪你
    回顾这阵子做过的事、给你一份贴心的小总结

【v1.2.12 沿用】

  · 权限更省心：第一次授权后，以后升级不再反复要求重新授权
  · 修复"按住说话"语音输入在部分情况下用不了的问题
  · 双击直接打开，安装更顺畅

【更早版本沿用】

  · OpenClaw —— 第 5 个 AI 模式，装着就自动连接，不用填密钥
  · 新桌宠 fomo 🦊（OpenClaw 模式的白色小狐狸）
  · 装了什么就自动启用什么 —— OpenClaw / Hermes / Claude / Codex
  · 关于页官方版本验证 —— 显示开发者身份，能识别盗版

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

# 两份 DMG 已 mv 进 dist（已签名 + 公证 + staple），成果落地，标记成功 → 退出时清理工作目录。
# 即便后面 PUBLISH 步骤失败，dist 里的 DMG 也已安全保存，可单独重跑 PUBLISH=1。
BUILD_OK=1

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
echo "    ✅ 已 Developer ID 签名 + Apple 公证 + staple，别人下载双击即可打开"
echo "    ✅ Team ID R34KL4X4D9，签名身份稳定，升级不再需要重新授权"

# =====================================================================
# 可选：自动发布到「公开仓库」的 GitHub Releases
# ---------------------------------------------------------------------
# 默认只构建、不发版（避免误发）。要发版时显式开启：
#     PUBLISH=1 ./make-dmg.sh
# 始终发到公开发布仓库 PUBLIC_REPO（即便本地 origin 已切到私有源码仓库，
# UpdateChecker 也只认这个公开仓库的 releases/latest）。
# release notes 来源：仓库根有 RELEASE_NOTES.md 就用它，否则让 GitHub 自动生成。
# =====================================================================
PUBLIC_REPO="basionwang-bot/HermesPet"

if [ "${PUBLISH:-0}" = "1" ]; then
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "📤 发布到公开仓库 Releases：$PUBLIC_REPO"
    echo "═══════════════════════════════════════════════"

    if ! command -v gh >/dev/null 2>&1; then
        echo "❌ 没装 gh CLI，无法自动发版。先：brew install gh && gh auth login"
        exit 1
    fi

    TAG="v${VERSION}"
    AS_DMG="$DIST_DIR/${APP_NAME}-${VERSION}-AppleSilicon.dmg"
    INTEL_DMG="$DIST_DIR/${APP_NAME}-${VERSION}-Intel.dmg"

    if gh release view "$TAG" --repo "$PUBLIC_REPO" >/dev/null 2>&1; then
        # Release 已存在 → 只替换/追加 DMG 附件（--clobber 覆盖同名），不动 release 正文，
        # 也绝不删除已有 release，避免误删历史版本。
        echo "ℹ️  Release $TAG 已存在 → 上传并覆盖同名 DMG 附件"
        gh release upload "$TAG" "$AS_DMG" "$INTEL_DMG" --repo "$PUBLIC_REPO" --clobber
    else
        if [ -f "$SCRIPT_DIR/RELEASE_NOTES.md" ]; then
            echo "📝 用 RELEASE_NOTES.md 作为发布说明"
            gh release create "$TAG" "$AS_DMG" "$INTEL_DMG" \
                --repo "$PUBLIC_REPO" --title "$TAG" \
                --notes-file "$SCRIPT_DIR/RELEASE_NOTES.md"
        else
            echo "📝 没有 RELEASE_NOTES.md → 让 GitHub 自动生成发布说明"
            gh release create "$TAG" "$AS_DMG" "$INTEL_DMG" \
                --repo "$PUBLIC_REPO" --title "$TAG" --generate-notes
        fi
    fi
    echo "✅ 已发布 $TAG → https://github.com/$PUBLIC_REPO/releases/tag/$TAG"
    echo "   老用户的 App 会在 24h 内自动检测到新版（手动检查：设置 → 检查更新）"
else
    echo ""
    echo "ℹ️  本次只构建、未发版。要发布到 GitHub Releases，运行："
    echo "       PUBLISH=1 ./make-dmg.sh"
fi
