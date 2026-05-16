import Foundation

/// 通过 spawn `codex exec --json` 子进程跟 OpenAI Codex CLI 对话。
/// 解析 JSONL 事件流，逐 agent_message 增量返回文本。
///
/// 图片捕获策略：
/// - spawn 前快照 `~/.codex/generated_images/` 当前所有图片文件
/// - spawn 后再次扫描，diff = 本次生成的图片
/// - stream 完成后通过 takeGeneratedImages() 给 ViewModel 消费，附加到 assistant 消息
final class CodexClient: @unchecked Sendable {

    /// codex CLI 的可执行路径 —— **不再 fallback 到硬编码路径**。
    /// 同 ClaudeCodeClient：由 CLIAvailability 探测后写到 UserDefaults；
    /// 找不到则返回 `""`，spawn 失败 → UI 显示 "找不到 codex 命令"
    private var executablePath: String {
        UserDefaults.standard.string(forKey: "codexExecutablePath") ?? ""
    }

    private var workingDir: String {
        UserDefaults.standard.string(forKey: "codexWorkingDir") ?? NSHomeDirectory()
    }

    private let imagesLock = NSLock()
    private var _pendingImages: [Data] = []
    private let sessionLock = NSLock()
    private static let sessionMapKey = "codexSessionIDsByConversationID"

    /// stream 完成后由 ViewModel 调用，消费本次生成的图片
    func takeGeneratedImages() -> [Data] {
        imagesLock.lock()
        defer { imagesLock.unlock() }
        let imgs = _pendingImages
        _pendingImages = []
        return imgs
    }

    /// 检查 codex CLI 是否可用 —— 走 CLIAvailability 统一探测
    func checkAvailable() async -> Bool {
        await CLIAvailability.codexAvailable()
    }

    /// 兼容旧接口（多 mode 共用 ChatViewModel.clearChat 调用）
    func resetSession() {}

