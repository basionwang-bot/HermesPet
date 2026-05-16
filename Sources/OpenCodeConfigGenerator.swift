import Foundation

/// 把 HermesPet 的 ProviderPreset + 用户 API Key 翻译成 opencode 能读的
/// `opencode.json`。让用户在 HermesPet 设置里配的 DeepSeek/GLM/Kimi/OpenAI key
/// 自动透传给 bundled opencode runtime，无需用户再去配 opencode 自己的文件。
///
/// **写到哪**：每次 `OpenCodeClient.runStream` spawn 之前，写一份到该对话的
/// `directory/opencode.json`。opencode 启动时会自动 load 对应 cwd 下的配置
/// （这是 opencode 配置加载链的最后一环，优先级 < 用户全局 ~/.config/opencode/）。
///
/// **为什么不写到全局 `~/.config/opencode/`**：用户可能自己装了 opencode 跑过
/// TUI，已经在那写了 provider 配置。HermesPet 不应该覆盖用户自己的偏好。
enum OpenCodeConfigGenerator {

    /// 在 `directory` 下写 `opencode.json` + `AGENTS.md`，让 opencode 启动时加载
    /// HermesPet 的 provider 配置 + agent 提示。
    /// - 没配 API Key 的 provider 不写（避免空 key 导致 opencode 报错）
    /// - 文件权限 600，避免被其他用户读到 API Key
    static func ensureConfig(in directory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("opencode.json")

        let config = buildConfig()
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        // AGENTS.md：告诉 opencode 加载的 agent 真实身份，避免它误以为自己是 Claude
        // （opencode 是 Claude Code 风格设计，默认 prompt 让 model 当 Claude 风格 agent）。
        // 用户在线 AI 用 Kimi / GLM / OpenAI / DeepSeek 时不希望 AI 自称 Claude
        let modelID = currentModelID()
        let identity = identityFor(modelID: modelID)
        let agentsMD = """
        # HermesPet Agent Identity

        你是 **\(identity.displayName)**（\(identity.providerName)，模型 ID `\(modelID)`），
        在 HermesPet 桌面客户端的「在线 AI」模式下为用户服务。

        ## 重要身份规则

        - 当用户问"你是什么模型"、"你是谁"、"who are you" 等身份问题时，**如实回答**你是 **\(identity.displayName)**，由 \(identity.providerName) 训练。
        - **不要自称 Claude / Claude Code / GPT / ChatGPT**，除非你**真的就是**对应模型。
        - 不要说"我的名字叫 Claude，但实际驱动我的是 X" 这种混淆表述。
        - 不要伪装其他厂商的模型。

        ## 行为规则

        - 用中文与用户对话（除非用户用英文）。
        - 用户问读文件 / 跑命令 / 联网等需要本地能力时，主动用对应工具（`list_files` / `read` / `bash` / `webfetch` 等）。
        - 回答时简洁直接，避免不必要的格式化（无意义的 markdown 标题、空 bullet 列表等）。
        """
        let agentsPath = (directory as NSString).appendingPathComponent("AGENTS.md")
        try? agentsMD.data(using: .utf8)?.write(to: URL(fileURLWithPath: agentsPath), options: .atomic)
    }

    /// model ID 到友好身份描述的映射（用于 AGENTS.md 让 AI 自我介绍时报真实身份）
    private static func identityFor(modelID: String) -> (displayName: String, providerName: String) {
        let lower = modelID.lowercased()
        // provider/model 拆开
        let parts = lower.split(separator: "/", maxSplits: 1).map(String.init)
        let providerPart = parts.first ?? ""
        let modelPart = parts.count > 1 ? parts[1] : ""

        // 按 provider + model 关键字推断
        if providerPart == "opencode" {
            // opencode 内置免费模型 —— 仍然是 DeepSeek 旗下，但走 opencode 中转
            if modelPart.contains("deepseek") { return ("DeepSeek V4 Flash (免费版)", "DeepSeek / 深度求索") }
            if modelPart.contains("minimax") { return ("MiniMax M2.5 (免费版)", "MiniMax") }
            if modelPart.contains("nemotron") { return ("Nemotron 3 Super (免费版)", "NVIDIA") }
            if modelPart.contains("ring") { return ("Ring 2.6 1T (免费版)", "蚁集 Ring") }
            return ("\(modelID)", "opencode 内置")
        }
        if providerPart == "deepseek" {
            return ("DeepSeek \(modelPart.uppercased())", "DeepSeek / 深度求索")
        }
        if providerPart == "moonshot" {
            // kimi-k2.6 / moonshot-v1-8k 等
            if modelPart.contains("kimi") {
                return ("Kimi \(modelPart.replacingOccurrences(of: "kimi-", with: "").uppercased())", "Moonshot AI / 月之暗面")
            }
            return ("\(modelPart)", "Moonshot AI / 月之暗面")
        }
        if providerPart == "zhipu" {
            return ("\(modelPart.uppercased())", "智谱 AI / Zhipu")
        }
        if providerPart == "openai" {
            return ("\(modelPart.uppercased())", "OpenAI")
        }
        return (modelID, "未知服务商")
    }

