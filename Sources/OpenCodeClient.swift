import Foundation

/// **在线 AI（directAPI mode）的客户端**，走 bundled opencode agent runtime。
///
/// 架构：通过 `opencode run --attach <serverURL> --format json` 连接
/// `OpenCodeServerManager` 起的 headless server，每个 HermesPet 对话
/// 独立绑定一个 opencode sessionID + working directory。
///
/// 单进程 server 多对话隔离，靠 server 自带的 multi-tenancy（每个 `--dir`
/// 对应一个 instance + 独立 event bus / file watcher / agent 配置）。
///
/// **事件流格式**（实测 v1.15.1）：每行一个 JSON object：
/// - `{"type":"step_start","sessionID":"ses_xxx","part":{...}}` — agent 开始一个 step
/// - `{"type":"text","part":{"id":"prt_xxx","text":"完整 chunk","time":{...}}}` — 文本块（**非 delta**，一次性给）
/// - `{"type":"tool_use","part":{"tool":"read","state":{"status":"completed","input":{...},"output":"..."}}}` — 工具调用
/// - `{"type":"step_finish","part":{"tokens":{...},"cost":0}}` — step 结束
///
/// **工具事件透出**：tool_use → `HermesPetToolStarted/Ended` 通知 → 灵动岛 + 桌宠精灵
final class OpenCodeClient: @unchecked Sendable {
    static let shared = OpenCodeClient()

    private let lock = NSLock()
    /// `conversationID -> opencode sessionID` 映射。第一次发消息从 JSON event 抓
    /// sessionID 存进来；后续 spawn 时带 `--session <id>` 让对话历史在 opencode 端延续
    private var sessionIDByConversation: [String: String] = [:]
    /// `conversationID -> 上次用的 model ID`。opencode session 跨 model 不兼容
    /// （用 free model 创建的 session 切到 deepseek/openai 会只输出 step_start 就空响应）
    /// model 变化时自动清掉 sessionID，让 opencode 创建新 session
    private var lastModelByConversation: [String: String] = [:]

    private init() {}

    // MARK: - Public API

