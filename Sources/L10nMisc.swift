import Foundation

/// 杂项模块的双语文案 —— 暂收：
/// - 桌面 Pin 卡片（PinCardOverlay.swift），key 前缀 `pin.`
/// - 全局热键失败横幅（GlobalHotkey.swift），key 前缀 `hotkey.banner.`
///
/// ⚠️ 注意：带「⚠️ 」前缀的横幅文本（错误态横幅）中英两版都必须保留「⚠️ 」前缀 ——
/// 灵动岛靠这个 emoji 前缀判断是否错误态。
enum L10nMisc {
    static let zh: [String: String] = [
        // —— Pin 卡片相对时间 ——
        "pin.time.justNow": "刚刚",
        "pin.time.minutesAgo": "%d 分钟前",
        "pin.time.hoursAgo": "%d 小时前",
        "pin.time.yesterday": "昨天",
        "pin.time.date.format": "M 月 d 日",

        // —— Pin 卡片操作 ——
        "pin.card.help": "点击转聊天 · 拖动调整位置",
        "pin.task.markUndone": "标记为未完成",
        "pin.task.markDone": "标记为已完成",
        "pin.action.copied": "已复制",
        "pin.action.copy": "复制内容",
        "pin.action.close": "关闭",
        "pin.footer.open": "打开",

        // —— Pin 导出 Markdown ——
        "pin.export.title": "Pin 导出",
        "pin.export.meta": "> 导出时间：%@  共 %d 条",
        "pin.export.task": "任务",
        "pin.export.taskDone": "（已完成）",
        "pin.export.filePrefix": "pins",
        "pin.export.panel.title": "导出全部 Pin 为 Markdown",

        // —— 全局热键失败横幅（保留 ⚠️ 前缀）——
        "hotkey.banner.occupied": "⚠️ 这些热键被别的 app 占用：%@",

        // —— 工具权限确认卡片（PermissionCardView，按钮 Deny/Always/Allow 保持英文）——
        "permission.diff.moreLines": "    … +%d 行",

        // —— 自动更新（UpdateChecker）——
        "update.error.httpStatus": "GitHub 返回 HTTP %d",
        "update.error.checkFailed": "检查失败：%@",
        "update.error.parseNotJSON": "解析失败：响应不是 JSON 对象",
        "update.error.parseMissingTag": "解析失败：缺少 tag_name",
        "update.error.noDMGAsset": "未在 release 中找到 DMG 资产",
        "update.error.missingDownloadURL": "下载链接缺失",
        "update.error.downloadHTTP": "下载失败：HTTP %d",
        "update.error.downloadFailed": "下载失败：%@",
        "update.error.mountFailed": "DMG 挂载失败，无法自动安装",
        "update.error.launchInstaller": "无法启动安装程序：%@",
        "update.ready.title": "新版 v%@ 已就绪",
        "update.ready.body": "点击「立即重启」自动完成安装。\n\n应用会先退出几秒，自动替换为新版后重新打开——你不用打开访达，也不用手动拖拽。",
        "update.button.restartNow": "立即重启",
        "update.button.later": "稍后",
        "update.manual.title": "新版已挂载，请拖入应用程序",
        "update.manual.body": "Finder 已经打开新版 DMG。请把里面的「Hermes 桌宠」拖到旁边的「应用程序」文件夹替换旧版即可。\n\n替换完成后退出当前版本（菜单栏右键 → 退出），重新打开新版本生效。",
        "update.button.gotIt": "知道了",

        // —— 聊天里的 Markdown 卡片（任务卡 / 选项卡 / 代码块 / 文档卡）——
        "markdown.code.untitled": "代码",
        "markdown.code.copied": "已复制",
        "markdown.code.copy": "复制",
        "markdown.tasks.header": "任务清单 · %d 项",
        "markdown.tasks.allArranged": "任务都安排好了",
        "markdown.task.dispatch": "让 AI 做",
        "markdown.task.dispatch.menuTitle": "用哪个 AI 来做",
        "markdown.task.skip": "跳过",
        "markdown.choice.fillHelp": "填入输入框：%@",
        "markdown.docs.header": "昨天碰过的文档",
        "markdown.docs.openHelp": "点击打开 · %@",
        "markdown.docs.missingHelp": "文件不在了（可能被移动或删除）· %@",

        // —— 在线 AI 回复偏好说明（ProviderPreset；品牌名 / 模型名 / label 不翻）——
        "provider.pref.fast.label": "快速",
        "provider.pref.balanced.label": "平衡",
        "provider.pref.deep.label": "深度",
        "provider.pref.fast.caption": "更快，适合日常问答",
        "provider.pref.balanced.caption": "默认推荐，速度和质量均衡",
        "provider.pref.deep.caption": "更慢，适合复杂问题",

        // —— 在线 AI 服务商 UI 名（品牌名不译，仅这几个中文名）——
        "provider.name.custom": "自定义",
        "provider.name.localGateway": "本地 Gateway",
        "provider.name.cloudGateway": "云端 Gateway",
        "provider.name.localOpenclaw": "本地 OpenClaw",

        // —— 日报风格名（BriefingStyle.label；toneInstruction 是 prompt，不在此）——
        "briefing.style.warm": "温暖陪伴",
        "briefing.style.concise": "简洁干练",
        "briefing.style.playful": "俏皮活泼",
        "briefing.style.encouraging": "鼓励打气",
        "briefing.style.sharp": "犀利点醒",
    ]

