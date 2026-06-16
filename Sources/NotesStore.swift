import Foundation
import AppKit

/// AI 笔记库 —— 管理本地一个文件夹里的 markdown 文件。
///
/// 默认库 = `~/.hermespet/notes/`，用户也可在窗口里改指任意文件夹（含现成的 Obsidian vault）。
/// 笔记 = 普通 `.md` 文件，数据完全属于用户、随时能在访达里打开、能搬走。
///
/// `@MainActor @Observable` —— UI 直接读 `notes` / `selectedNoteID` / `editorText`，
/// 编辑走 `textChanged`（标脏 + 1.2s 防抖自动保存），切换/关闭时强制落盘。
@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    /// 一条笔记 = 一个本地 .md 文件。绝对路径作为唯一 id。
    struct NoteFile: Identifiable, Hashable {
        var path: String
        var title: String          // 文件名去掉 .md
        var modifiedAt: Date

        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    private static let vaultKey = "notesVaultPath"
    /// 侧栏识别为"笔记"的扩展名（不止 .md）—— 纯文本类都能编辑
    static let noteExtensions: Set<String> = ["md", "markdown", "txt", "text", "mdown"]

    /// 笔记库文件夹
    private(set) var vaultURL: URL
    /// 当前库里的所有 .md（按修改时间倒序）
    var notes: [NoteFile] = []
    /// 当前选中的笔记 id（绝对路径）
    var selectedNoteID: String?
    /// 编辑器文本 —— 与 `loadedNoteID` 对应的文件内容。外部用 `textChanged` 写、不要直接赋值。
    private(set) var editorText: String = ""
    /// 有未保存改动
    private(set) var isDirty = false
    /// 最近一次文件 I/O 错误（UI 可显示）
    var lastError: String?

    /// editorText 当前对应已加载的笔记 id —— 防止保存时写错文件
    private var loadedNoteID: String?
    private let fm = FileManager.default
    private var autosaveTask: Task<Void, Never>?

    /// 库目录监听 —— 在访达里增删 / 改名 .md 时自动刷新侧栏（否则只有 onAppear 那一次扫描，外部改动不同步）
    private var dirSource: DispatchSourceFileSystemObject?
    private var watcherReloadTask: Task<Void, Never>?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.vaultKey), !saved.isEmpty {
            vaultURL = URL(fileURLWithPath: saved)
        } else {
            vaultURL = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermespet")
                .appendingPathComponent("notes")
        }
        try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        seedWelcomeNoteIfEmpty()
        reload()                 // 启动即扫一遍，notes 不再是空的
        startWatchingVault()     // 挂目录监听，外部改动自动同步
    }

    // MARK: - 库管理

    /// 换一个文件夹当笔记库（先把当前未存的存掉）
    func changeVault(to url: URL) {
        saveCurrentIfDirty()
        vaultURL = url
        UserDefaults.standard.set(url.path, forKey: Self.vaultKey)
        try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        selectedNoteID = nil
        loadedNoteID = nil
        editorText = ""
        isDirty = false
        reload()
        startWatchingVault()     // 换库后重新挂监听
    }

    /// 弹 NSOpenPanel 选文件夹当库（本 app 非沙盒，普通文件访问即可，无需安全作用域书签）
    func pickVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("notes.vault.choose")
        panel.directoryURL = vaultURL
        if panel.runModal() == .OK, let url = panel.url {
            changeVault(to: url)
        }
    }

    // MARK: - 列表

    /// 重新扫描库目录里的 .md 文件
    func reload() {
        let urls = (try? fm.contentsOfDirectory(
            at: vaultURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var list: [NoteFile] = []
        for u in urls where Self.noteExtensions.contains(u.pathExtension.lowercased()) {
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            list.append(NoteFile(path: u.path, title: u.deletingPathExtension().lastPathComponent, modifiedAt: mod))
        }
        notes = list.sorted { $0.modifiedAt > $1.modifiedAt }

        // 选中项若已不存在 → 清空编辑器
        if let sel = selectedNoteID, !notes.contains(where: { $0.id == sel }) {
            selectedNoteID = nil
            loadedNoteID = nil
            editorText = ""
            isDirty = false
        }
    }

    // MARK: - 选择 / 加载

    /// 切换选中的笔记（先存当前再加载新的）
    func select(_ id: String?) {
        guard id != selectedNoteID else { return }
        saveCurrentIfDirty()
        selectedNoteID = id
        loadSelected()
    }

    private func loadSelected() {
        guard let id = selectedNoteID, let note = notes.first(where: { $0.id == id }) else {
            editorText = ""
            loadedNoteID = nil
            isDirty = false
            return
        }
        do {
            editorText = try String(contentsOf: note.url, encoding: .utf8)
        } catch {
            editorText = ""
            lastError = error.localizedDescription
        }
        loadedNoteID = id
        isDirty = false
    }

    // MARK: - 编辑 / 保存

    /// 编辑器文本变化 —— 标脏 + 防抖自动保存
    func textChanged(_ newText: String) {
        guard loadedNoteID != nil else { return }
        guard newText != editorText else { return }
        editorText = newText
        isDirty = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // 1.2s 防抖
            guard !Task.isCancelled else { return }
            self?.saveCurrentIfDirty()
        }
    }

    /// 把当前编辑器内容落盘（仅在有改动时）。切换笔记 / 关窗 / 防抖到点都会调。
    func saveCurrentIfDirty() {
        guard isDirty, let id = loadedNoteID, let note = notes.first(where: { $0.id == id }) else { return }
        do {
            try editorText.write(to: note.url, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 新建 / 重命名 / 删除

    @discardableResult
    func createNote(title rawTitle: String? = nil, body: String? = nil) -> NoteFile? {
        saveCurrentIfDirty()
        let base: String = {
            let t = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? L("notes.untitled") : t
        }()
        let url = uniqueURL(for: sanitizeFilename(base))
        // body 非空 → 直接写入完整内容（会议纪要等）；否则写 seed 空白模板
        let seed = body ?? "# \(base)\n\n"
        do {
            try seed.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        reload()
        selectedNoteID = url.path
        loadSelected()
        return notes.first(where: { $0.id == url.path })
    }

    /// 重命名当前选中的笔记（改文件名）
    func renameSelected(to newTitle: String) {
        guard let id = loadedNoteID, let note = notes.first(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.title else { return }
        saveCurrentIfDirty()
        let dest = uniqueURL(for: sanitizeFilename(trimmed))
        do {
            try fm.moveItem(at: note.url, to: dest)
        } catch {
            lastError = error.localizedDescription
            return
        }
        reload()
        selectedNoteID = dest.path
        loadSelected()
    }

    /// 删除笔记 —— 进废纸篓（用户可恢复），不直接抹除
    func deleteNote(_ id: String) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        try? fm.trashItem(at: note.url, resultingItemURL: nil)
        if selectedNoteID == id {
            selectedNoteID = nil
            loadedNoteID = nil
            editorText = ""
            isDirty = false
        }
        reload()
    }

    /// 写作模式：把对话里 ```note 卡片确认后的【完整内容】写进文件(方案甲 · App 中介)。
    /// saveAsNew=true → 另存为不冲突的新文件；否则按文件名写入(覆盖或新建)。
    /// 写完选中这篇 + 同步 editorText，并发通知让画布刷新。
    func applyNote(filename rawName: String, content: String, saveAsNew: Bool) {
        saveCurrentIfDirty()
        var base = sanitizeFilename(rawName)
        if base.lowercased().hasSuffix(".md") {
            base = String(base.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if base.isEmpty {
            base = notes.first(where: { $0.id == selectedNoteID })?.title ?? L("notes.untitled")
        }
        let url = saveAsNew ? uniqueURL(for: base) : vaultURL.appendingPathComponent("\(base).md")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
            return
        }
        reload()
        selectedNoteID = url.path
        editorText = content
        loadedNoteID = url.path
        isDirty = false
        NotificationCenter.default.post(
            name: .init("HermesPetNotesDocReplaced"),
            object: nil,
            userInfo: ["path": url.path]
        )
    }

    // MARK: - 目录监听（外部改动自动同步侧栏）

    /// 给当前 vault 目录挂一个 DispatchSource 文件系统监听：
    /// 用户在访达里新建 / 删除 / 改名 .md（或别的 app 写入）→ 触发事件 → 防抖后 reload() 刷新侧栏。
    /// 监听回调在后台队列触发，统一 hop 回 MainActor 改 @Observable 状态（决策 #5）。
    private func startWatchingVault() {
        stopWatchingVault()
        let fd = open(vaultURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // ⚠️ 决策 #5：本类是 @MainActor，下面的回调闭包会被编译器**自动推断成 @MainActor 隔离**。
        // 若把它挂在后台队列(DispatchQueue.global)上跑 → Swift 6 运行时进闭包先查执行器、发现不在主线程
        // → `dispatch_assert_queue_fail` SIGTRAP 必崩(23:03 那次就是)。
        // 解法：DispatchSource 直接用**主队列**——回调在主线程跑、隔离匹配、还能直接调 @MainActor 方法。
        // 目录事件很稀疏(新建/删/存盘才有)且下面又防抖 300ms，放主线程零压力。
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .link],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleWatcherReload()   // 已在主线程，直接调
        }
        source.setCancelHandler { close(fd) }   // 关 fd，只碰本地 fd
        dirSource = source
        source.resume()
    }

    private func stopWatchingVault() {
        dirSource?.cancel()
        dirSource = nil
    }

    /// 目录事件防抖（外部一次保存常连发多个事件）—— 300ms 内合并成一次 reload。
    /// reload 只重建文件列表、不动正在编辑的 editorText，所以编辑中被外部事件触发也不会打断输入。
    private func scheduleWatcherReload() {
        watcherReloadTask?.cancel()
        watcherReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    // MARK: - 工具

    /// 文件名清洗 —— 去掉路径分隔符等非法字符
    private func sanitizeFilename(_ s: String) -> String {
        var t = s
        for ch in ["/", ":", "\\", "\n", "\r", "\t"] {
            t = t.replacingOccurrences(of: ch, with: " ")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L("notes.untitled") : t
    }

    /// 在库里生成不冲突的 `<base>.md`（已存在则追加序号）
    private func uniqueURL(for base: String) -> URL {
        var candidate = vaultURL.appendingPathComponent("\(base).md")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = vaultURL.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return candidate
    }

    // MARK: - 图片资源（插入文档用，存到库的 assets/ 子目录）

    /// 把外部图片文件拷进库的 `assets/`，返回相对库根的路径（如 `assets/img-3.png`，写进 `![](…)`）。
    func importImage(from url: URL) -> String? {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let dest = uniqueAssetURL(ext: ext)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dest)
        } catch { lastError = error.localizedDescription; return nil }
        return "assets/\(dest.lastPathComponent)"
    }

    /// 把图片二进制（粘贴板/截图）写进库的 `assets/`，返回相对路径。
    func saveImageData(_ data: Data, ext: String = "png") -> String? {
        let dest = uniqueAssetURL(ext: ext)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        } catch { lastError = error.localizedDescription; return nil }
        return "assets/\(dest.lastPathComponent)"
    }

    private func uniqueAssetURL(ext: String) -> URL {
        let assets = vaultURL.appendingPathComponent("assets")
        var n = 1
        var candidate = assets.appendingPathComponent("img-\(n).\(ext)")
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = assets.appendingPathComponent("img-\(n).\(ext)")
        }
        return candidate
    }

    /// 库里一篇笔记都没有时，放一篇欢迎笔记，避免首次进来空空如也
    private func seedWelcomeNoteIfEmpty() {
        let urls = (try? fm.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let hasMD = urls.contains { Self.noteExtensions.contains($0.pathExtension.lowercased()) }
        guard !hasMD else { return }
        let welcome = vaultURL.appendingPathComponent("\(L("notes.welcome.filename")).md")
        try? L("notes.welcome.body").write(to: welcome, atomically: true, encoding: .utf8)
    }
}
