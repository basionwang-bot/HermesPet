import AppKit

/// markdown 源码的**实时样式器**（Live Preview 第一步）。
///
/// 挂成 `NSTextStorageDelegate`：每次编辑只重排受影响的**整段**，给 markdown 上样式 ——
/// 标题变大加粗、`**粗**` / `*斜*` / `` `码` `` / `~~删~~` / `[链](url)` 各自变样，**标记符淡化成浅灰**。
///
/// ⭐ 只改**属性**、绝不改文字 → 底下 `tv.string` 还是纯 markdown，保存/同步零坑（不像替换文字那种 WYSIWYG）。
/// 用 TextKit 1（NotesSourceEditor 手搭了 layoutManager），textStorage 委托回调可靠。
final class NotesMarkdownStyler: NSObject, NSTextStorageDelegate {
    var baseSize: CGFloat = 15

    /// 光标所在段落范围 —— **该段内的标记符淡显(可编辑)，其余段的标记符隐藏**(完全 WYSIWYG)。
    /// NSNotFound = 不启用隐藏(所有标记符只淡显，Step1 行为)。由编辑器在选区变化时更新 + 重排相关段。
    var caretParagraph = NSRange(location: NSNotFound, length: 0)

    /// 是否暂停实时样式 —— 输入法组字(marked text)期间返回 true：那段时间每敲一键都重排会跟"组字中文本"
    /// 打架，把已渲染内容打回原形(闪)。组字时先不排，选词提交后再一次性排。
    var shouldSuspend: (() -> Bool)?

    // 编译一次的内联正则
    private static let reBold   = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let reItalic = try! NSRegularExpression(pattern: "(?<![\\*_`])[\\*_](?![\\*_\\s])([^\\*_\\n]+?)[\\*_](?![\\*_])")
    private static let reCode   = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let reStrike = try! NSRegularExpression(pattern: "~~(.+?)~~")
    private static let reLink   = try! NSRegularExpression(pattern: "!?\\[([^\\]]*)\\]\\(([^)\\n]+)\\)")

