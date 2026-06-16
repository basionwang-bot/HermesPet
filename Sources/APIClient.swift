import Foundation

/// 跨 Task 边界共享的 idle clock —— stream watchdog 用它检测服务端"装死"。
/// actor 保证并发安全，每次收到 SSE 数据就 touch()，watchdog 每 5s 查 idleSeconds()。
actor APIIdleClock {
    private var lastTouchedAt = Date()
    private(set) var timedOut = false
    func touch() { lastTouchedAt = Date() }
    func idleSeconds() -> TimeInterval { Date().timeIntervalSince(lastTouchedAt) }
    func markTimedOut() { timedOut = true }
}

/// OpenAI-compatible API client，可服务两种 AgentMode：
/// - `.hermes`：连本地 Hermes Gateway（用户自托管 API Server）
/// - `.direct`：直连第三方 OpenAI 兼容服务商（DeepSeek / 智谱 / Kimi / MiniMax / OpenAI…）
///
/// 两种 mode 的 URL / key / 模型名分别存在不同 UserDefaults key，避免相互覆盖。
/// 实例化时传入对应的 `ConfigSource` 决定读哪一套配置。
final class APIClient: @unchecked Sendable {

    /// 配置来源 —— 决定 baseURL / apiKey / modelName 从哪些 UserDefaults key 读，
    /// 以及"没配置时的兜底默认值"。
    enum ConfigSource {
        /// Hermes Gateway：默认 localhost:8642，模型 "hermes-agent"
        case hermes
        /// 直连第三方：无 sensible default URL（由 SettingsView ProviderPreset Picker 帮用户选）
        case direct
        /// OpenClaw：默认 localhost:18789，model 是 agent id（"openclaw" / "openclaw/default"），
        /// Bearer token 从 ~/.openclaw/openclaw.json 自动读（用户不填表），HermesPet 启动时由
        /// OpenClawGatewayManager 解析并缓存
        case openclaw
        /// QwenCode：直连阿里 DashScope 的 OpenAI 兼容端点（compatible-mode/v1），
        /// 跟 Hermes / OpenClaw 同款直连。baseURL / key / model 存独立 qwenCode* keys
        case qwen

        var baseURLKey: String {
            switch self {
            case .hermes:   return "apiBaseURL"
            case .direct:   return "directAPIBaseURL"
            case .openclaw: return "openclawBaseURL"
            case .qwen:     return "qwenCodeBaseURL"
            }
        }
        var apiKeyKey: String {
            switch self {
            case .hermes:   return "apiKey"
            case .direct:   return "directAPIKey"
            case .openclaw: return "openclawToken"   // 兜底；优先从 OpenClawGatewayManager.currentToken 读
            case .qwen:     return "qwenCodeKey"
            }
        }
        var modelNameKey: String {
            switch self {
            case .hermes:   return "modelName"
            case .direct:   return "directAPIModel"
            case .openclaw: return "openclawAgentId"
            case .qwen:     return "qwenCodeModel"
            }
        }
        var defaultBaseURL: String {
            switch self {
            case .hermes:   return "http://localhost:8642/v1"
            case .direct:   return ""   // 没默认 —— UI 强制让用户选预设
            case .openclaw: return "http://localhost:18789/v1"   // OpenClaw gateway 默认端口 + OpenAI 兼容路径
            case .qwen:     return "https://dashscope.aliyuncs.com/compatible-mode/v1"   // 阿里 DashScope OpenAI 兼容端点
            }
        }
        var defaultModel: String {
            switch self {
            case .hermes:   return "hermes-agent"
            case .direct:   return ""   // 同上
            case .openclaw: return "openclaw"   // 路由到 OpenClaw 配置的默认 agent
            case .qwen:     return "qwen-plus"   // 通义千问默认主力模型
            }
        }
    }

