import SwiftUI
import AppKit

// MARK: - Markdown Renderer

/// Renders Markdown content with support for:
/// - Bold, italic, inline code, links (via AttributedString)
/// - Code blocks with syntax label + copy button
/// - Headers, horizontal rules
/// - **编号列表渲染成可点击选项卡片**（AI 给出选项时一键回复）
struct MarkdownTextView: View {
    let content: String
    /// 点击编号列表卡片时的回调（点哪一项就把哪项内容传出去）。
    /// 由 MessageBubbleView 注入，最终由 ChatView 转发给 ViewModel.submitVoiceInput 发送
    var onChoiceSelected: ((String) -> Void)? = nil
    /// 点击任务卡片 📌 Pin → 把任务转成桌面任务 Pin
    var onPinTask: ((PlannedTask) -> Void)? = nil
    /// 点击任务卡片 🤖 让 AI 做 → 新开对话派发给用户选中的 mode 处理
    var onDispatchTask: ((PlannedTask, AgentMode) -> Void)? = nil
    /// 卡片主题色（跟当前 mode 联动：Hermes 绿 / Claude 橙 / Codex 青）
    var tint: Color = .accentColor

    /// 字号缩放因子（由 ChatView 经 Environment 注入）—— 应用到 header / 代码块 / 表格 / ChoiceCard
    /// 文本内容（InlineMarkdownView 的 Text）自动随容器 .font() 缩放，不用这里另传
    @Environment(\.chatFontScale) private var fontScale: Double

