import Foundation

/// 通用文案 + Phase 5-0 验证用的语言选择器文案。
/// 后续 Phase 5-1 各 UI 区域按文件批次新增 `L10nSettings` / `L10nChat` 等模块，
/// 并在 `LocaleManager.zhTable` / `enTable` 的数组里登记。
enum L10nCommon {
    static let zh: [String: String] = [
        // —— 通用动作词 ——
        "common.ok": "确定",
        "common.cancel": "取消",
        "common.save": "保存",
        "common.close": "关闭",
        "common.delete": "删除",
        "common.done": "完成",

        // —— 语言选择器（设置 → 系统）——
        "system.language.title": "语言",
        "system.language.caption": "切换后整个界面立即变为所选语言，无需重启。",

        // —— AgentMode 显示名（跨界面通用：聊天头 / 灵动岛 / 设置等）——
        "mode.label.hermes": "Hermes",
        "mode.label.direct_api": "在线 AI",
        "mode.label.openclaw": "OpenClaw",
        "mode.label.claude_code": "Claude Code",
        "mode.label.codex": "Codex",
        "mode.label.qwen_code": "QwenCode",

        // —— 桌宠名（Clawd / coco / fomo 专名不译，云朵 / 小马 译 Cloud / Pony）——
        "mode.petName.hermes": "小马",
        "mode.petName.direct_api": "云朵",
        "mode.petName.openclaw": "fomo",
        "mode.petName.claude_code": "Clawd",
        "mode.petName.codex": "coco",
        "mode.petName.qwen_code": "Qwen",
    ]

    static let en: [String: String] = [
        "common.ok": "OK",
        "common.cancel": "Cancel",
        "common.save": "Save",
        "common.close": "Close",
        "common.delete": "Delete",
        "common.done": "Done",

        "system.language.title": "Language",
        "system.language.caption": "The interface switches to the selected language instantly—no restart needed.",

        // —— AgentMode display names (shared across chat header / island / settings) ——
        "mode.label.hermes": "Hermes",
        "mode.label.direct_api": "Online AI",
        "mode.label.openclaw": "OpenClaw",
        "mode.label.claude_code": "Claude Code",
        "mode.label.codex": "Codex",
        "mode.label.qwen_code": "QwenCode",

        // —— Pet names (Clawd / coco / fomo are proper names; 云朵 / 小马 → Cloud / Pony) ——
        "mode.petName.hermes": "Pony",
        "mode.petName.direct_api": "Cloud",
        "mode.petName.openclaw": "fomo",
        "mode.petName.claude_code": "Clawd",
        "mode.petName.codex": "coco",
        "mode.petName.qwen_code": "Qwen",
    ]
}
