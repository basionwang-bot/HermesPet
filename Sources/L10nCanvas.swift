import Foundation

/// 画布工作区（CanvasView + CanvasService + CanvasTemplates）面向用户的双语文案。
/// key 前缀：`canvas.`，二级按区域（toolbar / progress / card / lightbox / creator / template / error 等）。
/// 在 `LocaleManager.zhTable` / `enTable` 数组里登记后生效。
///
/// ⚠️ 红线：画布里发给 AI 的生图 / 生文 prompt（promptHint / systemPrompt / 含 <topic> 模板）
/// **不翻译、保持中文原样**，那些是「内容生成指令」，翻了会改变生图效果。这里只收 UI 文案。
enum L10nCanvas {
    static let zh: [String: String] = [
        // —— 顶部 toolbar ——
        "canvas.toolbar.untitled": "未命名画布",
        "canvas.toolbar.regenFailed": "仅重生失败的卡",
        "canvas.toolbar.regenAll": "重生所有图片",
        "canvas.toolbar.regen.help": "重新生成",
        "canvas.toolbar.export.help": "打包下载到桌面",

        // —— 进度文案 ——
        "canvas.progress.generating": "%d 生成中",
        "canvas.progress.generatingCount": "生成中 %d/%d",

        // —— 导出 / 保存结果（toast）——
        "canvas.export.folderSuffix": "主图套图",
        "canvas.export.imagePrefix": "主图",
        "canvas.export.done": "✅ 已导出到桌面：%@",
        "canvas.export.failed": "导出失败：%@",
        "canvas.save.done": "✅ 已保存到桌面：%@",
        "canvas.save.failed": "保存失败：%@",
        "canvas.save.fallbackTopic": "canvas",

        // —— 辅助文案区 ——
        "canvas.legacy.title": "辅助文案",

        // —— 图片卡状态 ——
        "canvas.card.painting": "AI 正在画…",
        "canvas.card.genFailed": "生成失败",
        "canvas.card.creating": "AI 正在创作 · %@",
        "canvas.card.failedHint": "这张没生成成功",
        "canvas.card.retry": "再试一次",
        "canvas.card.waiting": "等待生成…",

        // —— 图片卡 hover 操作条 ——
        "canvas.card.op.view": "查看大图",
        "canvas.card.op.save": "保存到桌面",
        "canvas.card.op.regen": "重新生成",
        "canvas.card.op.delete": "删除此卡",

        // —— 文字卡 ——
        "canvas.text.generating": "（生成中…）",
        "canvas.text.menu.regen": "重新生成",
        "canvas.text.menu.delete": "删除",

        // —— 空状态 ——
        "canvas.empty.loading": "画布加载中…",

        // —— Lightbox ——
        "canvas.lightbox.save": "保存到桌面",

        // —— 新建画布 Sheet ——
        "canvas.creator.title": "新建画布",
        "canvas.creator.template": "选模板",
        "canvas.creator.topic": "主题",
        "canvas.creator.topic.placeholder": "如：可口可乐 / SwiftUI 入门课 / 一个孤独的灯塔",
        "canvas.creator.cancel": "取消",
        "canvas.creator.start": "开始生成",
        "canvas.creator.ref.title": "产品参考图",
        "canvas.creator.ref.recommend": "（强烈推荐 · 让品牌还原度大幅提升）",
        "canvas.creator.ref.note": "没上传也能生成，但 AI 会从零画，品牌细节大概率不对（如 logo 错版 / 标签糊）",
        "canvas.creator.ref.add.help": "点击选图，或拖一张产品图进来",
        "canvas.creator.ref.pick.message": "选择真实产品图（推荐多张：正面 / 侧面 / 细节）",

        // —— 模板名 / 说明（用户在模板选择器看到的）——
        "canvas.template.ecommerce.name": "电商主图 5 张套图",
        "canvas.template.ecommerce.summary": "淘宝/天猫规范的 5 张 800×800 主图，每张都带精确排版的中文文案",
        "canvas.template.courseware.name": "课件大纲",
        "canvas.template.courseware.summary": "封面图 + 课程标题 + 5 个章节要点 + 总结",
        "canvas.template.storyboard.name": "故事板",
        "canvas.template.storyboard.summary": "主题描述 + 4 格叙事插画 + 一句话报题",
        "canvas.template.custom.name": "AI 自由规划",
        "canvas.template.custom.summary": "不预设结构，让 AI 看主题自己决定生成什么",

        // —— 生成 / 规划过程中的错误（显示在卡片 tooltip 或底部输入提示）——
        "canvas.error.noImage": "Codex 没有返回图片",
        "canvas.error.planEncode": "规划 JSON 编码失败",
        "canvas.error.parseResponse": "未能解析 AI 响应",
        "canvas.error.missingElementID": "缺少 element_id 或匹配不到",
        "canvas.error.addIncomplete": "add 参数不完整",
        "canvas.error.unrecognized": "未识别",
    ]