    /// SSE 流空闲超时（秒）。超过此值无数据 → 主动断流报错，避免卡到 timeoutIntervalForRequest 才返回。
    /// ⭐ 按后端区分(2026-06-07):agent 后端(Hermes/OpenClaw)会真跑工具(浏览器过 Cloudflare、delegate_task),
    /// 一个工具调用静默 60~120s 很正常(实测 OpenClaw 成功路最大间隔都到 74s),90s 太紧会误杀 → 给 180s;
    /// 在线AI/直连是纯 chat 流、应当持续吐字,保持 90s 快速发现装死。
    private var streamIdleTimeoutSeconds: TimeInterval {
        switch source {
        case .hermes, .openclaw: return 180
        default:                 return 90
        }
    }

    /// 注入给 Hermes / 在线 AI 的 system 提示 —— 让 AI 识别任务规划意图时输出 ```tasks fence。
    /// Claude/Codex 的提示靠 prompt 末尾拼接（它们没 system 概念），Hermes/直连 走 OpenAI 兼容 API
    /// 直接前置一条 role=system 即可
    private func systemPrompt(injectMemory: Bool = true) -> String {
        let identityBlock: String
        switch source {
        case .hermes:
            identityBlock = """
            当前模式：Hermes
            当前后端：Hermes Gateway / OpenAI 兼容 API
            当前模型：\(modelName)
            你拥有本机的完整文件读写与命令执行工具（Hermes 自带 terminal / file 工具）。当用户的请求需要时，主动用这些工具读取、修改、新建文件或运行命令来真正完成任务，而不是只给文字建议。用户拖入的文档会以绝对路径附在消息里，按路径用文件工具打开即可。
            你可以称自己为 HermesPet 助手。不要自称 Claude、Claude Code 或 Codex。
            """
        case .openclaw:
            identityBlock = """
            当前模式：OpenClaw
            当前后端：OpenClaw Gateway（npm 装的本地 agent 系统，端口 18789）
            当前 agent：\(modelName)
            你运行在 HermesPet 的「OpenClaw」模式，通过 OpenClaw 的 OpenAI 兼容 chatCompletions 端点路由到用户配置的 agent。
            你拥有本机的完整文件读写与命令执行工具（OpenClaw core tools：read / write / edit / exec）。当用户的请求需要时，主动用这些工具读取、修改、新建文件或运行命令来真正完成任务，而不是只给文字建议。用户拖入的文档会以绝对路径附在消息里，按路径用文件工具打开即可。
            你可以称自己为 HermesPet 助手。不要自称 Claude、Claude Code 或 Codex。
            """
        case .direct:
            let provider = ProviderPreset.detect(baseURL: baseURL)
            let providerName = provider.id == "custom" ? "自定义 OpenAI 兼容服务" : provider.displayName
            let preferenceRaw = UserDefaults.standard.string(forKey: "directAPIResponsePreference") ?? ""
            let preference = DirectResponsePreference(rawValue: preferenceRaw) ?? .balanced
            identityBlock = """
            当前模式：在线 AI
            当前服务商：\(providerName)
            当前模型：\(modelName)
            当前回复偏好：\(preference.label)
            你运行在 HermesPet 的「在线 AI」模式。你可以说明自己是 HermesPet 在线 AI 助手，当前由 \(providerName) / \(modelName) 提供能力。
            除非当前模式明确是 Claude Code 或 Codex，否则不要自称 Claude、Claude Code、Codex，也不要说自己处在 Codex 模式。
            """
        case .qwen:
            identityBlock = """
            当前模式：QwenCode
            当前后端：阿里通义千问 / DashScope（OpenAI 兼容端点）
            当前模型：\(modelName)
            你运行在 HermesPet 的「QwenCode」模式，直连通义千问模型。你可以说明自己是 HermesPet QwenCode 助手，当前由 阿里通义千问 / \(modelName) 提供能力。
            不要自称 Claude、Claude Code、Codex。
            """
        }

        let base = """
    你运行在 HermesPet 桌面客户端。客户端约定：

    【身份与配置】
    \(identityBlock)

    1) 如果你想让用户做选择，用 Markdown 编号列表（1. xxx 2. yyy ...）。客户端会渲染成可点击卡片。

    2) 如果识别到用户输入是任务规划意图（"今天要做哪些事 / 待办 / 帮我分解任务"），用 fence block 输出：
    ```tasks
    - title: 任务标题
      desc: 一行描述
      mode: hermes        # hermes / claudeCode / codex 三选一
      eta: 30m            # 可选预估时长
    ```
    客户端会渲染成可点击任务卡片，每张有 📌 Pin / 🤖 让 AI 做 / ✗ 跳过 按钮。**只在确实是任务规划场景用此格式**。
    """
        // v1.3 Phase 4b：把跨模式「共享记忆」拼到 system prompt 末尾，让这家 AI 也接着懂用户。
        // OpenAI 兼容 API 是无状态的，system message 每次请求都带，所以这里直接拼在 systemPrompt 里。
        // Phase 5-3：拼「用界面语言回复」指令到 system prompt 末尾，让回复跟随界面语言。
        let withLang = base + "\n\n" + LocaleManager.aiReplyLanguageInstruction() + NotesWritingContextHolder.shared.promptSuffix()
        // injectMemory=false：工作流 / 验收等隔离调用不带长期画像，只对 {input} 干活（避免把"关于用户"那段也总结了）
        if injectMemory, let memory = UserMemoryStore.shared.injectionText() {
            return withLang + "\n\n" + memory
        }
        return withLang
    }