    /// 流式问答。接口跟 ClaudeCodeClient / CodexClient / APIClient 一致，
    /// 方便 ChatViewModel 按 mode 路由调用。
    /// - Parameters:
    ///   - messages: 对话历史（实际只取最后一条 user message —— opencode 用 session 管历史）
    ///   - conversationID: HermesPet 对话 ID，用于 directory 隔离 + session 映射
    ///   - modelOverride: 显式指定 model（格式 `provider/model`），nil 时按 ProviderPreset 推断
    func streamCompletion(
        messages: [ChatMessage],
        conversationID: String,
        modelOverride: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task.detached { @Sendable [weak self] in
                guard let self else {
                    continuation.finish(throwing: OpenCodeClientError.clientDeallocated)
                    return
                }
                await self.runStream(
                    messages: messages,
                    conversationID: conversationID,
                    modelOverride: modelOverride,
                    continuation: continuation
                )
            }
        }
    }

    /// 删除某对话绑定的 opencode session（HermesPet 删对话时调用，避免 server 端堆积）
    func clearSession(for conversationID: String) {
        lock.lock()
        sessionIDByConversation.removeValue(forKey: conversationID)
        lastModelByConversation.removeValue(forKey: conversationID)
        lock.unlock()
    }

    // MARK: - 主流程

    private func runStream(
        messages: [ChatMessage],
        conversationID: String,
        modelOverride: String?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        // 1. writable 二进制（不依赖 OpenCodeServerManager.isReady：spawn run 是独立进程，
        // 通过 SQLite db 跟 server 共享会话状态，不需要 attach）
        let binary = Self.writableBinaryURL()
        guard FileManager.default.fileExists(atPath: binary.path) else {
            continuation.finish(throwing: OpenCodeClientError.binaryMissing)
            return
        }

        // 等 ReasoningProxy ready（最多 1s）。proxy 在 App 启动时拉起，通常几十毫秒就 ready，
        // 但第一次用户立刻发消息可能撞上启动窗口期。proxy 没 ready 时 OpenCodeConfigGenerator
        // 会用原始 provider baseURL（绕过 proxy），那次请求 reasoning 模型可能"没响应"，
        // 但后续就用 proxy 了
        for _ in 0..<10 {
            if ReasoningProxy.shared.isReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // 2. 对话独立目录（multi-tenancy 隔离）+ 写 opencode.json 让 opencode
        // 看到用户配的 DeepSeek/GLM/Kimi/MiniMax/OpenAI API Key 和 baseURL
        let dir = Self.conversationDirectory(for: conversationID)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir),
            withIntermediateDirectories: true
        )
        OpenCodeConfigGenerator.ensureConfig(in: dir)

        // 3. 拼 prompt + 收集附件（最后一条 user message 的 images / documentPaths）
        let userMsg = messages.last(where: { $0.role == .user })
        let prompt = userMsg?.content ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.finish()
            return
        }
        // opencode `-f <path>` 给消息附加文件：图片走 vision、文档让 model 用 Read 工具读
        // imagePaths（持久化到 ~/.hermespet/images/）+ documentPaths（用户磁盘绝对路径）都直接附
        // 没 path 但有 Data 的图片，先写 temp 文件再附
        var attachedFiles: [String] = []
        attachedFiles.append(contentsOf: userMsg?.documentPaths ?? [])
        let userImagePaths = userMsg?.imagePaths ?? []
        attachedFiles.append(contentsOf: userImagePaths)
        let userImages = userMsg?.images ?? []
        for (idx, imgData) in userImages.enumerated() where idx >= userImagePaths.count {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermespet-img-\(UUID().uuidString).png")
            if (try? imgData.write(to: tmpURL)) != nil {
                attachedFiles.append(tmpURL.path)
            }
        }

        let model = modelOverride ?? Self.currentModelID()
        // **关键**：opencode session 绑定到 provider/model。用户切换了 provider
        // （比如从 free model 切到 DeepSeek 真 key），上次的 session 在新 model 下
        // 会"空响应"（只输出 step_start 就退）。检测 model 变化 → 清 stored sessionID
        // → opencode 创建新 session
        let sessionID = invalidateSessionIfModelChanged(
            conversationID: conversationID,
            newModel: model
        )

        // 4. 构造 args
        // 关键决策：**不用 `--attach`**。attach 模式下 stdout 不输出 JSON 流（事件全走
        // server 的 /global/event SSE，无法被 spawn 客户端 stdout 捕获）。直接 spawn 独立
        // run 进程，通过 `~/.local/share/opencode/opencode.db` SQLite WAL 跟 server 共享
        // 会话状态。Phase 2 切到 HTTP API 时再用 server。
        var args: [String] = [
            "run",
            "--format", "json",
            "--model", model,
            "--dir", dir,
            "--dangerously-skip-permissions",   // build agent 完整权限（用户决定）
        ]
        if let sid = sessionID {
            args.append(contentsOf: ["--session", sid])
        }
        // 附件：每个 -f 跟一个路径，opencode 支持多个 -f。
        // **关键坑（CLAUDE.md 决策 #8）**：`-f` 在 yargs 里是 array flag，会 greedy 吞掉
        // 后续所有 positional 参数（用户的 prompt 会被当成 file path → "File not found: 这是什么？"）。
        // 必须用 `--` 显式终止 array flag 解析，prompt 才能被识别为 positional
        for file in attachedFiles {
            args.append(contentsOf: ["-f", file])
        }
        if !attachedFiles.isEmpty {
            args.append("--")
        }
        args.append(prompt)

        // 6. spawn process
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        proc.environment = CLIProcessEnvironment.make(executablePath: binary.path)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        // 7. stdout 按行 JSON 解析；readabilityHandler 检测 EOF 时主动 finish。
        //
        // **关键 Unix pipe 坑**：Swift `Pipe` 父子进程都持有 fileHandleForWriting fd。
        // Process 把 writing end dup 给子进程，但**父进程自己也持有**一份。
        // 不显式关闭的话，子进程退出后 pipe 仍有 writer (父进程) → EOF 永远不传播
        // → readDataToEndOfFile() 永远 hang → terminationHandler 拖到永远 →
        // "(没有响应)"。
        //
        // 解决：① spawn 后立刻 close 父进程的 writing end（见 step 10）
        //       ② readabilityHandler 拿到空 data 视为 EOF，主动 finish stream
        //       ③ terminationHandler 退到兜底（仅在 readabilityHandler 没正常 EOF 时收尾）
        let buffer = LineBuffer()
        let stderrBuffer = LineBuffer()
        let stdoutCounter = ByteCounter()
        let typeCounter = EventTypeCounter()
        let streamDone = AtomicFlag()   // 防 EOF + terminationHandler 重复 finish
        let convID = conversationID

        // ⚠️ closure 跨多 callback 引用 self，避免重复定义；用 @Sendable
        let promptForLog = prompt   // capture 给 log 用
        let finishStream: @Sendable () -> Void = { [weak self] in
            guard streamDone.setOnce() else { return }
            // 解析最后残留行
            if let self {
                while let line = buffer.takeLine() {
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }
                    if let t = json["type"] as? String { typeCounter.bump(t) }
                    let yielded = self.handleEvent(json, conversationID: convID, continuation: continuation)
                    if yielded { typeCounter.markTextYielded() }
                }
            }
            let stdoutBytes = stdoutCounter.value
            let stderrText = stderrBuffer.drainAll()
            let eventSummary = typeCounter.summary.isEmpty ? "(no events)" : typeCounter.summary
            // 直接写 stderr，bypass macOS 26 对 NSLog 的压制，让 `log show` / Console 都能看到
            let logLine = "[OpenCode] finish prompt=\"\(promptForLog.prefix(60))\" stdout_bytes=\(stdoutBytes) events=[\(eventSummary)] stderr=\(stderrText.isEmpty ? "(empty)" : String(stderrText.prefix(400)))\n"
            FileHandle.standardError.write(logLine.data(using: .utf8) ?? Data())
            // 把诊断也写到 ~/.hermespet/opencode-debug.log 文件，方便事后翻
            let home = NSHomeDirectory()
            let logPath = "\(home)/.hermespet/opencode-debug.log"
            let ts = ISO8601DateFormatter().string(from: Date())
            let fileLine = "[\(ts)] \(logLine)"
            if let logData = fileLine.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(logData)
                    try? fh.close()
                } else {
                    try? logData.write(to: URL(fileURLWithPath: logPath))
                }
            }
            if stdoutBytes == 0 {
                let detail = stderrText.isEmpty
                    ? "opencode 没有任何输出（模型不可用或网络不通）"
                    : "opencode 报错: \(stderrText.prefix(300))"
                continuation.finish(throwing: OpenCodeClientError.runtimeFailure(detail))
            } else if !typeCounter.didYieldText {
                // stdout 非空（11906 字节那种）但 model 一句正文都没产出 ——
                // 通常是 reasoning 阶段被 disconnect / context 太长被模型空回 / tool 调用后没回正文。
                // 自动失效该对话的 session（让用户「重发」时重开 session，避开污染状态）
                if let self {
                    self.clearSession(for: convID)
                }
                let hint = "模型没产出正文（只跑了 \(eventSummary)）。已自动重置对话上下文，可以直接「重发」。"
                continuation.finish(throwing: OpenCodeClientError.runtimeFailure(hint))
            } else {
                continuation.finish()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF（父进程关 writing end 后，子进程 stdout 关闭就会到这里）
                handle.readabilityHandler = nil
                finishStream()
                return
            }
            stdoutCounter.add(data.count)
            buffer.append(data)
            while let line = buffer.takeLine() {
                guard let self,
                      !line.isEmpty,
                      let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                if let t = json["type"] as? String { typeCounter.bump(t) }
                let yielded = self.handleEvent(json, conversationID: convID, continuation: continuation)
                if yielded { typeCounter.markTextYielded() }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
        }

        // 8. terminationHandler 退到兜底：unregister + 50ms 后兜底 finish（防 EOF 没触发）
        // 不再调 readDataToEndOfFile（会 hang！）
        proc.terminationHandler = { p in
            SubprocessRegistry.shared.unregister(p)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                finishStream()   // 已 finish 过会被 setOnce 短路
            }
            let success = p.terminationStatus == 0
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .init("HermesPetTaskFinished"),
                    object: nil,
                    userInfo: ["success": success]
                )
            }
        }

        // 9. 用户取消 → terminate 子进程
        continuation.onTermination = { _ in
            if proc.isRunning { proc.terminate() }
        }

        // 10. run + **关键：关闭父进程持有的 pipe writing end**
        do {
            try proc.run()
            SubprocessRegistry.shared.register(proc)
            // Unix 经典操作：父进程关闭自己的 writing fd 让 pipe 在子进程退出时能 EOF
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .init("HermesPetTaskStarted"),
                    object: nil
                )
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// 等 OpenCodeServerManager.isReady 变 true（轮询 200ms 一次）
    private func waitForServerReady(timeoutSeconds: Int) async -> Bool {
        let maxTicks = timeoutSeconds * 5
        for _ in 0..<maxTicks {
            if OpenCodeServerManager.shared.isReady { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return OpenCodeServerManager.shared.isReady
    }

    // MARK: - JSON Event 派发

    /// 解析单个 JSON event，按 `type` 派发：
    /// - `text` 直接 yield 给 continuation（流式累积渲染）
    /// - `tool_use` 转换成 HermesPetToolStarted/Ended 通知 → 灵动岛工具卡 + 桌宠精灵
    /// - `step_start` 抓 sessionID 存映射
    ///
    /// 返回值：是否 yield 过文字（用于上层判断 stdout 非空但模型没产出正文）
    @discardableResult
    private func handleEvent(
        _ event: [String: Any],
        conversationID: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> Bool {
        // 抓 sessionID（首次出现时存入映射）
        if let sid = event["sessionID"] as? String, !sid.isEmpty {
            stashSessionID(sid, for: conversationID)
        }

        guard let type = event["type"] as? String else { return false }
        let part = event["part"] as? [String: Any]

        switch type {
        case "text", "assistant_text", "assistant_message", "text_delta", "message":
            // 主路径 + 兜底新格式：未来 opencode 可能改成 assistant_text / text_delta 等命名
            if let text = part?["text"] as? String, !text.isEmpty {
                continuation.yield(text); return true
            } else if let content = part?["content"] as? String, !content.isEmpty {
                continuation.yield(content); return true
            } else if let delta = part?["delta"] as? String, !delta.isEmpty {
                continuation.yield(delta); return true
            }
            return false

        case "tool_use":
            handleToolEvent(part: part)
            return false

        default:
            // 未知 type 兜底：如果 part 里有 text/content 字段也尝试当文本输出，
            // 避免 opencode 改格式后用户直接显示「没有响应」
            if let text = part?["text"] as? String, !text.isEmpty {
                continuation.yield(text); return true
            }
            return false
        }
    }

    private func handleToolEvent(part: [String: Any]?) {
        guard let p = part,
              let toolName = p["tool"] as? String,
              let state = p["state"] as? [String: Any] else { return }

        let status = state["status"] as? String ?? ""
        let input = state["input"] as? [String: Any] ?? [:]

        // 抽 filePath / path / command / url 作为 arg 摘要
        let filePath = (input["filePath"] as? String)
            ?? (input["path"] as? String)
            ?? (input["file"] as? String)
        let command = input["command"] as? String
        let url = input["url"] as? String
        let query = input["query"] as? String

        let argSummary: String = {
            if let fp = filePath { return (fp as NSString).lastPathComponent }
            if let cmd = command { return String(cmd.prefix(40)) }
            if let u = url { return u }
            if let q = query { return String(q.prefix(40)) }
            return ""
        }()

        let mappedName = Self.mapToHermesPetToolName(toolName)
        // 所有通知 post 必须主线程派发：HermesPet 内不少 observer（PillView /
        // ModeSprite / AppDelegate.handleTaskFinishedSound）是 @MainActor 隔离，
        // 后台线程直接 post 会 SIGTRAP（CLAUDE.md 决策 #4）

        switch status {
        case "running", "started":
            var info: [String: Any] = ["name": mappedName, "arg": argSummary]
            if let fp = filePath, !fp.isEmpty {
                info["file_path"] = fp
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .init("HermesPetToolStarted"),
                    object: nil,
                    userInfo: info
                )
            }

        case "completed":
            var info: [String: Any] = ["name": mappedName]
            if let fp = filePath, !fp.isEmpty {
                info["file_path"] = fp
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .init("HermesPetToolEnded"),
                    object: nil,
                    userInfo: info
                )
            }

        default:
            break
        }
    }

    // MARK: - Mapping

    /// opencode 工具名 → 现有 ToolKind 兼容名（让 PillView ToolKind.from 能识别）
    private static func mapToHermesPetToolName(_ openCodeTool: String) -> String {
        switch openCodeTool.lowercased() {
        case "read", "filesystem_read", "list_files": return "Read"
        case "write", "filesystem_write":              return "Write"
        case "edit", "filesystem_edit", "multiedit":   return "Edit"
        case "bash", "shell", "command_execution":     return "Bash"
        case "search", "grep", "ripgrep", "glob":      return "Search"
        case "webfetch", "web_fetch", "fetch_url":     return "WebFetch"
        case "task", "subagent":                       return "Task"
        case "todo", "todowrite":                      return "Todo"
        default:
            // 默认首字母大写 —— 让 ToolKind.from 走 fallback
            return openCodeTool.prefix(1).uppercased() + openCodeTool.dropFirst()
        }
    }

    // MARK: - Paths & Config

    private static func writableBinaryURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return appSupport.appendingPathComponent("HermesPet/bin/opencode")
    }

    /// 每个对话独立的工作目录 —— 让 opencode multi-tenancy 把不同对话隔离开
    private static func conversationDirectory(for conversationID: String) -> String {
        let home = NSHomeDirectory()
        let safe = conversationID.replacingOccurrences(of: "/", with: "_")
        return "\(home)/Library/Application Support/HermesPet/conversations/\(safe)"
    }

    /// 当前 model ID（`provider/model` 格式）—— 走 `OpenCodeConfigGenerator`：
    /// - 用户没配 API Key → 默认 opencode 内置 free 模型
    /// - 配了 key → 按 `directAPIProviderID` + `DirectResponsePreference` 推
    /// - 自定义 provider → 用 `directAPIModel`
    private static func currentModelID() -> String {
        return OpenCodeConfigGenerator.currentModelID()
    }

    // MARK: - Session ID 映射（线程安全）

    private func stashSessionID(_ sid: String, for conversationID: String) {
        lock.lock()
        if sessionIDByConversation[conversationID] == nil {
            sessionIDByConversation[conversationID] = sid
        }
        lock.unlock()
    }

    private func readSessionID(for conversationID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionIDByConversation[conversationID]
    }

    /// 检查当前 model 跟上次是否变了；变了就清掉 stored sessionID（opencode session 跨 model 不兼容）
    /// 返回应该传给本次 spawn 的 sessionID（nil 表示让 opencode 新建 session）
    private func invalidateSessionIfModelChanged(conversationID: String, newModel: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let lastModel = lastModelByConversation[conversationID]
        if lastModel != newModel {
            // model 变了 → 清 session，让 opencode 新建一个
            sessionIDByConversation.removeValue(forKey: conversationID)
            lastModelByConversation[conversationID] = newModel
            return nil
        }
        return sessionIDByConversation[conversationID]
    }
}

