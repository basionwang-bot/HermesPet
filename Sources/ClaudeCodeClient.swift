import Foundation

/// 流式解析时的可变状态 —— 用 class（引用类型）绕开 @Sendable 闭包不能 mutate var 的限制。
/// buffer / lastAssistant* / *ToolIds 只在 outPipe readabilityHandler（串行）里读写；
/// finished + 活动时间戳要被 watchdog / terminationHandler 跨队列访问，单独用锁保护。
private final class StreamState: @unchecked Sendable {
    var buffer = Data()
    var lastAssistantId: String?
    var lastAssistantText: String = ""
    /// 已发出 ToolStarted 通知的 tool_use_id 集合，避免 partial message 重复触发
    var startedToolIds: Set<String> = []
    /// 已发出 ToolEnded 通知的 tool_use_id 集合，避免重复
    var endedToolIds: Set<String> = []

    private let lock = NSLock()
    private var _finished = false
    private var _lastActivityAt = Date()

    /// 抢占式收尾：返回 true 表示「本次调用」抢到了收尾权（调用方去 finish continuation）；
    /// 已被别处收尾过则返回 false。保证一条流的 continuation 只 finish 一次。
    func claimFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _finished { return false }
        _finished = true
        return true
    }
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return _finished
    }
    /// 收到任何 stdout / stderr 字节就 touch —— watchdog 靠它判断 claude 是否「装死」
    func touch() {
        lock.lock(); _lastActivityAt = Date(); lock.unlock()
    }
    func idleSeconds() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastActivityAt)
    }
}

/// 通过 spawn `claude -p` 子进程跟 Claude Code 对话。
/// 解析 stream-json (jsonl) 输出，逐 chunk 流式返回 assistant 文本。
final class ClaudeCodeClient: @unchecked Sendable {

    /// 子进程「装死」看门狗阈值（秒）：claude 连续这么久没有任何输出就判定卡死、自动断流收尾。
    /// 故意比 APIClient 的 90s 大很多 —— Claude Code 会真的跑命令 / build，静默几分钟是正常的，不能误杀。
    private static let streamIdleTimeoutSeconds: TimeInterval = 300

    /// claude CLI 的可执行路径 —— **不再 fallback 到硬编码路径**。
    ///
    /// 路径解析顺序：
    /// 1. `CLIAvailability` 启动预热 / 用户在设置里"重新检测"时，把 zsh 找到的真实路径写到这里
    /// 2. 用户手动在 UserDefaults 里设过（极少数情况）
    /// 3. 都没有 → 返回 `""`，spawn 会失败 + checkAvailable 返回 false，UI 显示 "找不到 claude 命令"
    ///
    /// **为什么不再 fallback 到 `/Users/mac01/.local/bin/claude`**：硬编码的开发机路径在
    /// 任何其他人的电脑上都不存在，反而会让"明明装了 claude"的用户被误导成"app 找不到 CLI"
    private var executablePath: String {
        UserDefaults.standard.string(forKey: "claudeExecutablePath") ?? ""
    }

    private var workingDir: String {
        UserDefaults.standard.string(forKey: "claudeWorkingDir") ?? NSHomeDirectory()
    }

    // 注：不再用 claude 自己的 --continue 延续会话，
    // 改为每次都把 ChatViewModel 的完整 messages 作为 prompt 传过来 ——
    // 这样不论之前跟谁聊（Hermes / Claude），新一轮都能看到全部上下文，
    // 实现跨 AI 共享记忆。

    /// 检查 claude CLI 是否可用 —— 直接代理给 CLIAvailability，
    /// 它会用 `zsh -lic 'command -v claude'` 走用户真实 PATH（含 ~/.local/bin / brew / nvm 等）
    /// 并把找到的路径写回 UserDefaults["claudeExecutablePath"]
    func checkAvailable() async -> Bool {
        await CLIAvailability.claudeAvailable()
    }

    /// 兼容旧调用 —— 现在不维护 session 状态，no-op
    func resetSession() {}