    let source: ConfigSource

    init(source: ConfigSource = .hermes) {
        self.source = source
    }

    private var baseURL: String {
        UserDefaults.standard.string(forKey: source.baseURLKey) ?? source.defaultBaseURL
    }
    private var apiKey: String {
        switch source {
        case .hermes:
            return UserDefaults.standard.string(forKey: source.apiKeyKey) ?? ""
        case .openclaw:
            // OpenClaw: 优先用 OpenClawGatewayManager 从 ~/.openclaw/openclaw.json 解析出的 token
            // （零配置体验关键 —— 用户不用填 Key）。fallback 到 UserDefaults 让高级用户能覆盖
            if let t = OpenClawGatewayManager.shared.currentToken, !t.isEmpty { return t }
            return UserDefaults.standard.string(forKey: source.apiKeyKey) ?? ""
        case .direct:
            let providerID = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? ""
            guard !providerID.isEmpty else {
                return UserDefaults.standard.string(forKey: source.apiKeyKey) ?? ""
            }

            let providerKeyName = Self.directAPIKeyStorageKey(providerID: providerID)
            // 区分“还没迁移过”(nil) 和“这个服务商明确没有 Key”(空字符串)。
            // 前者允许读旧的 directAPIKey 兜底，后者必须保持空，避免拿别家 Key 去请求。
            if UserDefaults.standard.object(forKey: providerKeyName) != nil {
                return UserDefaults.standard.string(forKey: providerKeyName) ?? ""
            }
            return UserDefaults.standard.string(forKey: source.apiKeyKey) ?? ""
        case .qwen:
            // QwenCode 直连 DashScope：key 直接读 qwenCodeKey（不搞 provider-scope）
            return UserDefaults.standard.string(forKey: source.apiKeyKey) ?? ""
        }
    }
    private var modelName: String {
        UserDefaults.standard.string(forKey: source.modelNameKey) ?? source.defaultModel
    }