    /// 清掉某个 HermesPet conversation 绑定的 Codex session。
    /// 用户清空/关闭对话后，后续再发应该是一个干净的新 Codex 会话。
    func resetSession(conversationID: String) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        var map = UserDefaults.standard.dictionary(forKey: Self.sessionMapKey) as? [String: String] ?? [:]
        map.removeValue(forKey: conversationID)
        UserDefaults.standard.set(map, forKey: Self.sessionMapKey)
    }

    /// 流式问答。
    ///
    /// Codex CLI 的首次 `exec` 会做 session/bootstrap，通常比较慢；之后同一个 session 用
    /// `codex exec resume <thread_id>` 会快很多。HermesPet 的每个 Conversation 绑定一个
    /// Codex thread_id：第一次把完整历史发给 Codex，拿到 `thread.started.thread_id` 后持久化；
    /// 后续只把最新用户输入发给 `resume`，不再每轮冷启动 + 重传全量历史。
    /// streamCompletion 主入口。
    /// - parameter suppressIslandUpdates: 画布串行生成图片时传 true，
    ///   内部 post `HermesPetToolStarted/Ended` 通知会被跳过，
    ///   避免画布任务跟主对话共用灵动岛进度状态机互相污染（曾导致并发画布卡住灵动岛）。
    ///   画布进度由 CanvasView toolbar 独立展示。
    func streamCompletion(messages: [ChatMessage],
                          conversationID: String? = nil,
                          suppressIslandUpdates: Bool = false) -> AsyncThrowingStream<String, Error> {
        let existingSessionID = sessionID(for: conversationID)
        let prompt = buildPrompt(messages: messages, isResume: existingSessionID != nil)
        let inputImages = collectInputImagePaths(from: messages)
        return streamRaw(
            prompt: prompt,
            imageFiles: inputImages,
            conversationID: conversationID,
            sessionID: existingSessionID,
            suppressIslandUpdates: suppressIslandUpdates
        )
    }

    /// 提取最近一条 user 消息附带的图片路径，写到临时目录后给 codex `-i` 参数用。
    /// 优先用 `imagePaths`（sendMessage 时已落盘到 ~/.hermespet/images/）；
    /// 兜底再把 `images` Data 写一份到 Caches，避免有些路径在 user message 创建后才丢的边缘场景
    private func collectInputImagePaths(from messages: [ChatMessage]) -> [String] {
        guard let latestUser = messages.last(where: { $0.role == .user }) else { return [] }
        if !latestUser.imagePaths.isEmpty {
            // 验证文件还在（防止用户清空后又重发）
            let existing = latestUser.imagePaths.filter {
                FileManager.default.fileExists(atPath: $0)
            }
            if existing.count == latestUser.imagePaths.count {
                return existing
            }
        }
        // Fallback：把 images Data 写到临时目录
        guard !latestUser.images.isEmpty else { return [] }
        let baseCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let cacheDir = baseCache.appendingPathComponent("HermesPet/codex-inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var paths: [String] = []
        for (i, data) in latestUser.images.enumerated() {
            let url = cacheDir.appendingPathComponent("in-\(stamp)-\(i).png")
            if (try? data.write(to: url)) != nil {
                paths.append(url.path)
            }
        }
        return paths
    }

    /// 把完整对话历史拼成单 prompt（codex exec 不支持原生多轮，靠 prompt 传上下文）。
    /// 文档附件（拖入的 PDF / txt / md 等）以**用户真实绝对路径**写在 prompt 末尾，让 Codex 用自己的 shell 工具读。
    /// 我们已开 --dangerously-bypass-approvals-and-sandbox，Codex 能读 cwd 之外任意路径。
    /// 客户端能力提示 —— 跟 ClaudeCodeClient 一样告诉 Codex 用 markdown 列表问选择题
    private static let clientHints = """

[客户端约定 · 仅供你理解上下文，不要在回复里引用这段]
当前运行环境是 HermesPet 桌面客户端（纯文本聊天 UI）。如果你想让用户做选择，请直接在回复正文里用 Markdown 编号列表：
1. 选项 A 的简短描述
2. 选项 B 的简短描述
客户端会把这种编号列表自动渲染成可点击的选项卡片，用户点击后会作为新消息发给你。

【任务规划格式】
如果识别到用户输入是任务规划意图（"今天要做哪些事 / 待办 / 帮我分解任务"），请用如下 fence block 输出：

```tasks
- title: 任务标题（短）
  desc: 一行描述
  mode: hermes        # 三选一 hermes / claudeCode / codex（按任务性质推荐合适引擎）
  eta: 30m            # 可选预估时长
```

客户端会渲染成可点击任务卡片，每张有 📌 Pin / 🤖 让 AI 做 / ✗ 跳过 按钮。**只在确实是任务规划场景才用，普通对话仍自然语言回复**。

"""

    private func buildPrompt(messages: [ChatMessage], isResume: Bool) -> String {
        let convo = messages.filter { $0.role == .user || $0.role == .assistant }
        guard let latest = convo.last, latest.role == .user else {
            return convo.map { "\($0.role == .user ? "用户" : "助手"): \($0.content)" }.joined(separator: "\n\n") + Self.clientHints
        }
        let docPaths = latest.documentPaths
        if isResume {
            return buildLatestTurnPrompt(latest: latest, docPaths: docPaths)
        }
        let history = convo.dropLast()
        if history.isEmpty {
            if docPaths.isEmpty { return latest.content + Self.clientHints }
            var p = latest.content
            p += "\n\n附带的文档（请用 shell 工具按这些绝对路径读取）：\n"
            for path in docPaths { p += path + "\n" }
            return p + Self.clientHints
        }
        var lines: [String] = []
        lines.append("以下是我们之前的对话历史。请基于上下文回答最后的新问题，不要重复或总结历史。")
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
        if !docPaths.isEmpty {
            lines.append("")
            lines.append("用户附带了以下文档，请用 shell 工具按这些绝对路径读取：")
            for path in docPaths { lines.append(path) }
        }
        return lines.joined(separator: "\n") + Self.clientHints
    }

    /// resume 模式下 Codex 已经有前文，只发最新一轮用户输入，避免每条消息都像新会话一样重跑。
    private func buildLatestTurnPrompt(latest: ChatMessage, docPaths: [String]) -> String {
        guard !docPaths.isEmpty else {
            return latest.content + Self.clientHints
        }
        var p = latest.content
        p += "\n\n用户附带了以下文档，请用 shell 工具按这些绝对路径读取：\n"
        for path in docPaths { p += path + "\n" }
        return p + Self.clientHints
    }

    /// 底层 spawn codex exec --json 的流式实现。
    /// imageFiles：通过 `-i <path>` 传给 codex 让它视觉识别（最后一条 user 消息的附图）
    private func streamRaw(prompt: String,
                           imageFiles: [String] = [],
                           conversationID: String?,
                           sessionID: String?,
                           suppressIslandUpdates: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // spawn 前快照 codex 的默认图片目录
            let codexImageDir = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".codex/generated_images")
            let beforeSnapshot = Self.scanImageFiles(in: codexImageDir)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            var args: [String]
            if let sessionID, !sessionID.isEmpty {
                args = [
                    "exec",
                    "resume",
                    "--json",
                    "--skip-git-repo-check",
                    "--dangerously-bypass-approvals-and-sandbox"
                ]
            } else {
                args = [
                    "exec",
                    "--json",
                    "--skip-git-repo-check",
                    "--dangerously-bypass-approvals-and-sandbox"
                ]
            }
            // 每张输入图加一个 -i <path>，让 codex 视觉识别
            for path in imageFiles {
                args.append("-i")
                args.append(path)
            }
            // 关键：`-i <FILE>...` 是 clap 的 greedy multi-value flag，会一直吞后面的参数
            // 直到下一个 flag。所以传图后必须用 `--` 显式终止 flag 解析，再放 prompt positional，
            // 否则 prompt 会被 -i 吞走，codex 转去等 stdin 然后报 "No prompt provided via stdin"
            if !imageFiles.isEmpty {
                args.append("--")
            }
            if let sessionID, !sessionID.isEmpty {
                args.append(sessionID)
            }
            args.append(prompt)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
            process.standardInput = Self.nullInput
            // 透传环境变量并补齐 GUI App 缺失的 PATH；codex 自己读 ~/.codex/auth 凭据
            process.environment = CLIProcessEnvironment.make(executablePath: executablePath)

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let stderrBuffer = CodexLockedData()
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderrBuffer.append(data)
                }
            }

            let state = StreamState()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                state.buffer.append(data)

                while let nlRange = state.buffer.range(of: Data([0x0a])) {
                    let lineData = state.buffer.subdata(in: 0..<nlRange.lowerBound)
                    state.buffer.removeSubrange(0..<nlRange.upperBound)

                    guard !lineData.isEmpty,
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let type = json["type"] as? String
                    else { continue }

                    // Codex JSONL 事件类型：
                    //   thread.started / thread.completed
                    //   turn.started / turn.completed
                    //   item.started / item.completed
                    // 关心：
                    // - item.completed 且 item.type == "agent_message"  → assistant 文本
                    // - item.started / item.completed 且 item.type != "agent_message"  → 工具事件
                    //   （Codex 常见 item.type: command_execution / file_change / web_search ...）
                    if type == "thread.started",
                       let conversationID,
                       let threadID = json["thread_id"] as? String,
                       !threadID.isEmpty {
                        self.setSessionID(threadID, for: conversationID)
                    } else if type == "item.completed",
                       let item = json["item"] as? [String: Any],
                       let itemType = item["type"] as? String,
                       itemType == "agent_message",
                       let text = item["text"] as? String,
                       !text.isEmpty {
                        // 多段 agent_message 用换行拼接
                        if !state.lastEmittedText.isEmpty {
                            continuation.yield("\n\n")
                        }
                        continuation.yield(text)
                        state.lastEmittedText += text
                    } else if type == "item.started",
                              let item = json["item"] as? [String: Any],
                              let itemType = item["type"] as? String,
                              itemType != "agent_message",
                              itemType != "reasoning"  // Codex 的"内心独白"事件，不当工具
                    {
                        // 把字典字段抽成基础类型，避免 [String: Any] 跨闭包触发 Swift 6 sending 检查
                        let toolId = (item["id"] as? String) ?? UUID().uuidString
                        let filePath = (item["path"] as? String) ?? ""
                        let arg = Self.codexArgSummary(
                            command: item["command"] as? String,
                            path: item["path"] as? String,
                            query: item["query"] as? String,
                            url: item["url"] as? String,
                            name: item["name"] as? String
                        )
                        if !state.startedToolIds.contains(toolId) {
                            state.startedToolIds.insert(toolId)
                            if !suppressIslandUpdates {
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(
                                        name: .init("HermesPetToolStarted"),
                                        object: nil,
                                        userInfo: [
                                            "id": toolId,
                                            "name": itemType,
                                            "arg": arg,
                                            "file_path": filePath
                                        ]
                                    )
                                }
                            }
                        }
                    } else if type == "item.completed",
                              let item = json["item"] as? [String: Any],
                              let itemType = item["type"] as? String,
                              itemType != "agent_message",
                              itemType != "reasoning"
                    {
                        let toolId = (item["id"] as? String) ?? ""
                        if !toolId.isEmpty,
                           state.startedToolIds.contains(toolId),
                           !state.endedToolIds.contains(toolId) {
                            state.endedToolIds.insert(toolId)
                            if !suppressIslandUpdates {
                                DispatchQueue.main.async {
                                    NotificationCenter.default.post(
                                        name: .init("HermesPetToolEnded"),
                                        object: nil,
                                        userInfo: ["id": toolId]
                                    )
                                }
                            }
                        }
                    }
                }
            }

            process.terminationHandler = { [self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                SubprocessRegistry.shared.unregister(proc)

                // 扫新增的图片
                let afterSnapshot = Self.scanImageFiles(in: codexImageDir)
                let newPaths = afterSnapshot.subtracting(beforeSnapshot)
                let pngs: [Data] = newPaths.compactMap { path in
                    try? Data(contentsOf: URL(fileURLWithPath: path))
                }
                if !pngs.isEmpty {
                    self.imagesLock.lock()
                    self._pendingImages.append(contentsOf: pngs)
                    self.imagesLock.unlock()
                }

                if proc.terminationStatus != 0 {
                    var err = stderrBuffer.data
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let errStr = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Codex 进程异常退出"
                    continuation.finish(throwing: APIError.httpError(
                        statusCode: 0,
                        body: "Codex: \(errStr)"
                    ))
                } else {
                    continuation.finish()
                }
            }

            do {
                try process.run()
                SubprocessRegistry.shared.register(process)
            } catch {
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
                SubprocessRegistry.shared.unregister(process)
            }
        }
    }

    private func sessionID(for conversationID: String?) -> String? {
        guard let conversationID, !conversationID.isEmpty else { return nil }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let map = UserDefaults.standard.dictionary(forKey: Self.sessionMapKey) as? [String: String] ?? [:]
        return map[conversationID]
    }

    private func setSessionID(_ sessionID: String, for conversationID: String) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        var map = UserDefaults.standard.dictionary(forKey: Self.sessionMapKey) as? [String: String] ?? [:]
        map[conversationID] = sessionID
        UserDefaults.standard.set(map, forKey: Self.sessionMapKey)
    }

    private static var nullInput: FileHandle? {
        FileHandle(forReadingAtPath: "/dev/null")
    }

    /// 从 Codex 事件 item 的几个常见字段里抽最有用的一个做简短摘要（≤40 字）。
    /// 参数全是基础类型（String?）—— Swift 6 严格并发下不让把 [String: Any] 跨闭包传，
    /// 调用方先 as? String 把字段抽出来再传进来
    fileprivate static func codexArgSummary(
        command: String?,
        path: String?,
        query: String?,
        url: String?,
        name: String?
    ) -> String {
        func short(_ s: String, max: Int = 40) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "…"
        }
        if let cmd = command, !cmd.isEmpty { return short(cmd) }
        if let p = path, !p.isEmpty {
            return (p as NSString).lastPathComponent
        }
        if let q = query, !q.isEmpty { return short(q) }
        if let u = url, let host = URL(string: u)?.host { return host }
        if let n = name, !n.isEmpty { return short(n) }
        return ""
    }

    /// 递归扫描目录里所有图片文件（绝对路径）。用于做 spawn 前后的 diff
    private static func scanImageFiles(in dir: String) -> Set<String> {
        let url = URL(fileURLWithPath: dir)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: Set<String> = []
        for case let fileURL as URL in enumerator {
            let lower = fileURL.path.lowercased()
            if lower.hasSuffix(".png") || lower.hasSuffix(".jpg")
                || lower.hasSuffix(".jpeg") || lower.hasSuffix(".webp") {
                paths.insert(fileURL.path)
            }
        }
        return paths
    }
}

/// 流式解析时的可变状态 —— 避免 @Sendable 闭包不能 mutate var
private final class StreamState: @unchecked Sendable {
    var buffer = Data()
    var lastEmittedText: String = ""
    /// 已发出 HermesPetToolStarted 通知的 tool id 集合（按 item.id 去重）
    var startedToolIds: Set<String> = []
    /// 已发出 HermesPetToolEnded 通知的 tool id 集合
    var endedToolIds: Set<String> = []
}

private final class CodexLockedData: @unchecked Sendable {
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
