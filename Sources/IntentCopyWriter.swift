import Foundation

/// "当下感知"反馈的信号类型 —— 决定走哪个模板池 + 是否强制名词门槛
enum IntentSignalKind {
    /// ⌘C 命中 stack trace / 编译错误（必须有名词才发）
    case copiedError
    /// 切窗口标题含 debugger/breakpoint/console
    case windowTitleDebug
    /// Stack Overflow 页面
    case windowTitleStackOverflow
    /// 翻文档（MDN / Apple Doc 等）
    case windowTitleDoc
    /// OCR 命中关键词 + 上下文有名词（必须有名词才发）
    case screenKeyword
    // 注：原 windowTitleError 已砍掉 —— 子串匹配（error/fail/crash 等）假阳性太多，
    // 用户切到含这些子串的合理窗口（ErrorHandler.swift / Email Failed / 错误报告菜单）就误报
    // 真"看到报错"信号走 copiedError（用户主动复制）+ screenKeyword（OCR + 代码语境）
}

/// 反馈文案生成器（Wave D 核心）
///
/// 三个职责：
/// 1. **名词提取** —— 从原始文本（剪贴板内容 / 窗口标题 / OCR）里挖出"具体名词"
///    （文件名 / camelCase 标识符 / 引号包裹的代码）。**没名词的反馈宁可不发**
/// 2. **mode 人设** —— 4 个 mode 各自的语气池，让"AI 在场"感更鲜活：
///    - **Hermes 羽毛**：客气体（"注意到 xxx" / "你在 yyy 上"）
///    - **在线 AI 云朵**：软乎体（"咦，xxx？" / "我看到了哎"）
///    - **Claude 螃蟹 Clawd**：横向幽默（"横眼看 xxx" / "嗯？这个 yyy"）
///    - **Codex 终端 coco**：直接体（"→ xxx" / "err: yyy"）
/// 3. **长度天花板** —— 桌宠气泡 ≤12 字、灵动岛标签 ≤8 字，统一 truncate
///
/// 设计准则：宁可不发，不发废话 —— "没名词不发"是 Wave D 的核心硬规则。
@MainActor
enum IntentCopyWriter {

    // MARK: - 公开入口

    /// 组合一句反馈文案。
    /// - Parameters:
    ///   - kind: 反馈类型
    ///   - mode: 当前 AgentMode
    ///   - nounSource: 用于提取名词的原始文本（剪贴板 / 标题 / OCR 片段，nil 时跳过提取）
    /// - Returns: 已成型的短文字；nil 表示"无名词不发"硬规则触发，调用方应跳过
    static func compose(kind: IntentSignalKind, mode: AgentMode, nounSource: String?) -> String? {
        let noun: String? = nounSource.flatMap { extractNoun($0) }

        // 硬规则：copiedError / screenKeyword 类没名词直接不发 —— 防止"看到报错了"
        // 这种纯模板叙述（用户体验和"AI 在数次数"无差，无智能感）
        if (kind == .copiedError || kind == .screenKeyword) && noun == nil {
            return nil
        }

        return composeByMode(kind: kind, mode: mode, noun: noun)
    }

