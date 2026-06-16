import Foundation

/// 通过 spawn 本机已安装的 `qwen` CLI（Qwen Code，阿里通义千问命令行 agent）子进程对话。
/// 解析 `-o stream-json` 的 JSONL 事件流，逐 assistant 文本块增量返回。
///
/// **零配置**（这是相对 Hermes / OpenClaw / 直连 HTTP 配置最省的一条路）：
/// 复用用户在终端登录过的 qwen 认证（qwen 自己管在 ~/.qwen），HermesPet **不需要任何 URL / Key / 模型配置**——
/// 只要 `qwen` 在 PATH 里（由 `CLIAvailability` 探测）。跟 Claude Code / Codex 同款体验。
///
/// 子进程后端（`isLocalHeavy = true`）：每路 spawn 真实 node 进程，舰队里按并发闸限流（见 `FleetBackendGates`）。
final class QwenCodeClient: @unchecked Sendable {

    /// 子进程「装死」看门狗阈值（秒）：连续这么久无任何 stdout/stderr 输出就判卡死、自动断流。
    /// 跟 Claude / Codex 一致 300s —— qwen 也会真跑命令 / 读写文件，静默几分钟正常，不能误杀。
    private static let streamIdleTimeoutSeconds: TimeInterval = 300

    /// qwen 可执行路径 —— 由 `CLIAvailability` 探测后写到 UserDefaults；找不到则 ""（spawn 失败 → UI 提示没装）。
    private var executablePath: String {
        UserDefaults.standard.string(forKey: "qwenExecutablePath") ?? ""
    }
    private var workingDir: String {
        UserDefaults.standard.string(forKey: "qwenWorkingDir") ?? NSHomeDirectory()
    }

    /// 检查 qwen CLI 是否可用 —— 走 CLIAvailability 统一探测
    func checkAvailable() async -> Bool {
        await CLIAvailability.qwenAvailable()
    }

    /// 兼容多 mode 共用的 clearChat 调用（qwen 每次都是干净的一次性会话，无需重置）
    func resetSession() {}
    func resetSession(conversationID: String) {}

