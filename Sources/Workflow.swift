import SwiftUI

/// WTF 工作流容器（MVP·single 单发）—— `CanvasTemplate` 的超集精简版。
/// 设计见仓库根 `WTF-DESIGN.md`。本期只做 single（D2），pipeline/proactive/加密/远程下发留 M3-M6。
///
/// 身份双语**内联**（不依赖代码 L10n key，为将来远程 `workflows.json` 下发铺路）。

// MARK: - 工作流阶段（harness 执行单元）

/// 一个工作流由若干 **阶段(stage)** 顺序组成 —— 这是把"只塞一段 prompt"升级成
/// "多阶段 harness 流水线"的核心数据结构（泛化自 `MeetingAnalysisPipeline` 的 map/reduce/compose/critique）。
///
/// `kind`：
/// - `transform`：中间步骤，产出喂给后续阶段（`{prev}` / `{step:<id>}` 引用）
/// - `product`：产出最终产物（落聊天 / 网页 / 笔记，看 `Workflow.outputRender`）
/// - `eval`：质检阶段，调 `WorkflowEval` 验收，不通过可回退到 `retryStepID` 重跑
///
/// prompt 占位符：`{input}` 用户输入、`{prev}` 上一阶段输出、`{step:<id>}` 指定阶段输出。
struct WorkflowStage: Codable, Hashable, Identifiable {
    var id: String
    var titleZh: String, titleEn: String
    var kind: String = "transform"              // transform / product / eval
    var roleZh: String = "", roleEn: String = ""
    var promptZh: String = "", promptEn: String = ""
    var streaming: Bool = false                 // false=一次性累加 / true=流式（给 UI 看着长）
    var requireConfirm: Bool = false            // 执行前要用户确认（人工节点）
    var maxRetries: Int = 0                     // eval 不通过时最多回退重跑几次

    // eval 专用
    var requires: [String] = []                 // Tier-1：产物必含的子串（缺一即不通过）
    var evalRulesZh: String = "", evalRulesEn: String = ""   // Tier-3：模型评分 rubric
    var retryStepID: String? = nil              // 不通过回到哪个 stage（nil=回退到 product 阶段）

    private var isEN: Bool { LocaleManager.currentLanguage() == .en }
    var title: String { isEN ? (titleEn.isEmpty ? titleZh : titleEn) : titleZh }
    var evalRules: String { isEN ? (evalRulesEn.isEmpty ? evalRulesZh : evalRulesEn) : evalRulesZh }

    /// 拼这个阶段要发给模型的完整 prompt（role + 填好占位符的模板）。
    func buildPrompt(input: String, priorOutputs: [String: String] = [:], prevOutput: String = "") -> String {
        let role = isEN ? (roleEn.isEmpty ? roleZh : roleEn) : roleZh
        var t = isEN ? (promptEn.isEmpty ? promptZh : promptEn) : promptZh
        t = t.replacingOccurrences(of: "{input}", with: input)
        t = t.replacingOccurrences(of: "{prev}", with: prevOutput)
        for (k, v) in priorOutputs { t = t.replacingOccurrences(of: "{step:\(k)}", with: v) }
        return role.isEmpty ? t : role + "\n\n" + t
    }
}

struct Workflow: Identifiable, Codable, Hashable {
    let id: String
    var version: String = "1.0.0"

    // ① 身份（双语内联）
    var nameZh: String,  nameEn: String
    var summaryZh: String, summaryEn: String
    var icon: String            // SF Symbol
    var accent: String          // hex，如 "#FF8A3D"
    var category: String        // 写作 / 编程 / 学习 / 效率 …

    // ⑤ engine（single）—— role 注入 + userTemplate 填 {input}
    var roleZh: String,  roleEn: String
    var userTemplateZh: String, userTemplateEn: String
    var inputHintZh: String, inputHintEn: String   // 提示用户喂什么

    // ⑥ output（chat=落聊天 / artifact=生成网页 / note=落笔记）
    var outputRender: String = "chat"

    // ⑥b 输入来源："typed"=只用用户在输入框打/粘的内容；
    //    "auto"=用户没粘长文(短指令如「分析当前对话」)时，自动改用**当前对话内容**当材料
    //    —— 总结/洞察/纪要这类"对一段内容做事"的工作流设成 auto，符合用户直觉
    var inputSource: String = "typed"

    // ⑦ 竞技场垂类标记（如 "meeting"）—— 同 vertical 的多个 workflow 在「工作流竞技场」里同题比拼。
    //    空 = 不参赛。比拼单位就是这个可复用 Workflow 本身。
    var vertical: String = ""