    static let en: [String: String] = [
        "pin.time.justNow": "Just now",
        "pin.time.minutesAgo": "%d min ago",
        "pin.time.hoursAgo": "%d hr ago",
        "pin.time.yesterday": "Yesterday",
        "pin.time.date.format": "MMM d",

        "pin.card.help": "Click to open in chat · drag to reposition",
        "pin.task.markUndone": "Mark as not done",
        "pin.task.markDone": "Mark as done",
        "pin.action.copied": "Copied",
        "pin.action.copy": "Copy content",
        "pin.action.close": "Close",
        "pin.footer.open": "Open",

        "pin.export.title": "Pin export",
        "pin.export.meta": "> Exported: %@  %d items",
        "pin.export.task": "Task",
        "pin.export.taskDone": " (done)",
        "pin.export.filePrefix": "pins",
        "pin.export.panel.title": "Export all Pins as Markdown",

        "hotkey.banner.occupied": "⚠️ These hotkeys are taken by other apps: %@",

        // —— Permission card (PermissionCardView; Deny/Always/Allow stay English) ——
        "permission.diff.moreLines": "    … +%d lines",

        // —— Auto update (UpdateChecker) ——
        "update.error.httpStatus": "GitHub returned HTTP %d",
        "update.error.checkFailed": "Check failed: %@",
        "update.error.parseNotJSON": "Parse failed: response is not a JSON object",
        "update.error.parseMissingTag": "Parse failed: missing tag_name",
        "update.error.noDMGAsset": "No DMG asset found in release",
        "update.error.missingDownloadURL": "Download link missing",
        "update.error.downloadHTTP": "Download failed: HTTP %d",
        "update.error.downloadFailed": "Download failed: %@",
        "update.error.mountFailed": "Failed to mount DMG, cannot auto-install",
        "update.error.launchInstaller": "Could not launch installer: %@",
        "update.ready.title": "Version v%@ is ready",
        "update.ready.body": "Click \"Restart Now\" to finish installing automatically.\n\nThe app will quit for a few seconds, replace itself with the new version, and reopen — no need to open Finder or drag anything manually.",
        "update.button.restartNow": "Restart Now",
        "update.button.later": "Later",
        "update.manual.title": "New version mounted — drag it into Applications",
        "update.manual.body": "Finder has opened the new DMG. Drag the \"Hermes Pet\" app inside onto the \"Applications\" folder beside it to replace the old version.\n\nAfter replacing, quit the current version (menu bar right-click → Quit) and reopen the new one to take effect.",
        "update.button.gotIt": "Got it",

        // —— Markdown cards in chat (task / choice / code block / document) ——
        "markdown.code.untitled": "code",
        "markdown.code.copied": "Copied",
        "markdown.code.copy": "Copy",
        "markdown.tasks.header": "Task list · %d items",
        "markdown.tasks.allArranged": "All tasks arranged",
        "markdown.task.dispatch": "Let AI do it",
        "markdown.task.dispatch.menuTitle": "Which AI should do it",
        "markdown.task.skip": "Skip",
        "markdown.choice.fillHelp": "Fill into input box: %@",
        "markdown.docs.header": "Documents touched yesterday",
        "markdown.docs.openHelp": "Click to open · %@",
        "markdown.docs.missingHelp": "File is gone (moved or deleted) · %@",

        // —— Online AI response preference captions (ProviderPreset; brand/model/label not translated) ——
        "provider.pref.fast.label": "Fast",
        "provider.pref.balanced.label": "Balanced",
        "provider.pref.deep.label": "Deep",
        "provider.pref.fast.caption": "Faster, good for everyday Q&A",
        "provider.pref.balanced.caption": "Recommended default, balances speed and quality",
        "provider.pref.deep.caption": "Slower, good for complex questions",

        // —— Online AI provider UI names (brand names not translated) ——
        "provider.name.custom": "Custom",
        "provider.name.localGateway": "Local Gateway",
        "provider.name.cloudGateway": "Cloud Gateway",
        "provider.name.localOpenclaw": "Local OpenClaw",

        // —— Briefing style names (BriefingStyle) ——
        "briefing.style.warm": "Warm",
        "briefing.style.concise": "Concise",
        "briefing.style.playful": "Playful",
        "briefing.style.encouraging": "Encouraging",
        "briefing.style.sharp": "Sharp",
    ]
}
