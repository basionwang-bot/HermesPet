import Foundation

/// cc-switch 式「AI 档案中心」存储：每个 HTTP 后端可存多套命名配置档案 + 记录当前激活档案，一键切换。
///
/// **不破坏现有链路的关键**：档案 = 各后端"现有生效 UserDefaults 字段"的命名快照。
/// `activate` 把档案值**回填**到那些字段（directAPI 经 viewModel 赋值走 didSet → 复用现成的
/// `scheduleOpenCodeConfigReload` 安全重载 opencode），所有现有读取面原样工作。
/// 持久化在 `~/.hermespet/ai_profiles.json`（与 opencode / conversations 解耦，损坏互不影响）。
@MainActor
@Observable
final class AIProfileStore {
    static let shared = AIProfileStore()

    private(set) var profiles: [AIProfile] = []
    /// 每个后端当前激活的档案 id
    private(set) var activeProfileID: [AgentMode: String] = [:]

    static let didChangeNotification = Notification.Name("HermesPetAIProfilesChanged")

    /// 支持档案的后端（HTTP 类；CLI 类 claude/codex 和 OpenClaw 零配置不建档）
    static let supportedBackends: [AgentMode] = [.directAPI, .qwenCode, .hermes]

    private init() {
        load()
    }

    // MARK: - 查询

    func profiles(for backend: AgentMode) -> [AIProfile] {
        profiles.filter { $0.backend == backend }.sorted { $0.createdAt < $1.createdAt }
    }
    func activeProfile(for backend: AgentMode) -> AIProfile? {
        if let id = activeProfileID[backend], let p = profiles.first(where: { $0.id == id }) { return p }
        return profiles(for: backend).first
    }
    func isActive(_ p: AIProfile) -> Bool {
        activeProfileID[p.backend] == p.id || (activeProfileID[p.backend] == nil && profiles(for: p.backend).first?.id == p.id)
    }

    // MARK: - CRUD

    func add(_ p: AIProfile) {
        profiles.append(p)
        save(); broadcast()
    }
    func update(_ p: AIProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        var np = p; np.updatedAt = Date()
        profiles[i] = np
        save(); broadcast()
    }
    func delete(_ p: AIProfile) {
        // directAPI 至少保 1 个档（兜底，对齐 EnabledModesStore 对 directAPI 的兜底语义）
        if p.backend == .directAPI, profiles(for: .directAPI).count <= 1 { return }
        profiles.removeAll { $0.id == p.id }
        if activeProfileID[p.backend] == p.id {
            activeProfileID[p.backend] = profiles(for: p.backend).first?.id   // 自动激活剩余首个
        }
        save(); broadcast()
    }

    /// 用户在下方表单改了值时，把改动同步回当前激活档（不广播，避免输入时频繁刷 UI）。
    func syncActiveFromFields(backend: AgentMode, viewModel: ChatViewModel) {
        guard let active = activeProfile(for: backend),
              let i = profiles.firstIndex(where: { $0.id == active.id }) else { return }
        var p = profiles[i]
        let ud = UserDefaults.standard
        switch backend {
        case .directAPI:
            p.providerID = ud.string(forKey: "directAPIProviderID") ?? p.providerID
            p.baseURL = viewModel.directAPIBaseURL
            p.apiKey = viewModel.directAPIKey
            p.model = viewModel.directAPIModel
            p.responsePreference = viewModel.directAPIResponsePreference.rawValue
        case .hermes:
            p.providerID = ud.string(forKey: "hermesPresetID") ?? p.providerID
            p.baseURL = viewModel.apiBaseURL
            p.apiKey = viewModel.apiKey
            p.model = viewModel.modelName
        case .qwenCode:
            p.baseURL = viewModel.qwenBaseURL
            p.apiKey = viewModel.qwenAPIKey
            p.model = viewModel.qwenModel
        default: return
        }
        p.updatedAt = Date()
        profiles[i] = p
        save()
    }

    // MARK: - 激活（把档案值回填到该后端"现有生效字段"）

    func activate(_ p: AIProfile, viewModel: ChatViewModel) {
        activeProfileID[p.backend] = p.id
        save(); broadcast()
        let ud = UserDefaults.standard
        switch p.backend {
        case .directAPI:
            ud.set(p.providerID, forKey: "directAPIProviderID")
            ud.set(p.apiKey, forKey: "directAPIKey.\(p.providerID)")
            if p.providerID == "custom" {
                viewModel.directAPIBaseURL = p.baseURL    // didSet → 落盘 + scheduleOpenCodeConfigReload
                viewModel.directAPIModel = p.model
            } else {
                if let raw = p.responsePreference, let pref = DirectResponsePreference(rawValue: raw) {
                    viewModel.directAPIResponsePreference = pref
                }
                if !p.baseURL.isEmpty { viewModel.directAPIBaseURL = p.baseURL }   // 兼容 SettingsView.onAppear 的 detect 反查
            }
            viewModel.directAPIKey = p.apiKey   // ⭐ 最后赋值 → didSet 触发一次（800ms 防抖合并）安全重载 opencode
        case .hermes:
            ud.set(p.providerID, forKey: "hermesPresetID")
            viewModel.apiBaseURL = p.baseURL
            viewModel.apiKey = p.apiKey
            viewModel.modelName = p.model
        case .qwenCode:
            viewModel.qwenBaseURL = p.baseURL
            viewModel.qwenAPIKey = p.apiKey
            viewModel.qwenModel = p.model
        default:
            break
        }
    }

