import Foundation

/// 桌宠陪写的动作定义 + prompt 构建。
///
/// 两类动作：
/// - `.transform`：改写选中段（润色/改写/精简/扩写/改错/翻译）—— 需先选中文字。
/// - `.generate`：生成新内容（续写/总结/起标题）—— 不需选中。
///
/// v2(强化版)：所有 prompt 都把**整篇笔记**当上下文喂进去(懂全文、风格不飘)；
/// 另有 `refinePrompt` 支持"再短点/更正式/删第2点"的多轮打磨。
enum NotesAssistKind { case transform, generate }

struct NotesAssistAction: Identifiable, Hashable {
    let id: String
    let labelKey: String
    let icon: String
    let kind: NotesAssistKind

    static let polish    = NotesAssistAction(id: "polish",    labelKey: "notes.pet.action.polish",    icon: "wand.and.stars",                kind: .transform)
    static let expand    = NotesAssistAction(id: "expand",    labelKey: "notes.pet.action.expand",    icon: "arrow.up.left.and.arrow.down.right", kind: .transform)
    static let shorten   = NotesAssistAction(id: "shorten",   labelKey: "notes.pet.action.shorten",   icon: "arrow.down.right.and.arrow.up.left", kind: .transform)
    static let rewrite   = NotesAssistAction(id: "rewrite",   labelKey: "notes.pet.action.rewrite",   icon: "arrow.triangle.2.circlepath",   kind: .transform)
    static let fix       = NotesAssistAction(id: "fix",       labelKey: "notes.pet.action.fix",       icon: "checkmark.seal",                kind: .transform)
    static let translate = NotesAssistAction(id: "translate", labelKey: "notes.pet.action.translate", icon: "character.bubble",              kind: .transform)
    static let continueW = NotesAssistAction(id: "continue",  labelKey: "notes.pet.action.continue",  icon: "text.cursor",                   kind: .generate)
    static let summarize = NotesAssistAction(id: "summarize", labelKey: "notes.pet.action.summarize", icon: "text.append",                   kind: .generate)
    static let title     = NotesAssistAction(id: "title",     labelKey: "notes.pet.action.title",     icon: "textformat",                    kind: .generate)

    /// 右栏常用快捷（4 个）
    static let quick: [NotesAssistAction] = [polish, expand, continueW, summarize]
    /// 「更多」菜单里的其余动作
    static let more: [NotesAssistAction] = [rewrite, shorten, fix, translate, title]
}

enum NotesAssist {
    /// 单段内容截断上限，防超长笔记把 prompt 撑爆 context
    private static let maxSel = 8_000
    private static let maxNote = 12_000

    private static func cap(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) : s
    }

    /// 共用收尾约束：只返回结果本身，保证能干净地写回（不带"好的，这是…"之类前后缀）
    private static let cleanRule = "只返回结果文字本身，不要任何解释、说明、前后缀、引号或 ``` 代码块包裹。"

    /// 整篇笔记上下文块（让 AI 把握全文语气/术语/层级）
    private static func contextBlock(_ fullText: String) -> String {
        let note = cap(fullText, maxNote)
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "下面是整篇笔记，仅供你把握全文的语气、术语与上下文（不要整篇都改）：\n---\n\(note)\n---\n\n"
    }

    static func buildPrompt(action: NotesAssistAction, selection: String, fullText: String, instruction: String) -> String {
        let sel = cap(selection, maxSel)
        let ctx = contextBlock(fullText)
        switch action.id {
        case "polish":
            return "\(ctx)请润色其中这段文字，使其更流畅自然、表达更好，但保持原意，并与原文使用相同的语言。\(cleanRule)\n\n要润色的文字：\n\(sel)"
        case "expand":
            return "\(ctx)请把其中这段文字扩写得更详细充实，保持原意与语言不变、并与全文风格一致。\(cleanRule)\n\n要扩写的文字：\n\(sel)"
        case "shorten":
            return "\(ctx)请精简其中这段文字，去掉冗余、更简洁有力，但保留关键信息与语言。\(cleanRule)\n\n要精简的文字：\n\(sel)"
        case "rewrite":
            return "\(ctx)请用不同的表达方式改写其中这段文字，保持原意与语言不变、与全文风格一致。\(cleanRule)\n\n要改写的文字：\n\(sel)"
        case "fix":
            return "\(ctx)请只修正其中这段文字的错别字和语法错误，不改变其语义、风格与语言。\(cleanRule)\n\n要修正的文字：\n\(sel)"
        case "translate":
            return "\(ctx)请翻译其中这段文字：中文译成英文，英文译成中文，保持术语与全文一致。\(cleanRule)\n\n要翻译的文字：\n\(sel)"
        case "continue":
            return "\(ctx)请承接全文末尾自然地续写下去，延续其语气、术语与语言。只返回新续写的内容本身，不要重复已有文字，不要解释。"
        case "summarize":
            return "\(ctx)请用简洁的要点总结这篇笔记的核心内容（可用 Markdown 列表）。\(cleanRule)"
        case "title":
            return "\(ctx)请为这篇笔记起一个简洁贴切的标题，只返回标题本身一行，不要 # 号、引号或解释。"
        default:
            // 自由指令：有选中就以选中段为对象，否则就整篇笔记为对象
            let target = sel.isEmpty ? "（无选中，针对整篇笔记）" : "针对这段文字：\n\(sel)"
            return "\(ctx)用户的要求：\(instruction)\n\n\(target)\n\n\(cleanRule)"
        }
    }

    /// 多轮打磨 —— 用户对上一版结果提进一步要求
    static func refinePrompt(actionLabel: String, original: String, lastResult: String, noteContext: String, instruction: String) -> String {
        let ctx = contextBlock(noteContext)
        let orig = original.isEmpty ? "（这是新生成的内容，无原始选段）" : cap(original, maxSel)
        return """
        \(ctx)你刚才给出的版本是：
        ---
        \(cap(lastResult, maxSel))
        ---

        用户希望进一步调整：\(instruction)

        请据此给出修改后的新版本。\(cleanRule)
        （原始文字供参考：\(orig)）
        """
    }
}