    // ⑤b 多阶段 harness：声明了就走多阶段流水线；nil/空 = 老的单 prompt（自动合成单阶段，行为不变）
    var stages: [WorkflowStage]? = nil

    // ⑩ 分发
    var author: String = "official"

    // MARK: 本地化取值（currentLanguage 是 nonisolated，可随处调）
    private var isEN: Bool { LocaleManager.currentLanguage() == .en }
    var name: String { isEN ? (nameEn.isEmpty ? nameZh : nameEn) : nameZh }
    var summary: String { isEN ? (summaryEn.isEmpty ? summaryZh : summaryEn) : summaryZh }
    var inputHint: String { isEN ? (inputHintEn.isEmpty ? inputHintZh : inputHintEn) : inputHintZh }
    var accentColor: Color { Color(hex: accent) ?? .indigo }

    /// 把用户输入包成完整 prompt（role + 填好的 userTemplate）。{input} 替换成用户内容。
    func buildPrompt(input: String) -> String {
        let role = isEN ? (roleEn.isEmpty ? roleZh : roleEn) : roleZh
        let tmpl = isEN ? (userTemplateEn.isEmpty ? userTemplateZh : userTemplateEn) : userTemplateZh
        let filled = tmpl.replacingOccurrences(of: "{input}", with: input)
        return role.isEmpty ? filled : role + "\n\n" + filled
    }

    /// harness 真正执行的阶段列表：声明了 `stages` 就用；否则把老的单 prompt 合成 **一个 product 阶段**
    /// —— 这样所有现有单发工作流（polish/translate/…）就是"只有一步的流水线"，产出与旧版完全一致。
    var effectiveStages: [WorkflowStage] {
        if let s = stages, !s.isEmpty { return s }
        return [WorkflowStage(
            id: "main",
            titleZh: nameZh, titleEn: nameEn,
            kind: "product",
            roleZh: roleZh, roleEn: roleEn,
            promptZh: userTemplateZh, promptEn: userTemplateEn,
            streaming: true)]
    }
}

// MARK: - 工作流注册表（bundled 兜底，远程合并留 M1+，克隆 ProviderPresetRegistry 思路）

@MainActor
@Observable
final class WorkflowRegistry {
    static let shared = WorkflowRegistry()
    private(set) var workflows: [Workflow] = []
    private init() { workflows = Self.bundled }
    func workflow(id: String) -> Workflow? { workflows.first { $0.id == id } }

