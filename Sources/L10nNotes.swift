import Foundation

/// AI 笔记窗的双语文案。key 前缀：`notes.`（外加一条 `settings.hotkey.notes` 给热键设置面板）。
/// 在 `LocaleManager.zhTable` / `enTable` 数组里登记后生效。
enum L10nNotes {
    static let zh: [String: String] = [
        "notes.title": "AI 笔记",
        "notes.menu.openNotes": "写作模式",
        "settings.hotkey.notes": "写作模式",
        "chat.header.writing.help": "写作模式 · 文档 + 对话",
        "notes.sidebar.collapse": "收起文件栏",
        "notes.sidebar.expand": "展开文件栏",
        "notes.chat.collapse": "收起对话",
        "notes.chat.expand": "展开对话",
        "notes.exit.help": "退出写作模式 · 返回聊天",
        "notes.maximize.help": "最大化 / 还原",
        "notes.insertImage": "插入图片",

        "notes.untitled": "无标题",
        "notes.empty": "还没有笔记",
        "notes.noSelection": "选择或新建一篇笔记",
        "notes.unsaved": "有未保存的改动",

        "notes.action.new": "新建笔记",
        "notes.action.rename": "重命名",
        "notes.action.delete": "删除",
        "notes.action.refresh": "刷新列表",
        "notes.action.revealInFinder": "在访达中显示",
        "notes.cancel": "取消",

        "notes.vault.choose": "选择笔记文件夹…",
        "notes.rename.title": "重命名笔记",
        "notes.rename.placeholder": "笔记名称",

        "notes.pet.tagline": "选中文字、或直接告诉我做什么",
        "notes.pet.more": "更多…",
        "notes.pet.input.placeholder": "让桌宠帮你改…",

        "notes.pet.action.polish": "润色",
        "notes.pet.action.expand": "扩写",
        "notes.pet.action.summarize": "总结",
        "notes.pet.action.continue": "续写",
        "notes.pet.action.shorten": "精简",
        "notes.pet.action.rewrite": "改写",
        "notes.pet.action.fix": "改错别字",
        "notes.pet.action.translate": "翻译 中↔英",
        "notes.pet.action.title": "起标题",

        "notes.assist.writing": "%@ 正在写…",
        "notes.assist.done": "%@ 写好了",
        "notes.assist.stop": "停止",
        "notes.assist.replace": "替换原文",
        "notes.assist.insert": "插入下方",
        "notes.assist.keep": "保留",
        "notes.assist.discard": "放弃",
        "notes.assist.needSelection": "先选中要改的文字",
        "notes.assist.write": "写入笔记",
        "notes.assist.copy": "复制",
        "notes.assist.original": "原文",
        "notes.assist.followup": "再让桌宠改…(更正式 / 短一半 / 删第2点)",
        "notes.assist.statTransform": "%d 字 → %d 字",
        "notes.assist.statGenerate": "新增 %d 字",
        "markdown.note.untitled": "新文档",
        "markdown.note.apply": "应用",
        "markdown.note.saveAs": "另存为",
        "markdown.note.applied": "已写入",

        "notes.welcome.filename": "欢迎使用 AI 笔记",
        "notes.welcome.body": """
        # 欢迎使用 AI 笔记 👋

        这是住在你 Mac 上的本地笔记本。每一篇笔记都是普通的 **Markdown 文件**，存放在：

        `~/.hermespet/notes/`

        你随时能在「访达」里打开它们，也可以把文件夹换成你已有的 Obsidian 仓库 —— 数据完全属于你。

        ## 试试看

        - 点左上角 ✏️ **新建一篇笔记**
        - 在中间用 Markdown 书写，切换「编辑 / 分栏 / 预览」看实时渲染
        - 右边的桌宠会一直陪着你 —— 很快它就能帮你润色、扩写、总结

        > 写点什么吧，第一篇笔记交给你。
        """,
    ]

    static let en: [String: String] = [
        "notes.title": "AI Notes",
        "notes.menu.openNotes": "Writing Mode",
        "settings.hotkey.notes": "Writing Mode",
        "chat.header.writing.help": "Writing mode · doc + chat",
        "notes.sidebar.collapse": "Collapse files",
        "notes.sidebar.expand": "Expand files",
        "notes.chat.collapse": "Collapse chat",
        "notes.chat.expand": "Expand chat",
        "notes.exit.help": "Exit writing mode · back to chat",
        "notes.maximize.help": "Maximize / Restore",
        "notes.insertImage": "Insert image",

        "notes.untitled": "Untitled",
        "notes.empty": "No notes yet",
        "notes.noSelection": "Select or create a note",
        "notes.unsaved": "Unsaved changes",

        "notes.action.new": "New Note",
        "notes.action.rename": "Rename",
        "notes.action.delete": "Delete",
        "notes.action.refresh": "Refresh List",
        "notes.action.revealInFinder": "Reveal in Finder",
        "notes.cancel": "Cancel",

        "notes.vault.choose": "Choose Notes Folder…",
        "notes.rename.title": "Rename Note",
        "notes.rename.placeholder": "Note name",

        "notes.pet.tagline": "Select text, or just tell me what to do",
        "notes.pet.more": "More…",
        "notes.pet.input.placeholder": "Ask the pet to help…",

        "notes.pet.action.polish": "Polish",
        "notes.pet.action.expand": "Expand",
        "notes.pet.action.summarize": "Summarize",
        "notes.pet.action.continue": "Continue",
        "notes.pet.action.shorten": "Shorten",
        "notes.pet.action.rewrite": "Rewrite",
        "notes.pet.action.fix": "Fix grammar",
        "notes.pet.action.translate": "Translate",
        "notes.pet.action.title": "Title",

        "notes.assist.writing": "%@ is writing…",
        "notes.assist.done": "%@ is done",
        "notes.assist.stop": "Stop",
        "notes.assist.replace": "Replace",
        "notes.assist.insert": "Insert below",
        "notes.assist.keep": "Keep",
        "notes.assist.discard": "Discard",
        "notes.assist.needSelection": "Select some text first",
        "notes.assist.write": "Write to note",
        "notes.assist.copy": "Copy",
        "notes.assist.original": "Original",
        "notes.assist.followup": "Refine… (more formal / shorter / cut point 2)",
        "notes.assist.statTransform": "%d → %d chars",
        "notes.assist.statGenerate": "+%d chars",
        "markdown.note.untitled": "New document",
        "markdown.note.apply": "Apply",
        "markdown.note.saveAs": "Save as new",
        "markdown.note.applied": "Saved",

        "notes.welcome.filename": "Welcome to AI Notes",
        "notes.welcome.body": """
        # Welcome to AI Notes 👋

        This is your local notebook living on your Mac. Every note is a plain **Markdown file**, stored in:

        `~/.hermespet/notes/`

        You can open them in Finder anytime, or point the folder at your existing Obsidian vault — the data is entirely yours.

        ## Try it

        - Click ✏️ in the top-left to **create a note**
        - Write Markdown in the middle, toggle Edit / Split / Preview for live rendering
        - The pet on the right keeps you company — soon it'll help you polish, expand, and summarize

        > Go ahead and write something. The first note is yours.
        """,
    ]
}
