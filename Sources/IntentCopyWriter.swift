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
        let pool = templatePool(kind: kind, mode: mode, noun: noun)
        return pool.randomElement() ?? "看到了"
    }

    /// (kind, mode) → 至少 3 句模板的池。
    /// 模板里 {noun} 占位会被替换；如果传入的 noun 为 nil，相关需要 noun 的模板池里直接用兜底句。
    private static func templatePool(kind: IntentSignalKind, mode: AgentMode, noun: String?) -> [String] {
        switch kind {
        // MARK: copiedError
        case .copiedError:
            guard let n = noun else { return ["看到报错了"] }   // 兜底（实际不会到这，前置门槛已挡）
            switch mode {
            case .hermes:
                return ["注意到 \(n)", "你复制了 \(n)", "嗯，\(n)"]
            case .directAPI, .openclaw:
                return ["咦，\(n)？", "\(n) 这个…", "看到 \(n) 了"]
            case .claudeCode:
                return ["横眼看 \(n)", "嗯？\(n)", "\(n) 哦"]
            case .codex:
                return ["→ \(n)", "\(n) ←", "err: \(n)"]
            }

        // MARK: windowTitleDebug
        case .windowTitleDebug:
            switch mode {
            case .hermes:
                return ["你在调试", "调试模式？", "在 debug"]
            case .directAPI, .openclaw:
                return ["调试呢～", "在 debug？", "调试模式"]
            case .claudeCode:
                return ["调 bug 呢", "debug 中", "在抓虫"]
            case .codex:
                return ["→ debug", "断点中", "debug…"]
            }

        // MARK: windowTitleStackOverflow
        case .windowTitleStackOverflow:
            switch mode {
            case .hermes:
                return ["查 SO 呢", "Stack Overflow？", "去 SO 找答案"]
            case .directAPI, .openclaw:
                return ["SO 走起", "查 SO 呢", "翻 SO？"]
            case .claudeCode:
                return ["上 SO 啦", "SO 翻翻", "横着翻 SO"]
            case .codex:
                return ["→ SO", "SO 查询", "stackoverflow"]
            }

        // MARK: windowTitleDoc
        case .windowTitleDoc:
            switch mode {
            case .hermes:
                return ["在翻文档", "查文档呢？", "看文档？"]
            case .directAPI, .openclaw:
                return ["翻文档哎", "看文档？", "查文档呢"]
            case .claudeCode:
                return ["翻翻文档", "横着翻文档", "查文档"]
            case .codex:
                return ["→ docs", "docs?", "→ 文档"]
            }

        // MARK: screenKeyword
        case .screenKeyword:
            guard let n = noun else { return ["屏幕有报错"] }  // 兜底
            switch mode {
            case .hermes:
                return ["屏幕上 \(n)", "看到 \(n)", "注意到 \(n)"]
            case .directAPI, .openclaw:
                return ["\(n) 这个…", "咦，\(n)", "我看到 \(n)"]
            case .claudeCode:
                return ["横看 \(n)", "嗯？\(n)", "\(n) 哦"]
            case .codex:
                return ["→ \(n)", "\(n)?", "屏: \(n)"]
            }
        }
    }
}