    /// 截断到指定长度（中文 1 字 = 1 char），超长末尾换 …
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(max(1, limit - 1))
        return String(prefix) + "…"
    }

    // MARK: - 名词提取（5 级优先级）

    /// 从一段文本里挖"具体名词"。
    /// 优先级：backtick → 双引号 → 含扩展名的文件名 → CamelCase → snake_case
    /// 返回的字符串 2-30 字，避免过短（噪声）/ 过长（不像名词）
    static func extractNoun(_ text: String) -> String? {
        // 1. backtick 包裹（最高 —— 通常是代码引用）
        if let r = text.range(of: "`([^`]+)`", options: .regularExpression) {
            let s = text[r]
            let inner = s.dropFirst().dropLast()
            let cleaned = String(inner).trimmingCharacters(in: .whitespaces)
            if cleaned.count >= 2, cleaned.count <= 30 { return cleaned }
        }
        // 2. 双引号包裹
        if let r = text.range(of: "\"([^\"]+)\"", options: .regularExpression) {
            let s = text[r]
            let inner = s.dropFirst().dropLast()
            let cleaned = String(inner).trimmingCharacters(in: .whitespaces)
            if cleaned.count >= 2, cleaned.count <= 30 { return cleaned }
        }
        // 3. 含扩展名的文件名（FooBar.swift / bar.py / file_x.tsx）
        let extPattern = #"[A-Za-z0-9_\-]+\.(swift|py|js|jsx|ts|tsx|java|kt|cpp|c|h|m|mm|rb|go|rs|sh|json|yaml|yml|toml|md)"#
        if let r = text.range(of: extPattern, options: [.regularExpression, .caseInsensitive]) {
            let s = String(text[r])
            if s.count <= 30 { return s }
        }
        // 4. CamelCase 标识符（≥2 段，FooBar / NSException / handleClick）
        //    要求第一段首字母 + 第二段首字母都是大写，第一段中至少有小写
        let camelPattern = #"[A-Z][a-z]+(?:[A-Z][a-z]+)+"#
        if let r = text.range(of: camelPattern, options: .regularExpression) {
            let s = String(text[r])
            if s.count <= 30 { return s }
        }
        // 5. snake_case （≥2 段，user_name / handle_click_event）
        let snakePattern = #"[a-z]{2,}_[a-z][a-z_]+"#
        if let r = text.range(of: snakePattern, options: .regularExpression) {
            let s = String(text[r])
            if s.count <= 30 { return s }
        }
        return nil
    }

    // MARK: - 模板池（按 kind × mode 二维）

    private static func composeByMode(kind: IntentSignalKind, mode: AgentMode, noun: String?) -> String {
        // 1) 取出该 (kind, mode) 的台词池 key，读双语表后按 `|` split 成多句
        let key = poolKey(kind: kind, mode: mode, hasNoun: noun != nil)
        let pool = L(key).split(separator: "|").map(String.init)
        guard let picked = pool.randomElement() else { return L("pet.intent.fallback") }
        // 2) 带 %@ 占位的池：选中那句后再插值（占位只在有 noun 的 kind 出现）。
        //    无占位的句子 String(format:) 是 no-op，安全。
        if let n = noun {
            return String(format: picked, n)
        }
        return picked
    }

    /// (kind, mode) → 台词池在 L10nPet 里的 key。
    /// 含名词的 kind（copiedError / screenKeyword）在 noun==nil 时返回兜底句 key（无 %@）。
    /// directAPI 与 openclaw 共用一套"软乎体"池（cloud）。
    private static func poolKey(kind: IntentSignalKind, mode: AgentMode, hasNoun: Bool) -> String {
        switch kind {
        case .copiedError:
            guard hasNoun else { return "pet.intent.copiedError.fallback" }   // 实际不会到这，前置门槛已挡
            switch mode {
            case .hermes:                 return "pet.intent.copiedError.hermes"
            case .directAPI, .openclaw, .qwenCode:   return "pet.intent.copiedError.cloud"
            case .claudeCode:             return "pet.intent.copiedError.claude"
            case .codex:                  return "pet.intent.copiedError.codex"
            }
        case .windowTitleDebug:
            switch mode {
            case .hermes:                 return "pet.intent.debug.hermes"
            case .directAPI, .openclaw, .qwenCode:   return "pet.intent.debug.cloud"
            case .claudeCode:             return "pet.intent.debug.claude"
            case .codex:                  return "pet.intent.debug.codex"
            }
        case .windowTitleStackOverflow:
            switch mode {
            case .hermes:                 return "pet.intent.so.hermes"
            case .directAPI, .openclaw, .qwenCode:   return "pet.intent.so.cloud"
            case .claudeCode:             return "pet.intent.so.claude"
            case .codex:                  return "pet.intent.so.codex"
            }
        case .windowTitleDoc:
            switch mode {
            case .hermes:                 return "pet.intent.doc.hermes"
            case .directAPI, .openclaw, .qwenCode:   return "pet.intent.doc.cloud"
            case .claudeCode:             return "pet.intent.doc.claude"
            case .codex:                  return "pet.intent.doc.codex"
            }
        case .screenKeyword:
            guard hasNoun else { return "pet.intent.screen.fallback" }   // 兜底
            switch mode {
            case .hermes:                 return "pet.intent.screen.hermes"
            case .directAPI, .openclaw, .qwenCode:   return "pet.intent.screen.cloud"
            case .claudeCode:             return "pet.intent.screen.claude"
            case .codex:                  return "pet.intent.screen.codex"
            }
        }
    }
}