    var body: some View {
        let blocks = Self.cachedBlocks(content)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    InlineMarkdownView(text: text)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .divider:
                    Divider()
                        .padding(.vertical, 2)
                case .header(let level, let text):
                    headerView(level: level, text: text)
                case .choices(let items):
                    if let onChoiceSelected = onChoiceSelected {
                        ChoiceCardList(items: items, tint: tint, onSelect: onChoiceSelected)
                    } else {
                        // 没注入 callback（比如别处复用 MarkdownTextView）→ 退化为普通列表
                        plainListView(items: items)
                    }
                case .table(let headers, let alignments, let rows):
                    TableBlockView(headers: headers, alignments: alignments, rows: rows)
                case .taskList(let items):
                    TaskCardListView(
                        items: items,
                        tint: tint,
                        onPin: { task in onPinTask?(task) },
                        onDispatch: { task, mode in onDispatchTask?(task, mode) }
                    )
                case .docList(let paths):
                    DocumentLinkCardList(paths: paths, tint: tint)
                case .noteEdit(let filename, let content):
                    // 流式期间 onChoiceSelected 为 nil → 只预览不落地，避免半截内容被误应用
                    NoteApplyCard(filename: filename, content: content, tint: tint, interactive: onChoiceSelected != nil)
                case .image(let alt, let path):
                    MarkdownImageView(alt: alt, path: path)
                }
            }
        }
    }

    @ViewBuilder
    private func headerView(level: Int, text: String) -> some View {
        // Header 基础字号（用具体 pt 而非语义 .title2 是为了精确跟随 fontScale 缩放）
        let baseSize: CGFloat = switch level {
        case 1: 19
        case 2: 17
        case 3: 15
        default: 14
        }
        let padding: CGFloat = switch level {
        case 1: 4
        case 2: 3
        default: 2
        }
        InlineMarkdownView(text: text)
            .font(.system(size: baseSize * fontScale, weight: .bold))
            .padding(.top, padding)
    }

    @ViewBuilder
    private func plainListView(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(idx + 1).")
                        .foregroundStyle(.secondary)
                    InlineMarkdownView(text: item)
                }
            }
        }
    }

    // MARK: - Block Parsing

    private enum Block {
        case text(String)
        case codeBlock(language: String, code: String)
        case divider
        case header(level: Int, text: String)
        /// 连续的编号列表（≥ 2 项），渲染成可点击选项卡片
        case choices(items: [String])
        /// GFM 表格：header 行 + 数据行 + 每列的对齐
        case table(headers: [String], alignments: [TableColumnAlignment], rows: [[String]])
        /// AI 输出 ```tasks fence 时识别为任务清单，渲染成可操作卡片
        case taskList(items: [PlannedTask])
        /// ```docs fence（每行一个绝对文件路径）→ 渲染成可点击打开的文档卡（昨日回顾用）
        case docList(paths: [String])
        /// ```note:文件名 fence（写作模式）→ 渲染成"应用到笔记"卡片
        case noteEdit(filename: String, content: String)
        /// 独占一行的图片 `![alt](path)` → 渲染本地/远程图片（写作模式插图用）
        case image(alt: String, path: String)
    }

    /// 表格列对齐 —— 由 separator 行的 :--- / ---: / :---: 决定
    enum TableColumnAlignment {
        case leading, center, trailing
    }

    /// 解析结果缓存盒（NSCache 需要 class 值类型）。
    private final class BlocksBox {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    /// 块解析缓存：以**完整内容字符串**为 key。
    /// 之前 `body` 每次重渲染都 `parseBlocks(content)` 整段重拆 —— 流式逐字时每帧重解析（O(n²)），
    /// 非流式时 hover / 字号变 / 窗口缩放 / LazyVStack 滚动复用 cell 也都白拆一遍。
    /// 加缓存后：内容没变直接命中，SwiftUI 也因块身份稳定不再重建下游 AttributedString。
    /// `countLimit` 限 96 条 → 流式产生的大量中间态字符串会被自动淘汰，不会无限涨内存。
    private static let blockCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 96
        return cache
    }()

    /// 带缓存的块解析入口。命中即返回；未命中才真正 `parseBlocks` 并写回缓存。
    private static func cachedBlocks(_ text: String) -> [Block] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) {
            return hit.blocks
        }
        let parsed = parseBlocks(text)
        blockCache.setObject(BlocksBox(parsed), forKey: key)
        return parsed
    }

    private static func parseBlocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code block (```)
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let isNoteBlock = language.lowercased() == "note" || language.lowercased().hasPrefix("note:")
                var codeLines: [String] = []
                i += 1
                if isNoteBlock {
                    // ⚠️ note 内容常含嵌套代码块（如 ```cpp … ```）。普通收集器遇到内层 ``` 就误判
                    // note 结束 → 后半截被截断、写文件丢内容（用户实测 bug）。这里跟踪内层 fence：
                    // 带语言的 ```cpp = 内层开启；裸 ``` 在内层时 = 内层关闭，不在内层时 = note 真正结束。
                    var insideInner = false
                    while i < lines.count {
                        let l = lines[i]
                        if l.hasPrefix("```") {
                            let innerLang = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                            if insideInner {
                                insideInner = false; codeLines.append(l); i += 1; continue
                            } else if !innerLang.isEmpty {
                                insideInner = true; codeLines.append(l); i += 1; continue
                            } else {
                                i += 1; break   // 裸 ``` 且不在内层 → note 块结束
                            }
                        }
                        codeLines.append(l); i += 1
                    }
                } else {
                    while i < lines.count {
                        if lines[i].hasPrefix("```") {
                            i += 1
                            break
                        }
                        codeLines.append(lines[i])
                        i += 1
                    }
                }
                // 特殊语言 "tasks" → 解析为可操作的任务卡片清单
                if language.lowercased() == "tasks" {
                    let tasks = PlannedTask.parseTaskBlock(codeLines.joined(separator: "\n"))
                    if !tasks.isEmpty {
                        blocks.append(.taskList(items: tasks))
                        continue
                    }
                    // 解析不出来就退化成普通 code block 显示 raw 内容
                }
                // 特殊语言 "docs" → 每行一个绝对路径，渲染成可点击打开的文档卡（昨日回顾用）
                if language.lowercased() == "docs" {
                    let paths = codeLines
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.hasPrefix("/") }
                    if !paths.isEmpty {
                        blocks.append(.docList(paths: paths))
                        continue
                    }
                }
                // 特殊语言 "note" / "note:文件名"（写作模式）→ 渲染成"应用到笔记"卡片
                let langLower = language.lowercased()
                if langLower == "note" || langLower.hasPrefix("note:") {
                    let filename: String
                    if let colon = language.firstIndex(of: ":") {
                        filename = String(language[language.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        filename = ""
                    }
                    blocks.append(.noteEdit(filename: filename, content: codeLines.joined(separator: "\n")))
                    continue
                }
                blocks.append(.codeBlock(
                    language: language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Horizontal rule
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            // 独占一行的图片 ![alt](path) → 图片块
            if let img = Self.parseImageLine(line) {
                blocks.append(.image(alt: img.alt, path: img.path))
                i += 1
                continue
            }

            // GFM 表格：当前行像 |a|b| + 下一行是 |---|---| 分隔行 → 进入表格解析。
            // 要求至少 header + separator 都到位再识别（流式期间表格还没下完整时仍按文本走，
            // 不会出现"半截表格被错误识别 + 渲染抖动"的问题）
            if i + 1 < lines.count,
               Self.isLikelyTableRow(line),
               let aligns = Self.parseTableSeparator(lines[i + 1]),
               aligns.count >= 1 {
                let headerCells = Self.parseTableRow(line)
                // header 列数跟 separator 列数对齐（取较少的，多的截掉）
                let colCount = min(headerCells.count, aligns.count)
                let headers = Array(headerCells.prefix(colCount))
                let alignments = Array(aligns.prefix(colCount))
                var rows: [[String]] = []
                var j = i + 2   // 跳过 header + separator
                while j < lines.count, Self.isLikelyTableRow(lines[j]) {
                    var cells = Self.parseTableRow(lines[j])
                    // 补齐 / 截断到 colCount，避免 Grid 列数不齐
                    if cells.count < colCount {
                        cells.append(contentsOf: Array(repeating: "", count: colCount - cells.count))
                    } else if cells.count > colCount {
                        cells = Array(cells.prefix(colCount))
                    }
                    rows.append(cells)
                    j += 1
                }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                i = j
                continue
            }

            // Header
            let hashCount = line.prefix(while: { $0 == "#" }).count
            if hashCount > 0 && hashCount <= 6 && line.count > hashCount && line[line.index(line.startIndex, offsetBy: hashCount)] == " " {
                let headerText = String(line.dropFirst(hashCount + 1))
                blocks.append(.header(level: hashCount, text: headerText))
                i += 1
                continue
            }

            // 编号列表（"1. xxx" 风格）—— 连续 ≥ 2 项才识别为 choices block
            if let _ = Self.numberedItemContent(of: line) {
                var items: [String] = []
                var consumed = 0
                while i + consumed < lines.count,
                      let item = Self.numberedItemContent(of: lines[i + consumed]) {
                    items.append(item)
                    consumed += 1
                }
                if items.count >= 2 {
                    blocks.append(.choices(items: items))
                    i += consumed
                    continue
                }
                // 只有 1 项 → 当普通文本走
            }

            blocks.append(.text(line))
            i += 1
        }

        return blocks
    }

    /// 一行**看起来像**表格数据行 —— 至少 2 个 `|` 且 trim 后非空。
    /// 不严格校验内容，让 parseTableRow 处理细节
    static func isLikelyTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // 计 `|` 数量（不计转义的 \|）
        var count = 0
        var prev: Character = " "
        for ch in trimmed {
            if ch == "|", prev != "\\" { count += 1 }
            prev = ch
        }
        return count >= 2
    }

    /// 解析表格分隔行（separator）：`|---|:---:|---:|` 返回每列对齐数组；不是合法 separator 返回 nil。
    /// 至少一列且全部由 `:`/`-`/空白组成 + 至少 3 个 `-` 才算
    static func parseTableSeparator(_ line: String) -> [TableColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [TableColumnAlignment] = []
        for raw in cells {
            let cell = raw.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { return nil }
            // 必须由 `:` 和 `-` 组成，且包含至少 3 个 `-`（避免把"a | b | c"/"---"误判）
            let dashes = cell.filter { $0 == "-" }.count
            guard dashes >= 3,
                  cell.allSatisfy({ $0 == ":" || $0 == "-" }) else { return nil }
            let startsColon = cell.hasPrefix(":")
            let endsColon = cell.hasSuffix(":")
            switch (startsColon, endsColon) {
            case (true, true):   aligns.append(.center)
            case (false, true):  aligns.append(.trailing)
            default:             aligns.append(.leading)
            }
        }
        return aligns
    }

    /// 切表格一行的单元格 —— 按未转义的 `|` 切，去掉首尾空 cell（GFM 风格 `|a|b|` 切出来是 ["", "a", "b", ""]）。
    /// 处理 `\|` 转义（还原成 `|`）。trim 每个单元格首尾空白
    static func parseTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var prev: Character = " "
        for ch in line {
            if ch == "|", prev != "\\" {
                cells.append(current)
                current = ""
            } else if ch == "|", prev == "\\" {
                // 转义的 |  → 把上一个 \ 替换掉
                current.removeLast()
                current.append("|")
            } else {
                current.append(ch)
            }
            prev = ch
        }
        cells.append(current)
        // 去掉首尾空 cell（标准 GFM `|a|b|` 头尾各有一个空字串）
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 解析独占一行的图片 `![alt](path)`（可带 `"title"`）。不是图片行返回 nil。
    static func parseImageLine(_ line: String) -> (alt: String, path: String)? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("!["), s.hasSuffix(")"),
              let altEnd = s.firstIndex(of: "]") else { return nil }
        let afterAlt = s.index(after: altEnd)
        guard afterAlt < s.endIndex, s[afterAlt] == "(" else { return nil }
        let alt = String(s[s.index(s.startIndex, offsetBy: 2)..<altEnd])
        let pathStart = s.index(after: afterAlt)
        let pathEnd = s.index(before: s.endIndex)   // 末尾的 )
        guard pathStart < pathEnd else { return nil }
        var path = String(s[pathStart..<pathEnd]).trimmingCharacters(in: .whitespaces)
        // 去掉可选 title：![](path "标题")
        if let sp = path.firstIndex(of: " ") { path = String(path[..<sp]) }
        // 去掉路径外层尖括号 ![](<path>)
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        guard !path.isEmpty else { return nil }
        return (alt, path)
    }

    /// 解析编号列表项："1. xxx" / "12. xxx" / "  3. xxx"。返回去掉前缀后的内容；不是编号项返回 nil。
    static func numberedItemContent(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let firstChar = trimmed.first, firstChar.isNumber,
              let dotIdx = trimmed.firstIndex(of: ".")
        else { return nil }
        let numPart = trimmed[..<dotIdx]
        guard numPart.allSatisfy({ $0.isNumber }),
              numPart.count <= 3 else { return nil }
        // "." 后必须紧跟空格
        let afterDot = trimmed.index(after: dotIdx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return String(trimmed[trimmed.index(after: afterDot)...])
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 图片块（写作模式插图 / 一般本地图片）

/// 渲染 `![alt](path)`：本地相对路径按笔记库根解析、绝对/`file://` 直用、`http(s)` 走 AsyncImage。
/// 加载结果缓存(NSCache)，避免每次重渲染都重读盘。失败时给占位条。
struct MarkdownImageView: View {
    let alt: String
    let path: String

    var body: some View {
        // 库根在 body(@MainActor)里读，传给 nonisolated 的解析器
        let resolved = Self.resolve(path, vaultPath: NotesStore.shared.vaultURL.path)
        Group {
            if path.hasPrefix("http"), let u = URL(string: path) {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    placeholder
                }
                .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
            } else if let url = resolved, let ns = Self.cachedImage(url) {
                Image(nsImage: ns)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                placeholder
            }
        }
        .padding(.vertical, 2)
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            Text(alt.isEmpty ? path : alt)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
    }

    /// 把 markdown 里的路径解析成本地 URL（http 的不在这里处理）。
    nonisolated static func resolve(_ path: String, vaultPath: String) -> URL? {
        if path.hasPrefix("http") { return nil }
        if path.hasPrefix("file://") { return URL(string: path) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        return URL(fileURLWithPath: vaultPath).appendingPathComponent(clean)
    }

    // NSCache 本身线程安全 → nonisolated(unsafe) 让 nonisolated 的 cachedImage 能安全引用（决策 #5）
    nonisolated(unsafe) private static let imgCache = NSCache<NSString, NSImage>()
    nonisolated static func cachedImage(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = imgCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        imgCache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - 选项卡片列表

/// AI 给出编号选项时，渲染成一组可点击卡片。
/// 点击 = 把那项内容填入输入框（**不直接发送**，由用户确认后按回车）。
/// 这是有意为之 —— 防止 AI 用编号列表做纯叙述时（"先做 A / 再做 B"）被当成选项误触
/// （issue 反馈："点击后发出去一条无意义的序号消息打断对话节奏"）。
struct ChoiceCardList: View {
    let items: [String]
    let tint: Color
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                ChoiceCard(index: idx + 1, text: item, tint: tint) {
                    onSelect(item)
                }
            }
        }
        .padding(.top, 4)
    }
}

struct ChoiceCard: View {
    let index: Int
    let text: String
    let tint: Color
    let onTap: () -> Void

    @State private var isHovering = false
    @Environment(\.chatFontScale) private var fontScale: Double

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                // 编号徽章
                Text("\(index)")
                    .font(.system(size: 11 * fontScale, weight: .bold))
                    .foregroundStyle(isHovering ? Color.white : tint)
                    .frame(width: 20 * fontScale, height: 20 * fontScale)
                    .background(
                        Circle()
                            .fill(isHovering ? tint : tint.opacity(0.15))
                    )

                // 选项文本
                InlineMarkdownView(text: text)
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // hover 时显示"填入输入框"提示（点击不直接发送，仅填入让用户确认）
                if isHovering {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 10 * fontScale))
                        .foregroundStyle(tint)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? tint.opacity(0.55) : .primary.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(L("markdown.choice.fillHelp", text))
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}

