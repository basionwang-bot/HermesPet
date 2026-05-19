import Foundation

/// **EnabledModesStore** —— 用户级"哪些 AI mode 在 UI 上可见"配置。
///
/// 背景：v1.3.6 起 HermesPet 支持 5 个 AI mode（在线 AI / OpenClaw / Hermes / Claude Code / Codex）。
/// 新用户首启**默认只见在线 AI** 一个 mode，其他 4 个 mode 在设置里手动开启（开启时还会
/// 自动检测本机是否装好 CLI / daemon）。老用户保留以前的 4 mode 全开行为。
///
/// **U5 自动启用机制**：daemon ready 时 OpenClawGatewayManager / HermesGatewayManager 发通知，
/// 走 `autoEnableIfNotExplicitlyDisabled(_:)` 自动加进 enabledModes —— 除非用户曾经手动关过。
/// 用户手动关 = 加进 userExplicitlyDisabled 黑名单 = 永远不再自动加。
///
/// **持久化**：
/// - UserDefaults key `enabledModes` 存 String array（AgentMode raw values）
/// - UserDefaults key `explicitlyDisabledModes` 存"用户手动关过的 mode" String array
@MainActor
@Observable
final class EnabledModesStore {
    static let shared = EnabledModesStore()

    /// 当前 UI 可见的 mode 集合。
    /// **在线 AI (.directAPI) 永远在集合里**，是底线兜底（任何用户都至少能用 HTTP API 聊天）。
    private(set) var enabledModes: Set<AgentMode> = [.directAPI]

    /// 用户曾经主动关过的 mode 黑名单（U5）。
    /// `autoEnableIfNotExplicitlyDisabled` 检测到 mode 在这个集合里就不自动加。
    /// 用户后续在设置里手动重新打开 → 从黑名单移除，下次 daemon ready 又能自动加回。
    private(set) var userExplicitlyDisabled: Set<AgentMode> = []

    /// UserDefaults 持久化 keys
    static let storageKey = "enabledModes"
    static let disabledStorageKey = "explicitlyDisabledModes"

    /// 状态变化广播 —— mode 切换 UI（PetHeaderStrip / 灵动岛 / mode picker）订阅刷新
    static let didChangeNotification = Notification.Name("HermesPetEnabledModesChanged")

    private init() {
        loadOrMigrate()
    }

    // MARK: - 公开 API

    /// 检查某个 mode 是否启用
    func isEnabled(_ mode: AgentMode) -> Bool {
        enabledModes.contains(mode)
    }

    /// 启用某个 mode（如果已启用是 no-op）。
    /// 用户**手动**启用 → 从 explicitlyDisabled 黑名单移除，让 autoEnable 可以再次工作
    func enable(_ mode: AgentMode) {
        var changed = false
        if userExplicitlyDisabled.remove(mode) != nil { changed = true }
        if !enabledModes.contains(mode) {
            enabledModes.insert(mode)
            changed = true
        }
        if changed {
            save()
            broadcastChange()
        }
    }

    /// 关闭某个 mode。**这是用户主动关闭** → 加入 explicitlyDisabled 黑名单
    /// （之后 daemon ready 不会自动加回，尊重用户意愿）。
    /// **在线 AI 不能关** —— 静默忽略。
    func disable(_ mode: AgentMode) {
        guard mode != .directAPI else { return }
        var changed = false
        if enabledModes.contains(mode) {
            enabledModes.remove(mode)
            changed = true
        }
        if !userExplicitlyDisabled.contains(mode) {
            userExplicitlyDisabled.insert(mode)
            changed = true
        }
        if changed {
            save()
            broadcastChange()
        }
    }

    /// **U5 核心**：daemon ready 时调用 —— 自动加进 enabledModes，**除非用户曾经手动关过**。
    /// HermesPet 启动时 OpenClawGatewayManager / HermesGatewayManager 发 ready 通知后由 AppDelegate 调用。
    func autoEnableIfNotExplicitlyDisabled(_ mode: AgentMode) {
        // 已启用 / 用户关过 → 不动
        guard !enabledModes.contains(mode) else { return }
        guard !userExplicitlyDisabled.contains(mode) else { return }
        enabledModes.insert(mode)
        save()
        broadcastChange()
    }

    /// 一次性 set 整个集合（用于设置页 toggle 同步更新）。
    /// 自动确保 .directAPI 在集合里
    func setEnabled(_ modes: Set<AgentMode>) {
        var next = modes
        next.insert(.directAPI)   // 永远兜底
        guard next != enabledModes else { return }
        enabledModes = next
        save()
        broadcastChange()
    }

    // MARK: - Init 阶段的迁移逻辑

    /// 三路径加载：
    /// (a) UserDefaults 有 key → 直接 load
    /// (b) 无 key + 有 ~/.hermespet/conversations.json → 老用户 → 默认 4 mode 全开（保留旧体验）
    /// (c) 无 key + 无 conversations.json → 全新用户 → 默认仅 .directAPI
    /// 三路径走完都立即调 save() 落盘，下次启动就走单一持久化路径
    private func loadOrMigrate() {
        let ud = UserDefaults.standard

        // 先 load explicitlyDisabled 黑名单
        if let disabledArr = ud.array(forKey: Self.disabledStorageKey) as? [String] {
            var s = Set<AgentMode>()
            for raw in disabledArr {
                if let m = AgentMode(rawValue: raw) { s.insert(m) }
            }
            self.userExplicitlyDisabled = s
        }

        if let rawArr = ud.array(forKey: Self.storageKey) as? [String] {
            // 已有持久化值 —— 直接 load
            var s = Set<AgentMode>()
            for raw in rawArr {
                if let m = AgentMode(rawValue: raw) { s.insert(m) }
            }
            s.insert(.directAPI)   // 兜底
            self.enabledModes = s
            return
        }

        // 检查老用户标志：~/.hermespet/conversations.json 存在 = 老用户
        let home = FileManager.default.homeDirectoryForCurrentUser
        let convPath = home.appendingPathComponent(".hermespet/conversations.json")
        let isLegacyUser = FileManager.default.fileExists(atPath: convPath.path)

        if isLegacyUser {
            // 老用户：保留旧体验，4 mode 都启用（不含 .openclaw，老用户没用过这个 mode；
            // 但启动时 OpenClawGatewayManager ready 后会通过 autoEnableIfNotExplicitlyDisabled 自动加）
            self.enabledModes = [.directAPI, .hermes, .claudeCode, .codex]
        } else {
            // 全新用户：只开在线 AI，其他 mode 由 daemon ready / CLI 检测后自动加
            self.enabledModes = [.directAPI]
        }
        save()
    }

    // MARK: - 持久化

    private func save() {
        let arr = enabledModes.map { $0.rawValue }.sorted()
        UserDefaults.standard.set(arr, forKey: Self.storageKey)

        let disabledArr = userExplicitlyDisabled.map { $0.rawValue }.sorted()
        UserDefaults.standard.set(disabledArr, forKey: Self.disabledStorageKey)
    }

    private func broadcastChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
