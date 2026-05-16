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
/// - `.direct`：直连第三方 OpenAI 兼容服务商（DeepSeek / 智谱 / Kimi / OpenAI…）
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

        var baseURLKey: String {
            switch self {
            case .hermes: return "apiBaseURL"
            case .direct: return "directAPIBaseURL"
            }
        }
        var apiKeyKey: String {
            switch self {
            case .hermes: return "apiKey"
            case .direct: return "directAPIKey"
            }
        }
        var modelNameKey: String {
            switch self {
            case .hermes: return "modelName"
            case .direct: return "directAPIModel"
            }
        }
        var defaultBaseURL: String {
            switch self {
            case .hermes: return "http://localhost:8642/v1"
            case .direct: return ""   // 没默认 —— UI 强制让用户选预设
            }
        }
        var defaultModel: String {
            switch self {
            case .hermes: return "hermes-agent"
            case .direct: return ""   // 同上
            }
        }
    }

    /// SSE 流空闲超时（秒）。超过此值无数据 → 主动断流报错，避免卡到 timeoutIntervalForRequest 才返回
    private static let streamIdleTimeoutSeconds: TimeInterval = 90

    /// 注入给 Hermes / 在线 AI 的 system 提示 —— 让 AI 识别任务规划意图时输出 ```tasks fence。
    /// Claude/Codex 的提示靠 prompt 末尾拼接（它们没 system 概念），Hermes/直连 走 OpenAI 兼容 API
    /// 直接前置一条 role=system 即可
    private var systemPrompt: String {
        let identityBlock: String
        switch source {
        case .hermes:
            identityBlock = """
            当前模式：Hermes
            当前后端：Hermes Gateway / OpenAI 兼容 API
            当前模型：\(modelName)
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
        }

        return """
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
        }
    }
    private var modelName: String {
        UserDefaults.standard.string(forKey: source.modelNameKey) ?? source.defaultModel
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Streaming

    /// Returns an AsyncThrowingStream that yields text deltas as they arrive via SSE.
    func streamCompletion(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish(throwing: APIError.cancelled)
                return
            }

            let clock = APIIdleClock()  // 跟踪"最近一次收到数据"的时间戳

            let task = Task { [self] in
                do {
                    let url = try self.makeURL(path: "chat/completions")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    self.authorize(&request)

                    // 前置一条 system message 注入客户端约定（选项列表 / 任务规划 fence）
                    var apiMessages: [APIMessage] = [APIMessage(role: "system", text: self.systemPrompt)]
                    apiMessages.append(contentsOf: messages.map {
                        APIMessage(role: $0.role.rawValue, text: $0.content, images: $0.images)
                    })
                    let body = ChatCompletionRequest(model: self.modelName, messages: apiMessages, stream: true)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    guard httpResponse.statusCode == 200 else {
                        throw APIError.httpError(statusCode: httpResponse.statusCode, body: "stream failed")
                    }

                    for try await line in bytes.lines {
                        await clock.touch()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                        if trimmed.hasPrefix("data: ") {
                            let payload = String(trimmed.dropFirst(6))

                            if payload == "[DONE]" {
                                continue
                            }

                            if let data = payload.data(using: .utf8),
                               let chunk = try? JSONDecoder().decode(StreamingChunk.self, from: data),
                               let content = chunk.choices?.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    // 区分用户取消 vs 服务端装死，给用户更清晰的错误
                    if await clock.timedOut {
                        let msg = "服务器 \(Int(Self.streamIdleTimeoutSeconds))s 未响应，已自动断流"
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
                    if Task.isCancelled { return }  // sleep 期间被 cancel 立即退出，避免再 await idleSeconds
                    let idle = await clock.idleSeconds()
                    if idle > Self.streamIdleTimeoutSeconds {
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

        var apiMessages: [APIMessage] = [APIMessage(role: "system", text: systemPrompt)]
        apiMessages.append(contentsOf: messages.map {
            APIMessage(role: $0.role.rawValue, text: $0.content, images: $0.images)
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

    /// 健康检查 —— 两种 source 走不同 endpoint：
    /// - `.hermes`：访问 `<host>/health`（Hermes Gateway 自定义的健康端点）
    /// - `.direct`：访问 `<baseURL>/models`（OpenAI 标准端点，DeepSeek / 智谱 / Kimi / OpenAI 都支持）
    func checkHealth() async throws -> Bool {
        let url: URL
        switch source {
        case .hermes:
            url = try makeHealthURL()
        case .direct:
            // baseURL 已经是 .../v1，直接拼 /models 即可拿到模型列表
            // 注：智谱 GLM 的 GET /models 不开放（403），但 401 / 403 都说明"连通了但 key 有问题"
            // 这里把 200/401/403 都算"通"，纯网络不通才算 disconnected
            url = try makeURL(path: "models")
        }
        var request = URLRequest(url: url)
        authorize(&request)
        request.timeoutInterval = 5

        let (_, response) = try await session.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        if source == .direct {
            return code == 200 || code == 401 || code == 403
        }
        return code == 200
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