// MARK: - 表格

/// GFM 表格渲染 —— 用 SwiftUI Grid 自动对齐列宽。
///
/// 设计要点：
/// - 表头有底色 + 加粗 + 下方一条 hairline 分隔
/// - 单元格内复用 InlineMarkdownView（bold/italic/code/链接全部生效）
/// - 长内容自动换行（不做横向滚动 —— 聊天气泡本来就窄，强迫 wrapping 比横滚体验好）
/// - 外框 RoundedRectangle 8pt 圆角 + 0.5pt 描边，跟 CodeBlockView 视觉一致
/// - 每列按 GFM 对齐符（:-- / -- / -:）决定 horizontal alignment
struct TableBlockView: View {
    let headers: [String]
    let alignments: [MarkdownTextView.TableColumnAlignment]
    let rows: [[String]]

    @Environment(\.chatFontScale) private var fontScale: Double

    private var columnCount: Int { headers.count }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            // —— 表头 ——
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    cell(text: h, align: alignmentFor(idx), isHeader: true)
                }
            }
            .background(Color.primary.opacity(0.08))

            // hairline 分隔（GridRow 之间用一行 Divider 高度 0.5）
            GridRow {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 0.5)
                    .gridCellColumns(max(columnCount, 1))
            }

            // —— 数据行 ——
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cellText in
                        cell(text: cellText, align: alignmentFor(colIdx), isHeader: false)
                    }
                }
                // 隔行底色 —— 增强视觉分组，长表格更易扫读
                .background(rowIdx % 2 == 1 ? Color.primary.opacity(0.025) : Color.clear)
                // 行间细线 —— 除最后一行外都加
                if rowIdx < rows.count - 1 {
                    GridRow {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                            .gridCellColumns(max(columnCount, 1))
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 2)
    }

    /// 单元格：根据是否表头切字号/字重；按 align 决定 frame 内 text 的水平对齐
    @ViewBuilder
    private func cell(text: String, align: MarkdownTextView.TableColumnAlignment, isHeader: Bool) -> some View {
        let frameAlign: Alignment = switch align {
        case .leading:  .leading
        case .center:   .center
        case .trailing: .trailing
        }
        let textAlign: TextAlignment = switch align {
        case .leading:  .leading
        case .center:   .center
        case .trailing: .trailing
        }
        // 空字符串走 Text("") 占位，避免 InlineMarkdownView 返回 EmptyView 让 Grid 那列塌缩
        Group {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(" ")
            } else {
                InlineMarkdownView(text: text)
                    .multilineTextAlignment(textAlign)
            }
        }
        .font(.system(size: 12 * fontScale, weight: isHeader ? .semibold : .regular))
        .frame(maxWidth: .infinity, alignment: frameAlign)
        .padding(.horizontal, 10)
        .padding(.vertical, isHeader ? 7 : 6)
    }

    private func alignmentFor(_ idx: Int) -> MarkdownTextView.TableColumnAlignment {
        idx < alignments.count ? alignments[idx] : .leading
    }
}

