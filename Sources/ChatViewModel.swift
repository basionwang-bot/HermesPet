import Foundation
import SwiftUI
import ServiceManagement

@MainActor
@Observable
final class ChatViewModel {
    private static let completeThinkBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*?</think\s*>"#
    )
    private static let trailingThinkBlockRegex = try! NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*\z"#
    )

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

    /// WTF 工作流(MVP single)—— 当前待运行的 workflow id（选了还没发首条消息）。
    var pendingWorkflowID: String? = nil
    var pendingWorkflow: Workflow? { pendingWorkflowID.flatMap { WorkflowRegistry.shared.workflow(id: $0) } }
    /// 全量模式（AI 公司舰队）—— 选中后等用户在输入框打任务并发送。与 pendingWorkflowID 互斥。
    var pendingFleet: Bool = false
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
            // 错误音 —— 只在出新错误时响，避免同样错误连续 set 重复轰炸
            if oldValue != msg {
                SoundManager.play(.error)
            }
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

    /// 子进程后端（Claude Code）回报的真实模型 id（如 claude-opus-4-6）—— 给查 models.dev 真实窗口用。
    /// key = conversationID。
    private(set) var modelIDByConversation: [String: String] = [:]

    func recordModelID(_ modelID: String, for conversationID: String) {
        guard !modelID.isEmpty else { return }
        if modelIDByConversation[conversationID] != modelID {
            modelIDByConversation[conversationID] = modelID
        }
    }

    /// 当前对话实际使用的模型名（按 mode 取对应配置）—— 用于推断上下文窗口大小。
    var currentModelName: String {
        switch agentMode {
        case .hermes:     return modelName
        case .directAPI:  return directAPIModel.isEmpty ? "deepseek" : directAPIModel
        case .openclaw:   return "openclaw"
        case .claudeCode: return modelIDByConversation[activeConversationID] ?? "claude"
        case .codex:      return modelIDByConversation[activeConversationID] ?? "codex"
        case .qwenCode:   return modelIDByConversation[activeConversationID] ?? "qwen"
        }
    }

    /// 每个对话最近一次请求的**真实**输入上下文 token（AI 回报的 prompt_tokens）。
    /// 估算严重偏低（后端系统提示/工具定义/记忆不在可见消息里，实测 OpenClaw 真实 14K vs 估算 13），
    /// 所以拿到真实值后优先用它。key = conversationID。
    private(set) var contextTokensByConversation: [String: Int] = [:]

    /// 记一次某对话的真实上下文 token（流式回调里调，已 hop 到 MainActor）。
    func recordContextTokens(_ tokens: Int, for conversationID: String) {
        guard tokens > 0 else { return }
        contextTokensByConversation[conversationID] = tokens
    }

    /// 当前对话的上下文占用（给 ChatView 底部 Context 进度条用）。
    /// used 优先用 AI 真实回报的 prompt_tokens；首条消息还没回报前用估算兜底。
    /// window = 当前模型的上下文窗口。
    var contextUsage: (used: Int, window: Int) {
        let window = TokenEstimator.contextWindow(forModel: currentModelName, mode: agentMode)
        if let real = contextTokensByConversation[activeConversationID], real > 0 {
            return (real, window)
        }
        let est = TokenEstimator.estimateMessagesTokens(messages.map { $0.content })
        return (est, window)
    }

    // 在线 AI（directAPI）的配置 —— 跟 Hermes 完全独立，
    // 用户分发给朋友的场景：只用配这一组就能聊
    var directAPIBaseURL: String {
        didSet {
            UserDefaults.standard.set(directAPIBaseURL, forKey: "directAPIBaseURL")
            scheduleOpenCodeConfigReload()
        }
    }
    var directAPIKey: String {
        didSet {
            UserDefaults.standard.set(directAPIKey, forKey: "directAPIKey")
            let providerID = UserDefaults.standard.string(forKey: "directAPIProviderID") ?? ""
            if !providerID.isEmpty {
                UserDefaults.standard.set(directAPIKey, forKey: Self.directAPIKeyStorageKey(providerID: providerID))
            }
            scheduleOpenCodeConfigReload()
        }
    }
    var directAPIModel: String {
        didSet {
            UserDefaults.standard.set(directAPIModel, forKey: "directAPIModel")
            scheduleOpenCodeConfigReload()
        }
    }
    /// 在线 AI 的回复偏好，默认平衡。最终仍会映射成 directAPIModel 发给 API。
    var directAPIResponsePreference: DirectResponsePreference {
        didSet { UserDefaults.standard.set(directAPIResponsePreference.rawValue, forKey: "directAPIResponsePreference") }
    }
    // QwenCode 走 subprocess CLI（QwenCodeClient）。默认零配置复用本机 qwen 登录；
    // 也可在设置里填 API Key（傻瓜配置），spawn 时通过 --openai-api-key 传给 qwen，不动其全局 ~/.qwen/settings.json。
    var qwenAPIKey: String {
        didSet { UserDefaults.standard.set(qwenAPIKey, forKey: "qwenAPIKey") }
    }
    var qwenBaseURL: String {
        didSet { UserDefaults.standard.set(qwenBaseURL, forKey: "qwenBaseURL") }
    }
    var qwenModel: String {
        didSet { UserDefaults.standard.set(qwenModel, forKey: "qwenModel") }
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
                errorMessage = L("vm.error.modeLocked", conversations[idx].title, L(conversations[idx].mode.labelKey))
                return
            }
            guard conversations[idx].mode != newValue else { return }
            conversations[idx].mode = newValue
            // 新对话还没发 user 消息时，welcome message 的 mode label 跟着切（避免发完第一条消息后
            // 看见"👋 这是一个新对话（旧 mode）"残留，字面跟当前 mode 冲突）
            if !conversations[idx].hasUserMessages,
               conversations[idx].messages.count == 1,
               conversations[idx].messages[0].role == .assistant {
                conversations[idx].messages[0].content = Self.welcomeMessageContent(for: newValue)
            }
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
    /// 聊天窗"始终置顶"开关 —— 默认 true（老行为，浮在所有 app 上）。
    /// 关掉 → window.level = .normal，跟普通窗口一样会被其他 app 挡住。
    /// 持久化 + 发通知给 ChatWindowController 切 window.level，Key 跟 ChatWindowController 共用同一个常量
    var chatWindowAlwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(chatWindowAlwaysOnTop, forKey: kChatWindowAlwaysOnTopKey)
            NotificationCenter.default.post(
                name: .hermesPetChatWindowPinChanged,
                object: nil,
                userInfo: ["pinned": chatWindowAlwaysOnTop]
            )
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
    /// 桌宠静止/钉住开关 —— 开启后桌宠停在用户拖放的固定位置，不漫步/不追鼠标/不巡视/不回家，
    /// 但仍保留呼吸·眨眼·偶尔张望伸懒腰等微动作（保留生命感）。位置只随用户拖动改变并持久化。
    /// 默认 OFF。与「自由活动」「桌面巡视」互斥语义：钉住时那些自动行为都让位。
    var petPinnedEnabled: Bool {
        didSet {
            UserDefaults.standard.set(petPinnedEnabled, forKey: "petPinnedEnabled")
            NotificationCenter.default.post(
                name: .init("HermesPetPinnedSettingChanged"),
                object: nil,
                userInfo: ["enabled": petPinnedEnabled]
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
    /// 是否在 Dock 显示应用图标。
    /// Info.plist 默认 LSUIElement=true（菜单栏 agent 风格不占 Dock），但用户可以 runtime
    /// 通过 `NSApp.setActivationPolicy(.regular)` 切换显示。默认 OFF 保持极简定位。
    /// 切换后立即生效，无需重启。
    var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            // 切到 .regular 时强制激活，避免 Dock 图标显示但 app 仍在后台不可见的诡异状态
            if showDockIcon {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// 活动记录开关 —— 开启后持续记录用户在用什么 app/窗口/键盘节奏，让 AI 能"看见"用户做什么。
    /// 默认开启（首次启用会弹一次 Accessibility 权限框）
    var activityRecordingEnabled: Bool {
        didSet {
            ActivityRecorder.shared.setRunning(activityRecordingEnabled)
        }
    }
    /// 每天早报由哪个 AI 后端生成 —— 用户在设置里固定选一个，不跟随当前对话 mode
    /// （早报涉及隐私汇总，让用户对哪家服务商看到这些数据有明确控制）
    var morningBriefingBackend: AgentMode {
        didSet { UserDefaults.standard.set(morningBriefingBackend.rawValue, forKey: "morningBriefingBackend") }
    }
    /// 会议纪要由哪个 AI 整理 —— 跟早报同理，用户在设置里固定选一个，不跟随当前对话 mode。
    /// 默认「在线 AI」：整理是纯文本任务不需本地工具，HTTP 流式比 Claude/Codex 起子进程快得多。
    var meetingSummaryBackend: AgentMode {
        didSet { UserDefaults.standard.set(meetingSummaryBackend.rawValue, forKey: "meetingSummaryBackend") }
    }
    /// 权限审批 UI 开关 —— v1.3 新增。
    /// 关（默认）：directAPI 工具全 allow + Claude/Codex 的 ~/.claude/settings.json hook 撤销
    /// 开：directAPI 走 ask + Claude/Codex 注入 hook → 工具调用前灵动岛弹卡片让用户决策
    /// 切换后立即生效（hook 安装是异步的，下次工具调用时已经生效）
    var permissionUIEnabled: Bool {
        didSet {
            UserDefaults.standard.set(permissionUIEnabled, forKey: "permissionUIEnabled")
            Task { @MainActor in
                let port = PermissionHookServer.shared.port
                if permissionUIEnabled, port > 0 {
                    PermissionHookInstaller.installClaudeHook(port: port)
                    PermissionHookInstaller.installCodexHook(port: port)
                } else {
                    PermissionHookInstaller.uninstallClaudeHook()
                    PermissionHookInstaller.uninstallCodexHook()
                }
            }
        }
    }

    var showSettings: Bool = false

    /// 写作模式：聊天窗内切成「文件侧栏 + 文档画布 + 对话」三栏（外置大脑）。
    /// 由 ChatView 顶部切换按钮 / ⌘⇧N 置位；ChatWindowController 观察通知把窗口放大/缩小。
    /// 纯瞬态不持久化（关窗重开回普通聊天，避免冷启动直接进大窗踩尺寸坑）。
    var isWritingMode: Bool = false {
        didSet {
            guard oldValue != isWritingMode else { return }
            if !isWritingMode {
                NotesStore.shared.saveCurrentIfDirty()       // 退出写作先把文档落盘
                NotesWritingContextHolder.shared.clear()     // 普通对话不再注入文档上下文
            }
            NotificationCenter.default.post(
                name: .init("HermesPetWritingModeChanged"),
                object: nil,
                userInfo: ["on": isWritingMode]
            )
        }
    }

    /// 新用户首次引导：true 时聊天窗内覆盖一层 OnboardingView。
    /// 由 AppDelegate 在首启（且非老用户）时置 true，引导完成 / 跳过后置 false。
    var showOnboarding: Bool = false

    /// 开机自启状态（SMAppService 同步）
    var isLaunchAtLoginOn: Bool = false

    /// 5 个提示音事件 —— 详见 `SoundEvent`。值可能是：
    /// - 空字符串 = 关闭（不响）
    /// - 系统音名（如 "Glass" / "Pop"）= macOS 内置音
    /// - 以 `/` 开头的绝对路径 = 用户拖入的自定义音频文件
    var voiceStartSound: String {
        didSet { UserDefaults.standard.set(voiceStartSound, forKey: SoundEvent.voiceStart.defaultsKey) }
    }
    var voiceFinishSound: String {
        didSet { UserDefaults.standard.set(voiceFinishSound, forKey: SoundEvent.voiceFinish.defaultsKey) }
    }
    var dragInSound: String {
        didSet { UserDefaults.standard.set(dragInSound, forKey: SoundEvent.dragIn.defaultsKey) }
    }
    var sendSound: String {
        didSet { UserDefaults.standard.set(sendSound, forKey: SoundEvent.send.defaultsKey) }
    }
    var errorSound: String {
        didSet { UserDefaults.standard.set(errorSound, forKey: SoundEvent.error.defaultsKey) }
    }

    /// 待发送的图片附件（粘贴 / 拖拽 / 截屏都进这里）
    var pendingImages: [Data] = []

    /// 待发送的文档附件路径（拖入的 PDF / txt / md / 任意文件，仅 Claude / Codex 模式生效）。
    /// 不读内容，发送时把路径拼到 prompt 末尾让 AI 用 Read 工具自己访问，省 context、更快。
    var pendingDocuments: [URL] = []

    private let apiClient = APIClient(source: .hermes)
    private let directClient = APIClient(source: .direct)
    /// OpenClaw 走 OpenAI 兼容 chat completions（端口 18789）。Bearer token 由 OpenClawGatewayManager
    /// 从 ~/.openclaw/openclaw.json 自动读取并缓存，APIClient 内部直接拿（零填表体验）
    private let openClawClient = APIClient(source: .openclaw)
    private let qwenClient = QwenCodeClient()   // QwenCode = 本机 qwen CLI 子进程，零配置复用其登录
    private let claudeClient = ClaudeCodeClient()
    private let codexClient = CodexClient()
    private let storage = StorageManager.shared
    /// B 阶段：自上次更新长期记忆以来，是否聊过新内容。用户空闲（3min）时若为 true 才触发一次记忆更新，
    /// 避免每段对话都耗 AI 调用；更新完清回 false。
    private var memoryDirty = false
    /// 画布调度服务 —— init 末尾构造（@Observable class 不让用 lazy var）
    private var canvasService: CanvasService!
    private var statusTimer: Timer?

    static func directAPIKeyStorageKey(providerID: String) -> String {
        "directAPIKey.\(providerID)"
    }

    /// 新对话的 welcome message 文本模板 —— newConversation 跟 agentMode setter 都用它，
    /// 保证用户在新对话状态下切 mode 时，welcome message 的 mode label 跟实际 mode 同步
    static func welcomeMessageContent(for mode: AgentMode) -> String {
        L("vm.greeting.welcome", L(mode.labelKey))
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
        self.qwenAPIKey  = UserDefaults.standard.string(forKey: "qwenAPIKey") ?? ""
        self.qwenBaseURL = UserDefaults.standard.string(forKey: "qwenBaseURL") ?? ""
        self.qwenModel   = UserDefaults.standard.string(forKey: "qwenModel") ?? ""
        let savedMode = UserDefaults.standard.string(forKey: "agentMode")
        // 全新用户默认走「在线 AI」—— 对方拿到 dmg 多半没装 Hermes Gateway 也没 claude/codex CLI，
        // directAPI 配上 API Key 就能立刻用。老用户的 agentMode UserDefaults 还在，不受影响
        self.lastUsedMode = AgentMode(rawValue: savedMode ?? "") ?? .directAPI
        self.isLaunchAtLoginOn = SMAppService.mainApp.status == .enabled
        self.voiceStartSound  = UserDefaults.standard.string(forKey: SoundEvent.voiceStart.defaultsKey)  ?? SoundEvent.voiceStart.fallbackValue
        self.voiceFinishSound = UserDefaults.standard.string(forKey: SoundEvent.voiceFinish.defaultsKey) ?? SoundEvent.voiceFinish.fallbackValue
        self.dragInSound      = UserDefaults.standard.string(forKey: SoundEvent.dragIn.defaultsKey)      ?? SoundEvent.dragIn.fallbackValue
        self.sendSound        = UserDefaults.standard.string(forKey: SoundEvent.send.defaultsKey)        ?? SoundEvent.send.fallbackValue
        self.errorSound       = UserDefaults.standard.string(forKey: SoundEvent.error.defaultsKey)       ?? SoundEvent.error.fallbackValue
        // chatWindowAlwaysOnTop 默认 true —— 保持老用户行为（聊天窗本来就是浮窗 .floating）
        self.chatWindowAlwaysOnTop = (UserDefaults.standard.object(forKey: kChatWindowAlwaysOnTopKey) as? Bool) ?? true
        self.quietMode = UserDefaults.standard.bool(forKey: "quietMode")
        // hapticEnabled 默认 true（无值时 object(forKey:) → nil → ?? true）
        self.hapticEnabled = (UserDefaults.standard.object(forKey: "hapticEnabled") as? Bool) ?? true
        // clawdWalkEnabled 默认 true（首次见到时让用户被这个彩蛋惊艳一次）
        self.clawdWalkEnabled = (UserDefaults.standard.object(forKey: "clawdWalkEnabled") as? Bool) ?? true
        // clawdFreeRoamEnabled 默认 false（默认仅 idle 触发，避免一开机就一直在屏幕上）
        self.clawdFreeRoamEnabled = UserDefaults.standard.bool(forKey: "clawdFreeRoamEnabled")
        // petPinnedEnabled 默认 false（钉住是用户主动选择的"安静摆件"模式）
        self.petPinnedEnabled = UserDefaults.standard.bool(forKey: "petPinnedEnabled")
        // clawdDesktopPatrolEnabled 默认 false —— 需要 Finder 自动化权限，默认 OFF 让用户主动开
        self.clawdDesktopPatrolEnabled = UserDefaults.standard.bool(forKey: "clawdDesktopPatrolEnabled")
        // showDockIcon 默认 true（v1.3）—— 菜单栏 app 容易被新用户"弄丢"，默认显示 Dock 图标方便找到/切回
        self.showDockIcon = (UserDefaults.standard.object(forKey: "showDockIcon") as? Bool) ?? true
        // activityRecordingEnabled 默认 true（首次会弹 Accessibility 权限框，用户可在设置里关）
        self.activityRecordingEnabled = (UserDefaults.standard.object(forKey: "activityRecordingEnabled") as? Bool) ?? true
        // permissionUIEnabled 默认 false —— dmg 朋友升级零摩擦（行为不变），追求安全的用户设置里手动开
        self.permissionUIEnabled = UserDefaults.standard.bool(forKey: "permissionUIEnabled")
        // 早报后端默认「在线 AI」（跟新用户默认 mode 一致）—— 之前默认 Hermes，新用户没配 Hermes
        // 会导致早报/共享记忆/周期回顾全部空转。引导里配好在线 AI 后也会再确认设成 .directAPI。
        let savedBriefing = UserDefaults.standard.string(forKey: "morningBriefingBackend")
        self.morningBriefingBackend = AgentMode(rawValue: savedBriefing ?? "") ?? .directAPI
        // 会议整理后端默认「在线 AI」（最快），用户可在设置→隐私里改
        let savedMeeting = UserDefaults.standard.string(forKey: "meetingSummaryBackend")
        self.meetingSummaryBackend = AgentMode(rawValue: savedMeeting ?? "") ?? .directAPI

        // 加载持久化的对话列表（兼容旧版 session.json，自动迁移）
        var loaded = storage.loadConversations()
        if loaded.isEmpty {
            // 全新用户 / 没历史 —— 起一个带欢迎语的对话，mode 用上次记得的 lastUsedMode
            loaded = [Conversation(
                title: L("vm.title.new"),
                messages: [ChatMessage(
                    role: .assistant,
                    content: L("vm.greeting.firstLaunch")
                )],
                mode: self.lastUsedMode
            )]
        }
        self.conversations = loaded
        // 开机回填：把当前工作集镜像进永久历史库（保证即使本次没有任何存盘动作，历史库也是最新的）
        ConversationHistoryStore.shared.mirror(loaded)
        // 阶段5·自动归档：开机扫一遍，把超 90 天没碰、未加星的归档（云图/历史默认列表自动移走，仍可搜可恢复）
        Task.detached(priority: .utility) { ConversationHistoryStore.shared.autoArchive(olderThanDays: 90) }
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

        // 启动图片后台补水：loadConversations 用 lazy 解码跳过了图片文件读取（见 StorageManager），
        // 这里在后台读出来按 (conversationID, messageID) 精确回填，不卡冷启动
        hydrateImagesInBackground()

        // B 阶段：记忆功能默认开 —— 首次低调告知用户一次（横幅，可在设置关）。
        // 延迟到灵动岛起来 + 不在引导页时再弹；条件不满足就不标记，下次启动再试。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard UserMemoryStore.shared.firstRunNoticePending, !self.showOnboarding else { return }
            UserMemoryStore.shared.markNoticeShown()
            NotificationCenter.default.post(
                name: .init("HermesPetScreenshotAdded"),
                object: nil,
                userInfo: ["text": L("memory.firstRun.notice"), "count": 0, "durationMs": 4500]
            )
        }

        // 画布调度服务初始化（依赖 directClient / codexClient / storage 已构造）
        self.canvasService = CanvasService(
            textClient: directClient,
            codexClient: codexClient,
            storage: storage
        )

        // B 阶段：用户空闲（3min，复用 IdleStateTracker）且期间聊过新内容 → 后台静悄悄更新一次长期记忆。
        // 只在 isSleeping 翻 true 那一下触发，且要 memoryDirty，避免频繁/无谓的 AI 调用。
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetUserIdleChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard (note.userInfo?["isSleeping"] as? Bool) == true else { return }
            Task { @MainActor in
                guard self.memoryDirty, UserMemoryStore.shared.isEnabled else { return }
                self.memoryDirty = false
                await UserMemoryStore.shared.updateFromRecentConversations(viewModel: self)
            }
        }

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

        // PetHeaderStrip 右侧 mode mini sprite 点击 → 以指定 mode 新建对话
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetNewConversationWithMode"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let raw = note.userInfo?["mode"] as? String,
                  let target = AgentMode(rawValue: raw) else { return }
            Task { @MainActor in
                let ok = self.newConversation(mode: target)
                if !ok {
                    self.errorMessage = L("vm.error.convFullRetry", kMaxConversations)
                }
            }
        }

        // 灵动岛右侧「活动轨道」小胶囊点击 → 切到该后台对话 + 打开聊天窗
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetActivityCapsuleTapped"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in
                self.switchConversation(to: id)
                NotificationCenter.default.post(
                    name: .init("HermesPetOpenChatRequested"),
                    object: nil
                )
            }
        }

        // 灵动岛 permission 卡片用户决策 → POST 回 opencode（仅 directAPI 模式）
        // 设置开关「权限审批」打开 + 用户点 Allow once/Always/Deny 时触发
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetPermissionDecisionMade"),
            object: nil,
            queue: .main
        ) { note in
            guard let requestID = note.userInfo?["requestID"] as? String,
                  let raw = note.userInfo?["decision"] as? String,
                  let decision = PermissionDecision(rawValue: raw) else { return }
            Task.detached(priority: .userInitiated) {
                await OpenCodeHTTPClient.shared.replyPermission(
                    requestID: requestID,
                    decision: decision
                )
            }
        }

        // Question 卡片用户选了选项 → POST 回 opencode
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetQuestionAnswered"),
            object: nil,
            queue: .main
        ) { note in
            guard let requestID = note.userInfo?["requestID"] as? String,
                  let answers = note.userInfo?["answers"] as? [[String]] else { return }
            Task.detached(priority: .userInitiated) {
                await OpenCodeHTTPClient.shared.replyQuestion(
                    requestID: requestID,
                    answers: answers
                )
            }
        }
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetQuestionRejected"),
            object: nil,
            queue: .main
        ) { note in
            guard let requestID = note.userInfo?["requestID"] as? String else { return }
            Task.detached(priority: .userInitiated) {
                await OpenCodeHTTPClient.shared.rejectQuestion(requestID: requestID)
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

    /// 当前是否处于"掉线快速重试"节奏（H5）
    /// connected 时 30s 一次，disconnected 时切到 10s 一次，恢复后自动切回 30s
    private var fastRetryActive: Bool = false

    private func startStatusPolling() {
        checkConnection()
        scheduleStatusTimer(fast: false)
    }

    /// 按当前连接状态调度状态轮询定时器（H5 后台自动重试）
    /// - fast = true → 10s 一次；fast = false → 30s 一次
    private func scheduleStatusTimer(fast: Bool) {
        statusTimer?.invalidate()
        let interval: TimeInterval = fast ? 10 : 30
        fastRetryActive = fast
        statusTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkConnection()
            }
        }
    }

    /// connection 状态变化后回调：disconnected 时启用快速重试，connected 时回慢节奏 + 灵动岛短提示
    /// 在每个 mode 的 checkConnection 异步分支末尾调用
    private func handleConnectionStateChange() {
        let isDisconnected: Bool
        if case .disconnected = connectionStatus { isDisconnected = true } else { isDisconnected = false }

        if isDisconnected && !fastRetryActive {
            // 刚掉线 → 切快速重试
            scheduleStatusTimer(fast: true)
        } else if !isDisconnected && fastRetryActive {
            // 恢复连接 → 切回慢节奏 + 灵动岛恢复提示
            scheduleStatusTimer(fast: false)
            NotificationCenter.default.post(
                name: .init("HermesPetIslandTransientLabel"),
                object: nil,
                userInfo: [
                    "text": agentMode == .hermes ? L("vm.status.recovered") : L("vm.status.connected"),
                    "duration": 2.0
                ]
            )
        }
    }

    func checkConnection() {
        // 捕获本次请求的 mode；异步探测返回后若用户已切到别的对话/mode，丢弃旧结果不写脏 connectionStatus（决策 #11）
        let requestedMode = agentMode
        switch agentMode {
        case .hermes:
            // 自托管 Hermes 大概率无鉴权，apiKey 空也允许尝试连接（H2）
            // baseURL 至少要有值，否则压根没法 ping
            guard !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                connectionStatus = .disconnected(L("vm.status.noAPIURL"))
                return
            }
            Task {
                do {
                    let ok = try await apiClient.checkHealth()
                    guard requestedMode == agentMode else { return }
                    if ok {
                        connectionStatus = .connected
                    } else {
                        // 区分本地 vs 云端给清晰原因
                        let isLocal = apiBaseURL.contains("localhost") || apiBaseURL.contains("127.0.0.1")
                        connectionStatus = .disconnected(isLocal ? L("vm.status.localGatewayDown") : L("vm.status.gatewayNoResponse"))
                    }
                } catch {
                    guard requestedMode == agentMode else { return }
                    let isLocal = apiBaseURL.contains("localhost") || apiBaseURL.contains("127.0.0.1")
                    let reason: String = {
                        if isLocal { return L("vm.status.localGatewayDownHint") }
                        return error.localizedDescription
                    }()
                    connectionStatus = .disconnected(reason)
                }
                handleConnectionStateChange()
            }
        case .directAPI:
            // v1.2.0+：所有在线 AI 都走 opencode（含 DeepSeek，agent 能力优先于稳定性）
            // - 没装 API key 也能用（默认 opencode/deepseek-v4-flash-free 免费模型）
            // - opencode server 由 OpenCodeServerManager 在 App 启动时拉起
            // 连接状态 = server 是否 ready。Server 启动需要 1-2s，App 刚启动时可能还没 ready
            if OpenCodeServerManager.shared.isReady {
                connectionStatus = .connected
            } else if let err = OpenCodeServerManager.shared.lastError {
                connectionStatus = .disconnected(err)
            } else {
                // 还在启动中 —— 后台 watch 1-2s 后再检
                connectionStatus = .unknown
                Task { [weak self] in
                    for _ in 0..<15 {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if OpenCodeServerManager.shared.isReady {
                            await MainActor.run {
                                guard self?.agentMode == requestedMode else { return }
                                self?.connectionStatus = .connected
                            }
                            return
                        }
                    }
                    await MainActor.run {
                        guard self?.agentMode == requestedMode else { return }
                        if let err = OpenCodeServerManager.shared.lastError {
                            self?.connectionStatus = .disconnected(err)
                        } else {
                            self?.connectionStatus = .disconnected(L("vm.status.opencodeTimeout"))
                        }
                    }
                }
            }
        case .openclaw:
            // OC6: 走 openClawClient.checkHealth() —— APIClient .openclaw 分流先 /health 再 /models
            // OpenClawGatewayManager 启动时自动 enable chatCompletions endpoint，所以 /models 也通
            Task {
                do {
                    let ok = try await openClawClient.checkHealth()
                    guard requestedMode == agentMode else { return }
                    if ok {
                        connectionStatus = .connected
                    } else {
                        connectionStatus = .disconnected(L("vm.status.openclawNoResponse"))
                    }
                } catch {
                    guard requestedMode == agentMode else { return }
                    // 区分常见原因：binary 没装 vs daemon 没起
                    let reason: String = {
                        switch OpenClawGatewayManager.shared.status {
                        case .binaryMissing:   return L("vm.status.openclawMissing")
                        case .configMissing:   return L("vm.status.openclawNoOnboard")
                        case .endpointDisabled: return L("vm.status.openclawEndpointDisabled")
                        case .disabled:        return L("vm.status.openclawDisabled")
                        case .failed(let m):   return m
                        default:               return error.localizedDescription
                        }
                    }()
                    connectionStatus = .disconnected(reason)
                }
                handleConnectionStateChange()
            }
        case .claudeCode:
            Task {
                let ok = await claudeClient.checkAvailable()
                guard requestedMode == agentMode else { return }
                connectionStatus = ok ? .connected : .disconnected(L("vm.status.claudeMissing"))
            }
        case .codex:
            Task {
                let ok = await codexClient.checkAvailable()
                guard requestedMode == agentMode else { return }
                connectionStatus = ok ? .connected : .disconnected(L("vm.status.codexMissing"))
            }
        case .qwenCode:
            // QwenCode = 本机 qwen CLI 子进程，跟 Claude/Codex 一样看 CLI 是否装好
            Task {
                let ok = await qwenClient.checkAvailable()
                guard requestedMode == agentMode else { return }
                connectionStatus = ok ? .connected : .disconnected(L("vm.status.qwenMissing"))
            }
        }
    }

    // MARK: - Send Message

    /// 选中一个 workflow（加号 / 陈列页）→ 进入待运行态 + 聚焦输入框等用户喂内容。
    func activateWorkflow(_ id: String) {
        guard WorkflowRegistry.shared.workflow(id: id) != nil else { return }
        pendingFleet = false          // 互斥：选 workflow 就清掉全量模式
        pendingWorkflowID = id
        NotificationCenter.default.post(name: .init("HermesPetFocusInputField"), object: nil)
    }
    func cancelWorkflow() { pendingWorkflowID = nil }

    /// 选中「全量模式」(AI 公司舰队) → 待运行态 + 聚焦输入框等用户喂任务。与 workflow 互斥。
    func activateFleet() {
        pendingWorkflowID = nil       // 互斥：选全量就清掉待运行 workflow
        pendingFleet = true
        NotificationCenter.default.post(name: .init("HermesPetFocusInputField"), object: nil)
    }
    func cancelFleet() { pendingFleet = false }

    /// sendMessage 开头调用：有待运行的全量模式标记就把输入文本当任务交给舰队剧场，不走普通聊天。
    /// 返回 true = 已交给舰队，sendMessage 应直接 return。
    @discardableResult
    private func launchPendingFleetIfNeeded() -> Bool {
        guard pendingFleet else { return false }
        let topic = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return false }   // 没内容不拦，让原 guard 处理
        pendingFleet = false
        inputText = ""
        FleetTheaterController.shared.presentAndDispatch(vm: self, topic: topic)
        return true
    }

    /// sendMessage 开头调用：有待运行 workflow 就交给 **harness（WorkflowRunner）** 多阶段执行，
    /// 弹执行面板看进度、产出真正的产物 —— **不再往输入框塞一段 prompt**（用户明确要求）。
    /// 返回 true = 这次发送已交给工作流，sendMessage 应直接 return（不再走普通聊天流）。
    @discardableResult
    private func launchPendingWorkflowIfNeeded() -> Bool {
        guard let wf = pendingWorkflow else { return false }
        let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return false }   // 没内容就不拦，让原 guard 正常处理（只图片/文档另说）
        pendingWorkflowID = nil
        inputText = ""
        // inputSource=auto 且用户没粘长文（只打了「分析当前对话」这类短指令）→ 用**当前对话内容**当材料。
        // 解决"总结/洞察 却没拿到对话内容、AI 没东西可分析"的问题。
        var material = typed
        if wf.inputSource == "auto", typed.count < 60 {
            let convo = currentConversationTranscript()
            if !convo.isEmpty { material = convo }
        }
        runWorkflow(wf, displayInput: typed, material: material)
        return true
    }

    /// 当前对话的纯文本转写（喂给 inputSource=auto 的工作流）。跳过工作流记录条 + 空消息，
    /// 太长只留最近 maxChars（防爆 context）。
    func currentConversationTranscript(maxChars: Int = 40000) -> String {
        guard let conv = conversations.first(where: { $0.id == activeConversationID }) else { return "" }
        var lines: [String] = []
        for m in conv.messages {
            if m.workflowRunID != nil { continue }   // 跳过"运行了工作流"记录条本身
            let c = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.isEmpty { continue }
            lines.append((m.role == .user ? "用户：" : "AI：") + c)
        }
        var text = lines.joined(separator: "\n\n")
        if text.count > maxChars { text = String(text.suffix(maxChars)) }   // 留最近的
        return text
    }

    /// 把一次工作流交给 harness 执行：建轨迹 → 弹执行面板 → 后台跑 `WorkflowRunner`。
    /// - displayInput：聊天记录条 / run.input 里显示的（用户打的指令）
    /// - material：真正喂给 harness 的材料（粘的长文，或 auto 模式下的当前对话内容）
    /// 产物落在面板里由用户处置（复制 / 存为对话 / 生成网页），不自动塞聊天，避免污染当前对话。
    func runWorkflow(_ wf: Workflow, displayInput: String, material: String) {
        let backend = agentMode
        let stepRecords = wf.effectiveStages.map {
            WorkflowStepRecord(stepID: $0.id, title: $0.title, kind: $0.kind, status: "pending")
        }
        let run = WorkflowRun(id: UUID().uuidString,
                              workflowID: wf.id, workflowName: wf.name,
                              modeRaw: backend.rawValue, input: displayInput,
                              status: "running", steps: stepRecords,
                              createdAt: Date(), updatedAt: Date())
        let model = RunModel(run: run, workflow: wf)
        WorkflowRunStore.shared.add(run)
        WorkflowTelemetry.recordRun(id: wf.id, mode: backend.rawValue)

        // 在当前对话留一条"运行了工作流"的记录 —— 挂「查看运行过程」按钮，关掉独立窗口后也能重开
        // （轨迹已持久化在 ~/.hermespet/runs/，重启都能重开）。
        if let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) {
            conversations[idx].messages.append(ChatMessage(role: .user, content: displayInput, workflowRunID: run.id))
            storage.saveConversations(conversations)
        }

        RunPanelController.shared.show(model: model, vm: self)

        Task { @MainActor in
            _ = await WorkflowRunner.run(workflow: wf, input: material, backend: backend, vm: self, model: model)
        }
    }

    /// 聊天里「查看运行过程」按钮 → 重开该 workflow 运行面板（正在跑的复用实时模型，已结束的从轨迹重建）。
    func reopenWorkflowRun(_ runID: String) {
        RunPanelController.shared.reopen(runID: runID, vm: self)
    }

    /// 把工作流产物存成一个新对话（[用户输入, AI 产物]）+ 切过去 + 打开聊天窗。挤旧逻辑同早报。
    func createWorkflowResultConversation(content: String, title: String, input: String, mode: AgentMode) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let newConv = Conversation(
            title: title,
            messages: [
                ChatMessage(role: .user, content: input),
                ChatMessage(role: .assistant, content: content)
            ],
            mode: mode)
        if conversations.count >= kMaxConversations {
            if let oldestIdx = conversations.indices.reversed().first(where: { !conversations[$0].isStreaming }) {
                conversations.remove(at: oldestIdx)
            } else {
                errorMessage = L("vm.error.briefingAllBusy")
                return
            }
        }
        conversations.insert(newConv, at: 0)
        activeConversationID = newConv.id
        storage.saveConversations(conversations)
        NotificationCenter.default.post(name: .init("HermesPetModeChanged"), object: nil,
                                        userInfo: ["mode": mode.rawValue])
        checkConnection()
        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
    }

    func sendMessage() {
        if launchPendingWorkflowIfNeeded() { return }
        if launchPendingFleetIfNeeded() { return }       // 全量模式：输入即任务，交给舰队剧场
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 允许「只发图片 / 只拖文档不带文字」—— 文字、图片、文档任一非空就能发
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingDocuments.isEmpty else { return }

        // 画布对话：用户输入走"意图识别 + 应用到画布"，不走普通聊天流
        if let active = conversations.first(where: { $0.id == activeConversationID }),
           active.kind == .canvas {
            dispatchCanvasInput(canvasID: active.id, userInput: text)
            inputText = ""
            return
        }

        // 关键词触发新画布：用户输入 "画布：xxx" / "/canvas xxx" / "canvas xxx"
        // 自动开一个新画布对话（用电商模板兜底，用户可在 popover 改）
        if let topic = matchCanvasKeyword(text) {
            inputText = ""
            createCanvasConversation(template: CanvasTemplates.ecommerce, topic: topic)
            return
        }

        // Hermes 模式：至少要填 API 地址（自托管经常无鉴权，apiKey 空也允许）
        if agentMode == .hermes && apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = L("vm.error.hermesNeedsURL")
            showSettings = true
            return
        }
        // 在线 AI 模式：必须有 API Key + baseURL（任意一项空都跑不通）
        if agentMode == .directAPI && (directAPIKey.isEmpty || directAPIBaseURL.isEmpty) {
            errorMessage = L("vm.error.directNeedsKey")
            showSettings = true
            return
        }

        // 任意模式下断开都先尝试重连
        if case .disconnected(let reason) = connectionStatus {
            errorMessage = L("vm.error.disconnectedRetry", reason)
            checkConnection()
            return
        }

        // B 阶段：用户说了新内容 → 标记记忆"待更新"，等用户空闲时后台静悄悄刷新一次
        memoryDirty = true

        // 把当前 pending 图片 / 文档随消息一起发出去，发完清空
        let attachedImages = pendingImages
        pendingImages = []
        let attachedDocPaths = pendingDocuments.map { $0.path }
        pendingDocuments = []

        // **关键**：在线 AI + 拖图 → 立刻通知云朵戴眼镜。
        // 必须在下面的 `isStreaming = true` + broadcastBackgroundStreamingCount() 之前 post，
        // 否则 ClawdWalkOverlayController 收到 streaming 通知会先把云朵收回灵动岛，
        // 等 OpenCodeHTTPClient.runStream 那边异步触发 wear glasses 时云朵已经不在桌面了
        if agentMode == .directAPI && !attachedImages.isEmpty {
            NotificationCenter.default.post(
                name: .init("HermesPetCloudPetWearGlasses"),
                object: nil,
                userInfo: ["duration": 6.0]
            )
            NotificationCenter.default.post(
                name: .init("HermesPetClawdBubble"),
                object: nil,
                userInfo: ["text": L("vm.banner.cloudWearGlasses"), "duration": 2.5]
            )
        }

        inputText = ""
        errorMessage = nil

        // 发送音 —— 所有 guard 通过、清空输入之后才响，避免被拒/连接断开时也响
        SoundManager.play(.send)

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
            userText = L("chat.placeholder.image")
        } else {
            // 只拖了文档没写字 —— 让 AI 自己看附件
            userText = L("chat.placeholder.document")
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

        // 记 token 用量（用户输入侧）—— 沉淀给以后"宠物成长"联动用，当前不展示
        UsageLedger.record(TokenEstimator.estimateTokens(userText))

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

        // 长对话压缩（C）：有早期摘要就发"摘要 + 近况"，否则回退原粗暴裁剪。短对话零影响。
        apiMessages = compactHistory(apiMessages, conversationID: targetConversationID)

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
                msg.content = L("vm.banner.queued", ahead)
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
                          images: [Data] = [],
                          modeOverride: AgentMode? = nil,
                          recordToActivity: Bool = true,
                          injectMemory: Bool = true,
                          sessionTag: String = "quick-ask",
                          workingDirectory: String? = nil,   // claudeCode 真透传 cwd + --add-dir（工作台指挥/上学）
                          onUsage: (@Sendable (Int) -> Void)? = nil,
                          onActivity: (@Sendable (String) -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
        let mode = modeOverride ?? agentMode
        if recordToActivity {
            // QuickAsk 也是用户问 AI —— 同样写入 ActivityStore 给早报用
            ActivityRecorder.shared.queryStore.insertUserQuestion(
                conversationID: sessionTag,
                mode: mode.rawValue,
                content: prompt,
                hasImages: !images.isEmpty,
                hasDocuments: false
            )
        }
        let oneShot = ChatMessage(role: .user, content: prompt, images: images)
        let messages = [oneShot]
        switch mode {
        case .hermes:     return apiClient.streamCompletion(messages: messages, injectMemory: injectMemory, onUsage: onUsage)
        case .directAPI:
            // 在线 AI 走 bundled opencode agent runtime（v1.2.0+）。
            // quick-ask 没有真实 conversationID，用固定 "quick-ask" 让 opencode 端
            // 复用同一个 session 不重复创建（多次 quick-ask 也有上下文延续）
            return OpenCodeHTTPClient.shared.streamCompletion(
                messages: messages,
                conversationID: sessionTag,
                injectMemory: injectMemory,
                directory: workingDirectory,
                onUsage: onUsage
            )
        case .openclaw:
            // OC4: 走 openClawClient，APIClient 内部按 .openclaw source 分流 baseURL/token
            return openClawClient.streamCompletion(messages: messages, injectMemory: injectMemory, onUsage: onUsage)
        case .claudeCode: return claudeClient.streamCompletion(messages: messages, injectMemory: injectMemory, extraWorkingDir: workingDirectory, onUsage: onUsage, onActivity: onActivity)
        case .codex:      return codexClient.streamCompletion(messages: messages, injectMemory: injectMemory, onUsage: onUsage)
        case .qwenCode:   return qwenClient.streamCompletion(messages: messages, injectMemory: injectMemory, onUsage: onUsage)
        }
    }

    /// 语音陪聊把一轮对话（用户说的 + AI 回的）追加进**当前激活对话**的聊天记录。
    ///
    /// ⭐ 铁律（见 memory `[[voice-chat-talking-face-subsystem]]` 的血泪教训）：**绝不卡说话链路**。
    /// 调用方（`VoiceChatController.think`）必须在 `speak()` 已经开口**之后**才调本方法；
    /// 这里只做两件事：① 主线程追加 2 条消息（轻量）；② 写盘（重操作：encode 整个对话数组 + 原子写）
    /// 拍快照甩 `Task.detached(.utility)` 后台，**绝不同步 `saveConversations`**（首版同步写卡在
    /// 想完→说话之间，AI 半天不开口、要按空格，已踩过坑）。
    func appendVoiceChatTurn(userText: String, assistantText: String) {
        let u = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty || !a.isEmpty else { return }
        guard let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        if !u.isEmpty { conversations[idx].messages.append(ChatMessage(role: .user, content: u)) }
        if !a.isEmpty { conversations[idx].messages.append(ChatMessage(role: .assistant, content: a)) }
        conversations[idx].updatedAt = Date()
        let snapshot = conversations   // 值类型快照，后台写安全（Conversation 单模块自动 Sendable）
        Task.detached(priority: .utility) {
            StorageManager.shared.saveConversations(snapshot)
        }
    }

    /// 新用户引导完成 / 跳过：落标记 + 收起引导层 + 若用户在引导里勾了意图感知就立刻启动采集。
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        showOnboarding = false
        // start() 自带 isEnabled 守卫，没勾就 no-op；勾了就立刻开始采集（不用等下次启动）
        UserIntentRecorder.shared.start(viewModel: self, store: ActivityRecorder.shared.queryStore)
    }

    /// 早报：把生成好的 markdown 早报塞进一个新对话，自动切过去 + 打开 chat 窗口。
    /// 如果对话已满 (kMaxConversations)，挤掉**最旧的非 streaming** 对话（避免打断在跑的任务）。
    func createBriefingConversation(content: String, title: String? = nil, seedUserText: String? = nil) {
        let dateStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let convTitle = title ?? L("vm.title.briefing", dateStr)
        let seed = seedUserText ?? "请给我一份今日早报"   // 发给 AI 的 prompt，保持中文（Phase 5-3 处理）
        let newConv = Conversation(
            title: convTitle,
            messages: [
                ChatMessage(role: .user, content: seed),
                ChatMessage(role: .assistant, content: content)
            ],
            mode: morningBriefingBackend
        )
        // 已达上限：挤掉最旧的非 streaming 对话；如果全都在 streaming 就跳过早报，避免覆盖用户工作
        if conversations.count >= kMaxConversations {
            if let oldestIdx = conversations.indices.reversed().first(where: { !conversations[$0].isStreaming }) {
                conversations.remove(at: oldestIdx)
            } else {
                errorMessage = L("vm.error.briefingAllBusy")
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
            errorMessage = L("vm.error.convFullTransfer", kMaxConversations)
            return
        }
        let safeTitle = pin.title.isEmpty ? "Pin" : String(pin.title.prefix(20))
        let newConv = Conversation(
            title: safeTitle,
            messages: [
                // 发给 AI 的 prompt 片段，保持中文（Phase 5-3 处理）
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
            errorMessage = L("vm.error.convFullTransfer", kMaxConversations)
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

        // 真实 token 用量回调 —— 闭包捕获本次请求的 targetConversationID（每次各自捕获，无并发串味），
        // 流结束拿到 prompt_tokens 后 hop 回 MainActor 记到对应对话。
        let onUsage: @Sendable (Int) -> Void = { [weak self] tokens in
            Task { @MainActor in self?.recordContextTokens(tokens, for: targetConversationID) }
        }
        // 子进程后端回报真实模型 id（Claude Code）→ 记下来给窗口查询用
        let onModel: @Sendable (String) -> Void = { [weak self] model in
            Task { @MainActor in self?.recordModelID(model, for: targetConversationID) }
        }
        // Token 计费记账：client 在后台把真实用量明细（输入/输出/缓存）塞进 box，
        // 流结束后（同一个 Task、MainActor 上）取出记一笔。纯锁交接、无执行器断言（守决策 #5/#22）。
        let usageBox = TokenUsageBox()
        let onUsageDetail: @Sendable (TokenUsageBreakdown) -> Void = { bd in usageBox.set(bd) }

        let task = Task {
            var didSucceed = false
            do {
                let stream: AsyncThrowingStream<String, Error>
                switch mode {
                case .hermes:
                    stream = apiClient.streamCompletion(messages: apiMessages, onUsage: onUsage, onUsageDetail: onUsageDetail, onModel: onModel)
                case .openclaw:
                    // OC4: 走 openClawClient，APIClient 内部按 .openclaw source 分流 baseURL/token
                    stream = openClawClient.streamCompletion(messages: apiMessages, onUsage: onUsage, onUsageDetail: onUsageDetail, onModel: onModel)
                case .directAPI:
                    // 在线 AI 走 bundled opencode agent runtime（v1.2.0+）：能读写文件、跑命令、联网。
                    // 每个对话独立 directory + sessionID，由 OpenCodeClient 内部管理。
                    // 用户没配 API key 时默认用 opencode 内置 free 模型（deepseek-v4-flash-free）。
                    //
                    // **DeepSeek reasoning_content 已知不稳定**：opencode v1.15.1 偶尔识别不到
                    // DeepSeek V4 stream 末尾的 content 字段（前置 reasoning chain 长，opencode
                    // 在 reasoning 阶段就 disconnect）。上游 PR #25110 修复中，HermesPet 暂不在
                    // 路由层 fallback —— 保留 agent 能力（读文件/跑命令）优先，少数对话偶尔
                    // 空响应让用户重试或换 prompt 解决
                    stream = OpenCodeHTTPClient.shared.streamCompletion(
                        messages: apiMessages,
                        conversationID: targetConversationID,
                        onUsage: onUsage,
                        onUsageDetail: onUsageDetail
                    )
                case .claudeCode:
                    // 把完整对话历史（含跟其他 AI 的对话）传给 Claude，
                    // 实现跨 AI 共享记忆
                    stream = claudeClient.streamCompletion(messages: apiMessages, onUsage: onUsage, onModel: onModel, onUsageDetail: onUsageDetail)
                case .codex:
                    stream = codexClient.streamCompletion(
                        messages: apiMessages,
                        conversationID: targetConversationID,
                        onUsage: onUsage
                    )
                case .qwenCode:
                    // QwenCode 直连 DashScope（OpenAI 兼容），跟 Hermes / OpenClaw 同款走 APIClient
                    stream = qwenClient.streamCompletion(messages: apiMessages, onUsage: onUsage)
                }

                var fullContent = ""
                var lastUpdate = Date.distantPast
                // 流式刷新节流：32ms 一次（约 30fps）。
                // 之前 80ms 是 12fps，刷新跳变肉眼可见"卡一下"；改 32ms 后接近行级连续流动，
                // 跟 macOS 系统动效一致（60fps 是上限，30fps 是流畅基线）。
                // 渲染成本：MarkdownTextView.parseBlocks 与 InlineMarkdownView 的 AttributedString
                // 都已按"内容字符串"做缓存（见 MarkdownRenderer），完成消息重渲染零重解析；
                // 流式中间态会命中失败但被 NSCache countLimit 自动淘汰，不会无限涨内存。
                let throttle: TimeInterval = 0.032

                for try await delta in stream {
                    try Task.checkCancellation()
                    fullContent += delta
                    let visibleContent = Self.sanitizeAssistantVisibleContent(fullContent)
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) >= throttle {
                        self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                            msg.content = visibleContent
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
                let visibleContent = Self.sanitizeAssistantVisibleContent(fullContent)
                self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                    msg.content = visibleContent.isEmpty ? L("vm.msg.noResponse") : visibleContent
                    msg.isStreaming = false
                    if !generatedImages.isEmpty {
                        msg.images = generatedImages
                        msg.imagePaths = imagePaths
                    }
                }
                didSucceed = !visibleContent.isEmpty || !generatedImages.isEmpty

                // 记 token 用量（助手输出侧）—— 同上，沉淀给以后宠物成长用
                UsageLedger.record(TokenEstimator.estimateTokens(visibleContent))

                // Token 计费记账：按 后端 + 模型 记一笔实付 / 省钱（给灵动岛「Token 消耗」卡片）。
                let usageModel: String
                switch mode {
                case .hermes:     usageModel = self.modelIDByConversation[targetConversationID] ?? self.modelName
                case .directAPI:  usageModel = self.directAPIModel.isEmpty ? "deepseek" : self.directAPIModel
                case .openclaw:   usageModel = self.modelIDByConversation[targetConversationID] ?? "openclaw"
                case .claudeCode: usageModel = self.modelIDByConversation[targetConversationID] ?? "claude"
                case .codex:      usageModel = self.modelIDByConversation[targetConversationID] ?? "codex"
                case .qwenCode:   usageModel = self.modelIDByConversation[targetConversationID] ?? (self.qwenModel.isEmpty ? "qwen" : self.qwenModel)
                }
                if let detail = usageBox.take() {
                    TokenUsageStore.shared.record(mode: mode, model: usageModel, breakdown: detail)
                } else if didSucceed {
                    // 没拿到真实明细（Codex / 通义 等子进程后端）→ 输入用真实上下文 token 兜底、输出用估算。
                    let inTok = self.contextTokensByConversation[targetConversationID]
                        ?? TokenEstimator.estimateMessagesTokens(self.messages.map { $0.content })
                    let outTok = TokenEstimator.estimateTokens(visibleContent)
                    TokenUsageStore.shared.record(
                        mode: mode, model: usageModel,
                        breakdown: TokenUsageBreakdown(input: inTok, output: outTok))
                }

                // 灵动岛下方选项菜单 ChoiceMenuOverlay 已废弃 —— 跟聊天窗内 ChoiceCard 信息重复，
                // 用户决定只保留聊天窗里的 ChoiceCard。不再 post HermesPetChoiceListReady。
                // ChoiceMenuOverlay 渲染代码暂保留作 dead code，没人 trigger 永不弹出。
            } catch is CancellationError {
                self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                    msg.isStreaming = false
                    if msg.content.isEmpty {
                        msg.content = L("vm.msg.cancelled")
                    } else {
                        msg.content += L("vm.msg.cancelledInline")
                    }
                }
            } catch {
                let friendly = self.friendlyError(error)
                self.updateMessage(conversationID: targetConversationID, messageID: assistantMessageID) { msg in
                    msg.isStreaming = false
                    msg.content = L("vm.msg.errorPrefix", friendly)
                }
                self.errorMessage = friendly
                // directAPI 模式 + 撞错 → 云朵冒一句可操作 hint，让用户知道接下来怎么办
                if mode == .directAPI {
                    let petHint = Self.petHintForError(friendly)
                    NotificationCenter.default.post(
                        name: .init("HermesPetClawdBubble"),
                        object: nil,
                        userInfo: ["text": petHint, "duration": 2.8]
                    )
                }
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
            // 通知灵动岛右耳：成功 → 播放对勾动画；失败/取消 → 静默回 idle
            NotificationCenter.default.post(
                name: .init("HermesPetTaskFinished"),
                object: nil,
                userInfo: ["success": didSucceed]
            )
            // 任务成功 + 聊天窗关着 → 触发"AI 回复摘要"卡片（v1.2.7-dev）
            // 解决 ⌘⇧V 语音 / ⌘⇧Space quickAsk 这类场景"看不到回复"的痛点
            if didSucceed,
               ChatWindowController.shared?.isVisible != true,
               let idx = self.conversations.firstIndex(where: { $0.id == targetConversationID }),
               let lastAssistant = self.conversations[idx].messages.last(where: { $0.role == .assistant }),
               !lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !lastAssistant.content.hasPrefix("❌") {
                NotificationCenter.default.post(
                    name: .init("HermesPetResponseReady"),
                    object: nil,
                    userInfo: [
                        "content": lastAssistant.content,
                        "conversationID": targetConversationID,
                        "modeRaw": mode.rawValue
                    ]
                )
            }
            // 任务成功完成 → 给个轻触觉提示（不打扰，只是"做完了"的回执感）
            if didSucceed {
                Haptic.tap(.alignment)
                // C：长对话且新增够多 → 后台更新早期摘要，下次发送就能用上
                self.regenerateSummaryIfNeeded(conversationID: targetConversationID, mode: mode)
            }
            self.broadcastBackgroundStreamingCount()
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
        // 默认 title 的两种形态：旧版 "对话 N" / 新版 "新对话"（v1.2.x 之后默认改名了）
        // 之前只判 "对话 " 前缀导致新对话 title 永远不会被首条消息覆盖，这里补上 "新对话"
        // "对话 " 是旧版默认前缀（持久化数据里仍可能是中文）；"新对话" / "New chat" 覆盖中英两版默认标题，
        // 防止用户切语言后老标题不再被识别为"默认"
        let isDefaultTitle = current.hasPrefix("对话 ") || current == "新对话" || current == "New chat" || current == L("vm.title.new")
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
                msg.content = L("vm.msg.cancelled")
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

    /// 模型返回里的 `<think>...</think>` 是推理草稿，不应该进聊天气泡。
    /// 同时处理流式中尚未闭合的 `<think>`，避免先闪出思考过程再被最终答案替换。
    static func sanitizeAssistantVisibleContent(_ content: String) -> String {
        guard content.range(of: "<think", options: [.caseInsensitive]) != nil else {
            return content
        }
        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let withoutCompleteBlocks = completeThinkBlockRegex.stringByReplacingMatches(
            in: content,
            range: fullRange,
            withTemplate: ""
        )
        let trailingRange = NSRange(
            withoutCompleteBlocks.startIndex..<withoutCompleteBlocks.endIndex,
            in: withoutCompleteBlocks
        )
        return trailingThinkBlockRegex
            .stringByReplacingMatches(in: withoutCompleteBlocks, range: trailingRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            // 用 system 注释提示 AI 历史被裁剪。content 是 var，可以 mutate。
            // 这是发给 AI 的 prompt 片段（不是 UI 文案），保持中文（Phase 5-3 处理）
            result[0].content = "[系统注：本对话有 \(omitted) 条早期消息已省略以加速响应。如需了解早期内容请直接问用户。]\n\n" + result[0].content
        }

        return result
    }

    // MARK: - 长对话压缩（C）

    /// 触发摘要的对话长度（filtered user/assistant 计）
    static let summaryTriggerCount = 24
    /// 摘要后保留多少条最近原文（其余折进摘要）
    static let summaryKeepTail = 8
    /// 距上次摘要至少新增这么多条才重新摘要（避免每轮都调一次 AI）
    static let summaryRefreshGap = 12

    /// 发送前压缩历史：有早期摘要 → 发「摘要 + 近况原文」；否则回退 `trimHistoryForAPI`。
    /// 摘要以单行前缀塞进第一条保留消息（适配所有 mode——Claude 的 buildPrompt 只认 user/assistant，
    /// 不能用独立 system 消息）。
    private func compactHistory(_ msgs: [ChatMessage], conversationID: String) -> [ChatMessage] {
        guard let conv = conversations.first(where: { $0.id == conversationID }),
              let summary = conv.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              conv.summarizedCount > 0,
              conv.summarizedCount < msgs.count
        else {
            return Self.trimHistoryForAPI(msgs)   // 没摘要 → 原裁剪兜底
        }
        var tail = Array(msgs.dropFirst(conv.summarizedCount))
        // 极端情况：摘要没跟上、tail 仍很长 → 对 tail 再粗裁一刀
        if tail.count > 20 { tail = Self.trimHistoryForAPI(tail) }
        guard !tail.isEmpty else { return Self.trimHistoryForAPI(msgs) }
        tail[0].content = "[早期对话摘要（前 \(conv.summarizedCount) 条消息的要点，供你接上下文）]\n\(summary)\n\n" + tail[0].content
        return tail
    }

    /// 一轮成功后调用：长对话且新增够多时，后台静悄悄把早期消息折成 / 更新摘要（失败静默）。
    /// 仅"每轮重发整段历史"的模式需要；directAPI / codex 服务端自管上下文，跳过。
    func regenerateSummaryIfNeeded(conversationID: String, mode: AgentMode) {
        guard mode == .hermes || mode == .openclaw || mode == .claudeCode else { return }
        guard let conv = conversations.first(where: { $0.id == conversationID }) else { return }
        let history = conv.messages.filter { $0.role == .user || $0.role == .assistant }
        guard history.count > Self.summaryTriggerCount else { return }
        let prevCount = max(0, min(conv.summarizedCount, history.count))
        let foldTo = history.count - Self.summaryKeepTail
        guard foldTo - prevCount >= Self.summaryRefreshGap else { return }   // 新增不够多，先不刷
        guard prevCount < foldTo else { return }                            // 下界保护：summarizedCount 被外部翻位也不越界
        let newMessages = Array(history[prevCount..<foldTo])
        let prevSummary = conv.summary

        Task { @MainActor [weak self] in
            guard let self else { return }
            let prompt = Self.buildSummaryPrompt(previous: prevSummary, newMessages: newMessages)
            var result = ""
            do {
                // 静默后台维护固定走「在线 AI」保底（零依赖、永远可用），不赌用户配了 OpenClaw / 重型 CLI
                for try await chunk in self.streamOneShotAsk(
                    prompt: prompt,
                    modeOverride: .directAPI,
                    recordToActivity: false
                ) {
                    result += chunk
                }
            } catch {
                return   // 静默，下轮再试
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let idx = self.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            self.conversations[idx].summary = String(trimmed.prefix(2000))
            self.conversations[idx].summarizedCount = foldTo
            self.storage.saveConversations(self.conversations)
            NSLog("[Summary] 对话 \(conversationID.prefix(8)) 摘要已更新（覆盖前 \(foldTo) 条，\(trimmed.count) 字）")
        }
    }

    private static func buildSummaryPrompt(previous: String?, newMessages: [ChatMessage]) -> String {
        var lines: [String] = []
        lines.append("# 任务")
        lines.append("把下面这段对话压缩成一份简明摘要，供 AI 之后接着这个对话时快速了解前情。")
        if let prev = previous?.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            lines.append("")
            lines.append("# 已有摘要（更早的内容，请合并进新摘要）")
            lines.append(prev)
        }
        lines.append("")
        lines.append("# 需要纳入摘要的对话")
        for m in newMessages {
            let who = m.role == .user ? "用户" : "助手"
            let c = m.content.prefix(800).replacingOccurrences(of: "\n", with: " ")
            lines.append("【\(who)】\(c)")
        }
        lines.append("")
        lines.append("# 要求")
        lines.append("- 输出**完整的、合并后的摘要全文**（含已有摘要要点 + 新内容），我会直接保存。")
        lines.append("- 抓住：用户的目标 / 关键事实与结论 / 待办或未决问题 / 重要的具体名称（文件、函数、数字等）。")
        lines.append("- 简明扼要、分条写，**控制在 600 字以内**。")
        lines.append("- \(LocaleManager.aiReplyLanguageInstruction())")
        lines.append("- 直接输出摘要，不要任何开场白或解释。")
        return lines.joined(separator: "\n")
    }

    /// 在线 AI 撞错时云朵气泡说什么 —— 按错误关键词分类给可操作的 hint。
    /// 用云朵的"飘逸"语气，告诉用户下一步该做啥（不是冷冰冰报错）
    static func petHintForError(_ msg: String) -> String {
        // 关键词匹配同时覆盖中英两语的 friendlyError 输出（matching logic，非显示文案，不翻译）
        let m = msg.lowercased()
        if m.contains("deepseek") && (m.contains("图片") || m.contains("vision") || m.contains("image")) {
            return L("vm.petHint.deepseekNoVision")
        }
        if m.contains("api key") || m.contains("配置") || m.contains("apikey") || m.contains("settings") {
            return L("vm.petHint.needKey")
        }
        if m.contains("还在启动") || m.contains("serverready") || m.contains("server") && m.contains("ready") || m.contains("startup") {
            return L("vm.petHint.serverStarting")
        }
        if m.contains("超时") || m.contains("timeout") || m.contains("timed out") {
            return L("vm.petHint.timeout")
        }
        if m.contains("401") || m.contains("403") || m.contains("权限") || m.contains("denied") {
            return L("vm.petHint.keyWrong")
        }
        if m.contains("没产出正文") || m.contains("没有响应") || m.contains("no response") || m.contains("no reply") {
            return L("vm.petHint.noContent")
        }
        if m.contains("断") || m.contains("network") || m.contains("offline") {
            return L("vm.petHint.network")
        }
        // 兜底
        return L("vm.petHint.generic")
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
                return L("vm.fe.invalidResponse")
            case .httpError(let code, let body):
                switch code {
                case 401: return L("vm.fe.http401", snippet(body))
                case 403: return L("vm.fe.http403", snippet(body))
                case 404: return L("vm.fe.http404", snippet(body))
                case 429: return L("vm.fe.http429", snippet(body))
                case 500...599: return L("vm.fe.http5xx", code, snippet(body))
                case 0:
                    // ClaudeCodeClient / CodexClient 的特殊错误码 → body 本身就是错误描述
                    return body.isEmpty ? L("vm.fe.cliProcess") : body
                default:
                    return L("vm.fe.httpOther", code, snippet(body))
                }
            case .decodingError(let msg):
                return L("vm.fe.decoding", snippet(msg))
            case .cancelled:
                return L("vm.fe.cancelled")
            case .emptyResponse:
                return L("vm.fe.empty")
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .networkConnectionLost:
                return agentMode == .hermes
                    ? L("vm.fe.cannotConnectHermes")
                    : L("vm.fe.cannotConnect")
            case .notConnectedToInternet:
                return L("vm.fe.offline")
            case .timedOut:
                return L("vm.fe.timeout")
            case .cancelled:
                return L("vm.fe.cancelled")
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
            errorMessage = L("vm.error.launchAtLoginFailed", error.localizedDescription)
            // 操作失败 —— 同步回 SMAppService 的真实状态，避免 toggle 显示与系统不一致
            isLaunchAtLoginOn = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Actions

    func clearChat() {
        // 清空前先删掉这对话历史里所有图片文件，避免磁盘遗留
        let allPaths = messages.flatMap { $0.imagePaths }
        if !allPaths.isEmpty { storage.deleteImageFiles(allPaths) }
        // 清空 = 抹掉这段内容 —— 同时删掉永久历史库里这条旧存档，
        // 否则历史面板会残留一条指向"已删图片"的幽灵记录
        ConversationHistoryStore.shared.delete(id: activeConversationID)

        // 只清空当前激活对话的消息（不删除对话本身、不影响别的对话）
        messages = [
            ChatMessage(
                role: .assistant,
                content: L("vm.greeting.cleared")
            )
        ]
        // 标题也重置回默认（让下次发消息时能再次 auto-title）+ 清掉长对话摘要（内容已抹）
        if let idx = conversations.firstIndex(where: { $0.id == activeConversationID }) {
            conversations[idx].title = L("vm.title.new")
            conversations[idx].summary = nil
            conversations[idx].summarizedCount = 0
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
        var resolved = mode ?? lastUsedMode
        // M4: 守护切到 disabled mode —— 回退到 .directAPI（永远在 enabled 集合里）+ 提示用户去设置开启
        if !EnabledModesStore.shared.isEnabled(resolved) {
            errorMessage = L("vm.error.modeDisabledFellBack", L(resolved.labelKey))
            resolved = .directAPI
        }
        let conv = Conversation(
            title: L("vm.title.new"),
            messages: [ChatMessage(
                role: .assistant,
                content: Self.welcomeMessageContent(for: resolved)
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
                    "text": L("vm.banner.stillStreaming", leaving.title),
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
    }

    /// 每条对话「这次流式从何时开始」的时间戳。懒维护：在 broadcast 时按当前 isStreaming
    /// 集合增删，不必去 hook 每一处 isStreaming 变更。供活动轨道小胶囊显示「已运行时长」。
    private var streamStartTimes: [String: Date] = [:]

    /// 后台（即不是当前激活）流式中的对话数量。灵动岛右耳显示这个角标。
    /// 同时附带每条后台对话的 (id / mode / title / startedAt)，供第三形态「迷你胶囊」的任务胶囊渲染
    /// （`MiniIslandController` 消费 activities；老消费者只读 count，互不影响）。
    private func broadcastBackgroundStreamingCount() {
        // 维护流式起始时间表：新开始流式的记 now，已结束的清掉
        let streamingIDs = Set(conversations.filter { $0.isStreaming }.map { $0.id })
        for id in streamingIDs where streamStartTimes[id] == nil {
            streamStartTimes[id] = Date()
        }
        for id in Array(streamStartTimes.keys) where !streamingIDs.contains(id) {
            streamStartTimes.removeValue(forKey: id)
        }

        let bg = conversations.filter { $0.isStreaming && $0.id != activeConversationID }
        let activities: [[String: String]] = bg.map { conv in
            var d: [String: String] = [
                "id": conv.id,
                "mode": conv.mode.rawValue,
                "title": conv.title
            ]
            if let t = streamStartTimes[conv.id] {
                d["startedAt"] = String(t.timeIntervalSinceReferenceDate)
            }
            return d
        }
        NotificationCenter.default.post(
            name: .init("HermesPetBackgroundStreamingChanged"),
            object: nil,
            userInfo: ["count": bg.count, "activities": activities]
        )
    }

    /// v1.3 起在线 AI 走 opencode serve HTTP API，server 启动时一次性加载 provider 配置。
    /// 用户在设置改 API Key / 切服务商 → 防抖 800ms 后重启 server 让新配置生效。
    /// 防抖原因：directAPIKey 是 TextField 绑定，每打一个字符 didSet 都会触发；
    /// 800ms 内连续修改只会重启一次
    private var openCodeReloadTask: Task<Void, Never>?
    private func scheduleOpenCodeConfigReload() {
        openCodeReloadTask?.cancel()
        openCodeReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            // 先清掉内存里所有 sessionID 映射，再 terminate 旧 server：
            // 否则重启窗口内一条在途 directAPI 流可能复用指向已死 session 的 stale id → 404（顺序很关键）
            OpenCodeHTTPClient.shared.clearAllSessions()
            await OpenCodeServerManager.shared.restartForConfigChange()
            _ = self
        }
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
        // 注：关闭 = 从工作集移除（收进历史库），**不再删图片** ——
        // 对话已完整存档在 history.sqlite，之后能从历史面板重新打开（含图片）。
        // 真正的"永久删除 + 清图"由 deleteFromHistory（历史面板删除按钮）负责。
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

    // MARK: - 历史库（永久存档：重开 / 删除）

    /// 从永久历史库重新打开一个对话（历史面板点击一条时调）。
    /// - 已在工作集里 → 直接切过去；
    /// - 不在 → 从 history.sqlite 捞完整对话插回工作集顶部
    ///   （工作集满 kMaxConversations 个就挤掉最旧的非 streaming —— 它已在历史库，安全丢弃）。
    func openFromHistory(id: String) {
        // 阶段1·记回访：进了这个函数 = 用户主动调取这条历史对话（不管已开着还是从库捞回），算一次回访
        ConversationHistoryStore.shared.recordOpen(id: id)
        if conversations.contains(where: { $0.id == id }) {
            if id != activeConversationID { switchConversation(to: id) }
            NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
            return
        }
        guard var restored = ConversationHistoryStore.shared.load(id: id) else {
            errorMessage = L("history.open.failed")
            return
        }
        restored.isStreaming = false
        if conversations.count >= kMaxConversations {
            guard let oldestIdx = conversations.indices.reversed().first(where: { !conversations[$0].isStreaming }) else {
                errorMessage = L("vm.error.convFullTransfer", kMaxConversations)
                return
            }
            conversations.remove(at: oldestIdx)
        }
        conversations.insert(restored, at: 0)
        activeConversationID = restored.id
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        errorMessage = nil
        if lastUsedMode != restored.mode { lastUsedMode = restored.mode }
        UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
        storage.saveConversations(conversations)
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": restored.mode.rawValue]
        )
        checkConnection()
        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
    }

    /// 从永久历史库彻底删除一个对话（历史面板的删除按钮）。
    /// 同时删掉它的图片文件 + 工作集里还开着的副本。
    func deleteFromHistory(id: String) {
        // 还开在工作集里？
        if conversations.contains(where: { $0.id == id }) {
            if conversations.count <= 1 {
                // 唯一对话 → 清空它（clearChat 会删图 + 删历史行 + 重置成空白）
                if id == activeConversationID { clearChat() }
                return
            }
            closeConversation(id: id)   // 从工作集移除（已不删图、mirror 不会回填）
        }
        // 删图片文件（从历史库捞完整对话拿 imagePaths）
        if let conv = ConversationHistoryStore.shared.load(id: id) {
            let paths = conv.messages.flatMap { $0.imagePaths }
            if !paths.isEmpty { storage.deleteImageFiles(paths) }
        }
        ConversationHistoryStore.shared.delete(id: id)
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
                userInfo: ["text": L("vm.banner.voice.notHeard"), "count": 0]
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
    /// 把任务派给一个新对话执行。`mode` 是用户在任务卡下拉菜单里选的 AI
    /// （不再固定用 AI 建议的 `task.suggestedMode`）。
    func dispatchTaskToNewConversation(_ task: PlannedTask, mode: AgentMode) {
        guard conversations.count < kMaxConversations else {
            errorMessage = L("vm.error.convFullDispatch", kMaxConversations)
            return
        }
        // 用任务标题截 12 字作对话标题（让顶部胶囊一眼能区分）
        let convTitle = String(task.title.prefix(12))
        let conv = Conversation(
            title: convTitle,
            messages: [],
            mode: mode
        )
        conversations.append(conv)
        activeConversationID = conv.id
        if lastUsedMode != mode { lastUsedMode = mode }
        pendingImages.removeAll()
        pendingDocuments.removeAll()
        errorMessage = nil
        UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
        storage.saveConversations(conversations)
        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": mode.rawValue]
        )
        checkConnection()

        // 把任务描述拼成首条消息发送
        let prompt: String
        if task.desc.isEmpty {
            prompt = task.title
        } else {
            // 发给 AI 的 prompt 片段，保持中文（Phase 5-3 处理）
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
            case .hermes:     candidates = [.directAPI, .qwenCode, .openclaw, .claudeCode, .codex, .hermes]
            case .directAPI:  candidates = [.qwenCode, .openclaw, .claudeCode, .codex, .hermes, .directAPI]
            case .qwenCode:   candidates = [.openclaw, .claudeCode, .codex, .hermes, .directAPI]
            case .openclaw:   candidates = [.claudeCode, .codex, .hermes, .directAPI, .qwenCode, .openclaw]
            case .claudeCode: candidates = [.codex, .hermes, .directAPI, .qwenCode, .openclaw]
            case .codex:      candidates = [.hermes, .directAPI, .qwenCode, .openclaw]
            }
            // M4: 过滤掉用户在设置里未启用的 mode；候选只在 enabled 集合内找下一档
            let enabledSet = EnabledModesStore.shared.enabledModes
            for next in candidates where enabledSet.contains(next) {
                if await isModeUsable(next) {
                    agentMode = next
                    Haptic.tap(.alignment)
                    return
                }
            }
            // 一圈下来没找到能用的（理论上 .directAPI 永远在 enabled 里）—— 兜底保持原状
            Haptic.tap(.alignment)
        }
    }

    /// 显式跳到某个 mode（顶部头部分段控件用）。CLI 缺失会 toast + 拒绝。
    /// M4: 也会先检 EnabledModesStore，disabled mode 直接 toast 拒绝（理论上 UI 已经过滤了，
    /// 但作为防御兜底防止其他通知触发 disabled mode 的切换）
    func setAgentMode(_ mode: AgentMode) {
        Task { @MainActor in
            // 先检 enabled，再检 CLI 可用性
            guard EnabledModesStore.shared.isEnabled(mode) else {
                errorMessage = L("vm.error.modeDisabled", L(mode.labelKey))
                return
            }
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
        case .hermes, .directAPI, .openclaw:
            return true
        case .claudeCode:
            if await CLIAvailability.claudeAvailable() { return true }
            errorMessage = L("vm.error.claudeMissing")
            return false
        case .codex:
            if await CLIAvailability.codexAvailable() { return true }
            errorMessage = L("vm.error.codexMissing")
            return false
        case .qwenCode:
            if await CLIAvailability.qwenAvailable() { return true }
            errorMessage = L("vm.error.qwenMissing")
            return false
        }
    }

    // MARK: - 画布（Canvas）

    /// 识别用户输入是否在请求新建画布。匹配三种触发词：
    /// `画布：xxx` / `/canvas xxx` / `canvas: xxx`。返回主题字符串（去前缀 + trim）
    private func matchCanvasKeyword(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = ["画布:", "画布:", "画布:", "/canvas ", "canvas:", "Canvas:"]
        // 中文冒号 / 英文冒号都接受
        let normalized = trimmed.replacingOccurrences(of: "：", with: ":")
        for prefix in ["画布:", "/canvas ", "canvas:", "Canvas:"] {
            if normalized.hasPrefix(prefix) {
                let topic = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !topic.isEmpty { return topic }
            }
        }
        _ = triggers   // 保留变量避免编译警告（实际匹配用 normalized prefix）
        return nil
    }

    /// 创建一个新画布对话 —— 类似 newConversation，但 kind=.canvas 并立刻启动规划。
    /// - referenceImageURLs：用户上传的产品参考图（彻底解决品牌还原问题）
    @discardableResult
    func createCanvasConversation(template: CanvasTemplate,
                                  topic: String,
                                  referenceImageURLs: [URL] = []) -> Bool {
        guard conversations.count < kMaxConversations else {
            errorMessage = L("vm.error.convFullCanvas", kMaxConversations)
            return false
        }
        // 在线 AI 没配置 → 画布生成会失败，先提示
        if directAPIKey.isEmpty || directAPIBaseURL.isEmpty {
            errorMessage = L("vm.error.canvasNeedsKey")
            showSettings = true
            return false
        }
        // 把用户传的参考图复制一份到 ~/.hermespet/images/ 永久保存
        // 避免用户原文件移动 / 删除导致后续重生引用失败
        let canvasID = UUID().uuidString
        var savedRefPaths: [String] = []
        for (idx, url) in referenceImageURLs.enumerated() {
            if let data = try? Data(contentsOf: url) {
                let paths = storage.persistImages([data], forMessage: "\(canvasID)-ref\(idx)")
                if let p = paths.first { savedRefPaths.append(p) }
            }
        }
        let board = CanvasBoard(
            id: canvasID,
            topic: topic,
            templateID: template.id,
            referenceImagePaths: savedRefPaths,
            elements: []
        )
        let conv = Conversation(
            title: "📐 " + (topic.count > 12 ? String(topic.prefix(12)) + "…" : topic),
            messages: [],
            mode: .directAPI,         // 画布固定走在线 AI 做规划
            kind: .canvas,
            canvas: board,
            isStreaming: true
        )
        conversations.append(conv)
        activeConversationID = conv.id
        UserDefaults.standard.set(activeConversationID, forKey: "activeConversationID")
        storage.saveConversations(conversations)

        NotificationCenter.default.post(
            name: .init("HermesPetModeChanged"),
            object: nil,
            userInfo: ["mode": AgentMode.directAPI.rawValue]
        )

        // 异步启动规划 + 图片生成
        Task { @MainActor [weak self] in
            await self?.runCanvasGeneration(canvasID: conv.id, template: template)
        }
        return true
    }

    /// 完整跑一遍画布生成流程：
    /// Stage 0 事实调研（让 LLM 用知识库查产品参数）→ Stage 1 规划 → Stage 2 并行填图
    private func runCanvasGeneration(canvasID: String, template: CanvasTemplate) async {
        guard let board = canvasBoard(canvasID: canvasID) else { return }
        let topic = board.topic

        // Stage 0：事实调研（让 LLM 查 topic 的客观参数）
        let researchSummary = await canvasService.researchTopic(topic)
        if !researchSummary.isEmpty {
            updateCanvas(canvasID: canvasID) { $0.researchSummary = researchSummary }
        }

        // Stage 1：让 AI 规划 elements（带事实摘要进 prompt，让卖点有具体数据）
        do {
            let elements = try await canvasService.plan(
                template: template,
                topic: topic,
                researchSummary: researchSummary
            )
            updateCanvas(canvasID: canvasID) { $0.elements = elements }
        } catch {
            errorMessage = L("vm.error.canvasPlanFailed", error.localizedDescription)
            setCanvasStreaming(canvasID: canvasID, value: false)
            return
        }

        // Stage 2：并行填图
        await canvasService.fillImages(
            board: canvasBoard(canvasID: canvasID) ?? board,
            canvasID: canvasID,
            update: { [weak self] elementID, mutate in
                self?.updateCanvasElement(canvasID: canvasID, elementID: elementID, mutate)
            }
        )

        setCanvasStreaming(canvasID: canvasID, value: false)
        storage.saveConversations(conversations)
    }

    // MARK: - 画布：单卡操作

    /// 单卡重新生成 —— 点卡片右上角"重新生成"时调
    func regenerateCanvasElement(canvasID: String, elementID: String) {
        guard let board = canvasBoard(canvasID: canvasID),
              let element = board.elements.first(where: { $0.id == elementID }) else { return }
        Task { @MainActor [weak self] in
            await self?.canvasService.regenerateOne(
                element: element,
                canvasID: canvasID,
                referenceImagePaths: self?.canvasBoard(canvasID: canvasID)?.referenceImagePaths ?? [],
                update: { id, mutate in
                    self?.updateCanvasElement(canvasID: canvasID, elementID: id, mutate)
                }
            )
            self?.storage.saveConversations(self?.conversations ?? [])
        }
    }

    /// 重生所有失败的卡片（toolbar 菜单调用）
    func regenerateFailedCanvasElements(canvasID: String) {
        guard let board = canvasBoard(canvasID: canvasID) else { return }
        let failed = board.elements.filter { $0.status == .failed }
        for element in failed {
            regenerateCanvasElement(canvasID: canvasID, elementID: element.id)
        }
    }

    /// 重生所有图片卡片（toolbar 菜单调用）
    func regenerateAllCanvasImages(canvasID: String) {
        guard let board = canvasBoard(canvasID: canvasID) else { return }
        let images = board.elements.filter { $0.kind == .heroImage || $0.kind == .sceneImage }
        for element in images {
            // 先把状态设回 pending，然后重生
            updateCanvasElement(canvasID: canvasID, elementID: element.id) { $0.status = .pending }
            regenerateCanvasElement(canvasID: canvasID, elementID: element.id)
        }
    }

    /// 删除某张卡片
    func deleteCanvasElement(canvasID: String, elementID: String) {
        updateCanvas(canvasID: canvasID) { board in
            // 删图片文件
            if let idx = board.elements.firstIndex(where: { $0.id == elementID }),
               let path = board.elements[idx].imagePath {
                StorageManager.shared.deleteImageFiles([path])
            }
            board.elements.removeAll { $0.id == elementID }
        }
        storage.saveConversations(conversations)
    }

    // MARK: - 画布：意图识别（底部对话微调）

    /// 用户在画布底部输入 → 走 CanvasService.interpret → 应用 action
    private func dispatchCanvasInput(canvasID: String, userInput: String) {
        guard let board = canvasBoard(canvasID: canvasID) else { return }
        setCanvasStreaming(canvasID: canvasID, value: true)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let action = try await self.canvasService.interpret(userInput: userInput, board: board)
                self.applyCanvasAction(canvasID: canvasID, action: action)
            } catch {
                self.errorMessage = L("vm.error.canvasIntentFailed", error.localizedDescription)
                self.setCanvasStreaming(canvasID: canvasID, value: false)
            }
        }
    }

    /// 应用一个 CanvasAction —— 替换 / 新增 / 编辑文字 / 全部重生 / no-op
    private func applyCanvasAction(canvasID: String, action: CanvasService.CanvasAction) {
        switch action {
        case .replaceElement(let elementID, let newPrompt):
            updateCanvasElement(canvasID: canvasID, elementID: elementID) {
                $0.prompt = newPrompt
                $0.status = .pending
            }
            regenerateCanvasElement(canvasID: canvasID, elementID: elementID)
            setCanvasStreaming(canvasID: canvasID, value: false)

        case .addElement(let kind, let caption, let prompt):
            updateCanvas(canvasID: canvasID) { board in
                let nextSlot = (board.elements.map { $0.slot }.max() ?? -1) + 1
                let isImage = kind == .heroImage || kind == .sceneImage
                let element = CanvasElement(
                    kind: kind, caption: caption, prompt: prompt, slot: nextSlot,
                    content: isImage ? "" : prompt,
                    status: isImage ? .pending : .done
                )
                board.elements.append(element)
                if isImage {
                    // 后台跑一次图片生成
                    let elementID = element.id
                    Task { @MainActor [weak self] in
                        await self?.canvasService.regenerateOne(
                            element: element,
                            canvasID: canvasID,
                            update: { id, mutate in
                                self?.updateCanvasElement(canvasID: canvasID, elementID: id, mutate)
                            }
                        )
                        self?.storage.saveConversations(self?.conversations ?? [])
                    }
                    _ = elementID   // silence unused warning
                }
            }
            setCanvasStreaming(canvasID: canvasID, value: false)

        case .editText(let elementID, let newContent):
            updateCanvasElement(canvasID: canvasID, elementID: elementID) {
                $0.content = newContent
                $0.status = .done
            }
            setCanvasStreaming(canvasID: canvasID, value: false)

        case .regenerateAll:
            regenerateAllCanvasImages(canvasID: canvasID)
            setCanvasStreaming(canvasID: canvasID, value: false)

        case .noop(let reason):
            errorMessage = L("vm.error.canvasNoop", reason)
            setCanvasStreaming(canvasID: canvasID, value: false)
        }
        storage.saveConversations(conversations)
    }

    // MARK: - 画布：辅助 mutate

    /// 拿到指定画布的当前 CanvasBoard（找不到返回 nil）
    private func canvasBoard(canvasID: String) -> CanvasBoard? {
        conversations.first(where: { $0.id == canvasID })?.canvas
    }

    /// 给整个 CanvasBoard 做 in-place 修改（用于添加 / 删除元素 / 改主题等）
    private func updateCanvas(canvasID: String, _ mutate: (inout CanvasBoard) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == canvasID }),
              var board = conversations[idx].canvas else { return }
        mutate(&board)
        board.updatedAt = Date()
        conversations[idx].canvas = board
        conversations[idx].updatedAt = Date()
    }

    /// 改某张卡片
    private func updateCanvasElement(canvasID: String,
                                     elementID: String,
                                     _ mutate: (inout CanvasElement) -> Void) {
        updateCanvas(canvasID: canvasID) { board in
            guard let eIdx = board.elements.firstIndex(where: { $0.id == elementID }) else { return }
            mutate(&board.elements[eIdx])
        }
    }

    /// 切换画布的 isStreaming 状态（影响输入框 loading 显示）
    private func setCanvasStreaming(canvasID: String, value: Bool) {
        guard let idx = conversations.firstIndex(where: { $0.id == canvasID }) else { return }
        conversations[idx].isStreaming = value
        broadcastBackgroundStreamingCount()
    }

    // MARK: - 附件（图片 + 文档）

    /// 拖入文档时调用 —— 不读内容，只保存路径，发送时让 AI 用 Read 工具自己访问。
    /// **v1.2.0+ 在线 AI 走 opencode agent runtime 有 Read 工具，可以读本地文件**，
    /// 跟 Claude Code / Codex 一样开放。Hermes / OpenClaw 模式还是纯 HTTP chat completion，拒绝。
    func attachDocumentPath(_ url: URL) {
        // Hermes / OpenClaw 都是跑在本机、自带文件读写 + 命令执行工具的 agent，
        // 能按绝对路径读取本地文件（已实测可读工作区外路径），所以和 Claude Code / Codex / 在线 AI
        // 一样允许拖入文档：路径会拼进 prompt，交给对端 agent 用自己的工具去读取 / 修改 / 执行。
        // 去重：同一文件已在队列里就不重复加
        if pendingDocuments.contains(url) { return }
        pendingDocuments.append(url)

        SoundManager.play(.dragIn)

        // 灵动岛弹 toast 提示附加成功
        NotificationCenter.default.post(
            name: .init("HermesPetScreenshotAdded"),
            object: nil,
            userInfo: ["text": L("vm.banner.docAttached", url.lastPathComponent), "count": 0]
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
        SoundManager.play(.dragIn)
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
    /// **事件驱动同步**：以前用固定 250ms / 50ms sleep 等窗口隐藏完，但隐藏方式不一致：
    /// - ChatView 按钮触发：用 alphaValue=0，瞬时生效
    /// - 全局热键触发：用 ChatWindowController.hide()，0.22s 退出动画
    /// 固定 sleep 在第二种场景下截到半透明窗口。改成 callback：调用方在窗口真正
    /// 不可见时调 done()，截图才开始 —— 既快又准。
    func captureScreenAndAttach(
        hideAndShowWindow: @escaping @MainActor (_ hide: Bool, _ done: @escaping @MainActor () -> Void) -> Void
    ) {
        hideAndShowWindow(true) { [weak self] in
            Task { @MainActor in
                let result = await ScreenCapture.captureMainScreenWithError()
                hideAndShowWindow(false) {}   // 恢复窗口不需要等回调
                self?.handleScreenCaptureResult(result)
            }
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
            postIslandToast(L("vm.banner.captureAdded"))
        case .needsPermission:
            ScreenCapture.requestScreenRecordingPermission()
            errorMessage = L("vm.error.captureNeedsPermission")
            postIslandToast(L("vm.banner.captureNeedsPermission"))
        case .failed(let message):
            errorMessage = L("vm.error.captureFailed", message)
            postIslandToast(L("vm.banner.captureFailed"))
        }
    }

    /// 「+ → 分享窗口」里程碑 0：截某个指定窗口此刻的画面 → 当图片附件加入待发送区。
    /// 复用现成图片管线 + 截屏结果处理（含权限引导）。AI 接着就能「看到」那个窗口内容。
    /// 实时持续共享（每轮自动重截）属后续里程碑，这里先做一次性快照。
    func shareWindowSnapshot(id: CGWindowID, title: String) {
        Task { @MainActor in
            let result = await ScreenCapture.captureWindow(id: id)
            handleScreenCaptureResult(result)
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
        panel.title = L("vm.export.savePanelTitle")

        panel.begin { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let self = self else { return }
            let md = self.buildMarkdown()
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.errorMessage = L("vm.error.exportFailed", error.localizedDescription)
            }
        }
        #endif
    }

    private func buildMarkdown() -> String {
        var lines: [String] = []
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"

        lines.append(L("vm.export.title"))
        lines.append("")
        lines.append(L("vm.export.target", L(agentMode.labelKey)))
        lines.append(L("vm.export.exportedAt", dateFmt.string(from: Date())))
        lines.append("")
        lines.append("---")
        lines.append("")

        for msg in messages where msg.role != .system {
            let who = msg.role == .user ? L("vm.export.roleUser") : L(agentMode.labelKey)
            lines.append("### \(who) · \(dateFmt.string(from: msg.timestamp))")
            lines.append("")
            lines.append(msg.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 启动图片后台补水

extension ChatViewModel {
    /// 把启动时被 lazy 解码跳过的图片 Data 在后台读出来回填。
    ///
    /// 背景：`~/.hermespet/images` 可达几十 MB，旧版在 ChatMessage decode 里逐个同步
    /// `Data(contentsOf:)` → 冷启动主线程被磁盘 IO 卡住。现改成：启动只解 JSON（42K 级，瞬间），
    /// 图片在 utility 优先级后台读，逐条回主线程按 (conversationID, messageID) 精确回填 ——
    /// 跟流式更新同款定位方式，用户中途删对话/删消息也不会写错位置。
    /// 频率：每条消息回填一次（一次性、低频），不触发决策 #21 的高频渲染问题。
    func hydrateImagesInBackground() {
        // 收集待补水清单（值类型快照，Sendable，安全带进后台）
        var jobs: [(convID: String, msgID: String, paths: [String])] = []
        for conv in conversations {
            for msg in conv.messages where !msg.imagePaths.isEmpty && msg.images.isEmpty {
                jobs.append((conv.id, msg.id, msg.imagePaths))
            }
        }
        guard !jobs.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for job in jobs {
                // 磁盘读在后台；缺图静默跳过（跟旧 decode 行为一致，console 留日志）
                var datas: [Data] = []
                for path in job.paths {
                    if let d = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        datas.append(d)
                    } else {
                        print("[ChatViewModel] 补水：消息 \(job.msgID) 引用的图片已缺失: \(path)")
                    }
                }
                guard !datas.isEmpty else { continue }
                await MainActor.run { [weak self] in
                    guard let self,
                          let ci = self.conversations.firstIndex(where: { $0.id == job.convID }),
                          let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == job.msgID }),
                          self.conversations[ci].messages[mi].images.isEmpty   // 已被别处填过就不动
                    else { return }
                    self.conversations[ci].messages[mi].images = datas
                }
            }
        }
    }
}