    // MARK: - 从 ProviderPreset 新建

    func makeProfile(from preset: ProviderPreset, backend: AgentMode) -> AIProfile {
        if backend == .directAPI {
            // directAPI 走 opencode 的 provider 机制：providerID = 预设 id，model 由 pref 推
            return AIProfile(backend: .directAPI, name: preset.displayName, providerID: preset.id,
                             baseURL: preset.baseURL, apiKey: "", model: "", responsePreference: "balanced")
        }
        // hermes / qwen 直连：统一当 custom，用预设的 URL + 默认模型
        return AIProfile(backend: backend, name: preset.displayName, providerID: "custom",
                         baseURL: preset.baseURL, apiKey: "", model: preset.defaultModel)
    }

    func makeCustomProfile(backend: AgentMode) -> AIProfile {
        AIProfile(backend: backend, name: "自定义", providerID: "custom",
                  baseURL: "", apiKey: "", model: "",
                  responsePreference: backend == .directAPI ? "balanced" : nil)
    }

    // MARK: - 迁移：把现有配置转成各后端默认档案（SchemaMigrator v2 调，幂等无损）

    func seedFromLegacyIfNeeded() {
        guard profiles.isEmpty else { return }   // 已有档案 → 不重复 seed（幂等）
        let ud = UserDefaults.standard
        var built: [AIProfile] = []
        var active: [AgentMode: String] = [:]

        // directAPI —— 永远建 ≥1 个（对齐 directAPI 永久启用的兜底语义）
        let dpid = ud.string(forKey: "directAPIProviderID") ?? "deepseek"
        let dkey = ud.string(forKey: "directAPIKey.\(dpid)") ?? ud.string(forKey: "directAPIKey") ?? ""
        let dname = ProviderPreset.all.first(where: { $0.id == dpid })?.displayName
            ?? (dpid == "custom" ? "自定义" : dpid)
        let dProfile = AIProfile(
            backend: .directAPI, name: dname, providerID: dpid,
            baseURL: ud.string(forKey: "directAPIBaseURL") ?? "",
            apiKey: dkey, model: ud.string(forKey: "directAPIModel") ?? "",
            responsePreference: ud.string(forKey: "directAPIResponsePreference") ?? "balanced")
        built.append(dProfile); active[.directAPI] = dProfile.id

        // hermes —— 配过 baseURL 才建（默认本地 localhost:8642 也算配过）
        let hURL = (ud.string(forKey: "apiBaseURL") ?? "").trimmingCharacters(in: .whitespaces)
        if !hURL.isEmpty {
            let h = AIProfile(
                backend: .hermes, name: "Hermes",
                providerID: ud.string(forKey: "hermesPresetID") ?? "hermes-local",
                baseURL: hURL, apiKey: ud.string(forKey: "apiKey") ?? "",
                model: ud.string(forKey: "modelName") ?? "")
            built.append(h); active[.hermes] = h.id
        }

        // qwen —— 配过 Key 或 baseURL 才建
        let qKey = (ud.string(forKey: "qwenAPIKey") ?? "").trimmingCharacters(in: .whitespaces)
        let qURL = (ud.string(forKey: "qwenBaseURL") ?? "").trimmingCharacters(in: .whitespaces)
        if !qKey.isEmpty || !qURL.isEmpty {
            let q = AIProfile(
                backend: .qwenCode, name: "QwenCode", providerID: "custom",
                baseURL: qURL, apiKey: qKey, model: ud.string(forKey: "qwenModel") ?? "")
            built.append(q); active[.qwenCode] = q.id
        }

        profiles = built
        activeProfileID = active
        save()
    }

    // MARK: - 持久化（~/.hermespet/ai_profiles.json，atomic + 0o600）

    private var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet/ai_profiles.json")
    }

    private struct Persisted: Codable {
        var profiles: [AIProfile]
        var active: [String: String]   // backend rawValue → profile id
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        profiles = p.profiles
        var active: [AgentMode: String] = [:]
        for (raw, id) in p.active {
            if let m = AgentMode(rawValue: raw) { active[m] = id }
        }
        activeProfileID = active
    }

    private func save() {
        var active: [String: String] = [:]
        for (m, id) in activeProfileID { active[m.rawValue] = id }
        guard let data = try? JSONEncoder().encode(Persisted(profiles: profiles, active: active)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func broadcast() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