    // MARK: NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        // 只有改了字符才重排（改属性会再触发本回调，但 mask=.editedAttributes，被这里挡掉 → 不递归）
        guard editedMask.contains(.editedCharacters) else { return }
        // 输入法组字中 → 暂停（选词提交后那次编辑会再进来、那时不再 suspend → 一次性排）
        if shouldSuspend?() == true { return }
        let ns = textStorage.string as NSString
        guard ns.length > 0 else { return }
        let safe = NSRange(location: min(editedRange.location, ns.length),
                           length: min(editedRange.length, ns.length - min(editedRange.location, ns.length)))
        style(textStorage, range: ns.paragraphRange(for: safe))
    }

    /// 全量重排（切笔记 / 初次加载 / 字号变）
    func styleAll(_ textStorage: NSTextStorage) {
        guard textStorage.length > 0 else { return }
        style(textStorage, range: NSRange(location: 0, length: textStorage.length))
    }

    /// 重排指定段落（光标移动时，对"离开的旧段 + 进入的新段"各排一次 → 标记符显隐跟着光标走）
    func restyle(_ textStorage: NSTextStorage, paragraphAt range: NSRange) {
        guard textStorage.length > 0 else { return }
        let ns = textStorage.string as NSString
        let loc = max(0, min(range.location, ns.length))
        let safe = NSRange(location: loc, length: min(range.length, ns.length - loc))
        style(textStorage, range: ns.paragraphRange(for: safe))
    }

    // MARK: 上样式

    private func baseFont() -> NSFont { NSFont.systemFont(ofSize: baseSize) }
    private let dimColor = NSColor.tertiaryLabelColor

    private func style(_ storage: NSTextStorage, range: NSRange) {
        let ns = storage.string as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return }

        // 1) 整段先重置成基础样式（这样删掉标记符能恢复普通文字）。
        // ⚠️ 不能用 setAttributes（会连 .attachment 一起抹掉 → 图片附件丢失）—— 只 add 我们会设的几样、
        //    再 remove 会变动的几样，**保留图片附件**。
        storage.addAttribute(.font, value: baseFont(), range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.removeAttribute(.paragraphStyle, range: range)

        // 2) 行级：标题 / 引用
        ns.enumerateSubstrings(in: range, options: .byLines) { sub, lineRange, _, _ in
            guard let line = sub else { return }
            self.styleLine(line, lineRange: lineRange, storage: storage)
        }

        // 3) 内联：链接 / 粗 / 斜 / 删除线 / 行内代码（顺序：先链接，代码最后压住）
        styleLink(storage, range: range)
        styleInline(Self.reBold, trait: .bold, markerLen: 2, storage: storage, range: range)
        styleInline(Self.reItalic, trait: .italic, markerLen: 1, storage: storage, range: range)
        styleInline(Self.reStrike, strike: true, markerLen: 2, storage: storage, range: range)
        styleCode(storage, range: range)
    }

    private func styleLine(_ line: String, lineRange: NSRange, storage: NSTextStorage) {
        // 标题 # ~ ######
        let hashes = line.prefix(while: { $0 == "#" }).count
        if hashes >= 1, hashes <= 6, line.count > hashes,
           line[line.index(line.startIndex, offsetBy: hashes)] == " " {
            let bumps: [CGFloat] = [10, 7, 4, 2, 1, 1]
            let size = baseSize + bumps[hashes - 1]
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: lineRange)
            let markerLen = min(hashes + 1, lineRange.length)
            markMarker(storage, NSRange(location: lineRange.location, length: markerLen))
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 引用 > —— 缩进 + 次要色 + 隐藏 "> " 标记
        if trimmed.hasPrefix(">") {
            storage.addAttribute(.paragraphStyle, value: indentStyle(head: 18, firstLine: 18), range: lineRange)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
            if let gt = line.firstIndex(of: ">") {
                let off = line.distance(from: line.startIndex, to: gt)
                var mlen = 1
                let after = line.index(after: gt)
                if after < line.endIndex, line[after] == " " { mlen = 2 }
                markMarker(storage, NSRange(location: lineRange.location + off, length: mlen))
            }
            return
        }

        // 无序列表 - / * / + —— 悬挂缩进（折行对齐），保留符号当项目符
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            storage.addAttribute(.paragraphStyle, value: indentStyle(head: 20, firstLine: 2), range: lineRange)
            return
        }
        // 有序列表 N. —— 同样悬挂缩进
        if trimmed.range(of: #"^\d{1,3}\.\s"#, options: .regularExpression) != nil {
            storage.addAttribute(.paragraphStyle, value: indentStyle(head: 24, firstLine: 2), range: lineRange)
        }
    }

    /// 悬挂缩进段落样式（firstLine = 首行缩进，head = 折行后缩进）
    private func indentStyle(head: CGFloat, firstLine: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.headIndent = head
        p.firstLineHeadIndent = firstLine
        p.lineSpacing = 1
        return p
    }

    /// 通用内联：给匹配整体加字体 trait（或删除线），并淡化首尾标记符。
    private func styleInline(_ re: NSRegularExpression,
                             trait: NSFontDescriptor.SymbolicTraits? = nil,
                             strike: Bool = false,
                             markerLen: Int,
                             storage: NSTextStorage, range: NSRange) {
        let str = storage.string
        re.enumerateMatches(in: str, options: [], range: range) { m, _, _ in
            guard let r = m?.range, r.length > markerLen * 2 else { return }
            if let trait { self.addTrait(trait, storage: storage, range: r) }
            if strike {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            }
            self.markMarker(storage, NSRange(location: r.location, length: markerLen))
            self.markMarker(storage, NSRange(location: NSMaxRange(r) - markerLen, length: markerLen))
        }
    }

    private func styleCode(_ storage: NSTextStorage, range: NSRange) {
        let str = storage.string
        Self.reCode.enumerateMatches(in: str, options: [], range: range) { m, _, _ in
            guard let r = m?.range, r.length > 2 else { return }
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: self.baseSize * 0.95, weight: .regular), range: r)
            storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: r)
            // 行内代码底色 chip（只给反引号之间的内容上底，反引号本身隐藏不留色块）
            if r.length > 2 {
                let inner = NSRange(location: r.location + 1, length: r.length - 2)
                storage.addAttribute(.backgroundColor, value: NSColor.secondaryLabelColor.withAlphaComponent(0.13), range: inner)
            }
            self.markMarker(storage, NSRange(location: r.location, length: 1))
            self.markMarker(storage, NSRange(location: NSMaxRange(r) - 1, length: 1))
        }
    }

    private func styleLink(_ storage: NSTextStorage, range: NSRange) {
        let str = storage.string
        Self.reLink.enumerateMatches(in: str, options: [], range: range) { m, _, _ in
            guard let m, m.range.length > 4 else { return }
            let textRange = m.numberOfRanges >= 2 ? m.range(at: 1) : NSRange(location: NSNotFound, length: 0)
            guard textRange.location != NSNotFound else { return }
            // [文字] → 着重色 + 下划线（像可点链接）
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: textRange)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
            // 整体隐藏方括号/圆括号/url：前缀 "[" (含可能的 "!") + 后缀 "](url)" —— 非光标行藏、光标行淡显
            let lead = NSRange(location: m.range.location, length: max(0, textRange.location - m.range.location))
            let trail = NSRange(location: NSMaxRange(textRange), length: max(0, NSMaxRange(m.range) - NSMaxRange(textRange)))
            self.markMarker(storage, lead)
            self.markMarker(storage, trail)
        }
    }

    // MARK: 工具

    /// 给一段已有文字叠加字体 trait（保留各自字号，如标题里的加粗）
    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let f = (value as? NSFont) ?? self.baseFont()
            var traits = f.fontDescriptor.symbolicTraits
            traits.insert(trait)
            let desc = f.fontDescriptor.withSymbolicTraits(traits)
            if let nf = NSFont(descriptor: desc, size: f.pointSize) {
                storage.addAttribute(.font, value: nf, range: sub)
            }
        }
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: dimColor, range: range)
    }

    /// 标记符处理：**光标所在段** → 淡显(可见可编辑)；**其余段** → 隐藏(字号塌成 ~0 + 透明 → 视觉消失)。
    /// caretParagraph 为 NSNotFound 时退化为"只淡显"(不隐藏)。
    private func markMarker(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let onCaretLine = caretParagraph.location != NSNotFound
            && NSIntersectionRange(range, caretParagraph).length > 0
        if caretParagraph.location == NSNotFound || onCaretLine {
            storage.addAttribute(.foregroundColor, value: dimColor, range: range)   // 光标行：淡显
        } else {
            // 非光标行：隐藏 —— 字号塌成 0.02 + 透明色，标记符视觉上消失（文字本身保留，存盘不变）
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.02), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
    }
}
