import AppKit

/// 笔记编辑器的"手柄" —— 让桌宠陪写能：读选中 / 锁定编辑器(陪写期间不让光标乱跑) /
/// 把定稿结果写进笔记并短暂高亮(让人一眼看到 AI 动了哪一段)。
///
/// v2(强化版)：陪写过程搬到右栏跟桌宠对话，编辑器**不再**承载行内彩色待定文字。
/// 这里只负责"读"和"最终写入 + 高亮"，干净利落。
@MainActor
final class NotesEditorController {
    weak var textView: NSTextView?
    var fontSize: CGFloat = 14
    var petColor: NSColor = .controlAccentColor

    private var highlightFade: Task<Void, Never>?

    func attach(_ tv: NSTextView) { textView = tv }

    // MARK: - 读取

    func currentSelection() -> NSRange {
        textView?.selectedRange() ?? NSRange(location: 0, length: 0)
    }

    func selectedText() -> String {
        guard let tv = textView else { return "" }
        let r = tv.selectedRange()
        guard r.length > 0, r.location + r.length <= (tv.string as NSString).length else { return "" }
        return (tv.string as NSString).substring(with: r)
    }

    func fullText() -> String { textView?.string ?? "" }

    /// 陪写期间锁住编辑器，避免捕获的目标范围被用户编辑挪位
    func setLocked(_ locked: Bool) {
        textView?.isEditable = !locked
    }

    // MARK: - 写入定稿

    /// 把结果写进笔记：`replaceRange` 非 nil → 替换该范围；否则在 `insertAt` 处插入。返回写入文字的新范围。
    @discardableResult
    func applyResult(_ text: String, replaceRange: NSRange?, insertAt: Int) -> NSRange? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        let attrs = defaultAttrs
        let ns = NSAttributedString(string: text, attributes: attrs)
        let newLen = (text as NSString).length
        storage.beginEditing()
        let newRange: NSRange
        if let r = replaceRange {
            let rr = clamp(r, in: storage.length)
            storage.replaceCharacters(in: rr, with: ns)
            newRange = NSRange(location: rr.location, length: newLen)
        } else {
            let loc = max(0, min(insertAt, storage.length))
            storage.insert(ns, at: loc)
            newRange = NSRange(location: loc, length: newLen)
        }
        storage.endEditing()
        tv.isEditable = true
        tv.typingAttributes = attrs
        tv.scrollRangeToVisible(newRange)
        return newRange
    }

    /// 在光标处插入文本（走 insertText → 触发 textDidChange → draft 同步 + 自动保存）。
    /// 给"插入图片"用：把 `![](assets/xxx.png)` 插到当前光标。
    func insertAtCursor(_ text: String) {
        guard let tv = textView else { return }
        let wasEditable = tv.isEditable
        tv.isEditable = true
        let r = tv.selectedRange()
        if tv.shouldChangeText(in: r, replacementString: text) {
            tv.insertText(text, replacementRange: r)
            tv.didChangeText()
        }
        tv.isEditable = wasEditable
    }

    /// 写入后短暂高亮(桌宠主色淡底)，~1.6s 后淡掉 —— "改动可审阅"的轻量透明化
    func flashHighlight(_ range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let r = clamp(range, in: storage.length)
        guard r.length > 0 else { return }
        storage.addAttribute(.backgroundColor, value: petColor.withAlphaComponent(0.18), range: r)
        highlightFade?.cancel()
        highlightFade = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, let storage2 = self.textView?.textStorage else { return }
            let rr = self.clamp(r, in: storage2.length)
            if rr.length > 0 { storage2.removeAttribute(.backgroundColor, range: rr) }
        }
    }

    // MARK: - 工具

    private var defaultAttrs: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        ]
    }

    private func clamp(_ r: NSRange, in len: Int) -> NSRange {
        let loc = max(0, min(r.location, len))
        let maxLen = max(0, len - loc)
        return NSRange(location: loc, length: min(r.length, maxLen))
    }
}
