import Foundation

/// 一套命名的 AI 后端配置档案（cc-switch 式）：{名字, 地址, Key, 模型}。
///
/// 只用于 **HTTP 类后端**（directAPI / hermes / qwenCode）—— CLI 类（claudeCode/codex）和 OpenClaw
/// 是零配置（复用各自登录 / 本地 daemon），不建档。
///
/// **核心思想**：档案是各后端"现有生效 UserDefaults 字段"的**命名快照**。激活档案 =
/// 把这些值回填到那些字段（见 `AIProfileStore.activate`），所有现有读取面
/// （opencode `buildConfig` / `APIClient.apiKey` / `QwenCodeClient`）原样工作 —— 零侵入现有链路。
struct AIProfile: Identifiable, Codable, Equatable {
    let id: String
    var backend: AgentMode          // .directAPI / .hermes / .qwenCode
    var name: String                // 用户命名，如 "DeepSeek 个人号"
    /// directAPI: ProviderPreset.id 或 "custom"；hermes: hermesPresetID；qwen: 服务商名或 "custom"
    var providerID: String
    var baseURL: String
    var apiKey: String
    /// 预设档可空（由 responsePreference 经 ProviderPreset 推）；custom / hermes / qwen 显式填
    var model: String
    /// 仅 directAPI 预设档用（DirectResponsePreference.rawValue：fast/balanced/deep）
    var responsePreference: String?
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         backend: AgentMode,
         name: String,
         providerID: String,
         baseURL: String = "",
         apiKey: String = "",
         model: String = "",
         responsePreference: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.backend = backend
        self.name = name
        self.providerID = providerID
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.responsePreference = responsePreference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