    /// 把 ChatViewModel 的完整对话历史拼成 Claude 的 prompt：
    /// 让 Claude 知道前面跟其他 AI / 它自己说过什么，再回答最新一条用户问题。
    /// 如果消息里附带了图片，把图片写到临时目录，prompt 里用绝对路径引用 —— Claude 会自己 Read。
    /// 文档附件（拖入的 PDF / txt / md 等）直接传**用户真实路径**让 Claude 自己 Read，不复制不读内容。
    /// 客户端能力提示 —— 告诉 Claude 当前运行在 HermesPet 桌宠里，不支持 AskUserQuestion 工具卡片。
    /// 让它改用 Markdown 编号列表问问题，前端已有 ChoiceCard 自动渲染成可点击选项。
    /// 拼到 prompt 末尾，相对历史很短不算 token 负担
    private static let clientHints = """

[客户端约定 · 仅供你理解上下文，不要在回复里引用这段]
当前运行环境是 HermesPet 桌面客户端（纯文本聊天 UI）。**不支持 AskUserQuestion 工具的交互式选项卡片** —— 调用了用户也看不到。
如果你想让用户做选择，请直接在回复正文里用 Markdown 编号列表：
1. 选项 A 的简短描述
2. 选项 B 的简短描述
3. 选项 C 的简短描述
客户端会把这种编号列表自动渲染成可点击的选项卡片，用户点击后会作为新消息发给你。

【任务规划格式】
如果你识别到用户的输入是"今日任务清单 / 待办列表 / 我要做哪些事"这一类**任务规划意图**，
请把分解后的任务用如下 fence block 输出（客户端会渲染成可点击的任务卡片，每张卡片有 📌 Pin / 🤖 让 AI 做 / ✗ 跳过 三个按钮）：

```tasks
- title: 写本周周报
  desc: 总结本周完成的功能 + 下周计划
  mode: hermes
  eta: 30m
- title: 修 SwiftUI 列表渲染 bug
  desc: List 在 macOS 26 偶现错位，定位并修复
  mode: claudeCode
  eta: 60m
```

mode 字段从 [hermes / claudeCode / codex] 三选一 —— 选最适合该任务的引擎（写作翻译 → hermes，改文件跑命令 → claudeCode，生图 → codex）。
eta 是可选的预估时长（"30m" / "1h" / "5m"）。**只在确实是任务规划场景才用此格式，普通对话仍走自然语言回复**。

"""

    private func buildPrompt(messages: [ChatMessage], injectMemory: Bool = true) -> String {
        // v1.3 Phase 4c：把跨模式「共享记忆」拼在 prompt 最前，让 Claude Code 也接着懂用户。
        // Claude Code 不续 session（每次发全量历史，见上方注释），所以每次都带上记忆。
        // Phase 5-3：prompt 末尾拼「用界面语言回复」指令，让 Claude 回复跟随界面语言。
        // injectMemory=false：工作流 / 验收等隔离调用不带长期画像。
        let body = buildPromptBody(messages: messages) + "\n\n" + LocaleManager.aiReplyLanguageInstruction() + NotesWritingContextHolder.shared.promptSuffix()
        if injectMemory, let mem = UserMemoryStore.shared.injectionText() {
            return mem + "\n\n" + body
        }
        return body
    }

