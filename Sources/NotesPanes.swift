import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 写作模式的「文件侧栏」+「文档画布」两块可复用视图。
/// 从原独立笔记窗 NotesView 抽出来，现在挂进聊天窗的写作模式三栏里。
/// 都不含易崩的消息列表逻辑（决策 #21），可安全在 ChatView 内复用。

// MARK: - 左栏：文件侧栏

struct NotesFileSidebar: View {
    let store: NotesStore
    var onCollapse: (() -> Void)? = nil
    @State private var renaming = false
    @State private var renameText = ""
    @State private var headerHover = false

    var body: some View {
        VStack(spacing: 0) {
            // 极简头：库名(点开=换文件夹/访达/刷新) ········ [收起(hover才显)] [＋新建]
            HStack(spacing: 6) {
                Menu {
                    Button(L("notes.vault.choose")) { store.pickVaultFolder() }
                    Button(L("notes.action.revealInFinder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.vaultURL])
                    }
                    Button(L("notes.action.refresh")) { store.reload() }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.vaultURL.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

                Spacer()

                if let onCollapse, headerHover {
                    Button { onCollapse() } label: {
                        Image(systemName: "sidebar.left").font(.system(size: 12))
                            .foregroundStyle(.secondary).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).help(L("notes.sidebar.collapse"))
                    .transition(.opacity)
                }
                Button { store.createNote() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13))
                        .foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help(L("notes.action.new"))
            }
            .padding(.horizontal, 12).frame(height: 44)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(AnimTok.snappy) { headerHover = h } }

            Divider()

            if store.notes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(L("notes.empty")).font(.callout).foregroundStyle(.secondary)
                    Button(L("notes.action.new")) { store.createNote() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List(selection: Binding(get: { store.selectedNoteID }, set: { store.select($0) })) {
                    ForEach(store.notes) { note in
                        NotesFileRow(note: note)
                            .tag(note.id)
                            .contextMenu {
                                Button(L("notes.action.rename")) { beginRename(note) }
                                Button(L("notes.action.delete"), role: .destructive) { store.deleteNote(note.id) }
                                Divider()
                                Button(L("notes.action.revealInFinder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([note.url])
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .alert(L("notes.rename.title"), isPresented: $renaming) {
            TextField(L("notes.rename.placeholder"), text: $renameText)
            Button(L("notes.cancel"), role: .cancel) {}
            Button(L("notes.action.rename")) { store.renameSelected(to: renameText) }
        }
    }

    private func beginRename(_ note: NotesStore.NoteFile) {
        store.select(note.id)
        renameText = note.title
        renaming = true
    }
}

private struct NotesFileRow: View {
    let note: NotesStore.NoteFile
    @State private var hovering = false
    @State private var showPreview = false
    @State private var preview = ""
    @State private var dwell: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).font(.callout).lineLimit(1)
            Text(note.modifiedAt, format: .relative(presentation: .named))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3).padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // hover 高亮"突出一点"
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .animation(AnimTok.snappy, value: hovering)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            dwell?.cancel()
            if h {
                // 停留 0.5s 再弹简介(避免划过时狂闪)
                let url = note.url
                dwell = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    preview = NotesFileRow.loadPreview(url)
                    showPreview = true
                }
            } else {
                showPreview = false
            }
        }
        // 简介浮窗(笔记前几行,去掉 markdown 标记)
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Divider()
                Text(preview.isEmpty ? "（这篇还是空的）" : preview)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(10).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(width: 260)
        }
    }

    /// 读笔记前几行做简介(去掉 # > - * 等 markdown 标记)。
    static func loadPreview(_ url: URL) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { (line: String) -> String in
                var s = line
                while let f = s.first, "#>-*`| ".contains(f) { s.removeFirst() }
                return s
            }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 中栏：文档画布（markdown 编辑 / 预览）

struct NotesDocumentCanvas: View {
    let store: NotesStore
    var fontScale: Double

    @State private var draft = ""
    @State private var previewText = ""
    @State private var previewDebounce: Task<Void, Never>?
    @State private var editorController = NotesEditorController()

    enum PaneMode: Hashable { case edit, split, preview }
    // 默认单栏实时编辑器（边写边渲染样式）。preview 仍保留一颗眼睛切到"完整渲染(含图片)"，待 Step2 图片内联后再撤。
    @State private var paneMode: PaneMode = .edit
    /// 鼠标在文档区内 —— 右上角的「编辑/分栏/预览」切换才浮现（标题已搬到顶栏，中栏只剩正文）
    @State private var docHover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 文档主体（标题不再重复——顶栏已居中显示）
            if store.selectedNoteID == nil {
                VStack(spacing: 10) {
                    Image(systemName: "doc.richtext").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(L("notes.noSelection")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 内容居中(最宽 860),两侧留白方便阅读 + 给收起的边栏腾位置
                editorBody
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // hover 才浮现的工具组（插图 + 视图切换）—— 平时不打扰书写
            if docHover, store.selectedNoteID != nil {
                HStack(spacing: 10) {
                    if paneMode != .preview {
                        Button { insertImageViaPanel() } label: {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("notes.insertImage"))
                    }
                    // 单栏实时编辑 ↔ 完整渲染预览（含图片）。分栏已撤——实时编辑器本身就边写边渲染。
                    Picker("", selection: $paneMode) {
                        Image(systemName: "pencil").tag(PaneMode.edit)
                        Image(systemName: "eye").tag(PaneMode.preview)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 86)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.regularMaterial)
                )
                .padding(.top, 8).padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(AnimTok.snappy) { docHover = h } }
        .onAppear {
            store.reload()
            if store.selectedNoteID == nil { store.select(store.notes.first?.id) }
            syncDraftFromStore()
            updateWritingContext()
        }
        .onChange(of: store.selectedNoteID) { _ in
            syncDraftFromStore()
            updateWritingContext()
        }
        .onChange(of: draft) { newDraft in
            store.textChanged(newDraft)
            schedulePreview(newDraft)
            updateWritingContext()
        }
        // 对话里 ```note 卡片"应用"后写了当前文档 → 刷新画布
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetNotesDocReplaced"))) { _ in
            syncDraftFromStore()
            updateWritingContext()
        }
        .onDisappear { NotesWritingContextHolder.shared.clear() }
    }

    /// 把当前文档实时灌进写作上下文持有器(供右栏对话的 prompt 注入)
    private func updateWritingContext() {
        NotesWritingContextHolder.shared.update(
            vault: store.vaultURL.lastPathComponent,
            filename: currentTitle,
            content: draft,
            fileList: store.notes.map { $0.title }
        )
    }

    @ViewBuilder
    private var editorBody: some View {
        switch paneMode {
        case .edit:
            sourceEditor
        case .preview:
            previewScroll
        case .split:
            HSplitView {
                sourceEditor.frame(minWidth: 220)
                previewScroll.frame(minWidth: 220)
            }
        }
    }

    private var sourceEditor: some View {
        NotesSourceEditor(text: $draft, controller: editorController, fontSize: 14 * fontScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewScroll: some View {
        ScrollView {  // 决策 #21：ScrollView 不套 GeometryReader
            MarkdownTextView(content: previewText)
                // ⭐ 正文/列表(InlineMarkdownView)靠容器 .font() 缩放，必须在这套上缩放后的字号，
                // 否则只有 header/表格/代码块(自带 fontScale)放大、正文不动（用户："有的能放大有的不能"）
                .font(.system(size: 15 * fontScale))
                .environment(\.chatFontScale, fontScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentTitle: String {
        store.notes.first(where: { $0.id == store.selectedNoteID })?.title ?? ""
    }

    private func syncDraftFromStore() {
        previewDebounce?.cancel()
        draft = store.editorText
        previewText = store.editorText
    }

    private func schedulePreview(_ text: String) {
        previewDebounce?.cancel()
        previewDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            previewText = text
        }
    }

    /// 选图片插入：NSOpenPanel 选图 → 拷进库 assets/ → 光标处插 `![](相对路径)`。
    private func insertImageViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = L("notes.insertImage")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let rel = store.importImage(from: url) {
                editorController.insertAtCursor("\n![](\(rel))\n")
            }
        }
    }
}
