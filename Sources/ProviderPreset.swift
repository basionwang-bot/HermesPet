import Foundation

/// 在线 AI 的易懂回复偏好。UI 面向用户展示这个，而不是直接暴露模型字符串。
enum DirectResponsePreference: String, CaseIterable, Identifiable, Hashable {
    case fast
    case balanced
    case deep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "快速"
        case .balanced: return "平衡"
        case .deep: return "深度"
        }
    }

    var caption: String {
        switch self {
        case .fast: return "更快，适合日常问答"
        case .balanced: return "默认推荐，速度和质量均衡"
        case .deep: return "更慢，适合复杂问题"
        }
    }
}

/// Hermes 模式的"服务商预设" —— 让没装 Claude Code / Codex CLI 的用户
/// 也能开箱即用：选一家服务商，自动填好 baseURL + 推荐模型，只需要再粘 API Key。
///
/// **为什么不在 Hermes 之外单独开一个 AgentMode**：
/// Hermes 模式技术上就是 OpenAI 兼容 HTTP 客户端，换 baseURL 就能直连任何兼容服务商。
/// 多一个枚举会让 ChatViewModel / 持久化 / 灵动岛颜色一堆地方跟着改，没必要。
/// 这里只是把"配置体验"做傻瓜化。
struct ProviderPreset: Identifiable, Hashable {
    let id: String          // UserDefaults 存的预设标识
    let displayName: String // UI 显示名
    let baseURL: String     // OpenAI 兼容 base URL
    let defaultModel: String// 推荐主力模型
    let altModels: [String] // 备选模型（写进 placeholder / 文档提示）
    let signupURL: String?  // 注册 / 获取 API Key 的入口（用户点"如何获取 Key"时跳）
    private let fastModel: String
    private let balancedModel: String
    private let deepModel: String

    init(id: String,
         displayName: String,
         baseURL: String,
         defaultModel: String,
         altModels: [String],
         signupURL: String?,
         fastModel: String? = nil,
         balancedModel: String? = nil,
         deepModel: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.altModels = altModels
        self.signupURL = signupURL
        self.fastModel = fastModel ?? defaultModel
        self.balancedModel = balancedModel ?? defaultModel
        self.deepModel = deepModel ?? defaultModel
    }

    /// 预设列表 —— 顺序就是 UI 上 Picker 显示的顺序。
    /// 模型字符串以 2026-05 各家官方 GET /models 实测为准（不是文档，文档可能落后）。
    /// **重要**：默认 / 平衡 / 深度 全部避开 reasoning_content 字段类型的推理模型
    /// （DeepSeek V4 / Kimi K2.x / OpenAI o1+ 都属此类），因为 opencode v1.15.1
    /// 还没适配 reasoning_content 字段（PR #25110/#24443/#24218 在修但未合并）。
    /// DeepSeek 例外：API 只暴露 V4 系列，没非推理可选，所以仍用 V4 但用户要知道风险
    static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-v4-pro",
            altModels: ["deepseek-v4-flash"],
            signupURL: "https://platform.deepseek.com/api_keys",
            fastModel: "deepseek-v4-flash",
            balancedModel: "deepseek-v4-pro",
            deepModel: "deepseek-v4-pro"
        ),
        ProviderPreset(
            id: "zhipu",
            displayName: "智谱 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-5",
            altModels: ["glm-5.1", "glm-5-turbo"],
            signupURL: "https://open.bigmodel.cn/usercenter/apikeys",
            fastModel: "glm-5-turbo",
            balancedModel: "glm-5",
            deepModel: "glm-5.1"
        ),
        ProviderPreset(
            id: "moonshot",
            displayName: "Moonshot Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            // K2.x 是 reasoning 系列（用 delta.reasoning_content）—— opencode 之前因
            // 缺 reasoning_content 适配会偶尔无响应。HermesPet 内置 ReasoningProxy 后
            // 已经把 reasoning chunks 过滤掉了，K2.x 可以正常用 + 享受推理能力。
            defaultModel: "kimi-k2.6",
            altModels: ["kimi-k2.5", "kimi-k2"],
            signupURL: "https://platform.moonshot.cn/console/api-keys",
            fastModel: "kimi-k2",
            balancedModel: "kimi-k2.5",
            deepModel: "kimi-k2.6"
        ),
        ProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            // **避开 o1/o3/o4 reasoning 系列**，默认走 GPT-5 普通对话模型
            defaultModel: "gpt-5.4",
            altModels: ["gpt-5.5", "gpt-5.4-mini"],
            signupURL: "https://platform.openai.com/api-keys",
            fastModel: "gpt-5.4-mini",
            balancedModel: "gpt-5.4",
            deepModel: "gpt-5.5"
        )
    ]

    /// 自定义预设 —— 不在 all 里，由 UI 单独追加一项让用户自己填 URL/模型
    static let custom = ProviderPreset(
        id: "custom",
        displayName: "自定义",
        baseURL: "",
        defaultModel: "",
        altModels: [],
        signupURL: nil
    )

    /// 老用户 / 自托管 Hermes Gateway 的兜底预设（baseURL 含 localhost）。
    /// 用户已经配过 http://localhost:8642 的话设置面板会识别成这个。
    static let hermesLocal = ProviderPreset(
        id: "hermes-local",
        displayName: "Hermes Gateway（本地）",
        baseURL: "http://localhost:8642/v1",
        defaultModel: "hermes-agent",
        altModels: [],
        signupURL: nil
    )

    /// 根据当前已存的 baseURL 反查应该选哪个预设（设置面板首次打开时判断当前在用哪家）。
    /// 完全匹配优先；找不到就归到"自定义"，让用户能编辑完整 URL。
    static func detect(baseURL: String) -> ProviderPreset {
        // 归一化：去末尾斜杠，方便匹配（用户可能填 https://api.deepseek.com/v1/）
        let normalized = baseURL.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if normalized.isEmpty { return all[0] }   // 全新用户默认第一项
        if normalized.contains("localhost") || normalized.contains("127.0.0.1") {
            return hermesLocal
        }
        for preset in all {
            let presetURL = preset.baseURL.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            if normalized == presetURL { return preset }
        }
        return custom
    }

    func model(for preference: DirectResponsePreference) -> String {
        switch preference {
        case .fast: return fastModel
        case .balanced: return balancedModel
        case .deep: return deepModel
        }
    }

    func preference(for model: String) -> DirectResponsePreference? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == balancedModel { return .balanced }
        if trimmed == fastModel { return .fast }
        if trimmed == deepModel { return .deep }
        return nil
    }
}