    private func buildPromptBody(messages: [ChatMessage]) -> String {
        let convo = messages.filter { $0.role == .user || $0.role == .assistant }
        guard let latest = convo.last, latest.role == .user else {
            return convo.map { "\($0.role == .user ? "用户" : "助手"): \($0.content)" }.joined(separator: "\n\n") + Self.clientHints
        }

        // 把最新这条用户消息附带的图片写到临时目录
        let imagePaths = saveImagesToTemp(latest.images)
        let docPaths = latest.documentPaths
        let history = convo.dropLast()

        // 单轮 + 没历史：精简 prompt
        if history.isEmpty {
            if imagePaths.isEmpty && docPaths.isEmpty {
                return latest.content + Self.clientHints
            }
            var p = latest.content
            if !imagePaths.isEmpty {
                p += "\n\n附带的图片（请用 Read 工具查看）：\n"
                for path in imagePaths { p += path + "\n" }
            }
            if !docPaths.isEmpty {
                p += "\n\n附带的文档（请用 Read 工具按这些绝对路径查看，需要的话再做后续操作）：\n"
                for path in docPaths { p += path + "\n" }
            }
            return p + Self.clientHints
        }

        // 多轮 + 有历史
        var lines: [String] = []
        lines.append("以下是我们之前的对话历史（其中的「助手」可能是 Hermes 也可能是其他 AI）。请基于这些上下文回答最后一个新问题，不要重复或总结历史。")
        lines.append("")
        lines.append("--- 历史开始 ---")
        for msg in history {
            let who = msg.role == .user ? "用户" : "助手"
            lines.append("【\(who)】\(msg.content)")
            lines.append("")
        }
        lines.append("--- 历史结束 ---")
        lines.append("")
        lines.append("现在用户问：")
        lines.append(latest.content)
        if !imagePaths.isEmpty {
            lines.append("")
            lines.append("用户附带了以下图片，请用 Read 工具查看：")
            for path in imagePaths { lines.append(path) }
        }
        if !docPaths.isEmpty {
            lines.append("")
            lines.append("用户附带了以下文档，请用 Read 工具按这些绝对路径查看：")
            for path in docPaths { lines.append(path) }
        }
        return lines.joined(separator: "\n") + Self.clientHints
    }

    /// 收集最近一条 user 消息附带文档的父目录（dedupe），用于 spawn claude 时额外的 --add-dir
    /// Claude Code 没把目录加进白名单时 Read 会被拦，所以必须把用户真实文件所在目录传进去
    private func collectExtraAddDirs(from messages: [ChatMessage]) -> [String] {
        guard let latest = messages.last(where: { $0.role == .user }) else { return [] }
        var seen = Set<String>()
        var dirs: [String] = []
        for path in latest.documentPaths {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, !seen.contains(parent) {
                seen.insert(parent)
                dirs.append(parent)
            }
        }
        return dirs
    }

    /// 从 tool_use 的 input 里提取最重要的一个参数，做成简短摘要（≤40 字）
    /// 用于灵动岛上"正在读 README.md"那一行的尾部
    fileprivate static func toolArgSummary(name: String, input: [String: Any]?) -> String {
        guard let input = input else { return "" }
        func short(_ s: String, max: Int = 40) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "…"
        }
        switch name {
        case "Read", "Write", "Edit", "MultiEdit":
            if let path = input["file_path"] as? String {
                return (path as NSString).lastPathComponent   // 只显示文件名
            }
        case "NotebookEdit":
            if let path = input["notebook_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "Bash":
            if let cmd = input["command"] as? String { return short(cmd) }
        case "BashOutput":
            return "查看输出"
        case "Grep":
            if let pat = input["pattern"] as? String { return "\"\(short(pat, max: 30))\"" }
        case "Glob":
            if let pat = input["pattern"] as? String { return pat }
        case "WebFetch":
            if let url = input["url"] as? String,
               let host = URL(string: url)?.host { return host }
        case "WebSearch":
            if let q = input["query"] as? String { return short(q) }
        case "TodoWrite":
            return ""
        case "Task":
            if let desc = input["description"] as? String { return short(desc) }
        default:
            break
        }
        return ""
    }