    /// 流式问答。一次性调用（每次把完整历史拼进 prompt，不依赖 qwen 自己的 session 续接，简单稳妥）。
    func streamCompletion(messages: [ChatMessage],
                          conversationID: String? = nil,
                          injectMemory: Bool = true,
                          onUsage: (@Sendable (Int) -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
        let prompt = buildPrompt(messages: messages, injectMemory: injectMemory)
        let addDirs = collectDocDirs(from: messages)
        return streamRaw(prompt: prompt, addDirs: addDirs, onUsage: onUsage)
    }

    // MARK: - Prompt 构造

    /// 客户端能力提示 —— 跟 Claude / Codex 一样告诉 qwen 用 markdown 列表问选择题 / tasks fence
    private static let clientHints = """

    [客户端约定 · 仅供你理解上下文，不要在回复里引用这段]
    当前运行环境是 HermesPet 桌面客户端（纯文本聊天 UI）。如果你想让用户做选择，请直接在回复正文里用 Markdown 编号列表（1. xxx 2. yyy），客户端会渲染成可点击选项卡片。
    如果识别到用户输入是任务规划意图（"今天要做哪些事 / 待办 / 帮我分解任务"），请用 ```tasks fence 输出（每条 title/desc/mode/eta），客户端会渲染成可操作任务卡片。**只在确实是任务规划场景才用，普通对话仍自然语言回复**。

    """

    private func buildPrompt(messages: [ChatMessage], injectMemory: Bool) -> String {
        let convo = messages.filter { $0.role == .user || $0.role == .assistant }
        var body: String
        if let latest = convo.last, latest.role == .user {
            let history = convo.dropLast()
            if history.isEmpty {
                body = latest.content
            } else {
                var lines: [String] = [
                    "以下是我们之前的对话历史。请基于上下文回答最后的新问题，不要重复或总结历史。",
                    "",
                    "--- 历史开始 ---"
                ]
                for m in history {
                    lines.append("【\(m.role == .user ? "用户" : "助手")】\(m.content)")
                }
                lines.append("--- 历史结束 ---")
                lines.append("")
                lines.append("现在用户问：")
                lines.append(latest.content)
                body = lines.joined(separator: "\n")
            }
            let docs = latest.documentPaths
            if !docs.isEmpty {
                body += "\n\n用户附带了以下文档，请用你的文件工具按这些绝对路径读取：\n" + docs.joined(separator: "\n")
            }
        } else {
            body = convo.map { "\($0.role == .user ? "用户" : "助手"): \($0.content)" }.joined(separator: "\n\n")
        }
        body += Self.clientHints
        body += "\n\n" + LocaleManager.aiReplyLanguageInstruction() + NotesWritingContextHolder.shared.promptSuffix()
        if injectMemory, let mem = UserMemoryStore.shared.injectionText() {
            return mem + "\n\n" + body
        }
        return body
    }

    /// 取最近一条 user 消息附带文档的父目录，给 `--add-dir` 让 qwen 的文件工具能读到。
    private func collectDocDirs(from messages: [ChatMessage]) -> [String] {
        guard let latest = messages.last(where: { $0.role == .user }) else { return [] }
        let dirs = latest.documentPaths.map { ($0 as NSString).deletingLastPathComponent }
        return Array(Set(dirs)).filter { !$0.isEmpty }
    }

    // MARK: - 底层 spawn `qwen -o stream-json` 流式实现

    private func streamRaw(prompt: String,
                           addDirs: [String],
                           onUsage: (@Sendable (Int) -> Void)?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let exe = executablePath
            guard !exe.isEmpty, FileManager.default.isExecutableFile(atPath: exe) else {
                continuation.finish(throwing: APIError.httpError(
                    statusCode: 0,
                    body: "找不到 qwen 命令。请先在终端安装：npm install -g @qwen-code/qwen-code，并登录一次。"
                ))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            // --yolo：免逐条确认（headless 必需）；-o stream-json：JSONL 事件流；positional prompt = one-shot
            var args: [String] = ["--yolo", "-o", "stream-json"]
            for d in addDirs {
                args.append("--add-dir")
                args.append(d)
            }
            // 傻瓜配置：用户在设置里填了 Key 就通过命令行参数传给 qwen（不动其全局 ~/.qwen/settings.json）；
            // 没填则用 qwen 自己已登录的认证（零配置）。
            let cfgKey = UserDefaults.standard.string(forKey: "qwenAPIKey")?.trimmingCharacters(in: .whitespaces) ?? ""
            let cfgURL = UserDefaults.standard.string(forKey: "qwenBaseURL")?.trimmingCharacters(in: .whitespaces) ?? ""
            let cfgModel = UserDefaults.standard.string(forKey: "qwenModel")?.trimmingCharacters(in: .whitespaces) ?? ""
            if !cfgKey.isEmpty {
                args.append("--openai-api-key"); args.append(cfgKey)
                if !cfgURL.isEmpty { args.append("--openai-base-url"); args.append(cfgURL) }
            }
            if !cfgModel.isEmpty { args.append("-m"); args.append(cfgModel) }
            args.append(prompt)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
            process.standardInput = Self.nullInput
            // 透传环境 + 补齐 GUI App 缺失的 PATH；qwen 自己读 ~/.qwen 凭据（零配置关键）。
            // QWEN_CODE_SUPPRESS_YOLO_WARNING=1 消掉 headless yolo 的告警行（否则混进 stderr）。
            var env = CLIProcessEnvironment.make(executablePath: exe)
            env["QWEN_CODE_SUPPRESS_YOLO_WARNING"] = "1"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let stderrBuffer = QwenLockedData()
            let state = QwenStreamState()

            // 幂等收尾：terminationHandler / watchdog / run 失败三方抢占，continuation 只 finish 一次
            let finishStream: @Sendable (Error?) -> Void = { error in
                guard state.claimFinish() else { return }
                if let error { continuation.finish(throwing: error) }
                else { continuation.finish() }
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                state.touch()
                stderrBuffer.append(data)
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                state.touch()
                state.appendBuffer(data)

                while let lineData = state.nextLine() {
                    guard !lineData.isEmpty,
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let type = json["type"] as? String
                    else { continue }

                    // qwen stream-json 事件类型：
                    //   system(init) / assistant(message.content[]：text=正文 / thinking=内心独白要过滤) / result(收尾带 usage)
                    if type == "assistant",
                       let message = json["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        for part in content {
                            guard (part["type"] as? String) == "text",
                                  let text = part["text"] as? String,
                                  !text.isEmpty else { continue }
                            continuation.yield(text)
                            state.markEmitted(text)
                        }
                    } else if type == "result" {
                        if let usage = json["usage"] as? [String: Any],
                           let input = usage["input_tokens"] as? Int, input > 0 {
                            onUsage?(input)
                        }
                        // 兜底：整轮没产出过 text 块（极少数情况），用 result 的完整结果补一次
                        if !state.hasEmitted,
                           let result = json["result"] as? String, !result.isEmpty {
                            continuation.yield(result)
                            state.markEmitted(result)
                        }
                        // ⭐ result = 这一轮回答已经完成。立刻收尾断流，**不等 qwen node 进程慢吞吞退出**。
                        // 实测：内容早就吐完了，进程还要再过好几秒才退出 → 原来只在 terminationHandler 里
                        // finish → 流迟迟不关 → 语音陪聊「整段念」文字都出来了却迟迟不开口念（要按空格掐断
                        // 才说）。result 一到就 finish，残留的 qwen 进程交给 onTermination 去 terminate。
                        finishStream(nil)
                        break
                    }
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                SubprocessRegistry.shared.unregister(proc)
                if proc.terminationStatus != 0 {
                    var err = stderrBuffer.data
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    let errStr = String(data: err, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "qwen 进程异常退出"
                    finishStream(APIError.httpError(statusCode: 0, body: "QwenCode: \(errStr)"))
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

            // Watchdog：连续 streamIdleTimeoutSeconds 秒无任何输出 → 判卡死，杀进程 + 报错收尾。
            let watchdog = Task { @Sendable in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if state.isFinished { return }
                    if state.idleSeconds() > Self.streamIdleTimeoutSeconds {
                        if process.isRunning { process.terminate() }
                        let mins = Int(Self.streamIdleTimeoutSeconds / 60)
                        finishStream(APIError.httpError(
                            statusCode: 0,
                            body: "QwenCode 约 \(mins) 分钟没有任何响应，已自动断开。可能是某个命令卡住了，请重试或把操作拆小一点。"
                        ))
                        return
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                watchdog.cancel()
                if process.isRunning { process.terminate() }
                SubprocessRegistry.shared.unregister(process)
            }
        }
    }

    private static var nullInput: FileHandle? {
        FileHandle(forReadingAtPath: "/dev/null")
    }
}

// MARK: - 流式可变状态（NSLock 保护，跨 readabilityHandler / watchdog / termination 多线程访问）

private final class QwenStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lastTouchedAt = Date()
    private var finished = false
    private var emitted = false

    func touch() { lock.lock(); lastTouchedAt = Date(); lock.unlock() }
    func idleSeconds() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastTouchedAt) }

    func appendBuffer(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }
    /// 从 buffer 里切出下一整行（到 \n 为止），没有完整行返回 nil
    func nextLine() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let nl = buffer.range(of: Data([0x0a])) else { return nil }
        let line = buffer.subdata(in: 0..<nl.lowerBound)
        buffer.removeSubrange(0..<nl.upperBound)
        return line
    }

    func markEmitted(_ text: String) { lock.lock(); emitted = true; lock.unlock() }
    var hasEmitted: Bool { lock.lock(); defer { lock.unlock() }; return emitted }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    /// 抢占收尾权，只有第一个调用者拿到 true
    func claimFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

private final class QwenLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    func append(_ d: Data) { lock.lock(); _data.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
}