    /// 当前对话应该用什么 model ID（`provider/model` opencode 格式）：
    /// - 没配 API Key → 默认 opencode 内置 free 模型 `opencode/deepseek-v4-flash-free`
    /// - 配了 key → 按 directAPIProviderID + DirectResponsePreference 推 model
    /// - 自定义服务商 → 用户在设置里直接填 directAPIModel
    ///
    /// **强制原则（用户明确要求 2026-05-16）**：用户配了付费 Key 就走用户的 Key，
    /// 绝对不偷偷 fallback 到 opencode 免费模型。即便目标模型在 opencode 当前版本下
    /// 偶尔有 reasoning_content 兼容问题（DeepSeek V4 / Kimi K2.x 推理系列），也要忠于用户配置。
    /// 缓解方式：① ProviderPreset 默认推非推理模型（Kimi 默认 moonshot-v1 非推理系列）；
    /// ② 设置面板上明确警告 reasoning model 可能"偶尔无响应"；③ 后续做本地 ReasoningProxy
    /// 彻底解决（见 TODO.md）
    static func currentModelID() -> String {
        let providerID = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? "deepseek"

        // 自定义 provider：UserDefaults 里有完整 baseURL + 用户填的模型名
        if providerID == "custom" {
            let key = UserDefaults.standard.string(forKey: "directAPIKey.custom")
                ?? UserDefaults.standard.string(forKey: "directAPIKey") ?? ""
            let model = UserDefaults.standard.string(forKey: "directAPIModel") ?? ""
            if key.isEmpty || model.isEmpty {
                return defaultFreeModel
            }
            return "custom/\(model)"
        }

        let key = effectiveAPIKey(for: providerID)
        if key.isEmpty {
            return defaultFreeModel
        }

        guard let preset = ProviderPreset.all.first(where: { $0.id == providerID }) else {
            return defaultFreeModel
        }
        let prefRaw = UserDefaults.standard.string(forKey: "directResponsePreference") ?? "balanced"
        let pref = DirectResponsePreference(rawValue: prefRaw) ?? .balanced
        let model = preset.model(for: pref)
        return "\(providerID)/\(model)"
    }

    /// 当前选的 model 是不是 reasoning 类型且 proxy **没在跑**（unstable 状态）。
    /// ReasoningProxy 在跑时所有 reasoning 模型都被过滤后透传，已经稳定 → 返回 false
    static var isReasoningModelKnownUnstable: Bool {
        if ReasoningProxy.shared.isReady { return false }
        let model = currentModelID().lowercased()
        if model.contains("deepseek-v4") && !model.contains("free") { return true }
        if model.contains("kimi-k2") { return true }
        if model.hasPrefix("openai/o1") || model.hasPrefix("openai/o3") || model.hasPrefix("openai/o4") { return true }
        return false
    }

    /// 当前选中的 provider 是否已经配了能用的 API Key
    static var hasConfiguredKey: Bool {
        let providerID = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? "deepseek"
        return !effectiveAPIKey(for: providerID).isEmpty
    }

    // MARK: - Internal

    private static let defaultFreeModel = "opencode/deepseek-v4-flash-free"

    /// 每个 provider 的 API Key 存在 `directAPIKey.<providerID>`，
    /// 老用户可能只存了全局 `directAPIKey`（迁移兜底）
    private static func effectiveAPIKey(for providerID: String) -> String {
        let scoped = UserDefaults.standard.string(forKey: "directAPIKey.\(providerID)") ?? ""
        if !scoped.isEmpty { return scoped }
        return UserDefaults.standard.string(forKey: "directAPIKey") ?? ""
    }

    /// 拼 opencode 配置字典。只写已配 Key 的 provider，避免空 key 让 opencode 报错
    private static func buildConfig() -> [String: Any] {
        var providers: [String: Any] = [:]

        // 如果 ReasoningProxy 已 ready，所有 provider baseURL 改写到本地代理
        // → opencode 看到的是过滤掉 reasoning_content 的纯净 OpenAI 标准 stream
        let proxyURL = ReasoningProxy.shared.baseURL?.absoluteString

        for preset in ProviderPreset.all {
            let key = effectiveAPIKey(for: preset.id)
            guard !key.isEmpty else { continue }

            var models: [String: Any] = [:]
            // 默认模型
            models[preset.defaultModel] = ["name": "\(preset.displayName) · \(preset.defaultModel)"]
            // 备选模型
            for alt in preset.altModels {
                models[alt] = ["name": "\(preset.displayName) · \(alt)"]
            }

            // 改写 baseURL 到本地代理（仅当代理在跑）。代理按 providerID 路由：
            // http://127.0.0.1:<port>/<providerID> → 真实 baseURL
            let proxiedURL: String = {
                if let proxy = proxyURL,
                   ReasoningProxy.upstreamBaseURLs[preset.id] != nil {
                    return "\(proxy)/\(preset.id)"
                }
                return preset.baseURL
            }()

            providers[preset.id] = [
                "npm": "@ai-sdk/openai-compatible",
                "name": preset.displayName,
                "options": [
                    "baseURL": proxiedURL,
                    "apiKey": key
                ],
                "models": models
            ]
        }

        // 自定义 provider（用户手填 baseURL + model）
        let customID = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? ""
        if customID == "custom" {
            let baseURL = UserDefaults.standard.string(forKey: "directAPIBaseURL") ?? ""
            let key = effectiveAPIKey(for: "custom")
            let model = UserDefaults.standard.string(forKey: "directAPIModel") ?? ""
            if !baseURL.isEmpty && !key.isEmpty && !model.isEmpty {
                providers["custom"] = [
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Custom",
                    "options": [
                        "baseURL": baseURL,
                        "apiKey": key
                    ],
                    "models": [
                        model: ["name": "Custom · \(model)"]
                    ]
                ]
            }
        }

        return [
            "$schema": "https://opencode.ai/config.json",
            "provider": providers
        ]
    }
}