    static let en: [String: String] = [
        "canvas.toolbar.untitled": "Untitled canvas",
        "canvas.toolbar.regenFailed": "Regenerate failed cards only",
        "canvas.toolbar.regenAll": "Regenerate all images",
        "canvas.toolbar.regen.help": "Regenerate",
        "canvas.toolbar.export.help": "Export all to Desktop",

        "canvas.progress.generating": "%d generating",
        "canvas.progress.generatingCount": "Generating %d/%d",

        "canvas.export.folderSuffix": "main-images",
        "canvas.export.imagePrefix": "image",
        "canvas.export.done": "✅ Exported to Desktop: %@",
        "canvas.export.failed": "Export failed: %@",
        "canvas.save.done": "✅ Saved to Desktop: %@",
        "canvas.save.failed": "Save failed: %@",
        "canvas.save.fallbackTopic": "canvas",

        "canvas.legacy.title": "Supporting copy",

        "canvas.card.painting": "AI is drawing…",
        "canvas.card.genFailed": "Generation failed",
        "canvas.card.creating": "AI is creating · %@",
        "canvas.card.failedHint": "This one didn't generate",
        "canvas.card.retry": "Try again",
        "canvas.card.waiting": "Waiting to generate…",

        "canvas.card.op.view": "View larger",
        "canvas.card.op.save": "Save to Desktop",
        "canvas.card.op.regen": "Regenerate",
        "canvas.card.op.delete": "Delete this card",

        "canvas.text.generating": "(generating…)",
        "canvas.text.menu.regen": "Regenerate",
        "canvas.text.menu.delete": "Delete",

        "canvas.empty.loading": "Loading canvas…",

        "canvas.lightbox.save": "Save to Desktop",

        "canvas.creator.title": "New canvas",
        "canvas.creator.template": "Template",
        "canvas.creator.topic": "Topic",
        "canvas.creator.topic.placeholder": "e.g. Coca-Cola / Intro to SwiftUI / A lonely lighthouse",
        "canvas.creator.cancel": "Cancel",
        "canvas.creator.start": "Start generating",
        "canvas.creator.ref.title": "Product reference images",
        "canvas.creator.ref.recommend": "(highly recommended · greatly improves brand fidelity)",
        "canvas.creator.ref.note": "You can generate without uploads, but the AI draws from scratch and brand details are likely off (wrong logo / blurry labels).",
        "canvas.creator.ref.add.help": "Click to pick images, or drag a product photo here",
        "canvas.creator.ref.pick.message": "Choose real product photos (multiple recommended: front / side / detail)",

        "canvas.template.ecommerce.name": "E-commerce 5-image set",
        "canvas.template.ecommerce.summary": "Five 800×800 main images per Taobao/Tmall specs, each with precisely laid-out Chinese copy",
        "canvas.template.courseware.name": "Courseware outline",
        "canvas.template.courseware.summary": "Cover image + course title + 5 chapter points + summary",
        "canvas.template.storyboard.name": "Storyboard",
        "canvas.template.storyboard.summary": "Theme description + 4-panel narrative illustration + one-line title",
        "canvas.template.custom.name": "AI free planning",
        "canvas.template.custom.summary": "No preset structure—let the AI decide what to generate from the topic",

        "canvas.error.noImage": "Codex returned no image",
        "canvas.error.planEncode": "Failed to encode plan JSON",
        "canvas.error.parseResponse": "Couldn't parse the AI response",
        "canvas.error.missingElementID": "Missing element_id or no match",
        "canvas.error.addIncomplete": "Incomplete add parameters",
        "canvas.error.unrecognized": "Unrecognized",
    ]
}