    /// 把一条消息转成发给 API 的文本。
    /// Hermes / OpenClaw 是本机自带文件/命令工具的 agent —— 若该消息附带文档，
    /// 就把绝对路径拼进文本，交给对端 agent 用自己的读写/执行工具去操作。
    /// （.direct 在线 AI 走 OpenCodeHTTPClient 的原生 file part，不经过这里。）
    private func messageText(for message: ChatMessage) -> String {
        let paths = message.documentPaths
        guard !paths.isEmpty, source == .hermes || source == .openclaw else {
            return message.content
        }
        var text = message.content
        text += "\n\n附带的文档（绝对路径，请用你的文件工具按需读取 / 修改，或执行相关命令来真正完成任务，而不是只给文字建议）："
        for p in paths { text += "\n- \(p)" }
        return text
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        // ⭐ 整条请求的墙钟硬上限。原来 300s 会把全量模式里走 delegate_task 的长任务(实测 300~440s)
        // 在中途被 URLSession 单方面掐断报 NSURLErrorTimedOut(keepalive 心跳重置不了它)——
        // 这是 Hermes/OpenClaw「连纯计算也超时」的真凶,跟并发上限无关。提到 1800s 对齐 Hermes 网关
        // gateway_timeout:1800。真·装死仍由 90s idle watchdog(streamIdleTimeoutSeconds)兜底,不会无限挂。
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    // MARK: - Streaming

    /// Returns an AsyncThrowingStream that yields text deltas as they arrive via SSE.
    /// - Parameter onUsage: 流结束时拿到真实 token 用量（prompt_tokens）就回调一次，
    ///   给「上下文进度条」用真实数字（估算严重偏低）。在后台线程调用，调用方需自行 hop。
    func streamCompletion(
        messages: [ChatMessage],
        injectMemory: Bool = true,
        onUsage: (@Sendable (Int) -> Void)? = nil,
        onUsageDetail: (@Sendable (TokenUsageBreakdown) -> Void)? = nil,
        onModel: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish(throwing: APIError.cancelled)
                return
            }

            let clock = APIIdleClock()  // 跟踪"最近一次收到数据"的时间戳
            let idleTimeout = self.streamIdleTimeoutSeconds  // 按 source 取(agent 后端 180 / 直连 90),局部常量供两个 Task 闭包共用

            let task = Task { [self] in
                do {
                    let url = try self.makeURL(path: "chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    self.authorize(&request)

                    // 前置一条 system message 注入客户端约定（选项列表 / 任务规划 fence）
                    var apiMessages: [APIMessage] = [APIMessage(role: "system", text: self.systemPrompt(injectMemory: injectMemory))]
                    apiMessages.append(contentsOf: messages.map {
                        APIMessage(role: $0.role.rawValue, text: self.messageText(for: $0), images: $0.images)
                    })
                    let body = ChatCompletionRequest(
                        model: self.modelName,
                        messages: apiMessages,
                        stream: true,
                        streamOptions: StreamOptions(include_usage: true)
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    guard httpResponse.statusCode == 200 else {
                        throw APIError.httpError(statusCode: httpResponse.statusCode, body: "stream failed")
                    }

                    var reportedModel = false
                    for try await line in bytes.lines {
                        await clock.touch()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                        if trimmed.hasPrefix("data: ") {
                            let payload = String(trimmed.dropFirst(6))

                            if payload == "[DONE]" {
                                continue
                            }

                            if let data = payload.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(StreamingChunk.self, from: data) {
                                if let content = chunk.choices?.first?.delta.content {
                                    continuation.yield(content)
                                }
                                // 服务端实际模型（OpenClaw/Hermes 真实模型）—— 首次拿到就回报一次
                                if !reportedModel, let m = chunk.model, !m.isEmpty {
                                    reportedModel = true
                                    onModel?(m)
                                }
                                // include_usage 的末尾 chunk：拿真实 token 用量回调
                                if let usage = chunk.usage {
                                    if let prompt = usage.prompt_tokens, prompt > 0 { onUsage?(prompt) }
                                    let inTok = usage.prompt_tokens ?? 0
                                    let outTok = usage.completion_tokens ?? 0
                                    if inTok + outTok > 0 {
                                        onUsageDetail?(TokenUsageBreakdown(input: inTok, output: outTok))
                                    }
                                }
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    // 区分用户取消 vs 服务端装死，给用户更清晰的错误
                    if await clock.timedOut {
                        let msg = "服务器 \(Int(idleTimeout))s 未响应，已自动断流"
                        continuation.finish(throwing: NSError(
                            domain: "HermesAPI", code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        ))
                    } else if Task.isCancelled {
                        continuation.finish(throwing: APIError.cancelled)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            // Watchdog：每 5s 检查 idle 时间，超过阈值 → 标记 timedOut + cancel 主 task
            let watchdog = Task { [task] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    let idle = await clock.idleSeconds()
                    if idle > idleTimeout {
                        await clock.markTimedOut()
                        task.cancel()
                        return
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                watchdog.cancel()
            }
        }
    }

    // MARK: - Non-streaming

    func sendMessage(messages: [ChatMessage]) async throws -> String {
        let url = try makeURL(path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.timeoutInterval = 120

        var apiMessages: [APIMessage] = [APIMessage(role: "system", text: systemPrompt())]
        apiMessages.append(contentsOf: messages.map {
            APIMessage(role: $0.role.rawValue, text: messageText(for: $0), images: $0.images)
        })
        let body = ChatCompletionRequest(model: modelName, messages: apiMessages, stream: false)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: bodyStr)
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        // content 现在是 enum，取出文本
        if case .text(let s) = completion.choices.first?.message.content {
            return s
        }
        // multimodal 返回（少见）—— 把所有 text part 拼起来
        if case .parts(let arr) = completion.choices.first?.message.content {
            return arr.compactMap { $0.text }.joined()
        }
        return ""
    }

    // MARK: - Health Check

    /// 健康检查 —— 三种 source 走不同 endpoint：
    /// - `.hermes`：先访问 `<host>/health`（Hermes Gateway 自定义端点），失败回退试 `<baseURL>/models`
    ///   （云端部署经常没开 /health，回退到 OpenAI 标准 /models 才能正确判断连通性）
    /// - `.direct`：访问 `<baseURL>/models`（OpenAI 标准端点，DeepSeek / 智谱 / Kimi / MiniMax / OpenAI 都支持）
    /// - `.openclaw`：跟 `.hermes` 同款（OpenClaw gateway 自带 /health，开 endpoint 后 /models 也可用）
    func checkHealth() async throws -> Bool {
        switch source {
        case .hermes, .openclaw:
            // 先试 /health
            if let healthURL = try? makeHealthURL() {
                var request = URLRequest(url: healthURL)
                authorize(&request)
                request.timeoutInterval = 5
                if let (_, response) = try? await session.data(for: request),
                   let code = (response as? HTTPURLResponse)?.statusCode,
                   code == 200 {
                    return true
                }
            }
            // /health 没开 → 回退到 OpenAI 标准 /models
            let modelsURL = try makeURL(path: "models")
            var modelsReq = URLRequest(url: modelsURL)
            authorize(&modelsReq)
            modelsReq.timeoutInterval = 5
            let (_, response) = try await session.data(for: modelsReq)
            guard let code = (response as? HTTPURLResponse)?.statusCode else { return false }
            // 200 表示通；401/403 表示连通但需要 key（自托管也可能开严格鉴权）
            return code == 200 || code == 401 || code == 403
        case .direct, .qwen:
            // baseURL 已经是 .../v1，直接拼 /models 即可拿到模型列表
            // 注：智谱 GLM 的 GET /models 不开放（403），但 401 / 403 都说明"连通了但 key 有问题"
            // 这里把 200/401/403 都算"通"，纯网络不通才算 disconnected
            let url = try makeURL(path: "models")
            var request = URLRequest(url: url)
            authorize(&request)
            request.timeoutInterval = 5
            let (_, response) = try await session.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode else { return false }
            return code == 200 || code == 401 || code == 403
        }
    }

    /// 从 `<baseURL>/models` 拉可用模型列表（H3）
    /// OpenAI 兼容服务标准响应：`{"data": [{"id": "model-name", ...}, ...], "object": "list"}`
    func fetchModels() async throws -> [String] {
        let url = try makeURL(path: "models")
        var request = URLRequest(url: url)
        authorize(&request)
        request.timeoutInterval = 8

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
            throw APIError.httpError(statusCode: httpResp.statusCode, body: "需要鉴权（请填写 API 密钥）")
        }
        guard (200..<300).contains(httpResp.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: httpResp.statusCode, body: String(body.prefix(120)))
        }
        struct ModelsResponse: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        let parsed = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return parsed.data.map(\.id).sorted()
    }

    private func makeHealthURL() throws -> URL {
        guard let base = URL(string: baseURL),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.path = "/health"
        components.query = nil
        guard let url = components.url else {
            throw APIError.invalidResponse
        }
        return url
    }

    // MARK: - Private

    private func makeURL(path: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        guard let url = URL(string: "\(base)\(path)") else {
            throw APIError.invalidResponse
        }
        return url
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func directAPIKeyStorageKey(providerID: String) -> String {
        "directAPIKey.\(providerID)"
    }
}
