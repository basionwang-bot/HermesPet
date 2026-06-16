import Foundation

/// 写作模式下要注入对话 prompt 的「文档协作上下文」快照。
///
/// 各 client(APIClient / ClaudeCodeClient / CodexClient / OpenCodeHTTPClient)在后台线程构建 prompt 时,
/// 调 `promptAddition()` / `promptSuffix()` 取这段上下文——所以必须 **nonisolated 可读**(`@unchecked Sendable` + NSLock,
/// 照决策 #5 的 holder 范式)。内容由写作模式的文档画布(NotesDocumentCanvas)实时更新。
///
/// 它告诉 AI:当前打开的文档是什么、文件夹里有哪些文档、以及「要改/新建文档就用 ```note 围栏块输出,
/// app 渲染成卡片让用户确认后才写盘」的协议(方案甲 · App 中介 / Artifacts 式)。
final class NotesWritingContextHolder: @unchecked Sendable {
    static let shared = NotesWritingContextHolder()

    private let lock = NSLock()
    private var active = false
    private var vault = ""
    private var filename = ""
    private var content = ""
    private var fileList: [String] = []

    private init() {}

    /// 写作模式下,画布把当前文档实时灌进来(打开的文件名 + 完整内容 + 同夹文档清单)
    func update(vault: String, filename: String, content: String, fileList: [String]) {
        lock.lock()
        active = true
        self.vault = vault
        self.filename = filename
        self.content = content
        self.fileList = fileList
        lock.unlock()
    }

    /// 退出写作模式 —— 清掉,普通对话不再注入文档上下文
    func clear() {
        lock.lock()
        active = false
        content = ""
        filename = ""
        fileList = []
        lock.unlock()
    }

    /// 拼接进 system prompt 末尾用(空则返回空,不加多余换行)
    func promptSuffix() -> String {
        let s = promptAddition()
        return s.isEmpty ? "" : "\n\n" + s
    }

    /// 写作模式上下文正文(非写作模式返回空串)
    func promptAddition() -> String {
        lock.lock()
        let a = active, v = vault, fn = filename, c = content, fl = fileList
        lock.unlock()
        guard a else { return "" }

        let cappedContent = c.count > 8000 ? String(c.prefix(8000)) + "\n…（内容较长已截断）" : c
        let others = fl.isEmpty ? "（暂无其它文档）" : fl.prefix(40).joined(separator: "、")
        let docPart = fn.isEmpty
            ? "用户现在还没打开任何文档。"
            : "当前打开的文档是「\(fn)」，它的完整内容如下：\n---\n\(cappedContent)\n---"

        return """
        （写作模式 · 文档协作）你正在帮用户编辑本地笔记文件夹「\(v)」里的文档。\(docPart)
        文件夹里的文档有：\(others)。

        当你要新建或修改某个文档时，把该文档的【完整新内容】（要整篇，不是 diff、不是片段）放进下面这样的围栏块里输出：
        ```note:目标文件名.md
        <完整 markdown 内容>
        ```
        app 会把这个块渲染成一张卡片，由用户点「应用」确认后才真正写入文件——所以你不要假装已经保存了，产出 ```note 块就行。你可以照常用文字解释你做了什么改动。修改当前这篇就用它的文件名，新建就起一个新文件名。一次只在一个 ```note 块里放一个文件。
        """
    }
}
