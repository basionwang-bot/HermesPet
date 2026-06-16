import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 笔记中栏的 markdown 源码编辑器 —— NSTextView 包装（SwiftUI TextEditor 读不到选中、没法精确插字）。
///
/// 范式照搬 `SendOnEnterTextEditor`：用 coordinator 记 `lastSyncedText` 防"用户刚输入的字被旧值覆盖回去"
/// 的经典竞态（决策见 ChatComponents 注释）。额外把 NSTextView 交给 `NotesEditorController`，
/// 让桌宠陪写能读选中 / 插彩色待定文字。
/// 用 `NotesEditorTextView` 子类：**粘贴/拖入图片**时存进库的 assets/ 并插入 `![](…)`。
struct NotesSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: NotesEditorController
    var fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        // 手动搭 NSTextView（要用自定义子类，scrollableTextView() 给不了子类）
        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let tv = NotesEditorTextView(
            frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false

        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = true
        // 文档感：用系统比例字体（不再等宽），标题/正文层次更像 Obsidian
        tv.font = NSFont.systemFont(ofSize: fontSize)
        tv.textColor = .textColor
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        // 实时样式器挂上去（先挂委托再灌文字 → 初次加载即上样式 + 渲染图片）
        tv.styler.baseSize = fontSize
        tv.styler.shouldSuspend = { [weak tv] in tv?.hasMarkedText() ?? false }  // 输入法组字中暂停样式
        textStorage.delegate = tv.styler
        tv.setMarkdown(text)
        context.coordinator.lastSyncedText = text
        controller.attach(tv)
        controller.fontSize = fontSize

        scrollView.documentView = tv
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        controller.fontSize = fontSize
        // 陪写期间编辑器被锁定（isEditable=false）：不要覆盖文本、不要改字体
        guard tv.isEditable else { return }

        if let f = tv.font, abs(f.pointSize - fontSize) > 0.1 {
            tv.font = NSFont.systemFont(ofSize: fontSize)
            if let et = tv as? NotesEditorTextView {
                et.styler.baseSize = fontSize
                if let ts = tv.textStorage { et.styler.styleAll(ts) }
            }
        }
        let coordinator = context.coordinator
        // 只有"真·外部 set"（切笔记 / 确认落定后回灌）才覆盖；SwiftUI echo 我们自己的更新时跳过。
        // ⚠️ 比较**序列化 markdown**（不是 tv.string，后者含附件占位符 U+FFFC，会误判成"外部变了"反复重灌）。
        if let et = tv as? NotesEditorTextView {
            let currentMD = et.currentMarkdown()
            if currentMD != text && text != coordinator.lastSyncedText {
                et.setMarkdown(text)
                coordinator.lastSyncedText = text
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NotesSourceEditor
        var lastSyncedText = ""

        init(parent: NotesSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NotesEditorTextView else { return }
            if tv.isRendering { return }   // 渲染期是程序在 text↔附件互换，不回写、不抢
            if tv.hasMarkedText() { return }  // 输入法组字中 → 不回写/不渲染（提交后那次再处理）
            if !tv.isEditable { return }   // 锁定期（陪写写入）不算用户编辑
            let md = tv.currentMarkdown()  // ⭐ 序列化成纯 markdown（附件还原成 ![](…)），不是 tv.string
            lastSyncedText = md
            parent.text = md
            tv.scheduleRender()            // 编辑后防抖渲染图片
        }

        /// 光标移动 → ① 标记符显隐跟随(Step3) ② 重渲染图片(离开图片语法就变成图)
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NotesEditorTextView, !tv.isRendering else { return }
            if tv.hasMarkedText() { return }   // 组字中光标在跳，别重排/渲染
            tv.updateCaretConceal()
            tv.scheduleRender(160)
        }
    }
}

/// markdown 编辑器的 NSTextView 子类：
/// ① 实时样式（标题/加粗/斜体… 边写边变样，由 `styler` 上属性）；
/// ② 拦**粘贴/拖入图片** → 存进库 assets/ → 光标处插 `![](相对路径)`。
final class NotesEditorTextView: NSTextView {
    /// 实时 markdown 样式器（挂成 textStorage 委托）
    let styler = NotesMarkdownStyler()

    // MARK: - 图片内联渲染（Live Preview Step2）
    //
    // 原理：editor 里 `![](path)` / `![[name]]` 渲染成内联图片(NSTextAttachment)，但**底下保存的永远是纯
    // markdown** —— 靠 `currentMarkdown()` 把附件还原成 `markdownSource` 序列化回去（附件携带原始语法）。
    // 渲染只在 text↔附件之间来回换，序列化结果不变 → 数据零损坏（铁律）。
    // 光标正落在某处图片语法上时**先不渲染**(留给你编辑/删除)，移开光标再渲染成图。