    /// 桌宠专用缓存目录。极端权限配置下 cachesDirectory 可能返回空 → 回退到系统临时目录。
    private static var hermesPetCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("HermesPet", isDirectory: true)
    }

    /// 把图片写到 ~/Library/Caches/HermesPet/，返回绝对路径数组
    private func saveImagesToTemp(_ images: [Data]) -> [String] {
        guard !images.isEmpty else { return [] }
        let cacheDir = Self.hermesPetCacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var paths: [String] = []
        let stamp = Int(Date().timeIntervalSince1970)
        for (i, data) in images.enumerated() {
            let url = cacheDir.appendingPathComponent("img-\(stamp)-\(i).png")
            do {
                try data.write(to: url)
                paths.append(url.path)
            } catch {
                // 写不进去就跳过这张图
            }
        }
        return paths
    }

    /// 流式问答 —— 把整个对话历史作为 prompt 一次性传给 Claude
    /// - Parameter onUsage: result 事件里拿到真实输入 token 数就回调（给上下文进度条用）
    /// - Parameter extraWorkingDir: 工作台「指挥/上学」传来的目标目录。非空时既加进 `--add-dir`
    ///   白名单（acceptEdits 下 Claude 才能读写它），又设为子进程 cwd —— 让 Claude 真在那个文件夹干活
    ///   （上学时 = `~/agent-forge`，指挥时 = 该 tab 打开的文件夹）。
    func streamCompletion(
        messages: [ChatMessage],
        injectMemory: Bool = true,
        extraWorkingDir: String? = nil,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onModel: (@Sendable (String) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil,
        onActivity: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = buildPrompt(messages: messages, injectMemory: injectMemory)
        var extraDirs = collectExtraAddDirs(from: messages)
        if let w = extraWorkingDir, !w.isEmpty, !extraDirs.contains(w) { extraDirs.append(w) }
        return streamRaw(prompt: prompt, extraAddDirs: extraDirs, cwdOverride: extraWorkingDir, onUsage: onUsage, onModel: onModel, onUsageDetail: onUsageDetail, onActivity: onActivity)
    }

    /// 工具动作 → 给用户看的实时活动标签(数据采集时显"🌐 抓 xxx",治"卡片看着像死的")。
    private static func claudeActivityLabel(_ name: String, _ arg: String) -> String {
        let icon: String
        switch name {
        case "WebFetch", "WebSearch":      icon = "🌐"
        case "Bash":                       icon = "⌨️"
        case "Read":                       icon = "📄"
        case "Write", "Edit", "MultiEdit": icon = "✏️"
        case "Grep", "Glob":               icon = "🔎"
        default:                           icon = "🔧"
        }
        return arg.isEmpty ? "\(icon) \(name)" : "\(icon) \(name) · \(arg)"
    }

    /// 底层 spawn claude -p prompt 的流式实现
    private func streamRaw(
        prompt: String,
        extraAddDirs: [String] = [],
        cwdOverride: String? = nil,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onModel: (@Sendable (String) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil,
        onActivity: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)

            // 不再用 --continue，每次新 session
            // --permission-mode acceptEdits：非交互模式下自动允许 Read/Write/Edit 工具，
            //   否则 Claude 看不到附带的图片，也写不出桌面文件
            // --add-dir：显式把 Cache（截图存放地）和 Desktop（用户常用保存路径）
            //   加进可访问目录白名单
            let cacheDir = Self.hermesPetCacheDir.path
            let desktopDir = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
            var args: [String] = [
                "-p", prompt,
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",                  // stream-json 必须配 --verbose
                "--no-session-persistence",   // 不保存 session 文件，桌宠自己管历史
                "--permission-mode", "acceptEdits",
                "--add-dir", cacheDir,
                "--add-dir", desktopDir
            ]
            // 每个拖入文档的父目录都追加进 --add-dir，让 Claude 的 Read 工具能读到
            // dedupe 已在 collectExtraAddDirs 里做了；跟 cacheDir/desktopDir 重复无害
            for dir in extraAddDirs {
                args.append("--add-dir")
                args.append(dir)
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: cwdOverride ?? workingDir)
            process.standardInput = Self.nullInput

            // 关键：去掉用户环境里那个无效的 ANTHROPIC_API_KEY，
            // 让 claude 走 keychain 里的 OAuth 凭据
            process.environment = CLIProcessEnvironment.make(
                executablePath: executablePath,
                removing: ["ANTHROPIC_API_KEY"]
            )

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let stderrBuffer = LockedData()

            // 把流式解析的可变状态封装到一个引用类型里，
            // 避免 @Sendable 闭包捕获 var 引发的并发错误
            let state = StreamState()

            // 幂等收尾：result 事件 / 进程退出 / watchdog 三方都可能想结束这条流，
            // 用 state.claimFinish() 抢占，保证 continuation 只 finish 一次。
            let finishStream: @Sendable (Error?) -> Void = { error in
                guard state.claimFinish() else { return }
                if let error { continuation.finish(throwing: error) }
                else { continuation.finish() }
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {   // EOF：置 nil，避免进程退出后 handler 空转
                    handle.readabilityHandler = nil
                    return
                }
                state.touch()
                stderrBuffer.append(data)
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {   // EOF：置 nil 防空转
                    handle.readabilityHandler = nil
                    return
                }
                state.touch()
                state.buffer.append(data)

                // 按换行切，每行一个 JSON 对象
                while let nlRange = state.buffer.range(of: Data([0x0a])) {
                    let lineData = state.buffer.subdata(in: 0..<nlRange.lowerBound)
                    state.buffer.removeSubrange(0..<nlRange.upperBound)

                    guard !lineData.isEmpty,
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let type = json["type"] as? String
                    else { continue }

                    switch type {
                    case "assistant":
                        guard let message = json["message"] as? [String: Any],
                              let messageId = message["id"] as? String,
                              let content = message["content"] as? [[String: Any]]
                        else { continue }

                        // 捕获真实模型 id（如 claude-opus-4-6）→ 给上下文窗口查 models.dev 用
                        if let model = message["model"] as? String, !model.isEmpty {
                            onModel?(model)
                        }

                        // 把所有 type=text 的块拼起来作为这条 message 当前的完整文本
                        let fullText = content.compactMap { item -> String? in
                            guard item["type"] as? String == "text" else { return nil }
                            return item["text"] as? String
                        }.joined()

                        if messageId == state.lastAssistantId {
                            // 同一条 message 的 partial update，yield 增量
                            if fullText.count > state.lastAssistantText.count {
                                let delta = String(fullText.dropFirst(state.lastAssistantText.count))
                                continuation.yield(delta)
                                state.lastAssistantText = fullText
                            }
                        } else {
                            // 新的 message（多轮 tool calling 时会有多条），用换行分隔
                            if state.lastAssistantId != nil, !fullText.isEmpty {
                                continuation.yield("\n\n")
                            }
                            state.lastAssistantId = messageId
                            state.lastAssistantText = fullText
                            if !fullText.isEmpty {
                                continuation.yield(fullText)
                            }
                        }

                        // 扫 content 数组里的 tool_use 项 —— 发 ToolStarted 通知（按 id 去重）
                        for item in content {
                            guard item["type"] as? String == "tool_use",
                                  let toolId = item["id"] as? String,
                                  let toolName = item["name"] as? String
                            else { continue }
                            if !state.startedToolIds.contains(toolId) {
                                state.startedToolIds.insert(toolId)
                                let input = item["input"] as? [String: Any]
                                let argSummary = Self.toolArgSummary(name: toolName, input: input)
                                // ⭐ 实时活动:把"正在用什么工具"吐给调用方(全量模式卡片显"🌐 抓 xxx")
                                onActivity?(Self.claudeActivityLabel(toolName, argSummary))
                                // Edit/Write/MultiEdit 都用 file_path —— 灵动岛 diff 摘要按它去重统计文件数
                                let filePath = (input?["file_path"] as? String) ?? ""
                                let payload: [String: Any] = [
                                    "id": toolId,
                                    "name": toolName,
                                    "arg": argSummary,
                                    "file_path": filePath
                                ]
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(
                                        name: .init("HermesPetToolStarted"),
                                        object: nil,
                                        userInfo: payload
                                    )
                                }
                            }
                        }

                    case "user":
                        // user message 里的 tool_result —— 发 ToolEnded 通知
                        guard let message = json["message"] as? [String: Any] else { continue }
                        let contentArr: [[String: Any]]
                        if let arr = message["content"] as? [[String: Any]] {
                            contentArr = arr
                        } else { continue }
                        for item in contentArr {
                            guard item["type"] as? String == "tool_result",
                                  let toolUseId = item["tool_use_id"] as? String
                            else { continue }
                            if state.startedToolIds.contains(toolUseId),
                               !state.endedToolIds.contains(toolUseId) {
                                state.endedToolIds.insert(toolUseId)
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(
                                        name: .init("HermesPetToolEnded"),
                                        object: nil,
                                        userInfo: ["id": toolUseId]
                                    )
                                }
                            }
                        }

                    case "result":
                        // 真实输入上下文 token = input + cache_read + cache_creation（给进度条用）
                        if let usage = json["usage"] as? [String: Any] {
                            let input = (usage["input_tokens"] as? Int) ?? 0
                            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                            let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                            let output = (usage["output_tokens"] as? Int) ?? 0
                            let total = input + cacheRead + cacheCreate
                            if total > 0 { onUsage?(total) }
                            if total + output > 0 {
                                onUsageDetail?(TokenUsageBreakdown(
                                    input: input, output: output,
                                    cacheRead: cacheRead, cacheCreate: cacheCreate))
                            }
                        }
                        let isError = json["is_error"] as? Bool ?? false
                        if isError {
                            let result = json["result"] as? String ?? "未知错误"
                            finishStream(APIError.httpError(
                                statusCode: 0,
                                body: "Claude Code: \(result)"
                            ))
                        } else {
                            finishStream(nil)
                        }

                    default:
                        break  // system / user / tool_use / tool_result 等暂时忽略
                    }
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                SubprocessRegistry.shared.unregister(proc)
                // ⚠️ 关键修复：进程已退出，但流可能还没 finish。
                //   - 退出码 ≠ 0：带 stderr 报错收尾（原有逻辑）
                //   - 退出码 = 0 却没等到 result 事件（claude 内部异常 / 输出被截断 / 最后一行
                //     没带换行符卡在 buffer 没解析）：以前这里什么都不做 → continuation 永不 finish
                //     → 聊天框永久转圈。现在兜底 finishStream(nil)，已 yield 的文本照常显示。
                if state.isFinished { return }
                if proc.terminationStatus != 0 {
                    var errData = stderrBuffer.data
                    errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    finishStream(APIError.httpError(
                        statusCode: Int(proc.terminationStatus),
                        body: errStr.isEmpty ? "claude 退出码 \(proc.terminationStatus)" : errStr
                    ))
                } else {
                    finishStream(nil)
                }
            }

            do {
                try process.run()
                SubprocessRegistry.shared.register(process)
            } catch {
                finishStream(error)
                return
            }

            // Watchdog：claude 连续 streamIdleTimeoutSeconds 秒没有任何 stdout/stderr 输出
            // → 判定「装死」（例如跑了个永不返回的命令、网络卡死、OAuth 卡住），杀进程 + 报错收尾，
            // 避免聊天框永久转圈。阈值比 HTTP 的 90s 宽松很多 —— Claude Code 跑命令/build 正常也会静默几分钟。
            let watchdog = Task { @Sendable in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if state.isFinished { return }
                    if state.idleSeconds() > Self.streamIdleTimeoutSeconds {
                        if process.isRunning { process.terminate() }
                        let mins = Int(Self.streamIdleTimeoutSeconds / 60)
                        finishStream(APIError.httpError(
                            statusCode: 0,
                            body: "Claude Code 约 \(mins) 分钟没有任何响应，已自动断开。可能是某个命令卡住了，请重试或把操作拆小一点。"
                        ))
                        return
                    }
                }
            }

            // 取消请求 / 流结束时：停掉 watchdog + 杀子进程
            continuation.onTermination = { @Sendable _ in
                watchdog.cancel()
                if process.isRunning {
                    process.terminate()
                }
                SubprocessRegistry.shared.unregister(process)
            }
        }
    }

    private static var nullInput: FileHandle? {
        FileHandle(forReadingAtPath: "/dev/null")
    }
}

/// Small thread-safe buffer for subprocess stderr.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
