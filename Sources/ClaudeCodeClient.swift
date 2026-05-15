import Foundation

/// 流式解析时的可变状态 —— 用 class（引用类型）绕开 @Sendable 闭包不能 mutate var 的限制
private final class StreamState: @unchecked Sendable {
    var buffer = Data()
    var lastAssistantId: String?
    var lastAssistantText: String = ""
    /// 已发出 ToolStarted 通知的 tool_use_id 集合，避免 partial message 重复触发
    var startedToolIds: Set<String> = []
    /// 已发出 ToolEnded 通知的 tool_use_id 集合，避免重复
    var endedToolIds: Set<String> = []
}

/// 通过 spawn `claude -p` 子进程跟 Claude Code 对话。
/// 解析 stream-json (jsonl) 输出，逐 chunk 流式返回 assistant 文本。
final class ClaudeCodeClient: @unchecked Sendable {

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

    private func buildPrompt(messages: [ChatMessage]) -> String {
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
    func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let prompt = buildPrompt(messages: messages)
        let extraDirs = collectExtraAddDirs(from: messages)
        return streamRaw(prompt: prompt, extraAddDirs: extraDirs)
    }

    /// 底层 spawn claude -p prompt 的流式实现
    private func streamRaw(prompt: String, extraAddDirs: [String] = []) -> AsyncThrowingStream<String, Error> {
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
            // 用户在设置里指定了模型才传 --model；留空 = 沿用 claude CLI 自己的默认
            let userModel = (UserDefaults.standard.string(forKey: "claudeModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !userModel.isEmpty {
                args.append("--model")
                args.append(userModel)
            }
            // 每个拖入文档的父目录都追加进 --add-dir，让 Claude 的 Read 工具能读到
            // dedupe 已在 collectExtraAddDirs 里做了；跟 cacheDir/desktopDir 重复无害
            for dir in extraAddDirs {
                args.append("--add-dir")
                args.append(dir)
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)

            // 关键：去掉用户环境里那个无效的 ANTHROPIC_API_KEY，
            // 让 claude 走 keychain 里的 OAuth 凭据
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // 把流式解析的可变状态封装到一个引用类型里，
            // 避免 @Sendable 闭包捕获 var 引发的并发错误
            let state = StreamState()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
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
                        let isError = json["is_error"] as? Bool ?? false
                        if isError {
                            let result = json["result"] as? String ?? "未知错误"
                            continuation.finish(throwing: APIError.httpError(
                                statusCode: 0,
                                body: "Claude Code: \(result)"
                            ))
                        } else {
                            continuation.finish()
                        }

                    default:
                        break  // system / user / tool_use / tool_result 等暂时忽略
                    }
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                SubprocessRegistry.shared.unregister(proc)
                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.availableData
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.finish(throwing: APIError.httpError(
                        statusCode: Int(proc.terminationStatus),
                        body: errStr.isEmpty ? "claude 退出码 \(proc.terminationStatus)" : errStr
                    ))
                }
                // 正常退出已经在 result 事件里 finish 了
            }

            do {
                try process.run()
                SubprocessRegistry.shared.register(process)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // 取消请求时杀掉子进程
            continuation.onTermination = { @Sendable _ in
                if process.isRunning {
                    process.terminate()
                }
                SubprocessRegistry.shared.unregister(process)
            }
        }
    }
}
