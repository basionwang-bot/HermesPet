import Foundation

/// **v1.3 走 HTTP API 的 opencode 客户端**（替代 OpenCodeClient 的 subprocess 方案）
///
/// 跟 OpenCodeServerManager 拉起的 `opencode serve` 通过 HTTP 通信，**完全消除**
/// v1.2.2 用户痛点：subprocess 偶发 EOF / step_start×1 提前退场的「(没有响应)」bug。
///
/// **架构**：
/// 1. 用户发消息 → 走 `OpenCodeServerManager.serverURL`（默认 `http://127.0.0.1:<port>`）
/// 2. 第一次发消息 → `POST /session` 建 session（绑 directory + agent + model）
/// 3. 同时开 `GET /event` 长连接（SSE），listen 当前 sessionID 的 `message.part.delta` 事件
/// 4. `POST /session/{id}/message` 异步触发 prompt（server 后台跑模型）
/// 5. SSE 流的 `message.part.delta.delta` 字段 = token 增量 → yield 给 continuation
/// 6. `session.status.idle` 或 POST 同步返回完整 message → finish
///
/// **跟 OpenCodeClient 接口完全一致**：ChatViewModel 直接换 client 类型就好。
final class OpenCodeHTTPClient: @unchecked Sendable {
    static let shared = OpenCodeHTTPClient()

    /// 流式过程中追踪「assistant text 是否已经 yield 过」—— 没有就用 POST 返回体或
    /// `message.part.updated` 里的完整 text part 补一次，避免 MiniMax 等 provider
    /// 经 opencode HTTP 不发 `message.part.delta` 导致 UI 显示「(没有响应)」
    private final class StreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var yieldedText = false

        var hasYieldedText: Bool {
            lock.lock(); defer { lock.unlock() }
            return yieldedText
        }

