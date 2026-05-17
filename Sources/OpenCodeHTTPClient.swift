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

    private let lock = NSLock()
    /// `conversationID -> opencode sessionID` 映射。第一次 POST /session 建出来后存进来，
    /// 后续同对话直接复用 sessionID（让 opencode 端跨消息保持上下文）
    private var sessionIDByConversation: [String: String] = [:]
    /// `conversationID -> 上次用的 modelID`。model 变化时清掉 sessionID 让新建（避免 model 不兼容）
    private var lastModelByConversation: [String: String] = [:]

    private init() {}

    // MARK: - Public API

    /// 流式问答，接口跟 OpenCodeClient / ClaudeCodeClient / APIClient / CodexClient 一致
    func streamCompletion(
        messages: [ChatMessage],
        conversationID: String,
        modelOverride: String? = nil
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
                    continuation: continuation
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
        continuation: AsyncThrowingStream<String, Error>.Continuation
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

        // 3. 拿 sessionID（model 变了 → 新建）
        let sessionID: String
        do {
            sessionID = try await ensureSession(
                conversationID: conversationID,
                providerID: providerID,
                modelID: modelID,
                baseURL: baseURL,
                authHeader: authHeader
            )
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
                continuation: continuation
            )
        }

        // 5. 给 SSE 一点连接握手时间（避免 POST 太快 server 已经开始 emit delta 但 SSE 还没连上）
        try? await Task.sleep(nanoseconds: 150_000_000)

        // 6. POST prompt（这是同步 endpoint，等到 message 完整生成才返回）
        // parts/body 序列化成 Data 跨 Sendable 边界（Swift 6: [[String:Any]] 不是 Sendable）
        let parts = buildParts(userMsg: userMsg)
        // 如果消息带图片，且当前 model 是文本模型 → 仅这次 prompt override 到该 provider 的 vision model。
        // session 仍绑用户原 model（不改 lastModelByConversation）—— 下次纯文本消息又用回原 model
        let hasImage = (userMsg?.images.isEmpty == false) || (userMsg?.imagePaths.isEmpty == false)
        let promptModelID: String = {
            guard hasImage else { return modelID }
            let preset = ProviderPreset.all.first(where: { $0.id == providerID })
            if let vm = preset?.visionModel { return vm }
            return modelID
        }()
        if hasImage && promptModelID == modelID && providerID == "deepseek" {
            // DeepSeek 没 vision model，直接报清晰错误，让用户切到 Kimi / GLM / GPT-4o
            continuation.finish(throwing: OpenCodeHTTPClientError.runtimeFailure(
                "DeepSeek 当前不支持图片输入。请到设置切到 Moonshot Kimi / 智谱 GLM / OpenAI 任一家再试"
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
                authHeader: authHeader
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

    /// 拿 / 建 session：检测 model 变化、绑定 directory + agent + model
    private func ensureSession(
        conversationID: String,
        providerID: String,
        modelID: String,
        baseURL: URL,
        authHeader: String
    ) async throws -> String {
        let newModelKey = "\(providerID)/\(modelID)"

        // model 变了 → 清旧 session
        if let existing = checkExistingSession(conversationID: conversationID, newModelKey: newModelKey) {
            return existing
        }

        // 新建：directory 用对话独立目录（让 opencode 文件操作不互相串）
        let dir = conversationDirectory(for: conversationID)
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
        // permission rules：所有工具（read/edit/write/bash/webfetch...）都 allow，
        // 等价于 v1.2.x subprocess 模式的 `--dangerously-skip-permissions`。
        // 不传的话 server 默认是 ask，HermesPet 没做 permission UI → 工具调用会 hang。
        // 下一版本（v1.3+）会加 permission UI + 设置开关让追求安全的用户能切到 ask。
        // 用通配 ** + allow，覆盖所有工具的所有 pattern
        let permissionRules: [[String: String]] = [
            ["permission": "*",          "pattern": "**", "action": "allow"],
            ["permission": "read",       "pattern": "**", "action": "allow"],
            ["permission": "edit",       "pattern": "**", "action": "allow"],
            ["permission": "write",      "pattern": "**", "action": "allow"],
            ["permission": "bash",       "pattern": "**", "action": "allow"],
            ["permission": "webfetch",   "pattern": "**", "action": "allow"],
            ["permission": "glob",       "pattern": "**", "action": "allow"],
            ["permission": "grep",       "pattern": "**", "action": "allow"],
            ["permission": "list",       "pattern": "**", "action": "allow"]
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
        return sid
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
        authHeader: String
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
        continuation: AsyncThrowingStream<String, Error>.Continuation
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
                handleSSEEvent(event, targetSessionID: sessionID, continuation: continuation)
            }
        } catch {
            // SSE 断了 —— 不报错给用户，POST 那边正常拿到完整 message 即可
        }
    }

    private func handleSSEEvent(
        _ event: [String: Any],
        targetSessionID: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard let type = event["type"] as? String,
              let props = event["properties"] as? [String: Any] else { return }
        // 不是当前 session 的事件就丢
        if let sid = props["sessionID"] as? String, sid != targetSessionID { return }

        switch type {
        case "message.part.delta":
            // text 增量：{"field":"text","delta":"hello"}
            if let field = props["field"] as? String, field == "text",
               let delta = props["delta"] as? String, !delta.isEmpty {
                continuation.yield(delta)
            }

        case "message.part.updated":
            // 工具事件来这里：part.type == "tool" + part.state.status 表示状态
            if let part = props["part"] as? [String: Any] {
                handleToolPart(part)
            }

        default:
            break
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
    private func buildParts(userMsg: ChatMessage?) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        let text = userMsg?.content ?? ""
        if !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        // 文档：直接传 file:// URL，server 在本机能读到（走 Read tool 或 inline 都可）
        for path in userMsg?.documentPaths ?? [] {
            let url = URL(fileURLWithPath: path)
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
