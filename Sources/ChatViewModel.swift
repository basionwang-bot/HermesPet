import Foundation
import SwiftUI
import ServiceManagement

@MainActor
@Observable
final class ChatViewModel {
    /// 所有对话（≤ kMaxConversations 个）
    var conversations: [Conversation] = []
    /// 当前激活对话的 ID —— UI 上"高亮"的那个胶囊
    var activeConversationID: String = ""

    /// 当前激活对话的消息列表 —— computed property，
    /// 读写都会落到 conversations[activeIndex].messages 上。
    /// 这样老代码里所有 `self.messages.append(...)` / `self.messages[i] = ...` 不用改。
    var messages: [ChatMessage] {
        get {
            conversations.first(where: { $0.id == activeConversationID })?.messages ?? []
        }
        set {
            guard let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
            conversations[idx].messages = newValue
            conversations[idx].updatedAt = Date()
        }
    }

    var inputText: String = ""
    /// 当前激活对话是否正在等 AI 回复。computed，依赖 activeConversationID + conversations[].isStreaming，
    /// 切换对话时输入栏 loading 状态自动跟着切换 —— 对话 2 在 streaming 时切到对话 3 仍然可以正常输入发送
    var isLoading: Bool {
        conversations.first(where: { $0.id == activeConversationID })?.isStreaming ?? false
    }
    var errorMessage: String? {
        didSet {
            // 每次设新错误时，3 秒后自动清空（用户也可以手动点 toast 上的 ×）
            errorAutoDismissTask?.cancel()
            guard let msg = errorMessage, !msg.isEmpty else { return }
            errorAutoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !Task.isCancelled, self?.errorMessage == msg {
                    self?.errorMessage = nil
                }
            }
        }
    }
    private var errorAutoDismissTask: Task<Void, Never>?

    func dismissError() {
        errorAutoDismissTask?.cancel()
        errorMessage = nil
    }
    var connectionStatus: ConnectionStatus = .unknown
    /// 当前进行中的发送 Task，用户可取消
    /// 每个对话独立的请求 Task —— key 是 conversationID。
    /// 切对话不影响其他对话的请求；cancel 只取消当前激活对话的 Task。
    private var tasksByConversation: [String: Task<Void, Never>] = [:]

    /// 同时跑的 streaming 上限。超出 → 进入 `pendingStreams` 队列等前面的完成。
    /// 为什么不直接拒绝：3 个 claude 进程同时跑 RAM 占用接近 1GB，限到 2 个能保证流畅但不卡。
    static let maxConcurrentStreams = 2

    /// 排队等待发送的请求。tasksByConversation.count >= maxConcurrentStreams 时新请求进这里
    private var pendingStreams: [PendingStreamRequest] = []

    /// 排队中的一条请求 —— 持有发起 stream 所需的全部上下文
    private struct PendingStreamRequest {
        let conversationID: String
        let assistantMessageID: String
        let mode: AgentMode
        let apiMessages: [ChatMessage]
    }

    // Settings
    // Hermes Gateway 的配置（本地自托管 OpenAI 兼容 Server）
    var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: "apiBaseURL") }
    }
    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }
    var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: "modelName") }
    }

    // 在线 AI（directAPI）的配置 —— 跟 Hermes 完全独立，
    // 用户分发给朋友的场景：只用配这一组就能聊
    var directAPIBaseURL: String {
        didSet { UserDefaults.standard.set(directAPIBaseURL, forKey: "directAPIBaseURL") }
    }
    var directAPIKey: String {
        didSet {
            UserDefaults.standard.set(directAPIKey, forKey: "directAPIKey")
            let providerID = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? ""
            if !providerID.isEmpty {
                UserDefaults.standard.set(directAPIKey, forKey: Self.directAPIKeyStorageKey(providerID: providerID))
            }
        }
    }
    var directAPIModel: String {
        didSet { UserDefaults.standard.set(directAPIModel, forKey: "directAPIModel") }
    }
    /// 在线 AI 的回复偏好，默认平衡。最终仍会映射成 directAPIModel 发给 API。
    var directAPIResponsePreference: DirectResponsePreference {
        didSet { UserDefaults.standard.set(directAPIResponsePreference.rawValue, forKey: "directAPIResponsePreference") }
    }
    /// 上一次用过的 mode —— 持久化到 UserDefaults["agentMode"]。
    /// 新建对话时把这个值作为默认 mode 继承下去；切对话 / 切 mode 时也会跟着更新，
    /// 这样下次启动 / 下次新建都能记住"我习惯用什么"。
    /// 不直接对外暴露 —— 真正的"当前对话 mode"通过 computed `agentMode` 读取
    var lastUsedMode: AgentMode {
        didSet {
            UserDefaults.standard.set(lastUsedMode.rawValue, forKey: "agentMode")
        }
    }

    /// 当前激活对话锁定的 AI 后端 —— **每个 Conversation 自带 mode**，
    /// 这里是个 computed property，读写都路由到 `conversations[active].mode`。
    ///
    /// **写入语义**：仅当当前对话**还没发过 user 消息**时才允许改 mode；
    /// 否则静默拒绝并弹一个 toast 提示新建对话。这样三个对话可以并行用不同 CLI 不互相污染
    /// （之前 mode 是全局变量，切对话时 mode 仍然延续，容易让用户以为对话 2 是 Codex 其实还在用 Claude → 发送时连接错误 / 无响应）
    var agentMode: AgentMode {
        get {
            conversations.first(where: { $0.id == activeConversationID })?.mode ?? lastUsedMode
        }
        set {
            guard let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) else {
                lastUsedMode = newValue
                return
            }
            // 已经发过 user 消息 —— mode 锁死，写入静默拒绝（外部 UI 会同时禁用按钮，这里是防御）
            if conversations[idx].hasUserMessages {
                errorMessage = "「\(conversations[idx].title)」已锁定为 \(conversations[idx].mode.label)；想换模型请新建对话。"
                return
            }
            guard conversations[idx].mode != newValue else { return }
            conversations[idx].mode = newValue
            lastUsedMode = newValue
            // 通知灵动岛左耳 / Clawd 等：当前对话的 mode 变了
            NotificationCenter.default.post(
                name: .init("HermesPetModeChanged"),
                object: nil,
                userInfo: ["mode": newValue.rawValue]
            )
            storage.saveConversations(conversations)
            checkConnection()
        }
    }
    /// 桌宠"安静模式" —— 关闭呼吸 / 眨眼 / 完成跳跃等生命感动画。
    /// 反向语义存储（quietMode=true 表示关闭动画），方便首次启动默认 false → 动画开启
    var quietMode: Bool {
        didSet {
            UserDefaults.standard.set(quietMode, forKey: "quietMode")
            NotificationCenter.default.post(
                name: .init("HermesPetPetAnimationsChanged"),
                object: nil,
                userInfo: ["enabled": !quietMode]
            )
        }
    }
    /// 触觉反馈（trackpad 微震）开关，默认开。Haptic.tap() 内部直接读 UserDefaults
    var hapticEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticEnabled, forKey: "hapticEnabled")
        }
    }
    /// Clawd 桌面漫步开关 —— Claude 模式下，用户 3min 无操作时，Clawd 会从灵动岛跳到桌面顶部漫步。
    /// 默认开（用户随时可在设置里关掉）
    var clawdWalkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clawdWalkEnabled, forKey: "clawdWalkEnabled")
            NotificationCenter.default.post(
                name: .init("HermesPetClawdWalkSettingChanged"),
                object: nil,
                userInfo: ["enabled": clawdWalkEnabled]
            )
        }
    }
    /// Clawd 自由活动开关 —— 开启后跳过"3min idle"这个前置条件，
    /// 只要在 Claude 模式 + 漫步开关开着 + 没在 streaming，Clawd 就一直在屏幕上玩
    var clawdFreeRoamEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clawdFreeRoamEnabled, forKey: "clawdFreeRoamEnabled")
            NotificationCenter.default.post(
                name: .init("HermesPetClawdFreeRoamSettingChanged"),
                object: nil,
                userInfo: ["enabled": clawdFreeRoamEnabled]
            )
        }
    }
    /// Clawd 桌面巡视开关 —— 开启后 Clawd 漫步期间会定期下到桌面，
    /// 走到某个图标旁，把文件名扔给 Hermes 拿一句短评显示在气泡里。
    /// 需要 Finder 自动化权限（osascript 第一次会弹系统弹窗）+ 已配置 Hermes API key（用本地兜底文案除外）。
    /// 默认 OFF —— 这是个轻松彩蛋，让用户主动开启更合适
    var clawdDesktopPatrolEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clawdDesktopPatrolEnabled, forKey: "clawdDesktopPatrolEnabled")
            NotificationCenter.default.post(
                name: .init("HermesPetClawdPatrolSettingChanged"),
                object: nil,
                userInfo: ["enabled": clawdDesktopPatrolEnabled]
            )
        }
    }
    /// 活动记录开关 —— 开启后持续记录用户在用什么 app/窗口/键盘节奏，让 AI 能"看见"用户做什么。
    /// 默认开启（首次启用会弹一次 Accessibility 权限框）
    var activityRecordingEnabled: Bool {
        didSet {
            ActivityRecorder.shared.setRunning(activityRecordingEnabled)
        }
    }
    /// Hover 灵动岛 500ms 后的展开行为，三选一（HoverExpandMode）：
    /// - `.off`：不动（默认）
    /// - `.embedded`：胶囊本身扩展成迷你聊天框（融进刘海）
    /// - `.chatWindow`：自动展开主聊天窗（NSWindow，原 PR3 行为，鼠标离开 / Esc / 失焦收回）
    /// 老用户从旧 `hoverExpandChatEnabled: Bool` 迁移：true → .chatWindow（保留行为），false/未设置 → .off
    var hoverExpandMode: HoverExpandMode {
        didSet {
            UserDefaults.standard.set(hoverExpandMode.rawValue, forKey: "hoverExpandMode")
            NotificationCenter.default.post(
                name: .init("HermesPetHoverExpandSettingChanged"),
                object: nil,
                userInfo: ["mode": hoverExpandMode.rawValue]
            )
        }
    }
    /// 每天早报由哪个 AI 后端生成 —— 用户在设置里固定选一个，不跟随当前对话 mode
    /// （早报涉及隐私汇总，让用户对哪家服务商看到这些数据有明确控制）
    var morningBriefingBackend: AgentMode {
        didSet { UserDefaults.standard.set(morningBriefingBackend.rawValue, forKey: "morningBriefingBackend") }
    }
    var showSettings: Bool = false
    /// 开机自启状态（SMAppService 同步）
    var isLaunchAtLoginOn: Bool = false

    /// 按住 Cmd+Shift+V 启动语音时播放的系统音效名（空 = 静音）
    var voiceStartSound: String {
        didSet { UserDefaults.standard.set(voiceStartSound, forKey: "voiceStartSound") }
    }
    /// AI 任务成功完成时播放的系统音效名（空 = 静音）
    var voiceFinishSound: String {
        didSet { UserDefaults.standard.set(voiceFinishSound, forKey: "voiceFinishSound") }
    }

    /// 待发送的图片附件（粘贴 / 拖拽 / 截屏都进这里）
    var pendingImages: [Data] = []

    /// 待发送的文档附件路径（拖入的 PDF / txt / md / 任意文件，仅 Claude / Codex 模式生效）。
    /// 不读内容，发送时把路径拼到 prompt 末尾让 AI 用 Read 工具自己访问，省 context、更快。
    var pendingDocuments: [URL] = []

    private let apiClient = APIClient(source: .hermes)
    private let directClient = APIClient(source: .direct)
    private let claudeClient = ClaudeCodeClient()
    private let codexClient = CodexClient()
    private let storage = StorageManager.shared
    private var statusTimer: Timer?

    static func directAPIKeyStorageKey(providerID: String) -> String {
        "directAPIKey.\(providerID)"
    }

    init() {
        self.apiBaseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://localhost:8642/v1"
        self.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        self.modelName = UserDefaults.standard.string(forKey: "modelName") ?? "hermes-agent"
        // 在线 AI：默认不预填，让用户通过设置面板的 ProviderPreset Picker 选一家
        self.directAPIBaseURL = UserDefaults.standard.string(forKey: "directAPIBaseURL") ?? ""
        let savedDirectProvider = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? ""
        if !savedDirectProvider.isEmpty,
           let providerKey = UserDefaults.standard.string(forKey: Self.directAPIKeyStorageKey(providerID: savedDirectProvider)) {
            self.directAPIKey = providerKey
        } else {
            self.directAPIKey = UserDefaults.standard.string(forKey: "directAPIKey") ?? ""
        }
        self.directAPIModel = UserDefaults.standard.string(forKey: "directAPIModel") ?? ""
        let savedPreference = UserDefaults.standard.string(forKey: "directAPIResponsePreference")
        self.directAPIResponsePreference = DirectResponsePreference(rawValue: savedPreference ?? "") ?? .balanced
        let savedMode = UserDefaults.standard.string(forKey: "agentMode")
        // 全新用户默认走「在线 AI」—— 对方拿到 dmg 多半没装 Hermes Gateway 也没 claude/codex CLI，
        // directAPI 配上 API Key 就能立刻用。老用户的 agentMode UserDefaults 还在，不受影响
        self.lastUsedMode = AgentMode(rawValue: savedMode ?? "") ?? .directAPI
        self.isLaunchAtLoginOn = SMAppService.mainApp.status == .enabled
        self.voiceStartSound  = UserDefaults.standard.string(forKey: "voiceStartSound")  ?? "Funk"
        self.voiceFinishSound = UserDefaults.standard.string(forKey: "voiceFinishSound") ?? "Glass"
        self.quietMode = UserDefaults.standard.bool(forKey: "quietMode")
        // hapticEnabled 默认 true（无值时 object(forKey:) → nil → ?? true）
        self.hapticEnabled = (UserDefaults.standard.object(forKey: "hapticEnabled") as? Bool) ?? true
        // clawdWalkEnabled 默认 true（首次见到时让用户被这个彩蛋惊艳一次）
        self.clawdWalkEnabled = (UserDefaults.standard.object(forKey: "clawdWalkEnabled") as? Bool) ?? true
        // clawdFreeRoamEnabled 默认 false（默认仅 idle 触发，避免一开机就一直在屏幕上）
        self.clawdFreeRoamEnabled = UserDefaults.standard.bool(forKey: "clawdFreeRoamEnabled")
        // clawdDesktopPatrolEnabled 默认 false —— 需要 Finder 自动化权限，默认 OFF 让用户主动开
        self.clawdDesktopPatrolEnabled = UserDefaults.standard.bool(forKey: "clawdDesktopPatrolEnabled")
        // activityRecordingEnabled 默认 true（首次会弹 Accessibility 权限框，用户可在设置里关）
        self.activityRecordingEnabled = (UserDefaults.standard.object(forKey: "activityRecordingEnabled") as? Bool) ?? true
        // hoverExpandMode 默认 **.off** —— 自动展开是可选范式，默认关闭以保留传统点击交互。
        // 迁移规则：新 key "hoverExpandMode" 存在则直接用；否则看老 key "hoverExpandChatEnabled"：
        // - 老 true  → .chatWindow（保留原 PR3 行为，老用户毫无察觉地继续用）
        // - 老 false / 不存在 → .off（新用户首次见到 = 不动）
        if let raw = UserDefaults.standard.string(forKey: "hoverExpandMode"),
           let mode = HoverExpandMode(rawValue: raw) {
            self.hoverExpandMode = mode
        } else if let legacy = UserDefaults.standard.object(forKey: "hoverExpandChatEnabled") as? Bool {
            self.hoverExpandMode = legacy ? .chatWindow : .off
        } else {
            self.hoverExpandMode = .off
        }
        // 早报后端默认 Hermes（自托管/隐私零风险），用户可改
        let savedBriefing = UserDefaults.standard.string(forKey: "morningBriefingBackend")
        self.morningBriefingBackend = AgentMode(rawValue: savedBriefing ?? "") ?? .hermes

        // 加载持久化的对话列表（兼容旧版 session.json，自动迁移）
        var loaded = storage.loadConversations()
        if loaded.isEmpty {
            // 全新用户 / 没历史 —— 起一个带欢迎语的对话，mode 用上次记得的 lastUsedMode
            loaded = [Conversation(
                title: "对话 1",
                messages: [ChatMessage(
                    role: .assistant,
                    content: "👋 你好！我是你的 Hermes 桌宠，随时找我聊天或干活～\n点击 ⚙️ 配置好 API 地址和密钥就能用了。"
                )],
                mode: self.lastUsedMode
            )]
        }
        self.conversations = loaded
        // 恢复上次激活的对话；找不到就用第一个。
        // loaded 此时一定非空（前面 if isEmpty 已填默认对话），但用 first? 而非 [0]
        // 增加一层保险，防止未来重构破坏空数组保护
        let savedActive = UserDefaults.standard.string(forKey: "activeConversationID") ?? ""
        self.activeConversationID = loaded.contains(where: { $0.id == savedActive })
            ? savedActive
            : (loaded.first?.id ?? UUID().uuidString)

        // 如果 conversations.json 损坏过，把诊断信息暴露给用户（toast 显示 3.5s）
        if let loadErr = storage.lastLoadError {
            self.errorMessage = loadErr
        }

        // Start status polling
        startStatusPolling()

        // 初次广播 hoverContext，让灵动岛 hoverCard 启动后立刻有"上次 AI 回复预览"
        broadcastHoverContext()

        // 监听灵动岛选项下拉菜单的选中事件 → 把选项作为新消息发送
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetChoiceSelected"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let text = (note.userInfo?["text"] as? String) ?? ""
            Task { @MainActor in
                self.submitVoiceInput(text)
            }
        }
    }

    nonisolated deinit {
        Task { @MainActor [weak self] in
            self?.statusTimer?.invalidate()
        }
    }

    // MARK: - Status Polling

    enum ConnectionStatus {
        case unknown
        case connected
        case disconnected(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private func startStatusPolling() {
        checkConnection()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkConnection()
            }
        }
    }

    func checkConnection() {
        switch agentMode {
        case .hermes:
            guard !apiKey.isEmpty else {
                connectionStatus = .disconnected("未配置密钥")
                return
            }
            Task {
                do {
                    let ok = try await apiClient.checkHealth()
                    connectionStatus = ok ? .connected : .disconnected("API 未响应")
                } catch {
                    connectionStatus = .disconnected(error.localizedDescription)
                }
            }
        case .directAPI:
            guard !directAPIKey.isEmpty else {
                connectionStatus = .disconnected("未配置 API Key")
                return
            }
            guard !directAPIBaseURL.isEmpty else {
                connectionStatus = .disconnected("未选择服务商")
                return
            }
            Task {
                do {
                    let ok = try await directClient.checkHealth()
                    connectionStatus = ok ? .connected : .disconnected("服务商未响应")
                } catch {
                    connectionStatus = .disconnected(error.localizedDescription)
                }
            }
        case .claudeCode:
            Task {
                let ok = await claudeClient.checkAvailable()
                connectionStatus = ok ? .connected : .disconnected("找不到 claude 命令")
            }
        case .codex:
            Task {
                let ok = await codexClient.checkAvailable()
                connectionStatus = ok ? .connected : .disconnected("找不到 codex 命令")
            }
        }
    }

    // MARK: - Send Message

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 允许「只发图片 / 只拖文档不带文字」—— 文字、图片、文档任一非空就能发
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty else { return }

        // Hermes 模式：必须有 apiKey
        if agentMode == .hermes && apiKey.isEmpty {
            errorMessage = "请先在设置中配置 Hermes API 密钥"
            showSettings = true
            return
        }
        // 在线 AI 模式：必须有 API Key + baseURL（任意一项空都跑不通）
        if agentMode == .directAPI && (directAPIKey.isEmpty || directAPIBaseURL.isEmpty) {
            errorMessage = "请先在设置中选服务商并填 API Key"
            showSettings = true
            return
        }

        // 任意模式下断开都先尝试重连
        if case .disconnected(let reason) = connectionStatus {
            errorMessage = "连接断开: \(reason)，正在重试..."
            checkConnection()
            return
        }

        // 把当前 pending 图片 / 文档随消息一起发出去，发完清空
        let attachedImages = pendingImages
        pendingImages = []
        let attachedDocPaths = pendingDocuments.map { $0.path }
        pendingDocuments = []

        inputText = ""
        errorMessage = nil
        // 把当前激活对话标记为 streaming（每个对话独立 loading 状态）
        let targetConvIdx = conversations.firstIndex(where: { $0.id == activeConversationID })
        if let idx = targetConvIdx {
            conversations[idx].isStreaming = true
        }
        // 通知灵动岛右耳切换到 "working"（旋转加载圈）
        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)
        broadcastBackgroundStreamingCount()

        // 文字为空时按附件类型给个合理的默认 prompt
        let userText: String
        if !text.isEmpty {
            userText = text
        } else if !attachedImages.isEmpty {
            userText = "请分析这张图片。"
        } else {
            // 只拖了文档没写字 —— 让 AI 自己看附件
            userText = "请查看我附带的文档。"
        }
        // 用户附图也落盘到 ~/.hermespet/images/，重启后能恢复
        let userImagePaths = storage.persistImages(attachedImages)
        let userMessage = ChatMessage(
            role: .user,
            content: userText,
            images: attachedImages,
            imagePaths: userImagePaths,
            documentPaths: attachedDocPaths
        )
        messages.append(userMessage)

        // 写入 ActivityStore（仅用户那一侧）—— 给早报 / AI 反向分析用，
        // 不影响 conversations.json 的事实存储
        ActivityRecorder.shared.queryStore.insertUserQuestion(
            conversationID: activeConversationID,
            mode: agentMode.rawValue,
            content: userText,
            hasImages: !attachedImages.isEmpty,
            hasDocuments: !attachedDocPaths.isEmpty
        )

        // 第一条用户消息发出时，自动给当前对话取个有意义的标题
        autoTitleIfNeeded(forConversation: activeConversationID, fromUserText: userText)

        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)

        // 锁定本次请求所属的 conversationID 和 assistant messageID —— 即便用户中途切到别的对话，
        // 流式更新也能精准落到原来的对话上，不会写错位置
        let targetConversationID = activeConversationID
        let assistantMessageID = assistantMessage.id

        // 用目标对话**自己**绑定的 mode（不是全局 agentMode）—— 这样即便用户在 Task 跑期间
        // 切到了另一个对话（另一个 mode），本次请求依然走原来对话锁定的那个 CLI
        let mode: AgentMode = conversations.first(where: { $0.id == targetConversationID })?.mode
            ?? lastUsedMode

        // 拼 API 需要的历史 messages（仅当前对话内的 user/assistant）
        var apiMessages: [ChatMessage] = []
        for msg in messages {
            if msg.id == assistantMessage.id { break }
            if msg.role == .assistant || msg.role == .user {
                apiMessages.append(msg)
            }
        }

        // 长对话裁剪：每次都重发完整历史会越来越慢 + 烧 token，超阈值时只发开头+近况
        apiMessages = Self.trimHistoryForAPI(apiMessages)

        let request = PendingStreamRequest(
            conversationID: targetConversationID,
            assistantMessageID: assistantMessageID,
            mode: mode,
            apiMessages: apiMessages
        )

        // 并发上限：超过 maxConcurrentStreams 入队等前面完成
        if tasksByConversation.count >= Self.maxConcurrentStreams {
            let ahead = tasksByConversation.count
            updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                msg.content = "⏳ 排队中（前面还有 \(ahead) 个对话在跑，完成后自动开始）"
            }
            pendingStreams.append(request)
            return
        }

        startStream(request)
    }

    /// 一次性快问流式 —— 不写 conversations.json，不影响任何已有对话。
    /// 供 Spotlight 风快问浮窗（QuickAskWindowController）复用：
    ///   - 沿用当前激活对话的 mode（不在快问里切）
    ///   - 复用三个 client 已有的 streamCompletion 路由（保有 idle timeout / 错误友好提示 / Subprocess 清理）
    ///   - 不参与历史裁剪 / 排队 / broadcastBackgroundStreamingCount
    /// 一次性 prompt 流式调用（不创建对话，不进入 messages 列表）。
    /// - modeOverride: 显式指定 mode（早报用 morningBriefingBackend；快问/默认不传走当前 agentMode）
    /// - recordToActivity: 是否写入 user_questions（早报自己的内部 prompt 不算，传 false）
    func streamOneShotAsk(prompt: String,
                          modeOverride: AgentMode? = nil,
                          recordToActivity: Bool = true) -> AsyncThrowingStream<String, Error> {
        let mode = modeOverride ?? agentMode
        if recordToActivity {
            // QuickAsk 也是用户问 AI —— 同样写入 ActivityStore 给早报用
            ActivityRecorder.shared.queryStore.insertUserQuestion(
                conversationID: "quick-ask",
                mode: mode.rawValue,
                content: prompt,
                hasImages: false,
                hasDocuments: false
            )
        }
        let oneShot = ChatMessage(role: .user, content: prompt)
        let messages = [oneShot]
        switch mode {
        case .hermes:     return apiClient.streamCompletion(messages: messages)
        case .directAPI:  return directClient.streamCompletion(messages: messages)
        case .claudeCode: return claudeClient.streamCompletion(messages: messages)
        case .codex:      return codexClient.streamCompletion(messages: messages)
        }
    }

    /// 早报：把生成好的 markdown 早报塞进一个新对话，自动切过去 + 打开 chat 窗口。
    /// 如果对话已满 (kMaxConversations)，挤掉**最旧的非 streaming** 对话（避免打断在跑的任务）。
    func createBriefingConversation(content: String) {
        let dateStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let title = "📰 今日早报 \(dateStr)"
        let newConv = Conversation(
            title: title,
            messages: [
                ChatMessage(role: .user, content: "请给我一份今日早报"),
                ChatMessage(role: .assistant, content: content)
            ],
            mode: morningBriefingBackend
        )
        // 已达上限：挤掉最旧的非 streaming 对话；如果全都在 streaming 就跳过早报，避免覆盖用户工作
        if conversations.count >= kMaxConversations {
            if let oldestIdx = conversations.indices.reversed().first(where: { !conversations[$0].isStreaming }) {
                conversations.remove(at: oldestIdx)
            } else {
                errorMessage = "早报已生成，但所有对话都在跑任务，请关一个再看早报"
                return
            }
        }
        conversations.insert(newConv, at: 0)
        activeConversationID = newConv.id
        if lastUsedMode != morningBriefingBackend { lastUsedMode = morningBriefingBackend }
        storage.saveConversations(conversations)
        // 通知灵动岛 & 重新检测连接，避免切到早报对话后 header 还显示上一个 mode 的状态
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": morningBriefingBackend.rawValue]
        )
        checkConnection()
        // 通知 AppDelegate 把聊天窗调出来
        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
    }

    /// 点击桌面 Pin 卡片时调用。
    /// 优先跳回原对话并滚动到原消息；原对话已关闭或来源不明时才新建对话。
    func openPinAsConversation(pin: PinCard) {
        // 优先：原对话还在，直接切过去
        if let srcConvID = pin.sourceConversationID,
           conversations.contains(where: { $0.id == srcConvID }) {
            activeConversationID = srcConvID
            if let mode = conversations.first(where: { $0.id == srcConvID })?.mode {
                if lastUsedMode != mode { lastUsedMode = mode }
                NotificationCenter.default.post(
                    name: .init("HermesPetModeChanged"),
                    object: nil,
                    userInfo: ["mode": mode.rawValue]
                )
            }
            // 通知 ScrollView 滚动到原消息
            if let msgID = pin.sourceMessageID {
                NotificationCenter.default.post(
                    name: .init("HermesPetScrollToMessage"),
                    object: nil,
                    userInfo: ["messageID": msgID]
                )
            }
            NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
            return
        }
        // 兜底：原对话不在了，新建
        if conversations.count >= kMaxConversations {
            errorMessage = "对话已达 \(kMaxConversations) 个上限，请先关一个再转入"
            return
        }
        let safeTitle = pin.title.isEmpty ? "Pin" : String(pin.title.prefix(20))
        let newConv = Conversation(
            title: safeTitle,
            messages: [
                ChatMessage(role: .user, content: "📌 来自桌面 Pin 的内容："),
                ChatMessage(role: .assistant, content: pin.content)
            ],
            mode: pin.mode
        )
        conversations.insert(newConv, at: 0)
        activeConversationID = newConv.id
        if lastUsedMode != pin.mode { lastUsedMode = pin.mode }
        storage.saveConversations(conversations)
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": pin.mode.rawValue]
        )
        checkConnection()
        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
    }

    /// 把快问结果迁移到一个新对话（用户在快问浮窗按 💬 转聊天窗时调用）。
    /// 自动创建一个新对话，把问答两条消息塞进去，切到这个新对话并打开聊天窗。
    /// 快问当时用的是 lastUsedMode，所以新对话也锁定到同一个 mode
    func migrateQuickAskToNewConversation(question: String, answer: String) {
        let newConv = Conversation(
            title: question.prefix(20).description,
            messages: [
                ChatMessage(role: .user, content: question),
                ChatMessage(role: .assistant, content: answer)
            ],
            mode: lastUsedMode
        )
        if conversations.count >= kMaxConversations {
            // 已经 3 个对话满了 → 提示
            errorMessage = "对话已达 \(kMaxConversations) 个上限，请先关一个再转入"
            return
        }
        conversations.insert(newConv, at: 0)
        activeConversationID = newConv.id
        storage.saveConversations(conversations)
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": lastUsedMode.rawValue]
        )
        checkConnection()
    }

    /// 真正发起一次 streaming（被 sendMessage 直接调用 或 排队 dequeue 后调用）。
    /// 进入这里之前 sendMessage 已经做了 isStreaming=true + HermesPetTaskStarted + broadcastBackground，
    /// 这里只重置 assistant content（清掉可能存在的"排队中"占位）即可
    private func startStream(_ request: PendingStreamRequest) {
        let targetConversationID = request.conversationID
        let assistantMessageID = request.assistantMessageID
        let mode = request.mode
        let apiMessages = request.apiMessages

        updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
            msg.content = ""
            msg.isStreaming = true
        }

        let task = Task {
            var didSucceed = false
            do {
                let stream: AsyncThrowingStream<String, Error>
                switch mode {
                case .hermes:
                    stream = apiClient.streamCompletion(messages: apiMessages)
                case .directAPI:
                    // 直连第三方 OpenAI 兼容服务商，跟 Hermes 走同一份 client 代码，
                    // 只是配置（baseURL/key/model）来自 direct 那一套 UserDefaults
                    stream = directClient.streamCompletion(messages: apiMessages)
                case .claudeCode:
                    // 把完整对话历史（含跟其他 AI 的对话）传给 Claude，
                    // 实现跨 AI 共享记忆
                    stream = claudeClient.streamCompletion(messages: apiMessages)
                case .codex:
                    stream = codexClient.streamCompletion(
                        messages: apiMessages,
                        conversationID: targetConversationID
                    )
                }

                var fullContent = ""
                var lastUpdate = Date.distantPast
                // 流式刷新节流：32ms 一次（约 30fps）。
                // 之前 80ms 是 12fps，刷新跳变肉眼可见"卡一下"；改 32ms 后接近行级连续流动，
                // 跟 macOS 系统动效一致（60fps 是上限，30fps 是流畅基线）。
                // MarkdownTextView 的 parseBlocks 在中等长度回复（<5K 字符）下 CPU 可忽略，
                // 真正昂贵的是 InlineMarkdownView 内 AttributedString 重建，已被 SwiftUI 自动 diff
                let throttle: TimeInterval = 0.032

                for try await delta in stream {
                    try Task.checkCancellation()
                    fullContent += delta
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) >= throttle {
                        self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                            msg.content = fullContent
                        }
                        lastUpdate = now
                    }
                }
                // 流结束时一定要把最后剩余的内容刷出去
                // Codex 模式还要把它生成的图片附加到这条 assistant 消息上
                let generatedImages: [Data] = (mode == .codex) ? codexClient.takeGeneratedImages() : []
                // 图片落盘：写到 ~/.hermespet/images/，message 同时持 Data（显示用）+ path（持久化用）
                let imagePaths: [String] = generatedImages.isEmpty
                    ? []
                    : storage.persistImages(generatedImages, forMessage: assistantMessageID)
                self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                    msg.content = fullContent.isEmpty ? "(没有响应)" : fullContent
                    msg.isStreaming = false
                    if !generatedImages.isEmpty {
                        msg.images = generatedImages
                        msg.imagePaths = imagePaths
                    }
                }
                didSucceed = !fullContent.isEmpty || !generatedImages.isEmpty

                // 检测 AI 回复末尾是否有连续编号列表 → 灵动岛弹出选项下拉菜单
                // 仅当此回复属于当前激活对话才弹（后台对话不打扰用户当前注意力）
                if didSucceed, targetConversationID == self.activeConversationID,
                   let choices = Self.extractTrailingChoices(from: fullContent) {
                    NotificationCenter.default.post(
                        name: .init("HermesPetChoiceListReady"),
                        object: nil,
                        userInfo: ["options": choices]
                    )
                }
            } catch is CancellationError {
                self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                    msg.isStreaming = false
                    if msg.content.isEmpty {
                        msg.content = "(已取消)"
                    } else {
                        msg.content += "\n\n_(已取消)_"
                    }
                }
            } catch {
                let friendly = self.friendlyError(error)
                self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                    msg.isStreaming = false
                    msg.content = "❌ \(friendly)"
                }
                self.errorMessage = friendly
            }
            // 清理：目标对话 isStreaming → false；task 从字典里移除
            if let idx = self.conversations.firstIndex(where: { $0.id == targetConversationID }) {
                self.conversations[idx].isStreaming = false
                // 后台对话完成 → 标记未读（如果用户在等待期间切走了）
                if didSucceed, targetConversationID != self.activeConversationID {
                    self.conversations[idx].hasUnread = true
                }
            }
            self.tasksByConversation[targetConversationID] = nil

            self.storage.saveConversations(self.conversations)
            // 通知灵动岛右耳：成功 → 播放对勾动画；失败/取消 → 静默回 idle。
            // 额外携带 conversationID / isActive / preview / mode 给 MiniReplyCardController：
            // 它仅在 (success && isActive && !preview.isEmpty && !chatWindow.isVisible) 时弹卡片
            let assistantPreview: String = {
                if let idx = self.conversations.firstIndex(where: { $0.id == targetConversationID }),
                   let msg = self.conversations[idx].messages.first(where: { $0.id == assistantMessageID }) {
                    // mini card 是多行卡片（lineLimit(3)），保留 \n 让 markdown 列表分行显示，
                    // 否则"1. xxx\n2. yyy"会被挤成"1. xxx 2. yyy"挤一坨。
                    // 把连续空行压成单个 \n 避免 AI 回复里的双换行浪费 mini card 行数
                    let cleaned = Self.stripMarkdownForPreview(msg.content)
                        .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return String(cleaned.prefix(220))
                }
                return ""
            }()
            let convMode: String = {
                if let idx = self.conversations.firstIndex(where: { $0.id == targetConversationID }) {
                    return self.conversations[idx].mode.rawValue
                }
                return self.lastUsedMode.rawValue
            }()
            NotificationCenter.default.post(
                name: .init("HermesPetTaskFinished"),
                object: nil,
                userInfo: [
                    "success": didSucceed,
                    "conversationID": targetConversationID,
                    "isActive": targetConversationID == self.activeConversationID,
                    "preview": assistantPreview,
                    "mode": convMode
                ]
            )
            // 任务成功完成 → 给个轻触觉提示（不打扰，只是"做完了"的回执感）
            if didSucceed {
                Haptic.tap(.alignment)
            }
            self.broadcastBackgroundStreamingCount()
            self.broadcastHoverContext()
            // 当前 task 结束 → 检查排队队列，dequeue 下一个
            self.dequeueNextStreamIfAny()
        }
        // 把 task 存进字典 —— 每个对话独立，cancel 只取消当前 active 对话的
        tasksByConversation[targetConversationID] = task
    }

    /// 任意 streaming 完成后调一次：若排队队列非空且并发未满，启动下一个
    private func dequeueNextStreamIfAny() {
        guard !pendingStreams.isEmpty,
              tasksByConversation.count < Self.maxConcurrentStreams else { return }
        let next = pendingStreams.removeFirst()
        startStream(next)
    }

    /// 按 (conversationID, messageID) 精确定位并 mutate 一条消息。
    /// 这样即便用户在请求进行中切到别的对话，流式更新依然落到正确位置。
    private func updateMessage(conversationID: String,
                                messageID: String,
                                _ mutate: (inout ChatMessage) -> Void) {
        guard let convIdx = conversations.firstIndex(where: { $0.id == conversationID }),
              let msgIdx = conversations[convIdx].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        mutate(&conversations[convIdx].messages[msgIdx])
        conversations[convIdx].updatedAt = Date()
    }

    /// 第一次发用户消息时，把对话标题改成消息内容的前 8 个字符。
    /// 已经被用户改过标题（不再是默认"对话 N"）的不动。
    private func autoTitleIfNeeded(forConversation id: String, fromUserText text: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        let current = conversations[idx].title
        let isDefaultTitle = current.hasPrefix("对话 ")
        guard isDefaultTitle else { return }
        // 已经有用户消息（不是首条）就不再覆盖
        let priorUserCount = conversations[idx].messages.filter { $0.role == .user }.count
        guard priorUserCount <= 1 else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(trimmed.prefix(10))
        if !snippet.isEmpty {
            conversations[idx].title = snippet
        }
    }

    /// 取消当前激活对话正在进行的请求（不影响其他对话）。
    /// 既处理"已经在跑"（task cancel）也处理"还在排队"（从 pendingStreams 移除）
    func cancelCurrentRequest() {
        let id = activeConversationID

        // 排队中的请求：从队列里删掉 + 把消息标记为已取消
        if let queueIdx = pendingStreams.firstIndex(where: { $0.conversationID == id }) {
            let removed = pendingStreams.remove(at: queueIdx)
            updateMessage(conversationID: id, messageID: removed.assistantMessageID) { msg in
                msg.isStreaming = false
                msg.content = "(已取消)"
            }
            if let convIdx = conversations.firstIndex(where: { $0.id == id }) {
                conversations[convIdx].isStreaming = false
            }
            broadcastBackgroundStreamingCount()
            NotificationCenter.default.post(
                name: .init("HermesPetTaskFinished"),
                object: nil, userInfo: ["success": false]
            )
            return
        }

        // 正在跑的 task：cancel 即可，剩下清理在 task 闭包末尾
        tasksByConversation[id]?.cancel()
        tasksByConversation[id] = nil
    }

    /// 提取 assistant 回复末尾的连续编号列表 —— 用于触发灵动岛下拉菜单。
    /// 从末尾往前扫，跳过空行，收集连续的 "N. xxx" 格式行；少于 2 项不算选项
    static func extractTrailingChoices(from content: String) -> [String]? {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var items: [String] = []
        for line in lines.reversed() {
            if let item = MarkdownTextView.numberedItemContent(of: line) {
                items.insert(item, at: 0)
            } else {
                break
            }
        }
        return items.count >= 2 ? items : nil
    }

    /// 长对话历史裁剪 —— 避免每次重发完整历史导致：
    ///   - token 成本线性增长（30 轮对话第 31 条要带 30 条历史）
    ///   - 冷启动延迟变长（claude 进程要读 + 解析很大 prompt）
    ///
    /// 策略：超过 `maxMessages` 条时，保留**第一条 user 消息**（提供原始上下文）+ **最近 `keepRecent` 条**。
    /// 在最早保留的消息内容前 prepend 一行系统注，让 AI 知道历史被裁剪过。
    /// 静态方法 —— 纯函数，方便测试 + 不依赖 self
    static func trimHistoryForAPI(_ messages: [ChatMessage]) -> [ChatMessage] {
        let maxMessages = 20
        let keepRecent = 16

        guard messages.count > maxMessages else { return messages }

        let recent = Array(messages.suffix(keepRecent))
        let recentIDs = Set(recent.map { $0.id })

        // 第一条 user 消息：如果不在 recent 里，作为起始上下文单独保留
        var head: [ChatMessage] = []
        if let firstUser = messages.first(where: { $0.role == .user }),
           !recentIDs.contains(firstUser.id) {
            head.append(firstUser)
        }

        let omitted = messages.count - head.count - recent.count
        var result = head + recent

        if omitted > 0, !result.isEmpty {
            // 用 system 注释提示 AI 历史被裁剪。content 是 var，可以 mutate
            result[0].content = "[系统注：本对话有 \(omitted) 条早期消息已省略以加速响应。如需了解早期内容请直接问用户。]\n\n" + result[0].content
        }

        return result
    }

    /// 把各种 Error 转成中文友好提示。
    /// 设计原则：友好的开头 + 保留服务端 body / 系统 error 的关键诊断信息（前 120 字），
    /// 不让用户看到一句"出错了"就没下文 —— 真出问题时这点上下文非常救命
    private func friendlyError(_ error: Error) -> String {
        // body 摘录：最多 120 字符，过滤换行避免 toast 多行变形
        func snippet(_ s: String, max: Int = 120) -> String {
            let cleaned = s.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return "" }
            if cleaned.count <= max { return " — \(cleaned)" }
            return " — \(cleaned.prefix(max))…"
        }

        if let api = error as? APIError {
            switch api {
            case .invalidResponse:
                return "服务器返回了异常响应，请检查 API 配置"
            case .httpError(let code, let body):
                switch code {
                case 401: return "API 密钥无效或已过期，请检查设置\(snippet(body))"
                case 403: return "没有访问权限（403）\(snippet(body))"
                case 404: return "找不到 API 端点（404），检查 API 地址是否正确\(snippet(body))"
                case 429: return "请求太频繁，稍后再试\(snippet(body))"
                case 500...599: return "服务器内部错误（\(code)）\(snippet(body))"
                case 0:
                    // ClaudeCodeClient / CodexClient 的特殊错误码 → body 本身就是错误描述
                    return body.isEmpty ? "Claude/Codex 进程错误" : body
                default:
                    return "请求失败（HTTP \(code)）\(snippet(body))"
                }
            case .decodingError(let msg):
                return "数据解析失败\(snippet(msg))"
            case .cancelled:
                return "请求已取消"
            case .emptyResponse:
                return "未收到回复"
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .networkConnectionLost:
                return agentMode == .hermes
                    ? "无法连接 Hermes Gateway，请确认它已启动（hermes gateway）"
                    : "无法连接到目标服务"
            case .notConnectedToInternet:
                return "网络已断开"
            case .timedOut:
                return "请求超时，模型可能在长任务中"
            case .cancelled:
                return "请求已取消"
            default:
                return url.localizedDescription
            }
        }
        // 兜底：NSError 走这里（包括我们 APIClient 抛的 idle timeout）
        // localizedDescription 已是人类可读
        return error.localizedDescription
    }

    // MARK: - 开机自启 (SMAppService)

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // 操作成功 —— 用 SMAppService 实际状态作为真相
            isLaunchAtLoginOn = SMAppService.mainApp.status == .enabled
        } catch {
            errorMessage = "开机自启设置失败: \(error.localizedDescription)"
            // 操作失败 —— 同步回 SMAppService 的真实状态，避免 toggle 显示与系统不一致
            isLaunchAtLoginOn = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Actions

    func clearChat() {
        // 清空前先删掉这对话历史里所有图片文件，避免磁盘遗留
        let allPaths = messages.flatMap { $0.imagePaths }
        if !allPaths.isEmpty { storage.deleteImageFiles(allPaths) }

        // 只清空当前激活对话的消息（不删除对话本身、不影响别的对话）
        messages = [
            ChatMessage(
                role: .assistant,
                content: "👋 已清空聊天记录，有什么新问题？"
            )
        ]
        // 标题也重置回默认（让下次发消息时能再次 auto-title）
        if let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) {
            let n = nextDefaultTitleNumber()
            conversations[idx].title = "对话 \(n)"
        }
        // 清空时也重置 Claude 的会话延续状态
        claudeClient.resetSession()
        codexClient.resetSession(conversationID: activeConversationID)
        storage.saveConversations(conversations)
    }

    // MARK: - 多会话管理

    /// 新建一个对话。已满（kMaxConversations 个）就返回 false 不做任何事。
    /// - mode: 新对话锁定的 AI 后端。不传 → 继承当前 lastUsedMode（即上次正在用的）。
    /// 用户的设计：新建对话即"开一个独立 CLI 通道"，所以发了消息后这个对话的 mode 就锁死。
    @discardableResult
    func newConversation(mode: AgentMode? = nil) -> Bool {
        guard conversations.count < kMaxConversations else { return false }
        let n = nextDefaultTitleNumber()
        let resolved = mode ?? lastUsedMode
        let conv = Conversation(
            title: "对话 \(n)",
            messages: [ChatMessage(
                role: .assistant,
                content: "👋 这是一个新对话（\(resolved.label)），开始聊天吧～"
            )],
            mode: resolved
        )
        conversations.append(conv)
        activeConversationID = conv.id
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        errorMessage = nil
        // 记一下"上次的 mode"，让下次新建延续这个选择
        if lastUsedMode != resolved { lastUsedMode = resolved }
        UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
        storage.saveConversations(conversations)
        // 新建对话可能跟上一个 active 对话 mode 不同 —— 通知灵动岛 & 重新检测连接
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": resolved.rawValue]
        )
        checkConnection()
        broadcastHoverContext()
        return true
    }

    /// 切到上一个对话（左移，cycle 到末尾）
    func switchToPreviousConversation() {
        guard conversations.count > 1,
              let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        let prevIdx = (idx - 1 + conversations.count) % conversations.count
        switchConversation(to: conversations[prevIdx].id)
    }

    /// 切到下一个对话（右移，cycle 到开头）
    func switchToNextConversation() {
        guard conversations.count > 1,
              let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        let nextIdx = (idx + 1) % conversations.count
        switchConversation(to: conversations[nextIdx].id)
    }

    /// 切到第 N 个对话（1-based 索引，对应顶部胶囊的数字）
    func switchToConversation(index: Int) {
        let zeroBased = index - 1
        guard zeroBased >= 0, zeroBased < conversations.count else { return }
        switchConversation(to: conversations[zeroBased].id)
    }

    /// 关闭当前激活的对话
    func closeCurrentConversation() {
        closeConversation(id: activeConversationID)
    }

    /// 切换到指定对话
    func switchConversation(to id: String) {
        guard id != activeConversationID,
              conversations.contains(where: { $0.id == id }) else { return }

        // 离开的对话若还在 streaming，弹个轻提示让用户知道它在后台继续跑
        if let leaving = conversations.first(where: { $0.id == activeConversationID }),
           leaving.isStreaming {
            NotificationCenter.default.post(
                name: .init("HermesPetScreenshotAdded"),
                object: nil,
                userInfo: [
                    "text": "「\(leaving.title)」仍在生成中",
                    "count": 0
                ]
            )
        }

        activeConversationID = id
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        errorMessage = nil
        // 切到的对话清除未读标记 + 同步 mode 给灵动岛 / Clawd / 连接检测
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            if conversations[idx].hasUnread {
                conversations[idx].hasUnread = false
            }
            let newMode = conversations[idx].mode
            // 同步 lastUsedMode（让"下次新建"延续当前正在看的这个 mode）
            if lastUsedMode != newMode { lastUsedMode = newMode }
            // 通知灵动岛左耳精灵 / Clawd 等监听者
            NotificationCenter.default.post(
                name: .init("HermesPetModeChanged"),
                object: nil,
                userInfo: ["mode": newMode.rawValue]
            )
            storage.saveConversations(conversations)
        }
        UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
        // 切到新 mode —— 重新检测连接（不重检的话 header 的状态点可能还是上一个 mode 的）
        checkConnection()
        // 活跃对话变化 → 后台流式数会跟着变
        broadcastBackgroundStreamingCount()
        broadcastHoverContext()
    }

    /// 后台（即不是当前激活）流式中的对话数量。灵动岛右耳显示这个角标
    private func broadcastBackgroundStreamingCount() {
        let count = conversations
            .filter { $0.isStreaming && $0.id != activeConversationID }
            .count
        NotificationCenter.default.post(
            name: .init("HermesPetBackgroundStreamingChanged"),
            object: nil,
            userInfo: ["count": count]
        )
    }

    /// 灵动岛 hoverCard 的上下文：当前激活对话最近一条 AI 回复预览 + 未读后台对话数。
    /// 在 TaskFinished / switchConversation / newConversation 等时机调用，让 hover 展开时
    /// 能直接看到"上一条 AI 说了啥"+"还有几个对话等着看"，不必打开聊天窗
    func broadcastHoverContext() {
        let preview: String = {
            guard let active = conversations.first(where: { $0.id == activeConversationID }) else { return "" }
            for msg in active.messages.reversed() where msg.role == .assistant {
                let cleaned = Self.stripMarkdownForPreview(msg.content)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    return String(cleaned.prefix(60))
                }
            }
            return ""
        }()
        let unreadCount = conversations
            .filter { $0.hasUnread && $0.id != activeConversationID }
            .count
        NotificationCenter.default.post(
            name: .init("HermesPetHoverContextChanged"),
            object: nil,
            userInfo: ["preview": preview, "unreadCount": unreadCount]
        )
    }

    /// 把 markdown 简化为纯文本，给灵动岛 hoverCard 和 MiniReplyCard 当预览用 ——
    /// 不去做完整 markdown 解析（那是 MarkdownRenderer 的活），只剥掉常见标记符号：
    /// `**bold**` / `*italic*` / `` `code` `` / `[text](url)` / `# heading` / 代码栅栏 ```
    static func stripMarkdownForPreview(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "```", with: "")
        out = out.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<!\*)\*([^\*\n]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<!_)_([^_\n]+)_(?!_)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"!?\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^#+\s+"#, with: "", options: [.regularExpression, .anchored])
        return out
    }

    /// 手动重命名对话（右键胶囊 → 重命名）
    func renameConversation(id: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = String(trimmed.prefix(20))
        storage.saveConversations(conversations)
    }

    /// 关闭某个对话。至少要保留 1 个，所以最后一个不允许关。
    func closeConversation(id: String) {
        guard conversations.count > 1 else { return }
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        // 关闭前清理图片文件
        let allPaths = conversations[idx].messages.flatMap { $0.imagePaths }
        if !allPaths.isEmpty { storage.deleteImageFiles(allPaths) }
        if conversations[idx].mode == .codex {
            codexClient.resetSession(conversationID: id)
        }

        let wasActive = (id == activeConversationID)
        conversations.remove(at: idx)
        if wasActive {
            // 关闭的是当前激活的 —— 切到最邻近的那个
            let newIdx = min(idx, conversations.count - 1)
            activeConversationID = conversations[newIdx].id
            pendingImages.removeAll()
            errorMessage = nil
            UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
            // 新 active 的 mode 可能跟旧的不同 —— 通知灵动岛 / 重检连接
            let newMode = conversations[newIdx].mode
            if lastUsedMode != newMode { lastUsedMode = newMode }
            NotificationCenter.default.post(
                name: .init("HermesPetModeChanged"),
                object: nil,
                userInfo: ["mode": newMode.rawValue]
            )
            checkConnection()
        }
        storage.saveConversations(conversations)
    }

    /// 找一个不冲突的默认标题序号（避免新建后跟现有的"对话 N"重名）
    private func nextDefaultTitleNumber() -> Int {
        let usedNumbers = conversations.compactMap { conv -> Int? in
            guard conv.title.hasPrefix("对话 ") else { return nil }
            return Int(conv.title.dropFirst(3).trimmingCharacters(in: .whitespaces))
        }
        let maxUsed = usedNumbers.max() ?? 0
        return maxUsed + 1
    }

    /// 重试：把最后一条出错的 assistant 消息及它对应的 user 消息撤回，
    /// 用 user 消息的内容重新发送一次。
    func retryLastMessage() {
        var msgs = messages
        // 找最后一条 user 消息（出错的 assistant 一定在它后面）
        guard let lastUserIdx = msgs.lastIndex(where: { $0.role == .user }) else { return }
        let userMsg = msgs[lastUserIdx]
        // 截掉 user 消息及其之后所有消息（出错的 assistant 回复）
        msgs.removeSubrange(lastUserIdx..<msgs.count)
        messages = msgs

        // 恢复输入框内容 + 附件 → sendMessage 会重新追加 user/assistant
        inputText = userMsg.content
        pendingImages = userMsg.images
        pendingDocuments = userMsg.documentPaths.map { URL(fileURLWithPath: $0) }
        sendMessage()
    }

    func copyLastResponse() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant && !$0.isStreaming }),
              !lastAssistant.content.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastAssistant.content, forType: .string)
        #endif
    }

    /// 全局语音热键松开后调用：把识别出的文字填入输入框并自动发送。
    /// text 为空或全是空白时只做提示，不发空消息。
    func submitVoiceInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 让灵动岛弹一个"没听到"提示
            NotificationCenter.default.post(
                name: .init("HermesPetScreenshotAdded"),
                object: nil,
                userInfo: ["text": "⚠️ 没听到内容", "count": 0]
            )
            return
        }
        inputText = trimmed
        sendMessage()
    }

    /// 把一个 AI 分解出来的任务派到新对话执行 —— "🤖 让 AI 做" 按钮的入口。
    /// 流程：
    ///   1. 新建一个对话（mode = task.suggestedMode），继承不到上限就开
    ///   2. 把 task 作为首条 user 消息发送，让对应 AI 立刻开始干
    ///   3. 切到新对话让用户能看到进度（也可以选择不切，但默认切让用户立即看见 AI 在干嘛）
    func dispatchTaskToNewConversation(_ task: PlannedTask) {
        guard conversations.count < kMaxConversations else {
            errorMessage = "对话已达 \(kMaxConversations) 个上限，请先关一个再派发任务"
            return
        }
        // 用任务标题截 12 字作对话标题（让顶部胶囊一眼能区分）
        let convTitle = String(task.title.prefix(12))
        let conv = Conversation(
            title: convTitle,
            messages: [],
            mode: task.suggestedMode
        )
        conversations.append(conv)
        activeConversationID = conv.id
        if lastUsedMode != task.suggestedMode { lastUsedMode = task.suggestedMode }
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        errorMessage = nil
        UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
        storage.saveConversations(conversations)
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": task.suggestedMode.rawValue]
        )
        checkConnection()

        // 把任务描述拼成首条消息发送
        let prompt: String
        if task.desc.isEmpty {
            prompt = task.title
        } else {
            prompt = "请帮我完成这个任务：\(task.title)\n\n\(task.desc)"
        }
        inputText = prompt
        sendMessage()
    }

    /// 切换对话对象（聊天头部一键切） —— 4 态 cycle：
    ///   Hermes → 在线 AI → Claude Code → Codex → Hermes
    /// 切到需要 CLI 的 mode 前先用 CLIAvailability 探测，没装就跳过这一档继续往下找
    func toggleAgentMode() {
        Task { @MainActor in
            let candidates: [AgentMode]
            switch agentMode {
            case .hermes:     candidates = [.directAPI, .claudeCode, .codex, .hermes]
            case .directAPI:  candidates = [.claudeCode, .codex, .hermes, .directAPI]
            case .claudeCode: candidates = [.codex, .hermes, .directAPI]
            case .codex:      candidates = [.hermes, .directAPI]
            }
            for next in candidates {
                if await isModeUsable(next) {
                    agentMode = next
                    Haptic.tap(.alignment)
                    return
                }
            }
            // 一圈下来没找到能用的（理论上至少 hermes / directAPI 永远可切）—— 兜底保持原状
            Haptic.tap(.alignment)
        }
    }

    /// 显式跳到某个 mode（顶部头部分段控件用）。CLI 缺失会 toast + 拒绝。
    func setAgentMode(_ mode: AgentMode) {
        Task { @MainActor in
            if await isModeUsable(mode) {
                agentMode = mode
                Haptic.tap(.alignment)
            }
        }
    }

    /// 检查目标 mode 是否能用。
    /// - hermes / directAPI 永远可用（key 没配在这里不挡，由发送时拦截 + 状态点提示）
    /// - claudeCode / codex 必须有对应 CLI；缺失就 toast 提示让用户切到「在线 AI」，并返回 false
    private func isModeUsable(_ mode: AgentMode) async -> Bool {
        switch mode {
        case .hermes, .directAPI:
            return true
        case .claudeCode:
            if await CLIAvailability.claudeAvailable() { return true }
            errorMessage = "未检测到 claude CLI，切到「在线 AI」就能只用 API Key 聊天"
            return false
        case .codex:
            if await CLIAvailability.codexAvailable() { return true }
            errorMessage = "未检测到 codex CLI，切到「在线 AI」就能只用 API Key 聊天"
            return false
        }
    }

    // MARK: - 附件（图片 + 文档）

    /// 拖入文档时调用 —— 不读内容，只保存路径，发送时让 AI 用 Read 工具自己访问。
    /// Hermes / 在线 AI 都走 OpenAI 兼容 HTTP API，访问不了本地文件，直接弹错误拒绝。
    func attachDocumentPath(_ url: URL) {
        if agentMode == .hermes || agentMode == .directAPI {
            errorMessage = "在线 / Hermes 模式无法读取本地文件，请切到 Claude Code 或 Codex 再拖入"
            return
        }
        // 去重：同一文件已在队列里就不重复加
        if pendingDocuments.contains(url) { return }
        pendingDocuments.append(url)

        // 灵动岛弹 toast 提示附加成功
        NotificationCenter.default.post(
            name: .init("HermesPetScreenshotAdded"),
            object: nil,
            userInfo: ["text": "已附加：\(url.lastPathComponent)", "count": 0]
        )
    }

    func removePendingDocument(at index: Int) {
        guard pendingDocuments.indices.contains(index) else { return }
        pendingDocuments.remove(at: index)
    }

    func clearPendingDocuments() {
        pendingDocuments.removeAll()
    }

    /// 把粘贴板/拖拽来的图片加入待发送队列
    func addPendingImage(_ data: Data) {
        pendingImages.append(data)
    }

    func removePendingImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    func clearPendingImages() {
        pendingImages.removeAll()
    }

    /// 截屏：先临时隐藏聊天窗口避免被截进去，截完恢复，把截图加到附件。
    /// 不用 CGPreflightScreenCaptureAccess 预检（macOS 26 + ScreenCaptureKit 下不可靠）。
    ///
    /// **同步策略**：`hideAndShowWindow(true, done:)` 接受一个 `done` callback，
    /// ChatView 端用 `NSAnimationContext.runAnimationGroup` 等动画完成后才调 done，
    /// 这样不依赖固定 250ms sleep，慢电脑也不会截到一半的窗口。
    func captureScreenAndAttach(hideAndShowWindow: @escaping (_ hide: Bool) -> Void) {
        hideAndShowWindow(true)
        Task { @MainActor [weak self] in
            // alphaValue=0 是立即生效的（非动画），等一次 CALayer commit + 一帧渲染就好。
            // 之前 250ms 是历史遗留，3 帧 ≈ 50ms 已经够，比之前快 5 倍 + 更可靠。
            try? await Task.sleep(nanoseconds: 50_000_000)
            let result = await ScreenCapture.captureMainScreenWithError()
            hideAndShowWindow(false)
            self?.handleScreenCaptureResult(result)
        }
    }

    private func handleScreenCaptureResult(_ result: ScreenCapture.CaptureResult) {
        switch result {
        case .success(let data):
            addPendingImage(data)
            // 先触发灵动岛快门动效（0.3s 闪白 + 缩放反弹），再发常规 toast
            NotificationCenter.default.post(
                name: .init("HermesPetCaptureShutter"),
                object: nil
            )
            Haptic.tap(.levelChange)        // 截图成功 → 明显的层级跳变
            postIslandToast("截图已添加")
        case .needsPermission:
            ScreenCapture.requestScreenRecordingPermission()
            errorMessage = "需要「屏幕录制」权限。已弹出系统申请框；如果没弹，请到 系统设置 → 隐私与安全性 → 屏幕录制 中允许 HermesPet，然后重启应用"
            postIslandToast("⚠️ 需要屏幕录制权限")
        case .failed(let message):
            errorMessage = "截屏失败：\(message)"
            postIslandToast("⚠️ 截屏失败")
        }
    }

    /// 通过 NotificationCenter 让灵动岛弹一个瞬时提示
    private func postIslandToast(_ text: String) {
        NotificationCenter.default.post(
            name: .init("HermesPetScreenshotAdded"),
            object: nil,
            userInfo: ["text": text, "count": self.pendingImages.count]
        )
    }

    /// 导出当前对话为 Markdown，弹出 macOS 保存面板让用户选位置
    func exportChatToMarkdown() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.allowsOtherFileTypes = true
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            return f.string(from: Date())
        }()
        panel.nameFieldStringValue = "hermes-chat-\(stamp).md"
        panel.title = "导出对话为 Markdown"

        panel.begin { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let self = self else { return }
            let md = self.buildMarkdown()
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.errorMessage = "导出失败: \(error.localizedDescription)"
            }
        }
        #endif
    }

    private func buildMarkdown() -> String {
        var lines: [String] = []
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"

        lines.append("# 对话记录")
        lines.append("")
        lines.append("> 对话对象：**\(agentMode.label)**")
        lines.append("> 导出时间：\(dateFmt.string(from: Date()))")
        lines.append("")
        lines.append("---")
        lines.append("")

        for msg in messages where msg.role != .system {
            let who = msg.role == .user ? "你" : agentMode.label
            lines.append("### \(who) · \(dateFmt.string(from: msg.timestamp))")
            lines.append("")
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