        func markTextYielded() {
            lock.lock()
            yieldedText = true
            lock.unlock()
        }
    }

    private let lock = NSLock()
    /// `conversationID -> opencode sessionID` 映射。第一次 POST /session 建出来后存进来，
    /// 后续同对话直接复用 sessionID（让 opencode 端跨消息保持上下文）
    private var sessionIDByConversation: [String: String] = [:]
    /// `conversationID -> 上次用的 modelID`。model 变化时清掉 sessionID 让新建（避免 model 不兼容）
    private var lastModelByConversation: [String: String] = [:]
    /// `conversationID -> 在途建 session 的 Task`。同对话并发建 session 时复用同一个 Task，
    /// 避免 check→POST→commit 之间无锁导致建出两个 session 互相覆盖、泄漏一个（决策 #15）
    private var sessionTasks: [String: Task<(id: String, isNew: Bool), Error>] = [:]

    private init() {}

    // MARK: - Public API

    /// 流式问答，接口跟 OpenCodeClient / ClaudeCodeClient / APIClient / CodexClient 一致
    func streamCompletion(
        messages: [ChatMessage],
        conversationID: String,
        modelOverride: String? = nil,
        injectMemory: Bool = true,
        directory: String? = nil,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task.detached { @Sendable [weak self] in
                guard let self else {
                    continuation.finish(throwing: OpenCodeHTTPClientError.clientDeallocated)
                    return
                }
                await self.runStream(
                    messages: messages,
                    conversationID: conversationID,
                    modelOverride: modelOverride,
                    injectMemory: injectMemory,
                    directory: directory,
                    continuation: continuation,
                    onUsage: onUsage,
                    onUsageDetail: onUsageDetail
                )
            }
        }
    }

    /// 清掉所有内存 session 映射（server 重启后调用：旧 sessionID 全部失效）。
    /// 不删 server 端 session 记录（server 已经重启了，旧 session 自然没了）
    func clearAllSessions() {
        lock.lock()
        sessionIDByConversation.removeAll()
        lastModelByConversation.removeAll()
        lock.unlock()
    }

    /// 删对话时清绑定 session（避免 server 端堆积）
    /// 调用方有需要时也可手动调（比如检测到模型空响应时尝试新开 session）
    func clearSession(for conversationID: String) {
        lock.lock()
        let sid = sessionIDByConversation.removeValue(forKey: conversationID)
        lastModelByConversation.removeValue(forKey: conversationID)
        lock.unlock()

        // 同步把 server 端 session 删掉（fire and forget）
        if let sid {
            Task.detached { [weak self] in
                try? await self?.deleteSession(sid)
            }
        }
    }

    // MARK: - 主流程

    private func runStream(
        messages: [ChatMessage],
        conversationID: String,
        modelOverride: String?,
        injectMemory: Bool = true,
        directory: String? = nil,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil
    ) async {
        // 1. 等 server ready（最多 5s）
        for _ in 0..<25 {
            if OpenCodeServerManager.shared.isReady { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else {
            continuation.finish(throwing: OpenCodeHTTPClientError.serverNotReady)
            return
        }

        // 2. 拼 prompt + 收集附件
        let userMsg = messages.last(where: { $0.role == .user })
        let prompt = userMsg?.content ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.finish()
            return
        }

        let modelTuple = parseModelID(modelOverride ?? OpenCodeConfigGenerator.currentModelID())
        let (providerID, modelID) = modelTuple
        let streamState = StreamState()

        // 3. 拿 sessionID（model 变了 → 新建）
        let sessionID: String
        let sessionIsNew: Bool
        do {
            let info = try await ensureSession(
                conversationID: conversationID,
                providerID: providerID,
                modelID: modelID,
                baseURL: baseURL,
                authHeader: authHeader,
                directory: directory
            )
            sessionID = info.id
            sessionIsNew = info.isNew
        } catch {
            continuation.finish(throwing: error)
            return
        }

        // 4. 开 SSE 订阅（在 POST 前，避免错过首批 delta）
        let sseTask = Task.detached { @Sendable [weak self] in
            await self?.subscribeSSE(
                sessionID: sessionID,
                baseURL: baseURL,
                authHeader: authHeader,
                streamState: streamState,
                continuation: continuation,
                onUsage: onUsage,
                onUsageDetail: onUsageDetail
            )
        }

        // 5. 给 SSE 一点连接握手时间（避免 POST 太快 server 已经开始 emit delta 但 SSE 还没连上）
        try? await Task.sleep(nanoseconds: 150_000_000)

        // 6. POST prompt（这是同步 endpoint，等到 message 完整生成才返回）
        // parts/body 序列化成 Data 跨 Sendable 边界（Swift 6: [[String:Any]] 不是 Sendable）
        var parts = await buildParts(userMsg: userMsg)
        // v1.3 Phase 4b：只在新建 session 时，把跨模式「共享记忆」作为头部 text part 注入一次。
        // opencode session 后台保留上下文，后续消息复用同 session（isNew=false）不重复注入，省 token。
        // injectMemory=false：工作流 / 验收等隔离调用不带长期画像（只对 {input} 干活）
        if sessionIsNew, injectMemory, let memory = UserMemoryStore.shared.injectionText() {
            parts.insert(["type": "text", "text": memory], at: 0)
        }
        // 如果消息带图片，且当前 model 是文本模型 → 仅这次 prompt override 到该 provider 的 vision model。
        // session 仍绑用户原 model（不改 lastModelByConversation）—— 下次纯文本消息又用回原 model
        let hasImage = (userMsg?.images.isEmpty == false) || (userMsg?.imagePaths.isEmpty == false)
        let preset = ProviderPreset.all.first(where: { $0.id == providerID })
        let promptModelID: String = {
            guard hasImage else { return modelID }
            if let vm = preset?.visionModel { return vm }
            return modelID
        }()
        if hasImage && promptModelID == modelID && preset?.visionModel == nil {
            let providerName = preset?.displayName ?? providerID
            // 当前 provider 没有配置 vision model（DeepSeek / MiniMax 等），直接报清晰错误
            continuation.finish(throwing: OpenCodeHTTPClientError.runtimeFailure(
                "\(providerName) 当前不支持图片输入。请到设置切到 Moonshot Kimi / 智谱 GLM / OpenAI 任一家再试"
            ))
            return
        }
        // 戴眼镜 / 气泡通知已经在 ChatViewModel.sendMessage 里提前 post 了
        // （必须早于 streaming 通知，否则 CloudPet 会先回家）
        // 这里只保留 DeepSeek 无 vision 的硬错误拦截（在上方 if）
        let bodyDict: [String: Any] = [
            "model": ["providerID": providerID, "modelID": promptModelID],
            "parts": parts
        ]
        let bodyData = (try? JSONSerialization.data(withJSONObject: bodyDict)) ?? Data()
        let postTask = Task.detached { @Sendable [weak self] () -> Error? in
            await self?.postPrompt(
                sessionID: sessionID,
                bodyData: bodyData,
                baseURL: baseURL,
                authHeader: authHeader,
                streamState: streamState,
                continuation: continuation
            )
        }

        // 7. 用户取消时 → kill SSE + 告诉 server abort
        continuation.onTermination = { @Sendable _ in
            sseTask.cancel()
            postTask.cancel()
            Task.detached { [weak self] in
                try? await self?.abortSession(
                    sessionID: sessionID,
                    baseURL: baseURL,
                    authHeader: authHeader
                )
            }
        }

        // 8. 等 POST 完成 = 流式生成完毕，关 SSE，finish 流
        let postError = await postTask.value
        // 给 SSE 把最后几个 delta 收完（server idle 通知到达需要 200ms）
        try? await Task.sleep(nanoseconds: 200_000_000)
        sseTask.cancel()

        if let err = postError {
            // POST 失败常常是「这个 session 已经坏掉」（比如 file part media type 不支持），
            // 留着下次还会复用 → 主动清掉，让下条消息自动新建恢复。
            clearSession(for: conversationID)
            continuation.finish(throwing: err)
        } else {
            continuation.finish()
        }

        // 9. 通知灵动岛 —— 必须主线程 dispatch（CLAUDE.md 决策 #4：observer 是 @MainActor，
        // 后台线程直接 post 会 _swift_task_checkIsolatedSwift SIGTRAP）
        let success = postError == nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("HermesPetTaskFinished"),
                object: nil,
                userInfo: ["success": success]
            )
        }
    }

    // MARK: - Session

    /// 拿 / 建 session：检测 model 变化、绑定 directory + agent + model。
    /// 返回 isNew=true 表示这次是新建（caller 据此决定是否注入一次共享记忆，决策 #15 + Phase 4b）。
    private func ensureSession(
        conversationID: String,
        providerID: String,
        modelID: String,
        baseURL: URL,
        authHeader: String,
        directory: String? = nil
    ) async throws -> (id: String, isNew: Bool) {
        // directory 编进 key：工作台换了工作目录 → key 变 → 复用「model 变化清旧 session 重建」那套，
        // 让新 session 绑新目录（不另加字典、不碰锁/竞态，决策 #15 安全）
        let newModelKey = "\(providerID)/\(modelID)@\(directory ?? "")"

        // 快路径：已有可复用 session（model 变了会在 checkExistingSession 内清旧返回 nil）
        if let existing = checkExistingSession(conversationID: conversationID, newModelKey: newModelKey) {
            return (existing, false)
        }

        // 慢路径：按 conversationID 去重 —— 并发只起一个建 session 的 Task，其余 await 复用结果（决策 #15）
        let task = sessionTask(for: conversationID) {
            Task { [weak self] in
                guard let self else { throw OpenCodeHTTPClientError.runtimeFailure("client released") }
                defer { self.clearSessionTask(conversationID) }
                return try await self.createSession(
                    conversationID: conversationID,
                    providerID: providerID,
                    modelID: modelID,
                    baseURL: baseURL,
                    authHeader: authHeader,
                    newModelKey: newModelKey,
                    directory: directory
                )
            }
        }
        return try await task.value
    }

    /// 真正 POST /session 建会话。进 Task 后再查一次：可能在排队等本 Task 期间另一路已建好（彻底关竞态窗口）
    private func createSession(
        conversationID: String,
        providerID: String,
        modelID: String,
        baseURL: URL,
        authHeader: String,
        newModelKey: String,
        directory: String? = nil
    ) async throws -> (id: String, isNew: Bool) {
        if let existing = checkExistingSession(conversationID: conversationID, newModelKey: newModelKey) {
            return (existing, false)
        }

        // 工作台传了真实工作目录就用它（让 AI 真在用户打开的文件夹干活）；否则用对话独立目录（文件操作不互相串）
        let dir = directory ?? conversationDirectory(for: conversationID)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir),
            withIntermediateDirectories: true
        )

        var comp = URLComponents(url: baseURL.appendingPathComponent("session"), resolvingAgainstBaseURL: false)
        comp?.queryItems = [URLQueryItem(name: "directory", value: dir)]
        guard let url = comp?.url else { throw OpenCodeHTTPClientError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // permission rules：按 UserDefaults `permissionUIEnabled` 二选一。
        //   开关关（默认）→ 全 allow，等价于 v1.2.x `--dangerously-skip-permissions`
        //   开关开 → 全 ask，工具调用前会 SSE 推 `permission.asked` 事件，灵动岛弹卡片让用户决策
        // 设置面板「权限审批」开关控制；默认关是为了 dmg 朋友的零摩擦体验
        let action = UserDefaults.standard.bool(forKey: "permissionUIEnabled") ? "ask" : "allow"
        let permissionRules: [[String: String]] = [
            ["permission": "*",          "pattern": "**", "action": action],
            ["permission": "read",       "pattern": "**", "action": action],
            ["permission": "edit",       "pattern": "**", "action": action],
            ["permission": "write",      "pattern": "**", "action": action],
            ["permission": "bash",       "pattern": "**", "action": action],
            ["permission": "webfetch",   "pattern": "**", "action": action],
            ["permission": "glob",       "pattern": "**", "action": action],
            ["permission": "grep",       "pattern": "**", "action": action],
            ["permission": "list",       "pattern": "**", "action": action]
        ]
        let body: [String: Any] = [
            "title": "HermesPet 对话",
            "agent": "build",
            "model": ["id": modelID, "providerID": providerID],
            "permission": permissionRules
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            throw OpenCodeHTTPClientError.runtimeFailure("建 session 失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(msg.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = json["id"] as? String else {
            throw OpenCodeHTTPClientError.runtimeFailure("server 没返回 session id")
        }

        commitSession(conversationID: conversationID, sessionID: sid, modelKey: newModelKey)
        return (sid, true)
    }

    // Swift 6 严格并发：NSLock 不能在 async 函数里直接 lock/unlock。
    // 所有锁操作收敛到 sync helper（同 OpenCodeServerManager 模式）。
    private func checkExistingSession(conversationID: String, newModelKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let lastModel = lastModelByConversation[conversationID]
        if lastModel != nil && lastModel != newModelKey {
            sessionIDByConversation.removeValue(forKey: conversationID)
            return nil
        }
        return sessionIDByConversation[conversationID]
    }
    private func commitSession(conversationID: String, sessionID: String, modelKey: String) {
        lock.lock(); defer { lock.unlock() }
        sessionIDByConversation[conversationID] = sessionID
        lastModelByConversation[conversationID] = modelKey
    }

    /// 原子 get-or-insert 在途建 session Task：锁内已有就返回复用，否则 create 起一个存入再返回。
    /// create 起的 Task 体内首次访问 lock 都在 await 之后（锁外），不与本锁嵌套（沿用 L320 sync-helper 铁律）。
    private func sessionTask(
        for conversationID: String,
        create: () -> Task<(id: String, isNew: Bool), Error>
    ) -> Task<(id: String, isNew: Bool), Error> {
        lock.lock(); defer { lock.unlock() }
        if let t = sessionTasks[conversationID] { return t }
        let t = create()
        sessionTasks[conversationID] = t
        return t
    }
    private func clearSessionTask(_ conversationID: String) {
        lock.lock(); defer { lock.unlock() }
        sessionTasks.removeValue(forKey: conversationID)
    }

    private func deleteSession(_ sessionID: String) async throws {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("session/\(sessionID)"))
        req.httpMethod = "DELETE"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    private func abortSession(sessionID: String, baseURL: URL, authHeader: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("session/\(sessionID)/abort"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Prompt (POST /session/{id}/message)

    private func postPrompt(
        sessionID: String,
        bodyData: Data,
        baseURL: URL,
        authHeader: String,
        streamState: StreamState,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async -> Error? {
        var req = URLRequest(
            url: baseURL.appendingPathComponent("session/\(sessionID)/message"),
            timeoutInterval: 300   // 5 分钟，给模型充分时间
        )
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return OpenCodeHTTPClientError.runtimeFailure("没拿到 HTTP response")
            }
            if http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? "(empty)"
                return OpenCodeHTTPClientError.runtimeFailure("HTTP \(http.statusCode): \(msg.prefix(300))")
            }
            // server 返回 200 但 body 里可能藏着 `info.error`（比如 file part media type 不支持），
            // 旧逻辑只看 text parts 会把这种回复显示成「(没有响应)」并复用坏 session。
            // 这里识别 info.error 转成明确错误信息让上游 finish(throwing:)。
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                return OpenCodeHTTPClientError.runtimeFailure("opencode 返回了无法解析的响应")
            }
            if let message = Self.extractOpenCodeError(from: json) {
                return OpenCodeHTTPClientError.runtimeFailure(message)
            }
            // 兜底：没有 delta 也没有 part.updated 时，从 POST 返回体里抽 assistant text 补一次
            if !streamState.hasYieldedText,
               let text = Self.extractAssistantText(from: json),
               !text.isEmpty {
                streamState.markTextYielded()
                continuation.yield(text)
            }
            return nil
        } catch {
            return error
        }
    }

    // MARK: - SSE Subscribe (GET /event)

    /// 订阅 server 的 SSE event 流，filter 出当前 sessionID 的 message.part.delta + 工具事件
    private func subscribeSSE(
        sessionID: String,
        baseURL: URL,
        authHeader: String,
        streamState: StreamState,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil
    ) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("event"))
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 600

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return   // server 没起来或认证失败 —— 静默退出（POST 路径会报错）
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let jsonData = jsonStr.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }
                handleSSEEvent(
                    event,
                    targetSessionID: sessionID,
                    streamState: streamState,
                    continuation: continuation,
                    onUsage: onUsage,
                    onUsageDetail: onUsageDetail
                )
            }
        } catch {
            // SSE 断了 —— 不报错给用户，POST 那边正常拿到完整 message 即可
        }
    }

    private func handleSSEEvent(
        _ event: [String: Any],
        targetSessionID: String,
        streamState: StreamState,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil
    ) {
        guard let type = event["type"] as? String,
              let props = event["properties"] as? [String: Any] else { return }
        // 不是当前 session 的事件就丢
        if let sid = props["sessionID"] as? String, sid != targetSessionID { return }

        switch type {
        case "message.updated":
            // opencode 的 assistant message 信息，含真实 token 用量
            if let info = (props["info"] as? [String: Any]) ?? (props["message"] as? [String: Any]) {
                Self.reportTokens(from: info, onUsage: onUsage, onUsageDetail: onUsageDetail)
            }

        case "message.part.delta":
            // text 增量：{"field":"text","delta":"hello"}
            if let field = props["field"] as? String, field == "text",
               let delta = props["delta"] as? String, !delta.isEmpty {
                streamState.markTextYielded()
                continuation.yield(delta)
            }

        case "message.part.updated":
            // 有些版本把 message info（含 tokens）也带在这个事件里
            if let info = props["message"] as? [String: Any] {
                Self.reportTokens(from: info, onUsage: onUsage, onUsageDetail: onUsageDetail)
            }
            if let part = props["part"] as? [String: Any] {
                // 有些 provider 经 opencode HTTP API 只发 updated 里的完整 text part，
                // 不发 delta；这里补一次，避免 UI 显示「(没有响应)」。
                let role = (props["role"] as? String)
                    ?? ((props["message"] as? [String: Any])?["role"] as? String)
                if !streamState.hasYieldedText,
                   (role == "assistant" || role == "model"),
                   let text = Self.extractAssistantText(from: part),
                   !text.isEmpty {
                    streamState.markTextYielded()
                    continuation.yield(text)
                }
                handleToolPart(part)
            }

        case "permission.asked":
            // permission.asked event payload 的 properties 字段就是 PermissionRequest 本身
            handlePermissionAsked(props)

        case "permission.replied":
            // 服务端确认收到 reply（可能是我们自己 POST 的回执，也可能是其他 client）
            // 广播让灵动岛把卡片收起来（防止两端同时 reply 出现 UI 残留）
            if let requestID = props["requestID"] as? String {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("HermesPetPermissionReplied"),
                        object: nil,
                        userInfo: ["requestID": requestID]
                    )
                }
            }

        case "question.asked":
            // AI 主动问问题（v1.3+ 新增）—— 卡片展示问题 + 选项让用户选
            handleQuestionAsked(props)

        case "question.replied", "question.rejected":
            if let requestID = props["requestID"] as? String {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("HermesPetPermissionReplied"),   // 复用同一个 dismiss 通知
                        object: nil,
                        userInfo: ["requestID": requestID]
                    )
                }
            }

        default:
            break
        }
    }

    private func handleQuestionAsked(_ props: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: props) else { return }
        guard let request = try? JSONDecoder().decode(QuestionRequest.self, from: data) else {
            NSLog("[OpenCodeHTTP] failed to decode question.asked payload")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("HermesPetQuestionAsked"),
                object: nil,
                userInfo: ["request": request]
            )
        }
    }

    /// 把 SSE permission.asked event 的 properties 解析成 PermissionRequest 并广播给灵动岛
    private func handlePermissionAsked(_ props: [String: Any]) {
        // properties 字段就是完整 PermissionRequest schema 的 JSON
        // JSONSerialization → Data → JSONDecoder → PermissionRequest
        guard let data = try? JSONSerialization.data(withJSONObject: props) else { return }
        guard let request = try? JSONDecoder().decode(PermissionRequest.self, from: data) else {
            NSLog("[OpenCodeHTTP] failed to decode permission.asked payload: %@",
                  String(data: data, encoding: .utf8) ?? "(empty)")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .init("HermesPetPermissionAsked"),
                object: nil,
                userInfo: ["request": request]
            )
        }
    }

    // MARK: - Permission Reply (POST /permission/{id}/reply)

    /// 用户在灵动岛点了 Allow/AllowAlways/Deny → 把决策 POST 回 opencode。
    /// 服务端会取消阻塞，让对应工具调用 either 继续 (once/always) 或报错 (reject)。
    ///
    /// **不抛错**：失败只 NSLog，因为如果回执失败 server 那边会一直 hang 等。
    /// UI 这边卡片已经收起来了，用户不会再次决策同一个 requestID
    /// （服务端那边对同 id 二次 reply 会返回 200 / true 无副作用，见 issue 15386）
    /// 回答 AI 提的问题 → POST /question/{id}/reply
    /// answers 是嵌套数组：外层每个 question 一个元素，内层是该 question 选中的 label 数组
    /// （单选 question 内层只有 1 个，multiple=true 时可能多个）
    func replyQuestion(requestID: String, answers: [[String]]) async {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("question/\(requestID)/reply"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["answers": answers]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 拒绝回答 AI 提的问题 → POST /question/{id}/reject
    func rejectQuestion(requestID: String) async {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else { return }
        var req = URLRequest(url: baseURL.appendingPathComponent("question/\(requestID)/reject"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    func replyPermission(requestID: String, decision: PermissionDecision) async {
        guard OpenCodeServerManager.shared.isReady,
              let baseURL = OpenCodeServerManager.shared.serverURL,
              let authHeader = OpenCodeServerManager.shared.authorizationHeader else {
            NSLog("[OpenCodeHTTP] replyPermission skipped: server not ready")
            return
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("permission/\(requestID)/reply"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["reply": decision.rawValue]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                NSLog("[OpenCodeHTTP] replyPermission HTTP %d: %@",
                      http.statusCode, String(data: data, encoding: .utf8) ?? "(empty)")
            }
        } catch {
            NSLog("[OpenCodeHTTP] replyPermission error: %@", "\(error)")
        }
    }

    /// 从 opencode 的 message info 里取真实输入上下文 token = input + cache.read + cache.write。
    /// opencode 把 input（非缓存）和 cache（read/write）分开记，相加才是完整上下文（同 Claude 口径）。
    private static func reportTokens(from info: [String: Any],
                                     onUsage: (@Sendable (Int) -> Void)?,
                                     onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil) {
        guard let tokens = info["tokens"] as? [String: Any] else { return }
        let input = (tokens["input"] as? Int) ?? 0
        let output = (tokens["output"] as? Int) ?? 0
        var cacheRead = 0, cacheWrite = 0
        if let c = tokens["cache"] as? [String: Any] {
            cacheRead = (c["read"] as? Int) ?? 0
            cacheWrite = (c["write"] as? Int) ?? 0
        }
        let total = input + cacheRead + cacheWrite
        if total > 0 { onUsage?(total) }
        if total + output > 0 {
            onUsageDetail?(TokenUsageBreakdown(input: input, output: output,
                                               cacheRead: cacheRead, cacheCreate: cacheWrite))
        }
    }

    private func handleToolPart(_ part: [String: Any]) {
        guard let partType = part["type"] as? String, partType == "tool",
              let tool = part["tool"] as? String,
              let state = part["state"] as? [String: Any] else { return }
        let status = state["status"] as? String ?? ""
        let input = state["input"] as? [String: Any] ?? [:]
        let filePath = (input["filePath"] as? String)
            ?? (input["path"] as? String)
            ?? (input["file"] as? String)
        let command = input["command"] as? String
        let url = input["url"] as? String
        let argSummary: String = {
            if let fp = filePath { return (fp as NSString).lastPathComponent }
            if let cmd = command { return String(cmd.prefix(40)) }
            if let u = url { return u }
            return ""
        }()
        let mappedName = Self.mapToolName(tool)

        switch status {
        case "running", "started":
            var info: [String: Any] = ["name": mappedName, "arg": argSummary]
            if let fp = filePath, !fp.isEmpty { info["file_path"] = fp }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("HermesPetToolStarted"), object: nil, userInfo: info)
            }
        case "completed":
            var info: [String: Any] = ["name": mappedName]
            if let fp = filePath, !fp.isEmpty { info["file_path"] = fp }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("HermesPetToolEnded"), object: nil, userInfo: info)
            }
        default:
            break
        }
    }

    // MARK: - Parts 构造

    /// 把 user message 的 text + 图片/文档拼成 opencode parts 数组：
    /// - text: `{type:"text",text:"..."}`
    /// - 文件: `{type:"file",mime:"...",filename:"...",url:"file:///..."}`
    private func buildParts(userMsg: ChatMessage?) async -> [[String: Any]] {
        var parts: [[String: Any]] = []
        // 写作模式：把当前文档 + 文件夹清单 + ```note 协议作为上下文前置（在线 AI 系统提示是配置静态的，
        // 走消息注入才能每次带最新文档）。非写作模式返回空串，不影响普通对话。
        let writingCtx = NotesWritingContextHolder.shared.promptAddition()
        if !writingCtx.isEmpty {
            parts.append(["type": "text", "text": writingCtx])
        }
        let text = userMsg?.content ?? ""
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        // 文档：直接传 file:// URL，server 在本机能读到（走 Read tool 或 inline 都可）
        for path in userMsg?.documentPaths ?? [] {
            let url = URL(fileURLWithPath: path)
            // PDF 特殊处理：OpenAI 兼容模型读不了 PDF 二进制 file part（opencode 会报
            // 「file part media type not supported」或被模型忽略），所以在客户端本地用
            // PDFKit 把 PDF 抽成纯文本内联进 prompt（扫描版走 VisionOCR）。详见
            // PDFTextExtractor / 决策 #9。其他文档照旧走 file part（opencode 能读纯文本）。
            if (path as NSString).pathExtension.lowercased() == "pdf" {
                let result = await PDFTextExtractor.extract(from: url)
                let header = "【附件 PDF：\(url.lastPathComponent)】"
                if result.isEmpty {
                    parts.append(["type": "text", "text": "\(header)\n（这个 PDF 没有可提取的文字，可能是加密或损坏的文件，无法读取内容。）"])
                } else {
                    var body = ""
                    if result.usedOCR {
                        body += "（以下是扫描版 PDF 的 OCR 识别结果，可能有少量错字）\n"
                    }
                    body += result.text
                    if result.truncated {
                        body += "\n\n……（文档较长，以上仅为前面部分，已截断）"
                    }
                    parts.append(["type": "text", "text": "\(header)\n\(body)"])
                    // 记一笔「本地省 token」：本地把 PDF 抽成文本，省下了"把每页当图发给视觉模型"的视觉 token。
                    let imagesAvoided = result.usedOCR ? min(result.pageCount, 30) : result.pageCount
                    let textTokens = TokenEstimator.estimateTokens(result.text)
                    let savedTok = max(0, imagesAvoided * ModelPricing.visionTokensPerImage - textTokens)
                    if savedTok > 0 {
                        let refModel = UserDefaults.standard.string(forKey: "directAPIModel") ?? "deepseek"
                        Task { @MainActor in
                            TokenUsageStore.shared.recordLocalSaving(
                                savedTokens: savedTok, referenceModel: refModel, mode: .directAPI)
                        }
                    }
                }
                continue
            }
            let mime = mimeType(forPath: path)
            parts.append([
                "type": "file",
                "mime": mime,
                "filename": url.lastPathComponent,
                "url": url.absoluteString
            ])
        }
        // 图片：**必须 base64 data URL**（OpenAI/Moonshot/智谱 vision API 标准格式）。
        // 之前用 file:// URL 会被 server 当文本塞进 prompt，model 看不到真图（input token 翻倍但 model 说「无法查看」）
        for path in userMsg?.imagePaths ?? [] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                // 按 **Data 字节头** 检测真实 mime（用户拖入 JPG 但磁盘可能存成 .png 后缀）
                let mime = Self.detectImageMime(data: data) ?? mimeType(forPath: path)
                let b64 = data.base64EncodedString()
                parts.append([
                    "type": "file",
                    "mime": mime,
                    "filename": (path as NSString).lastPathComponent,
                    "url": "data:\(mime);base64,\(b64)"
                ])
            }
        }
        // 没落盘的图（Data 直接 base64 inline）
        let imagePaths = userMsg?.imagePaths ?? []
        for (idx, data) in (userMsg?.images ?? []).enumerated() where idx >= imagePaths.count {
            let mime = Self.detectImageMime(data: data) ?? "image/png"
            let b64 = data.base64EncodedString()
            parts.append([
                "type": "file",
                "mime": mime,
                "filename": "image-\(idx).\(Self.extForMime(mime))",
                "url": "data:\(mime);base64,\(b64)"
            ])
        }
        return parts
    }

    /// 看 Data 头几个字节判断真实图片格式 —— 拖入 JPG 时 mime 不会错标成 png。
    /// JPG 头: FF D8 FF / PNG 头: 89 50 4E 47 / GIF 头: 47 49 46 38 / WEBP: RIFF...WEBP
    static func detectImageMime(data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        return nil
    }

    static func extForMime(_ mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png":  return "png"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        default: return "bin"
        }
    }

    private func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":           return "application/pdf"
        case "md", "markdown": return "text/markdown"
        case "txt":           return "text/plain"
        case "json":          return "application/json"
        case "html", "htm":   return "text/html"
        case "png":           return "image/png"
        case "jpg", "jpeg":   return "image/jpeg"
        case "gif":           return "image/gif"
        case "svg":           return "image/svg+xml"
        case "csv":           return "text/csv"
        case "yaml", "yml":   return "text/yaml"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h":
                              return "text/plain"
        default:              return "application/octet-stream"
        }
    }

    // MARK: - Model & Path

    /// "moonshot/kimi-k2.5" → ("moonshot", "kimi-k2.5")
    private func parseModelID(_ id: String) -> (provider: String, model: String) {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return ("opencode", id)   // 兜底
    }

    private func conversationDirectory(for conversationID: String) -> String {
        let home = NSHomeDirectory()
        let safe = conversationID.replacingOccurrences(of: "/", with: "_")
        return "\(home)/Library/Application Support/HermesPet/conversations/\(safe)"
    }

    /// 从 opencode HTTP 的 part/message 返回体里抽 assistant 文本。
    /// 只作为没有 delta 时的兜底，避免误把工具参数、用户输入等内容当回复。
    private static func extractAssistantText(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let type = dict["type"] as? String,
               type == "text",
               let text = dict["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let role = dict["role"] as? String,
               role != "assistant" && role != "model" {
                return nil
            }
            for key in ["part", "message", "data"] {
                if let nested = dict[key], let text = extractAssistantText(from: nested) {
                    return text
                }
            }
            if let parts = dict["parts"] as? [Any] {
                let texts = parts.compactMap { extractAssistantText(from: $0) }
                if !texts.isEmpty { return texts.joined() }
            }
        }
        if let array = value as? [Any] {
            let texts = array.compactMap { extractAssistantText(from: $0) }
            if !texts.isEmpty { return texts.joined() }
        }
        return nil
    }

    /// opencode 返回 200 但 body 里 `info.error.data.message` 含错误信息时，转人话提示用户。
    /// 已知场景：file part media type ...xlsx not supported
    private static func extractOpenCodeError(from value: Any) -> String? {
        guard let dict = value as? [String: Any],
              let info = dict["info"] as? [String: Any],
              let error = info["error"] as? [String: Any] else {
            return nil
        }
        let name = error["name"] as? String ?? "OpenCodeError"
        let data = error["data"] as? [String: Any]
        let message = (data?["message"] as? String)
            ?? (error["message"] as? String)
            ?? name
        if message.contains("file part media type"),
           message.contains("not supported") {
            return "当前在线 AI 引擎不支持直接读取这个文件格式。请先转成 PDF / CSV / txt，或把内容复制进聊天框。"
        }
        return message
    }

    /// opencode 工具名 → HermesPet ToolKind 兼容名（让 PillView ToolKind.from 能识别）
    private static func mapToolName(_ openCodeTool: String) -> String {
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
            return openCodeTool.prefix(1).uppercased() + openCodeTool.dropFirst()
        }
    }
}

// MARK: - Errors

enum OpenCodeHTTPClientError: LocalizedError {
    case serverNotReady
    case clientDeallocated
    case badURL
    case runtimeFailure(String)

    var errorDescription: String? {
        switch self {
        case .serverNotReady:    return "在线 AI 服务还在启动，请稍等再试"
        case .clientDeallocated: return "OpenCodeHTTPClient 已释放"
        case .badURL:            return "URL 拼错了"
        case .runtimeFailure(let s): return s
        }
    }
}