    /// 渲染期标记：程序在改 storage，coordinator 不回写、委托不抢
    var isRendering = false
    private var renderTask: Task<Void, Never>?
    private var lastRenderWidth: CGFloat = 0
    /// 上次光标所在段（Step3 标记符显隐跟随光标用）
    private var lastCaretPara = NSRange(location: NSNotFound, length: 0)

    static let imageRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "!\\[\\[[^\\]\\n]+\\]\\]"),          // ![[name]]（Obsidian）
        try! NSRegularExpression(pattern: "!\\[[^\\]\\n]*\\]\\([^)\\n]+\\)"),  // ![alt](path)
    ]

    /// 把当前内容序列化成**纯 markdown**（图片附件 → 其 markdownSource，其余 → 原文）。保存/同步都用它。
    static func markdown(from storage: NSTextStorage) -> String {
        let full = NSRange(location: 0, length: storage.length)
        let out = NSMutableString()
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: full, options: []) { val, range, _ in
            if let att = val as? MDImageAttachment {
                out.append(att.markdownSource)
            } else {
                out.append(ns.substring(with: range))
            }
        }
        return out as String
    }

    func currentMarkdown() -> String {
        guard let ts = textStorage else { return string }
        return Self.markdown(from: ts)
    }

    /// 外部灌入 markdown（切笔记 / 回灌）：设文字 → 上样式 → 渲染图片。
    func setMarkdown(_ md: String) {
        guard let ts = textStorage else { string = md; return }
        isRendering = true
        string = md
        let ns = ts.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        styler.caretParagraph = para
        lastCaretPara = para
        styler.styleAll(ts)
        isRendering = false
        renderImages()
    }

    /// 选区变化 → 标记符显隐跟着光标走：重排"离开的旧段 + 进入的新段"。
    func updateCaretConceal() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        guard para.location != lastCaretPara.location || para.length != lastCaretPara.length else { return }
        let old = lastCaretPara
        lastCaretPara = para
        styler.caretParagraph = para
        let saved = isRendering
        isRendering = true   // 只改属性不动文字，仍保险地挡住回写
        if old.location != NSNotFound, old.location <= storage.length {
            styler.restyle(storage, paragraphAt: old)
        }
        styler.restyle(storage, paragraphAt: para)
        isRendering = saved
    }

    /// 防抖渲染（编辑/选区变化后）
    func scheduleRender(_ delayMs: UInt64 = 280) {
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.renderImages()
        }
    }

    /// 渲染一遍：① 已有附件按当前宽度更新尺寸；② 原始图片语法(非光标处)转成附件。
    func renderImages() {
        guard let storage = textStorage, !isRendering else { return }
        let maxW = imageMaxWidth()
        let full = NSRange(location: 0, length: storage.length)
        let ns = storage.string as NSString

        // ① 已是附件 → 跟随宽度更新尺寸（窗口变宽变窄时图片跟着缩放）
        var boundsChanged = false
        storage.enumerateAttribute(.attachment, in: full, options: []) { val, range, _ in
            if let att = val as? MDImageAttachment, let img = att.image {
                let nb = Self.scaledBounds(img.size, maxW)
                if abs(att.bounds.width - nb.width) > 1 { att.bounds = nb; boundsChanged = true }
            }
        }
        if boundsChanged { layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil) }

        // ② 原始图片语法 → 附件（光标正落在该语法上的先跳过，留着编辑）
        let sel = selectedRange()
        var matches: [(range: NSRange, md: String, img: NSImage)] = []
        for re in Self.imageRegexes {
            re.enumerateMatches(in: storage.string, options: [], range: full) { m, _, _ in
                guard let r = m?.range else { return }
                if sel.location >= r.location && sel.location <= NSMaxRange(r) { return }  // 光标在此处 → 不渲染
                let md = ns.substring(with: r)
                if let url = self.resolveImage(md), let img = NSImage(contentsOf: url) {
                    matches.append((r, md, img))
                }
            }
        }
        guard !matches.isEmpty else { return }
        matches.sort { $0.range.location > $1.range.location }   // 从后往前改，偏移稳定

        isRendering = true
        undoManager?.disableUndoRegistration()
        var caret = sel.location
        storage.beginEditing()
        for (range, md, img) in matches {
            let att = MDImageAttachment(markdownSource: md, image: img, maxWidth: maxW)
            storage.replaceCharacters(in: range, with: NSAttributedString(attachment: att))
            let delta = 1 - range.length
            if NSMaxRange(range) <= caret { caret += delta }
            else if range.location < caret { caret = range.location + 1 }
        }
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        isRendering = false
        setSelectedRange(NSRange(location: max(0, min(caret, storage.length)), length: 0))
    }

    /// 图片内联语法解析成本地 URL（`![](path)` 走库根解析；`![[name]]` 在库根/assets 找）
    private func resolveImage(_ md: String) -> URL? {
        let vault = NotesStore.shared.vaultURL
        if md.hasPrefix("![[") && md.hasSuffix("]]") {
            let name = String(md.dropFirst(3).dropLast(2)).trimmingCharacters(in: .whitespaces)
            for c in [vault.appendingPathComponent(name),
                      vault.appendingPathComponent("assets").appendingPathComponent(name)]
            where FileManager.default.fileExists(atPath: c.path) { return c }
            return nil
        }
        if let (_, path) = MarkdownTextView.parseImageLine(md) {
            return MarkdownImageView.resolve(path, vaultPath: vault.path)
        }
        return nil
    }

    private func imageMaxWidth() -> CGFloat {
        let w = (textContainer?.size.width ?? bounds.width) - textContainerInset.width * 2 - 6
        return max(220, min(w, 680))
    }

    // 纯几何计算、无 MainActor 状态 → nonisolated，让 MDImageAttachment.init 等 nonisolated 上下文能调（决策 #5）
    nonisolated static func scaledBounds(_ size: NSSize, _ maxW: CGFloat) -> CGRect {
        let w = min(size.width, maxW)
        let h = size.width > 0 ? w * (size.height / size.width) : w
        return CGRect(x: 0, y: 0, width: max(1, w), height: max(1, h))
    }

    /// 提交输入（普通输入 / 输入法选词）后：组字态已清 → 补排当前段，确保样式跟上
    /// （防"组字中暂停样式"那一帧把提交后的样式也漏掉）。
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        if !hasMarkedText() { restyleCurrentParagraph() }
    }

    func restyleCurrentParagraph() {
        guard let storage = textStorage, storage.length > 0, !isRendering else { return }
        let ns = storage.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        isRendering = true
        styler.restyle(storage, paragraphAt: para)
        isRendering = false
    }

    /// 编辑器宽度变了（窗口/分栏拖动）→ 重渲染让图片跟着缩放
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastRenderWidth) > 24 {
            lastRenderWidth = newSize.width
            scheduleRender(120)
        }
    }

    // MARK: 粘贴

    override func paste(_ sender: Any?) {
        if insertImageFromPasteboard(NSPasteboard.general) { return }
        super.paste(sender)   // 没图片 → 正常粘文字
    }

    // MARK: 拖入

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertImageFromPasteboard(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    // MARK: 共用：从粘贴板/拖拽板抽图片并插入

    @discardableResult
    private func insertImageFromPasteboard(_ pb: NSPasteboard) -> Bool {
        // 1) 图片文件（Finder 复制 / 拖文件）
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first,
           let rel = NotesStore.shared.importImage(from: url) {
            insertMarkdownImage(rel); return true
        }
        // 2) 直接是图片数据（截图到剪贴板 / 从预览复制）
        if let png = pb.data(forType: .png),
           let rel = NotesStore.shared.saveImageData(png) {
            insertMarkdownImage(rel); return true
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           let rel = NotesStore.shared.saveImageData(png) {
            insertMarkdownImage(rel); return true
        }
        return false
    }

    /// 独占一行插入图片引用（前后补换行 → 被 markdown 解析成图片块、预览能渲染）
    private func insertMarkdownImage(_ relPath: String) {
        let md = "\n![](\(relPath))\n"
        let r = selectedRange()
        if shouldChangeText(in: r, replacementString: md) {
            insertText(md, replacementRange: r)
            didChangeText()
        }
        // 插完把光标移开图片那行，让它立刻渲染成图
        scheduleRender(80)
    }
}

/// 内联图片附件 —— 携带它对应的**原始 markdown 语法**，序列化时还原回去（保证存盘永远是纯 markdown）。
final class MDImageAttachment: NSTextAttachment {
    let markdownSource: String
    init(markdownSource: String, image: NSImage, maxWidth: CGFloat) {
        self.markdownSource = markdownSource
        super.init(data: nil, ofType: nil)
        self.image = image
        self.bounds = NotesEditorTextView.scaledBounds(image.size, maxWidth)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