// MARK: - Inline Markdown

struct InlineMarkdownView: View {
    let text: String

    /// 富文本缓存盒（NSCache 需要 class 值；`nil` 也缓存，避免对解析失败的文本反复重试）。
    private final class AttributedBox {
        let value: AttributedString?
        init(_ value: AttributedString?) { self.value = value }
    }

    /// inline markdown → AttributedString 的缓存。以文本为 key。
    /// `.inlineOnly` 只解析 **粗体/斜体/行内代码/链接**、不烘焙字号，所以缓存对字号缩放安全
    /// （字号由外层 Text.font() 施加，不进 AttributedString）。完成消息重渲染时直接命中、不再重建。
    private static let attributedCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = 256
        return cache
    }()

    private static func attributed(for text: String) -> AttributedString? {
        let key = text as NSString
        if let hit = attributedCache.object(forKey: key) { return hit.value }
        let built = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnly)
        )
        attributedCache.setObject(AttributedBox(built), forKey: key)
        return built
    }

    var body: some View {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if let attributed = Self.attributed(for: text) {
            Text(attributed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    @Environment(\.chatFontScale) private var fontScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? L("markdown.code.untitled") : language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                Spacer()
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(copied ? L("markdown.code.copied") : L("markdown.code.copy"))
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .background(.primary.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: true) {
                // .caption ≈ 12pt（macOS）—— 用具体 pt 让代码块也随 fontScale 缩放
                Text(code)
                    .font(.system(size: 12 * fontScale, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyCode() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - 任务规划

/// AI 输出 ```tasks fence 后解析出来的一条任务。
/// 注意是**临时**数据 —— 跟随聊天消息存在，用户点 Pin 时才转 PinCard 持久化
struct PlannedTask: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let desc: String
    let suggestedMode: AgentMode   // AI 推荐用哪个引擎执行
    let eta: String?               // 可选预估时长，如 "30m" / "1h"

    /// 解析 ```tasks fence 内文本（YAML-like 列表）。
    /// 格式：
    /// ```tasks
    /// - title: xxx
    ///   desc: yyy
    ///   mode: hermes
    ///   eta: 30m
    /// - title: ...
    /// ```
    /// 容忍格式不严格（AI 可能漏 eta / 写错 mode）
    static func parseTaskBlock(_ raw: String) -> [PlannedTask] {
        var tasks: [PlannedTask] = []
        var curTitle: String?
        var curDesc: String?
        var curMode: AgentMode?
        var curEta: String?

        func flush() {
            if let title = curTitle, !title.isEmpty {
                tasks.append(PlannedTask(
                    title: title,
                    desc: curDesc ?? "",
                    suggestedMode: curMode ?? .hermes,
                    eta: curEta
                ))
            }
            curTitle = nil
            curDesc = nil
            curMode = nil
            curEta = nil
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 新任务起始 "- title: xxx" 或 "- xxx"（兼容简略写法）
            if trimmed.hasPrefix("- ") {
                flush()
                let after = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let v = extractValue(after, key: "title") {
                    curTitle = v
                } else if !after.contains(":") {
                    // 简略写法 "- 任务标题"
                    curTitle = after
                }
                continue
            }

            // 后续字段 "title: xxx" / "desc: xxx" / "mode: xxx" / "eta: xxx"
            if let v = extractValue(trimmed, key: "title") { curTitle = v }
            else if let v = extractValue(trimmed, key: "desc") ?? extractValue(trimmed, key: "description") {
                curDesc = v
            } else if let v = extractValue(trimmed, key: "mode") ?? extractValue(trimmed, key: "engine") {
                let raw = v.lowercased()
                if raw.contains("claude") { curMode = .claudeCode }
                else if raw.contains("codex") { curMode = .codex }
                else { curMode = .hermes }
            } else if let v = extractValue(trimmed, key: "eta") ?? extractValue(trimmed, key: "time") {
                curEta = v
            }
        }
        flush()
        return tasks
    }

    /// 从 "key: value" 形式提取 value；不匹配返回 nil
    private static func extractValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        let after = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        // 去掉可能的引号
        if (after.hasPrefix("\"") && after.hasSuffix("\""))
            || (after.hasPrefix("'") && after.hasSuffix("'")) {
            return String(after.dropFirst().dropLast())
        }
        return after
    }
}

/// AI 输出的任务清单 —— 渲染成一组可操作卡片
struct TaskCardListView: View {
    let items: [PlannedTask]
    let tint: Color
    let onPin: (PlannedTask) -> Void
    let onDispatch: (PlannedTask, AgentMode) -> Void

    /// 用户操作过的任务 id —— 点 ✗ 跳过 / 点 📌 Pin / 点 🤖 让 AI 做 后该任务标记为"已处理"，淡出
    @State private var dismissedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：小标题说明这是任务清单
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(L("markdown.tasks.header", items.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            ForEach(items) { task in
                if !dismissedIDs.contains(task.id) {
                    TaskCard(
                        task: task,
                        tint: tint,
                        onPin: {
                            onPin(task)
                            dismissedIDs.insert(task.id)
                        },
                        onDispatch: { mode in
                            onDispatch(task, mode)
                            dismissedIDs.insert(task.id)
                        },
                        onSkip: {
                            dismissedIDs.insert(task.id)
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
                }
            }
            // 全部处理完时显示一个完成态
            if dismissedIDs.count == items.count, !items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L("markdown.tasks.allArranged"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: dismissedIDs)
    }
}

/// 单张任务卡 —— 标题 + 描述 + 建议 mode + ETA + 3 个操作按钮
struct TaskCard: View {
    let task: PlannedTask
    let tint: Color
    let onPin: () -> Void
    /// 选哪个 AI 来做这条任务 —— 由卡片上的下拉菜单传出用户选中的 mode
    let onDispatch: (AgentMode) -> Void
    let onSkip: () -> Void

    @State private var isHovering = false

    private var modeColor: Color {
        switch task.suggestedMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        case .qwenCode:   return .teal
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // —— 标题行 ——
            HStack(spacing: 6) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                // 建议 mode 徽章
                HStack(spacing: 3) {
                    Image(systemName: task.suggestedMode.iconName)
                        .font(.system(size: 9, weight: .semibold))
                    Text(L(task.suggestedMode.labelKey))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(modeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(modeColor.opacity(0.15))
                )

                if let eta = task.eta, !eta.isEmpty {
                    Text(eta)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            // —— 描述 ——
            if !task.desc.isEmpty {
                Text(task.desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // —— 三个操作按钮 ——
            HStack(spacing: 6) {
                taskActionButton(icon: "pin.fill", label: "Pin", color: tint, action: onPin)
                dispatchMenu
                Spacer()
                taskActionButton(icon: "xmark", label: L("markdown.task.skip"), color: .secondary, action: onSkip, prominent: false)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isHovering ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }

    /// 🤖「让 AI 做」下拉菜单 —— 列出全部 5 个 AI，选哪个就用哪个新开对话去做。
    /// 卡片右上角徽章已标了 AI 建议的引擎，菜单里给它打个 ✓，但允许换成任意一个。
    private var dispatchMenu: some View {
        Menu {
            Section(L("markdown.task.dispatch.menuTitle")) {
                ForEach(AgentMode.allCases) { mode in
                    Button {
                        onDispatch(mode)
                    } label: {
                        Label(
                            mode == task.suggestedMode ? "\(L(mode.labelKey))  ✓" : L(mode.labelKey),
                            systemImage: mode.iconName
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                Text(L("markdown.task.dispatch"))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(modeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(modeColor.opacity(0.15)))
            .overlay(Capsule().stroke(modeColor.opacity(0.35), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func taskActionButton(icon: String, label: String, color: Color,
                                  action: @escaping () -> Void,
                                  prominent: Bool = true) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(prominent ? color : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(prominent ? color.opacity(0.15) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(prominent ? color.opacity(0.35) : .primary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 应用到笔记卡片（写作模式 ```note fence 渲染）

/// AI 在写作模式产出的 ```note:文件名 块 → 一张"应用到笔记"卡片。
/// interactive=true(非流式)时显示「应用 / 另存为」按钮，点了直接写进 NotesStore；
/// 流式期间 interactive=false，只预览不落地。
struct NoteApplyCard: View {
    let filename: String
    let content: String
    let tint: Color
    var interactive: Bool = true

    @State private var applied = false

    private var displayName: String {
        filename.isEmpty ? L("markdown.note.untitled") : filename
    }
    private var preview: String {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 360 ? String(t.prefix(360)) + "…" : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.pencil")
                Text(displayName).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)

            Text(preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if applied {
                Label(L("markdown.note.applied"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if interactive {
                HStack(spacing: 6) {
                    Button(L("markdown.note.apply")) {
                        NotesStore.shared.applyNote(filename: filename, content: content, saveAsNew: false)
                        applied = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L("markdown.note.saveAs")) {
                        NotesStore.shared.applyNote(filename: filename, content: content, saveAsNew: true)
                        applied = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - 可点击文档卡（昨日回顾的 ```docs fence 渲染）

/// 昨日回顾里"碰过的文档"清单 —— 一组可点击打开的文档卡。
/// 数据来自 MorningBriefingService 收集到的真实文件路径（kAXDocumentAttribute），
/// 点击 / ⌘+点击 → 用默认 App 直接打开，把用户送回工作现场。
struct DocumentLinkCardList: View {
    let paths: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                Text(L("markdown.docs.header"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                DocumentLinkCard(path: path, tint: tint)
            }
        }
    }
}

/// 单张可点击文档卡。文件不存在时置灰不可点（移动/删除过的文档）。
struct DocumentLinkCard: View {
    let path: String
    let tint: Color

    @State private var isHovering = false

    private var url: URL { URL(fileURLWithPath: path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    private var iconName: String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "doc.plaintext"
        case "txt", "log", "rtf": return "doc.text"
        case "json", "yml", "yaml", "toml", "ini", "conf": return "curlybraces"
        case "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java",
             "c", "cpp", "h", "rb", "php", "kt", "scala", "lua", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "csv": return "tablecells"
        case "html", "xml": return "globe"
        case "doc", "docx", "pages": return "doc.text"
        case "xls", "xlsx", "numbers": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: exists ? iconName : "doc.badge.ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(exists ? tint : .secondary)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(exists ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            if exists, isHovering {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isHovering && exists ? tint.opacity(0.12) : .primary.opacity(0.06))
        )
        .overlay(
            Capsule().stroke(isHovering && exists ? tint.opacity(0.4) : .primary.opacity(0.14), lineWidth: 0.5)
        )
        .opacity(exists ? 1 : 0.55)
        .contentShape(Capsule())
        .help(exists ? L("markdown.docs.openHelp", path) : L("markdown.docs.missingHelp", path))
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
            if exists {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .onTapGesture {
            guard exists else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