// MARK: - 错误

enum OpenCodeClientError: LocalizedError {
    case serverNotReady
    case binaryMissing
    case clientDeallocated
    case runtimeFailure(String)

    var errorDescription: String? {
        switch self {
        case .serverNotReady:    return "opencode server 还没准备好，请稍后重试"
        case .binaryMissing:     return "找不到 opencode 二进制，请重新安装 HermesPet"
        case .clientDeallocated: return "OpenCodeClient 已释放"
        case .runtimeFailure(let detail): return detail
        }
    }
}

// MARK: - 辅助：字节计数器 + LineBuffer 全 drain

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    func add(_ n: Int) {
        lock.lock(); _value += n; lock.unlock()
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

/// 按 event type 统计出现次数。诊断「stdout 非空但没拿到 text」问题用：
/// 把整次 spawn 的 event type 序列汇总写到 opencode-debug.log，
/// 出现「(没有响应)」时可以一眼看出是不是 model 只跑了 tool_use / step_finish 没 text
final class EventTypeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var _textYielded = false
    func bump(_ type: String) {
        lock.lock(); counts[type, default: 0] += 1; lock.unlock()
    }
    /// handleEvent 实际 yield 了文字（含 fallback 抽 part.text/.content/.delta）后调
    func markTextYielded() {
        lock.lock(); _textYielded = true; lock.unlock()
    }
    /// 这一次 spawn 是否真的产出过正文 —— 用于诊断「stdout 非空但内容空」
    var didYieldText: Bool {
        lock.lock(); defer { lock.unlock() }
        return _textYielded
    }
    /// `text×3, tool_use×2, step_start×4` 这种紧凑格式
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
    }
}