    /// 内置首发 workflow（都是 single 单发、对"你输入/粘贴的文字"做事，最实用的几样）。
    static let bundled: [Workflow] = [
        Workflow(
            id: "polish", nameZh: "写作润色", nameEn: "Polish",
            summaryZh: "把口语化/啰嗦的文字润色得通顺专业", summaryEn: "Make text fluent & professional",
            icon: "wand.and.stars", accent: "#7C6CFF", category: "写作",
            roleZh: "你是资深中文编辑，擅长把口语化、啰嗦或生硬的文字润色得通顺、专业、有条理，同时保留原意和作者语气。",
            roleEn: "You are a senior editor who polishes text to be fluent and professional while keeping the original meaning and tone.",
            userTemplateZh: "请润色下面这段文字：更通顺专业、去掉啰嗦和病句，但**不改变原意、不扩写、不过度删减**。直接输出润色后的文字：\n\n{input}",
            userTemplateEn: "Polish the following text to be fluent and professional, without changing its meaning. Output only the polished text:\n\n{input}",
            inputHintZh: "粘贴要润色的文字…", inputHintEn: "Paste text to polish…"),

        Workflow(
            id: "translate", nameZh: "中英翻译", nameEn: "Translate",
            summaryZh: "中↔英互译，地道准确", summaryEn: "Idiomatic ZH↔EN translation",
            icon: "character.book.closed", accent: "#2FB5E8", category: "写作",
            roleZh: "你是专业的中英双语译者，译文地道、准确、符合目标语言的表达习惯。",
            roleEn: "You are a professional bilingual translator producing idiomatic, accurate translations.",
            userTemplateZh: "请翻译下面的内容（中文→英文，英文→中文）。只输出译文，不要解释：\n\n{input}",
            userTemplateEn: "Translate the following (ZH→EN, EN→ZH). Output only the translation:\n\n{input}",
            inputHintZh: "粘贴要翻译的中文或英文…", inputHintEn: "Paste text to translate…"),

        Workflow(
            id: "summarize", nameZh: "长文总结", nameEn: "Summarize",
            summaryZh: "抓核心结论 + 关键要点", summaryEn: "Core takeaway + key points",
            icon: "list.bullet.rectangle", accent: "#FF8A3D", category: "效率",
            roleZh: "你是擅长抓重点的分析师，总结具体、不写空话。",
            roleEn: "You are an analyst who summarizes concretely, no fluff.",
            userTemplateZh: "把下面的内容总结好：先一句话核心结论，再分条列关键信息（具体、有数字/事实，不要正确的废话）：\n\n{input}",
            userTemplateEn: "Summarize: one-sentence takeaway, then key points (concrete, no fluff):\n\n{input}",
            inputHintZh: "粘贴长文，或直接发「总结当前对话」", inputHintEn: "Paste a long text, or say 'summarize this chat'",
            inputSource: "auto"),

        Workflow(
            id: "commit", nameZh: "生成 Commit 信息", nameEn: "Git Commit",
            summaryZh: "改动说明/diff → 规范 commit", summaryEn: "Diff → conventional commit",
            icon: "checkmark.seal", accent: "#3DDC97", category: "编程",
            roleZh: "你是严谨的工程师，写规范的 git commit message（Conventional Commits 风格：`type: 简洁描述`）。",
            roleEn: "You write clean Conventional Commits git messages.",
            userTemplateZh: "根据下面的改动描述/diff，生成规范的 git commit message：首行 `type: 摘要`（≤50字），需要的话空行后加要点。只输出 commit message：\n\n{input}",
            userTemplateEn: "From the change/diff below, write a conventional commit message. Output only the message:\n\n{input}",
            inputHintZh: "粘贴改动说明或 git diff…", inputHintEn: "Paste change notes or git diff…"),

        Workflow(
            id: "minutes", nameZh: "整理成纪要", nameEn: "To Minutes",
            summaryZh: "杂乱记录 → 主题/要点/决定/待办", summaryEn: "Notes → structured minutes",
            icon: "doc.text", accent: "#E85C8A", category: "效率",
            roleZh: "你是顶级的会议/笔记整理师，纪要结构清晰、具体、不空话。",
            roleEn: "You turn messy notes into clean, concrete minutes.",
            userTemplateZh: "把下面这段文字/记录整理成纪要：**主题、关键要点、结论或决定、待办（如有，标注负责人/时间）**。具体、不写「进行了讨论」这类空话：\n\n{input}",
            userTemplateEn: "Turn the notes below into minutes: topic, key points, decisions, action items. Be concrete:\n\n{input}",
            inputHintZh: "粘贴记录，或直接发「整理当前对话」", inputHintEn: "Paste notes, or say 'turn this chat into minutes'",
            inputSource: "auto"),

        Workflow(
            id: "explain", nameZh: "讲给我听", nameEn: "Explain It",
            summaryZh: "复杂概念讲通俗 + 举例", summaryEn: "Explain simply with examples",
            icon: "lightbulb", accent: "#F5B82E", category: "学习",
            roleZh: "你是擅长把复杂概念讲得通俗易懂的老师，会用类比和例子，循序渐进。",
            roleEn: "You explain complex things simply with analogies and examples.",
            userTemplateZh: "请用通俗易懂的方式给我讲清楚下面这个概念/问题，必要时举个例子或打个比方，让没基础的人也能听懂：\n\n{input}",
            userTemplateEn: "Explain the following clearly, with an example or analogy if helpful:\n\n{input}",
            inputHintZh: "粘贴你想搞懂的概念/术语/问题…", inputHintEn: "Paste a concept/term/question…"),

        // ⭐ 多阶段 harness 样板：提炼主张 → 挖盲点 → 成稿(流式) → 自检验收（不通过回退重跑）
        Workflow(
            id: "deep-insight", nameZh: "深度洞察", nameEn: "Deep Insight",
            summaryZh: "多阶段精读：提炼主张 → 挖盲点 → 出结构化洞察", summaryEn: "Multi-stage: claims → blind spots → structured insight",
            icon: "lightbulb.max", accent: "#FF8A3D", category: "效率",
            roleZh: "你是顶级的洞察分析师，敢于指出盲点、不写正确的废话。",
            roleEn: "You are a top insight analyst who exposes blind spots and avoids fluff.",
            userTemplateZh: "{input}", userTemplateEn: "{input}",
            inputHintZh: "粘贴内容，或直接发「深挖当前对话」", inputHintEn: "Paste content, or say 'analyze this chat'",
            outputRender: "chat",
            inputSource: "auto",
            stages: [
                WorkflowStage(
                    id: "claims", titleZh: "提炼核心主张", titleEn: "Extract claims",
                    kind: "transform",
                    promptZh: "通读下面的内容，**忠实地**提炼出其中的核心主张 / 关键事实 / 已下的结论（markdown 列表，贴着原文、不泛化、不编造）：\n\n{input}",
                    promptEn: "Faithfully extract the core claims / key facts / conclusions from the content below (markdown list, no fabrication):\n\n{input}"),
                WorkflowStage(
                    id: "blindspots", titleZh: "挖掘盲点", titleEn: "Find blind spots",
                    kind: "transform",
                    promptZh: "下面是从一段内容里提炼的核心主张。请你**批判性地**找出：① 没说出口的隐含假设；② 站不住或证据不足的地方；③ 被忽略的反例 / 风险 / 边界情况；④ 真正值得追问的关键问题。具体、犀利，不要正确的废话：\n\n【核心主张】\n{step:claims}\n\n【原文供参考】\n{input}",
                    promptEn: "Below are core claims from some content. Critically find: hidden assumptions; weak/unsupported points; ignored counter-examples/risks/edge cases; key questions worth asking. Be sharp and specific:\n\n[Claims]\n{step:claims}\n\n[Original]\n{input}"),
                WorkflowStage(
                    id: "insight", titleZh: "撰写洞察", titleEn: "Compose insight",
                    kind: "product",
                    promptZh: "综合下面的核心主张和盲点分析，写一份高质量的深度洞察，严格用这四个二级标题：\n## 🎯 核心洞察\n## ⚠️ 盲点\n## ❓ 关键追问\n## 💡 延伸建议\n要求：不复述原文、敢下判断、具体有依据、不要正确的废话。直接输出 markdown：\n\n【核心主张】\n{step:claims}\n\n【盲点分析】\n{step:blindspots}",
                    promptEn: "Synthesize into a deep insight using exactly these four H2 headers: ## 🎯 Core insight / ## ⚠️ Blind spots / ## ❓ Key questions / ## 💡 Suggestions. Be concrete, output markdown:\n\n[Claims]\n{step:claims}\n\n[Blind spots]\n{step:blindspots}",
                    streaming: true),
                WorkflowStage(
                    id: "check", titleZh: "验收", titleEn: "Verify",
                    kind: "eval", maxRetries: 1,
                    requires: ["核心洞察", "盲点", "追问", "建议"],
                    evalRulesZh: "这份深度洞察是否：四个板块齐全、有具体判断而非空话、确实指出了盲点？",
                    evalRulesEn: "Does the insight have all four sections, concrete judgments (not fluff), and real blind spots?",
                    retryStepID: "insight"),
            ]),

        // ===== 🏟 会议纪要竞技场参赛者（vertical="meeting"，同题比拼，深浅不同）=====

        // ① 基线：一遍过，单 prompt（证明"裸 prompt"的天花板）
        Workflow(
            id: "minutes-quick", nameZh: "快速纪要（基线）", nameEn: "Quick Minutes",
            summaryZh: "一遍过：直接把转写整理成纪要", summaryEn: "One-pass: transcript → minutes",
            icon: "bolt", accent: "#9AA0A6", category: "会议纪要",
            roleZh: "你是会议记录员。", roleEn: "You are a meeting note taker.",
            userTemplateZh: "把下面的会议转写整理成一份纪要：\n\n{input}",
            userTemplateEn: "Turn the meeting transcript below into minutes:\n\n{input}",
            inputHintZh: "粘贴会议转写…", inputHintEn: "Paste transcript…",
            inputSource: "auto", vertical: "meeting"),

        // ② 精读：提取→归并定类型→成稿→自检（多阶段 harness，泛化自 MeetingAnalysisPipeline）
        Workflow(
            id: "minutes-pro", nameZh: "精读纪要", nameEn: "Deep-Read Minutes",
            summaryZh: "提取要点→归并定类型→成稿→自检补漏", summaryEn: "Extract→organize→compose→self-check",
            icon: "doc.text.magnifyingglass", accent: "#E85C8A", category: "会议纪要",
            roleZh: "你是顶级会议纪要整理师，具体、有依据、不写空话。",
            roleEn: "You are a top minutes editor: concrete, grounded, no fluff.",
            userTemplateZh: "{input}", userTemplateEn: "{input}",
            inputHintZh: "粘贴会议转写…", inputHintEn: "Paste transcript…",
            inputSource: "auto", vertical: "meeting",
            stages: [
                WorkflowStage(
                    id: "extract", titleZh: "提取要点", titleEn: "Extract points", kind: "transform",
                    promptZh: "忠实提取下面会议转写里的全部要点（事实/数字/名称/结论/决定/待办/疑问/分歧），贴着原文、不泛化、不编造，markdown 列表：\n\n{input}",
                    promptEn: "Faithfully extract all points (facts/numbers/decisions/todos/disagreements) from the transcript, markdown list:\n\n{input}"),
                WorkflowStage(
                    id: "organize", titleZh: "归并定类型", titleEn: "Organize", kind: "transform",
                    promptZh: "把下面的要点按主题归并、去重、排出逻辑顺序，保留所有具体事实/数字/结论；并判断会议类型（工作会/评审/头脑风暴/同步…）：\n\n{step:extract}",
                    promptEn: "Merge/dedup/order the points by topic, keep all concrete facts, and decide the meeting type:\n\n{step:extract}"),
                WorkflowStage(
                    id: "compose", titleZh: "成稿", titleEn: "Compose", kind: "transform",
                    promptZh: "根据下面整理好的要点写一份高质量纪要：首行 `主题：xxx`，再按 议题 / 关键讨论 / 决议 / 行动项（谁·何时） / 遗留问题 组织；具体、敢下结论、杜绝「进行了讨论」这类空话：\n\n{step:organize}",
                    promptEn: "Write high-quality minutes from the organized points: first line `主题：`, then 议题/关键讨论/决议/行动项/遗留问题. Concrete, no fluff:\n\n{step:organize}"),
                WorkflowStage(
                    id: "critique", titleZh: "自检补漏", titleEn: "Self-check", kind: "product",
                    promptZh: "对照原始要点检查这份纪要：漏了哪些重要结论/数字/决定/待办？补回去；哪里空泛？换具体的；有没有编造？删掉。直接输出改进后的完整纪要：\n\n【纪要】\n{step:compose}\n\n【原始要点（以此为准）】\n{step:organize}",
                    promptEn: "Check the minutes against the points: add missing items, replace vague text, delete fabrications. Output the improved full minutes:\n\n[Minutes]\n{step:compose}\n\n[Points]\n{step:organize}",
                    streaming: true),
            ]),

        // ③ 行动导向：聚焦决议与待办（谁·何时·状态）
        Workflow(
            id: "minutes-action", nameZh: "行动纪要", nameEn: "Action Minutes",
            summaryZh: "聚焦决议 + 待办（谁·何时·状态）", summaryEn: "Decisions + action items focus",
            icon: "checklist", accent: "#3DDC97", category: "会议纪要",
            roleZh: "你是把会议转成可执行清单的项目经理。", roleEn: "You turn meetings into actionable lists.",
            userTemplateZh: "{input}", userTemplateEn: "{input}",
            inputHintZh: "粘贴会议转写…", inputHintEn: "Paste transcript…",
            inputSource: "auto", vertical: "meeting",
            stages: [
                WorkflowStage(
                    id: "pick", titleZh: "抽取决议与待办", titleEn: "Pick decisions/actions", kind: "transform",
                    promptZh: "从下面会议转写里只抽取：① 达成的决议；② 待办行动项（尽量带负责人/时间）；③ 悬而未决的问题。贴原文、不编造：\n\n{input}",
                    promptEn: "From the transcript, extract only: decisions made; action items (with owner/time if any); open questions:\n\n{input}"),
                WorkflowStage(
                    id: "compose", titleZh: "成稿", titleEn: "Compose", kind: "product",
                    promptZh: "把下面内容整理成行动导向纪要：首行 `主题：xxx`；然后 ## 决议（分条）、## 行动项（- [ ] 事项 — 负责人 · 截止）、## 待跟进。具体、可执行：\n\n{step:pick}",
                    promptEn: "Compose action-oriented minutes: `主题：`, then ## Decisions, ## Action items (- [ ] task — owner · due), ## Follow-ups:\n\n{step:pick}",
                    streaming: true),
            ]),
    ]
}

// MARK: - 飞轮燃料（先埋 runCount，D3：不做积分，只攒数据）

@MainActor
enum WorkflowTelemetry {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/workflow-stats.json")
    }
    private static var counts: [String: Int] = load()

    private static func load() -> [String: Int] {
        guard let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: Int].self, from: d) else { return [:] }
        return m
    }
    private static func save() {
        guard let d = try? JSONEncoder().encode(counts) else { return }
        // 先确保父目录存在，否则首次运行（~/.hermespet 还没建）write 静默失败 → 运行计数永久丢失（审计 #9）
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// 跑了一次某 workflow（记 runCount + 哪个 mode）。
    static func recordRun(id: String, mode: String) {
        counts[id, default: 0] += 1
        save()
        NSLog("[Workflow] run \(id) via \(mode) (累计 \(counts[id] ?? 0) 次)")
    }
    static func runCount(id: String) -> Int { counts[id] ?? 0 }
}