/// 一次性 flag。`setOnce()` 第一次调用返回 true 并把 flag 标 true；
/// 第二次起返回 false。线程安全。
/// 用于防 readabilityHandler EOF + terminationHandler 兜底都触发 finishStream 时的重复调用
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _set = false
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _set { return false }
        _set = true
        return true
    }
}

extension LineBuffer {
    /// 把 buffer 里剩余所有字节当 UTF-8 字符串返回（不要求完整行），用于 stderr 诊断 dump
    func drainAll() -> String {
        var parts: [String] = []
        while let line = takeLine() { parts.append(line) }
        let rest = takeRest()
        if !rest.isEmpty { parts.append(rest) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - 行缓冲（按 \n 切分 JSON event）

/// stdout 数据可能跨多个 read 才凑齐一行 JSON。LineBuffer 累积字节流，
/// 每次 takeLine 返回一行（去掉 \n），调用方循环 take 直到 nil
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func takeLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let idx = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: 0..<idx)
        buffer.removeSubrange(0...idx)
        return String(data: lineData, encoding: .utf8)
    }

    /// 拿走 buffer 里残留的所有字节（不要求 \n 结尾），用 UTF-8 解码。
    /// 主要给 stderr 诊断 dump 用，调用后 buffer 清空
    func takeRest() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return "" }
        let rest = String(data: buffer, encoding: .utf8) ?? ""
        buffer.removeAll()
        return rest
    }
}
