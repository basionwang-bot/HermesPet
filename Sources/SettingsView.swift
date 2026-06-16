import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers

/// 设置面板 —— macOS Sonoma 系统设置风格：
/// - 左侧 156pt 侧栏分类列表
/// - 右侧 ScrollView 详情区，分类标题 + 内容卡片
/// - 5 类：AI 后端 / 桌宠 / 音效 / 系统 / 关于
struct SettingsView: View {
    @Bindable var viewModel: ChatViewModel

    @State private var selectedCategory: Category = .account
    @State private var showKey = false
    @State private var testing = false
    @State private var testResult: (success: Bool, message: String)?
    @State private var hotkeyRefreshID = UUID()
    /// 画布模式开关（实验性功能）—— ChatView 的 + 菜单根据这个 flag 决定是否显示"新建画布"
    @AppStorage("canvasModeEnabled") private var canvasModeEnabled: Bool = false
    @AppStorage(ChatFontScale.storageKey) private var chatFontScale: Double = ChatFontScale.default
    @AppStorage(DisplayMode.storageKey) private var displayModeRaw: String = DisplayMode.auto.rawValue
    @State private var pendingRestartFromDisplayMode = false
    /// 灵动岛显示在哪块屏（多显示器）—— "follow" 跟随鼠标 / displayID 字符串固定到某块屏；默认 follow，即时生效不用重启
    @AppStorage(IslandScreenChoice.storageKey) private var islandScreenChoiceRaw: String = IslandScreenChoice.followRaw
    /// 插拔屏时强制刷新设置里的屏幕下拉列表（NSScreen.screens 变化不会自动触发 SwiftUI 重渲）
    @State private var islandScreenListVersion = 0
    /// 桌宠桌面漫步大小档位（5 档：迷你 / 小 / 默认 / 大 / 特大）
    @AppStorage(PetWalkSizeScale.storageKey) private var petWalkSizeScale: Double = PetWalkSizeScale.default
    @AppStorage("systemStatsEnabled") private var systemStatsEnabled: Bool = true
    @AppStorage("islandHubApps") private var islandHubApps: Bool = true
    @AppStorage("islandHubTokens") private var islandHubTokens: Bool = false   // 消耗面板发版前默认隐藏(token 估算先不暴露给终端用户)
    @AppStorage("islandHubPets") private var islandHubPets: Bool = true
    /// 当前正在"查看 / 编辑配置"的 mode。
    /// **不绑定 viewModel.agentMode** —— 设置里调这个 Picker 不会切换正在进行的对话的 mode，
    /// 仅决定下面 hermesConfig / claudeCard / codexCard 显示哪一个。
    /// 之前直接 bind viewModel.agentMode 会破坏"对话 mode 锁死"的语义（已发消息的对话被设置面板改了 mode）
    @State private var configViewingMode: AgentMode = .hermes
    /// 手风琴列表：当前展开（就地显示配置卡）的后端；nil = 全收起
    @State private var expandedMode: AgentMode? = nil
    /// 全局调色板存储 —— ColorPicker 改色后通过它更新 + 持久化
    @State private var paletteStore = PetPaletteStore.shared

    enum Category: String, CaseIterable, Identifiable {
        case account, backend, pet, island, sound, hotkeys, privacy, system, experimental, arena, about
        var id: String { rawValue }

        @MainActor
        var label: String {
            switch self {
            case .backend: return L("settings.category.backend")
            case .pet:     return L("settings.category.pet")
            case .island:  return L("settings.category.island")
            case .sound:   return L("settings.category.sound")
            case .hotkeys: return L("settings.category.hotkeys")
            case .privacy: return L("settings.category.privacy")
            case .system:  return L("settings.category.system")
            case .account: return L("settings.category.account")
            case .experimental: return L("settings.category.experimental")
            case .arena:   return L("settings.category.arena")
            case .about:   return L("settings.category.about")
            }
        }
        var icon: String {
            switch self {
            case .backend: return "cpu"
            case .pet:     return "pawprint.fill"
            case .island:  return "macbook.gen2"
            case .sound:   return "speaker.wave.2.fill"
            case .hotkeys: return "keyboard.fill"
            case .privacy: return "lock.shield.fill"
            case .system:  return "gearshape.fill"
            case .account: return "person.crop.circle.fill"
            case .experimental: return "flask.fill"
            case .arena:   return "flag.checkered"
            case .about:   return "info.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .backend: return .blue
            case .pet:     return .pink
            case .island:  return .purple
            case .sound:   return .orange
            case .hotkeys: return .teal
            case .privacy: return .indigo
            case .system:  return .gray
            case .account: return .blue
            case .experimental: return .pink
            case .arena:   return .yellow
            case .about:   return Color(white: 0.55)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 620, height: 470)
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Category.allCases) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: cat.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedCategory == cat ? .white : cat.color)
                            .frame(width: 18)
                        Text(cat.label)
                            .font(.system(size: 13))
                            .foregroundStyle(selectedCategory == cat ? .white : .primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        if selectedCategory == cat {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 156)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }

    // MARK: - 详情区

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 11) {
                    SettingsIconTile(icon: selectedCategory.icon, color: selectedCategory.color, size: 30)
                    Text(selectedCategory.label)
                        .font(.system(size: 22, weight: .bold))
                }
                .padding(.top, 2)

                Group {
                    switch selectedCategory {
                    case .backend: backendSection
                    case .pet:     petSection
                    case .island:  islandSection
                    case .sound:   soundSection
                    case .hotkeys: hotkeysSection
                    case .privacy: privacySection
                    case .system:  systemSection
                    case .account: AccountSettingsView(viewModel: viewModel)
                    case .experimental: experimentalSection
                    case .arena:   arenaSection
                    case .about:   aboutSection
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - AI 后端

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("settings.backend.aiMode.title"))
                .font(.system(size: 13, weight: .medium))
            Text(L("settings.backend.aiMode.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // ⭐ 一体化「AI 配置中心」：每个后端一行（图标/状态/开关），点行就地展开它的配置卡。
            // 取代旧的"开关列表 + segmented Picker + 底部配置卡"三段割裂（要点两次才看到配置）。
            // 显示顺序：在线 AI 永远第一（兜底），然后 QwenCode / OpenClaw / Hermes / Claude Code / Codex
            ForEach([AgentMode.directAPI, .qwenCode, .openclaw, .hermes, .claudeCode, .codex]) { mode in
                VStack(alignment: .leading, spacing: 0) {
                    ModeEnableRow(mode: mode, isExpanded: expandedMode == mode) {
                        if expandedMode == mode {
                            expandedMode = nil
                        } else {
                            expandedMode = mode
                            configViewingMode = mode   // 供展开的配置卡内 testConnection / 预设反查用
                        }
                    }
                    if expandedMode == mode {
                        VStack(alignment: .leading, spacing: 14) {
                            configCard(for: mode)
                            // 上下文窗口手动覆盖（自部署 / models.dev 没收录的模型用）
                            ContextWindowOverrideField(mode: mode)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    }
                }
            }
        }
        // 进入设置时把"查看配置"默认设到当前对话的 mode，方便用户直接编辑当前在用的那个
        .onAppear {
            configViewingMode = viewModel.agentMode
            expandedMode = viewModel.agentMode   // 一体化列表：默认展开当前在用的后端
            // 反查"在线 AI"当前是哪个预设
            selectedProvider = ProviderPreset.detect(baseURL: viewModel.directAPIBaseURL)
            if selectedProvider.id != "custom" {
                UserDefaults.standard.set(selectedProvider.id, forKey: "directAPIProviderID")
                loadDirectAPIKey(for: selectedProvider, allowLegacyMigration: true)
            }
            if selectedProvider.id != "custom",
               let detected = selectedProvider.preference(for: viewModel.directAPIModel) {
                viewModel.directAPIResponsePreference = detected
            }
            ensureDirectProviderConfig()

            // 反查 Hermes 当前是哪个预设（H1）
            let savedHermesID = UserDefaults.standard.string(forKey: "hermesPresetID") ?? ""
            if savedHermesID == "custom" {
                selectedHermesPreset = ProviderPreset.custom
            } else if savedHermesID == "hermes-cloud" {
                selectedHermesPreset = ProviderPreset.hermesCloud
            } else if savedHermesID == "hermes-local" {
                selectedHermesPreset = ProviderPreset.hermesLocal
            } else {
                // 首次打开 / 老用户没存过：按 baseURL 自动判断
                selectedHermesPreset = ProviderPreset.detectHermes(baseURL: viewModel.apiBaseURL)
                UserDefaults.standard.set(selectedHermesPreset.id, forKey: "hermesPresetID")
            }
        }
    }

    /// 当前选中的服务商预设（仅给「在线 AI」配置区用）。
    /// 初值在 .onAppear 里根据 viewModel.directAPIBaseURL 反查赋值
    @State private var selectedProvider: ProviderPreset = ProviderPreset.all[0]
    /// QwenCode 傻瓜配置：服务商预设（选了自动填 base url + 默认模型，用户只填 Key）
    @State private var qwenProviderName: String = "DeepSeek"
    private var qwenProviders: [(name: String, url: String, model: String)] {
        [("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
         ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
         ("Kimi", "https://api.moonshot.cn/v1", "moonshot-v1-8k"),
         ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "glm-4.5"),
         (L("settings.backend.qwen.custom"), "", "")]
    }
    /// 在线 AI 自定义服务商：从 /v1/models 拉到的可用模型（一键填，不用用户记模型名）
    @State private var directAvailableModels: [String] = []
    @State private var directFetchingModels = false
    @State private var directModelFetchError: String?

    // MARK: - Hermes 配置（本地 Gateway / 云端 / 自定义）

    /// Hermes 当前选中的预设档位（本地 / 云端 / 自定义）。
    /// .onAppear 时根据 viewModel.apiBaseURL 反查
    @State private var selectedHermesPreset: ProviderPreset = ProviderPreset.hermesLocal
    /// 从 /v1/models 拉到的可用模型列表（H3 模型自动拉取）
    @State private var hermesAvailableModels: [String] = []
    @State private var hermesFetchingModels = false
    @State private var hermesModelFetchError: String?
    /// 本地档"高级"折叠区是否展开（Key / 模型 默认折叠）
    @State private var hermesAdvancedExpanded: Bool = false
    /// 自动启动 hermes gateway 开关（持久化 key 在 HermesGatewayManager.autoStartKey）
    @AppStorage(HermesGatewayManager.autoStartKey) private var hermesAutoStart: Bool = true
    /// 1s 一次刷新 Gateway 状态卡片，让 spawn 进度可视
    @State private var gatewayStatusTick: Int = 0
    /// 当前在跑的状态计时器 —— 持有引用才能 ① 防 onAppear 反复进入时叠加多个、② 卡片消失时停掉
    /// （旧版只靠"切走预设自停"，用户停在本地档关掉设置窗后计时器会永远 1s 一跳）
    @State private var gatewayStatusTimer: Timer? = nil

    // MARK: - OpenClaw 配置（U4：跟 Hermes 同款 Gateway 状态卡片 + 高级折叠区，不再沿用 directAPI 表单）
    @State private var openclawAvailableAgents: [String] = []
    @State private var openclawFetchingAgents = false
    @State private var openclawAgentFetchError: String?
    @State private var openclawAdvancedExpanded: Bool = false
    // 一键安装并配置 OpenClaw（非交互 onboard）
    @State private var openclawSetupAuth: String = ""
    @State private var openclawSetupKey: String = ""
    @State private var openclawInstalling: Bool = false
    @State private var openclawSetupError: String? = nil
    @AppStorage(OpenClawGatewayManager.autoStartKey) private var openclawAutoStart: Bool = true
    @AppStorage("openclawAgentId") private var openclawAgentId: String = "openclaw"
    /// 用户手填的 token 覆盖（默认空 = 自动从 ~/.openclaw/openclaw.json 读）
    @AppStorage("openclawToken") private var openclawTokenOverride: String = ""
    @State private var showOpenclawToken = false

    private var hermesConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 预设 Picker：本地 / 云端 / 自定义，跟 directAPI 体验对齐
            settingRow(L("settings.backend.hermes.deployMethod")) {
                Picker(selection: $selectedHermesPreset) {
                    ForEach(ProviderPreset.hermesPresets) { preset in
                        Text(preset.localizedDisplayName).tag(preset)
                    }
                    Divider()
                    Text(ProviderPreset.custom.localizedDisplayName).tag(ProviderPreset.custom)
                } label: { EmptyView() }
                    .labelsHidden()
                    .onChange(of: selectedHermesPreset) { _, newPreset in
                        applyHermesPreset(newPreset)
                    }
            }

            // 本地档：状态卡片 + 高级折叠区；URL/Key/模型默认隐藏（H9 简化）
            // 云端/自定义档：保留完整输入框
            if selectedHermesPreset.id == "hermes-local" {
                hermesGatewayStatusCard
                hermesLocalAdvancedSection
            } else {
                settingRow(L("settings.backend.hermes.apiURL")) {
                    TextField(L("settings.backend.hermes.urlPlaceholder"), text: $viewModel.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: viewModel.apiBaseURL) { _, _ in
                            hermesAvailableModels = []
                            hermesModelFetchError = nil
                        }
                }
                hermesKeyRow
                hermesModelRow
                if let err = hermesModelFetchError {
                    hermesModelFetchErrorRow(err)
                }
            }

            testConnectionRow

            // 底部提示：按预设档位变化
            HStack(spacing: 6) {
                Spacer().frame(width: 92)
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(hermesHintText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 本地档：Gateway 运行状态卡片（H9 核心）
    /// 跟 directAPI 的 opencodeEngineCard 视觉对齐
    private var hermesGatewayStatusCard: some View {
        let _ = gatewayStatusTick   // 建立 1s tick 依赖让 body 重渲重读 status（不改 identity，避免 .id 重建子树→onAppear 重启计时器自我繁殖）
        let status = HermesGatewayManager.shared.status
        let (dotColor, statusText, tone): (Color, String, Color) = {
            switch status {
            case .starting:       return (.orange, L("settings.common.status.connecting"),    .secondary)
            case .running:        return (.green,  L("settings.common.status.connected"),      .secondary)
            case .external:       return (.green,  L("settings.common.status.connected"),      .secondary)
            case .binaryMissing:  return (.gray,   L("settings.common.status.notInstalled"),   .secondary)
            case .failed:         return (.red,    L("settings.common.status.connectFailed"),  .red)
            case .disabled:       return (.gray,   L("settings.common.status.autoConnectOff"), .secondary)
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                Text(L("settings.backend.hermes.statusName"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                // 重检按钮
                Button {
                    Task.detached(priority: .utility) {
                        await HermesGatewayManager.shared.startIfAvailable()
                        await MainActor.run { viewModel.checkConnection() }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help(L("settings.backend.reconnect"))
            }

            // 未安装时给安装入口
            if case .binaryMissing = status {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(L("settings.backend.hermes.notInstalledHint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Link(L("settings.backend.hermes.installGuide"), destination: URL(string: "https://github.com/anomalyco/hermes-agent")!)
                        .font(.caption2)
                }
            }

            Toggle(isOn: $hermesAutoStart) {
                Text(L("settings.backend.hermes.autoConnect"))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.green.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.green.opacity(0.2), lineWidth: 0.5)
        )
        // 1s tick 刷新 status（spawn 中的状态变化通过 @State 重新读 manager；依赖建在 body 顶部，不再用 .id 重建子树）
        .onAppear {
            startGatewayStatusTimer()
        }
        .onDisappear {
            stopGatewayStatusTimer()
        }
    }

    /// 本地档：高级折叠区（Key / 模型，默认隐藏；用户需要时点开调）
    private var hermesLocalAdvancedSection: some View {
        DisclosureGroup(isExpanded: $hermesAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                hermesKeyRow
                hermesModelRow
                if let err = hermesModelFetchError {
                    hermesModelFetchErrorRow(err)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("settings.backend.hermes.advancedLabel"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - OpenClaw 配置（U4：跟 Hermes 同款 Gateway 状态卡片 + 高级折叠区）

    /// OpenClaw 设置主视图。零配置（HermesPet 自动读 ~/.openclaw/openclaw.json）—— UI 只展示
    /// Gateway 运行状态 + 高级折叠区（Token / Agent 覆盖，给想自定义的用户用）
    private var openclawConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            openclawGatewayStatusCard
            openclawAdvancedSection

            // 底部提示
            HStack(spacing: 6) {
                Spacer().frame(width: 92)
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(L("settings.backend.openclaw.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// OpenClaw 连接状态卡片（小白文案：只显"已连接/连接中/未连接"，不显端口、不显技术词）
    private var openclawGatewayStatusCard: some View {
        let _ = gatewayStatusTick   // 同 hermesGatewayStatusCard：建立 tick 依赖但不改 identity，避免计时器自我繁殖
        let status = OpenClawGatewayManager.shared.status
        let (dotColor, statusText, tone): (Color, String, Color) = {
            switch status {
            case .starting:          return (.orange, L("settings.common.status.connecting"),        .secondary)
            case .running:           return (.green,  L("settings.common.status.connected"),          .secondary)
            case .binaryMissing:     return (.gray,   L("settings.backend.openclaw.status.notConnected"), .secondary)
            case .configMissing:     return (.orange, L("settings.backend.openclaw.status.needInit"),  .orange)
            case .endpointDisabled:  return (.orange, L("settings.backend.openclaw.status.autoConfiguring"), .orange)
            case .failed:            return (.red,    L("settings.common.status.connectFailed"),       .red)
            case .disabled:          return (.gray,   L("settings.common.status.autoConnectOff"),       .secondary)
            }
        }()
        let fomoTint = Color(red: 0.706, green: 0.773, blue: 0.910)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(fomoTint)
                Text(L("settings.backend.openclaw.statusName"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                // 重检按钮
                Button {
                    Task.detached(priority: .utility) {
                        await OpenClawGatewayManager.shared.startIfAvailable()
                        await MainActor.run { viewModel.checkConnection() }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help(L("settings.backend.reconnect"))
            }

            // 状态分支：给具体修复指引（小白能懂的语言）
            switch status {
            case .binaryMissing:
                openclawOneClickSetup(needsInstall: true)
            case .configMissing:
                openclawOneClickSetup(needsInstall: false)
            case .endpointDisabled:
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(L("settings.backend.openclaw.autoConfigRetry"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }

            Toggle(isOn: $openclawAutoStart) {
                Text(L("settings.backend.openclaw.autoConnect"))
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(fomoTint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(fomoTint.opacity(0.35), lineWidth: 0.5)
        )
        .onAppear {
            startGatewayStatusTimer()
        }
        .onDisappear {
            stopGatewayStatusTimer()
        }
    }

    /// OpenClaw 高级设置（默认折叠 —— 一般用户不用打开）
    /// 一键安装并配置 OpenClaw（非交互 onboard + 装 daemon），免去用户开终端走向导。
    /// needsInstall=true 连 npm install 一起跑（没装）；false 只 onboard（装了没配）。
    @ViewBuilder
    private func openclawOneClickSetup(needsInstall: Bool) -> some View {
        let opts = openclawAuthOptions()
        let selected = opts.first(where: { $0.choice == openclawSetupAuth }) ?? opts.first
        VStack(alignment: .leading, spacing: 8) {
            Text(needsInstall ? L("settings.backend.openclaw.notInstalledHint")
                              : L("settings.backend.openclaw.installedNotInit"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if openclawInstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(L("settings.backend.openclaw.setupRunning"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Text(L("settings.backend.openclaw.setupAuth")).font(.caption)
                    Picker(selection: Binding(
                        get: { openclawSetupAuth.isEmpty ? (opts.first?.choice ?? "") : openclawSetupAuth },
                        set: { openclawSetupAuth = $0 }
                    )) {
                        ForEach(opts, id: \.choice) { opt in Text(opt.label).tag(opt.choice) }
                    } label: { EmptyView() }
                    .labelsHidden().fixedSize()
                }
                if let sel = selected, sel.needsKey {
                    SecureField("API Key", text: $openclawSetupKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 8) {
                    Button { runOpenclawSetup(needsInstall: needsInstall) } label: {
                        Label(L("settings.backend.openclaw.oneClickSetup"), systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(needsInstall
                            ? "npm install -g openclaw@latest && openclaw onboard --install-daemon"
                            : "openclaw onboard --install-daemon", forType: .string)
                    } label: { Image(systemName: "doc.on.clipboard").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .help(L("settings.backend.openclaw.copyInstall"))
                }
                if let err = openclawSetupError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// OpenClaw 一键配置的认证来源：优先复用已装的 Claude/Codex（零填 Key），否则选服务商填 Key。
    private func openclawAuthOptions() -> [(label: String, choice: String, keyFlag: String?, needsKey: Bool)] {
        var o: [(label: String, choice: String, keyFlag: String?, needsKey: Bool)] = []
        if !(UserDefaults.standard.string(forKey: "claudeExecutablePath") ?? "").isEmpty {
            o.append((label: L("settings.backend.openclaw.reuseClaude"), choice: "claude-cli", keyFlag: nil, needsKey: false))
        }
        if !(UserDefaults.standard.string(forKey: "codexExecutablePath") ?? "").isEmpty {
            o.append((label: L("settings.backend.openclaw.reuseCodex"), choice: "codex-cli", keyFlag: nil, needsKey: false))
        }
        o.append((label: "DeepSeek",       choice: "deepseek-api-key", keyFlag: "--deepseek-api-key", needsKey: true))
        o.append((label: "Kimi (Moonshot)", choice: "moonshot-api-key", keyFlag: "--moonshot-api-key", needsKey: true))
        o.append((label: "小米 MiMo",       choice: "xiaomi-api-key",   keyFlag: "--xiaomi-api-key",   needsKey: true))
        o.append((label: "OpenAI",         choice: "openai-api-key",   keyFlag: "--openai-api-key",   needsKey: true))
        return o
    }

    /// 拼非交互 onboard 命令并在 App 内跑（spawn），跑完触发 Gateway 检测 → HermesPet 自动连上。
    private func runOpenclawSetup(needsInstall: Bool) {
        let opts = openclawAuthOptions()
        let choice = openclawSetupAuth.isEmpty ? (opts.first?.choice ?? "") : openclawSetupAuth
        guard let sel = opts.first(where: { $0.choice == choice }) else { return }
        let key = openclawSetupKey.trimmingCharacters(in: .whitespaces)
        if sel.needsKey && key.isEmpty {
            openclawSetupError = L("settings.backend.openclaw.setupNeedKey")
            return
        }
        // quickstart = 安全默认（loopback + 18789 + 自动 token，HermesPet 启动时自动读 token 连上）；
        // skip-* 跳过频道/技能/搜索/钩子等非必要步骤，加速且少出错。
        var cmd = needsInstall ? "npm install -g openclaw@latest && " : ""
        cmd += "openclaw onboard --non-interactive --accept-risk --mode local --flow quickstart --auth-choice \(sel.choice)"
        if let f = sel.keyFlag, !key.isEmpty { cmd += " \(f) \(key)" }
        cmd += " --install-daemon --skip-channels --skip-skills --skip-search --skip-hooks --skip-ui --skip-bootstrap"
        openclawSetupError = nil
        openclawInstalling = true
        Task {
            let r = await CLIInstaller.run(command: cmd)
            openclawInstalling = false
            switch r {
            case .success:
                openclawSetupKey = ""
                await OpenClawGatewayManager.shared.startIfAvailable()
                viewModel.checkConnection()
            case .missingNpm:
                openclawSetupError = L("settings.backend.mode.installNeedNode")
            case .failed:
                openclawSetupError = L("settings.backend.openclaw.setupFailed")
            }
        }
    }

    private var openclawAdvancedSection: some View {
        DisclosureGroup(isExpanded: $openclawAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                settingRow(L("settings.backend.openclaw.tokenLabel")) {
                    HStack(spacing: 4) {
                        Group {
                            if showOpenclawToken {
                                TextField(L("settings.backend.openclaw.tokenPlaceholder"), text: $openclawTokenOverride)
                            } else {
                                SecureField(L("settings.backend.openclaw.tokenPlaceholder"), text: $openclawTokenOverride)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        Button {
                            showOpenclawToken.toggle()
                        } label: {
                            Image(systemName: showOpenclawToken ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                settingRow(L("settings.backend.openclaw.agentLabel")) {
                    HStack(spacing: 6) {
                        TextField("openclaw", text: $openclawAgentId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        if !openclawAvailableAgents.isEmpty {
                            Menu {
                                ForEach(openclawAvailableAgents, id: \.self) { name in
                                    Button(name) { openclawAgentId = name }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                            .help(L("settings.backend.openclaw.pickFromList"))
                        }

                        Button {
                            fetchOpenclawAgents()
                        } label: {
                            if openclawFetchingAgents {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            } else {
                                Text(L("settings.common.refresh")).font(.caption)
                            }
                        }
                        .controlSize(.small)
                        .disabled(openclawFetchingAgents)
                    }
                }

                if let err = openclawAgentFetchError {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 92)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                        Text(err).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("settings.common.advanced"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// 拉取 OpenClaw agent 列表（GET /v1/models）
    private func fetchOpenclawAgents() {
        openclawFetchingAgents = true
        openclawAgentFetchError = nil
        Task {
            do {
                let client = APIClient(source: .openclaw)
                let agents = try await client.fetchModels()
                openclawAvailableAgents = agents
                openclawFetchingAgents = false
            } catch {
                openclawAgentFetchError = L("settings.backend.fetchFailed", error.localizedDescription)
                openclawFetchingAgents = false
            }
        }
    }

    /// 拆出 Key 行 + 模型行 + 错误行作为独立组件，本地档高级区 + 云端档都共用
    private var hermesKeyRow: some View {
        settingRow(L("settings.backend.apiKey.optional")) {
            HStack(spacing: 4) {
                Group {
                    if showKey { TextField(L("settings.backend.apiKey.optionalPlaceholder"), text: $viewModel.apiKey) }
                    else { SecureField(L("settings.backend.apiKey.optionalPlaceholder"), text: $viewModel.apiKey) }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(showKey ? L("settings.backend.key.hide") : L("settings.backend.key.show"))
            }
        }
    }

    private var hermesModelRow: some View {
        settingRow(L("settings.backend.model.title")) {
            HStack(spacing: 6) {
                TextField(L("settings.backend.model.placeholder"), text: $viewModel.modelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                if !hermesAvailableModels.isEmpty {
                    Menu {
                        ForEach(hermesAvailableModels, id: \.self) { name in
                            Button(name) { viewModel.modelName = name }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .help(L("settings.backend.model.pickFromList"))
                }

                Button {
                    fetchHermesModels()
                } label: {
                    if hermesFetchingModels {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(hermesFetchingModels)
                .help(L("settings.backend.model.fetchHelp"))
            }
        }
    }

    private func hermesModelFetchErrorRow(_ err: String) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 92)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 1s tick 重渲染 Gateway 状态卡片（spawn 进度可视化）
    private func startGatewayStatusTimer() {
        // 防叠加：两张卡片（Hermes 本地档 / OpenClaw）onAppear 都会进来，先停旧的再起新的
        gatewayStatusTimer?.invalidate()
        gatewayStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            // Timer 闭包是 @Sendable，但在主 RunLoop 触发 → 显式 hop 回主 actor 再访问 @MainActor 状态（决策 #5）。
            // 不把非 Sendable 的 timer 送进 assumeIsolated（会触发数据竞争告警），只回传是否该停，invalidate 留在外层
            let shouldStop = MainActor.assumeIsolated { () -> Bool in
                // 离开当前 mode 就停（避免后台一直 tick）
                if selectedHermesPreset.id != "hermes-local" { return true }
                gatewayStatusTick &+= 1
                return false
            }
            if shouldStop { timer.invalidate() }
        }
    }

    /// 卡片消失（切标签页 / 关设置窗）就停 —— 否则用户停在本地档时计时器会在后台永远 1s 一跳
    private func stopGatewayStatusTimer() {
        gatewayStatusTimer?.invalidate()
        gatewayStatusTimer = nil
    }

    /// Hermes 底部说明文字，按预设档位区分
    private var hermesHintText: String {
        switch selectedHermesPreset.id {
        case "hermes-local":
            return L("settings.backend.hermes.hint.local")
        case "hermes-cloud":
            return L("settings.backend.hermes.hint.cloud")
        default:
            return L("settings.backend.hermes.hint.custom")
        }
    }

    /// 切换 Hermes 预设时回写 baseURL + 模型名
    private func applyHermesPreset(_ preset: ProviderPreset) {
        if preset.id == "hermes-local" {
            // 本地档：强制写默认值，让用户无需手填
            viewModel.apiBaseURL = preset.baseURL
            if viewModel.modelName.isEmpty {
                viewModel.modelName = preset.defaultModel
            }
        } else if preset.id == "hermes-cloud" {
            // 云端档：如果当前还是 localhost，清掉让用户重填
            if viewModel.apiBaseURL.contains("localhost") || viewModel.apiBaseURL.contains("127.0.0.1") {
                viewModel.apiBaseURL = ""
            }
        }
        // 持久化用户选的预设档位
        UserDefaults.standard.set(preset.id, forKey: "hermesPresetID")
        hermesAvailableModels = []
        hermesModelFetchError = nil
        testResult = nil
    }

    /// 从 baseURL/v1/models 拉模型列表（H3）
    private func fetchHermesModels() {
        hermesFetchingModels = true
        hermesModelFetchError = nil
        let client = APIClient(source: .hermes)
        Task {
            do {
                let models = try await client.fetchModels()
                hermesAvailableModels = models
                if models.isEmpty {
                    hermesModelFetchError = L("settings.backend.hermes.modelFetchEmpty")
                } else if viewModel.modelName.isEmpty || !models.contains(viewModel.modelName) {
                    // 当前 modelName 不在列表里 → 自动选第一个
                    viewModel.modelName = models[0]
                }
            } catch {
                hermesModelFetchError = L("settings.backend.fetchFailed", error.localizedDescription)
            }
            hermesFetchingModels = false
        }
    }

    /// 从在线 AI 当前配置的 baseURL `/v1/models` 拉模型列表（让自定义服务商「省心」：一键填模型名，
    /// 也让新模型自动出现、过时模型名自愈）。用户填好 baseURL+Key 后点刷新触发；空/失败有提示。
    private func fetchDirectModels() {
        directFetchingModels = true
        directModelFetchError = nil
        let client = APIClient(source: .direct)
        Task {
            do {
                let models = try await client.fetchModels()
                directAvailableModels = models
                if models.isEmpty {
                    directModelFetchError = L("settings.backend.hermes.modelFetchEmpty")
                } else if viewModel.directAPIModel.isEmpty || !models.contains(viewModel.directAPIModel) {
                    // 当前模型名为空 / 不在列表 → 自动填第一个（过时名自愈）
                    viewModel.directAPIModel = models[0]
                }
            } catch {
                directModelFetchError = L("settings.backend.fetchFailed", error.localizedDescription)
            }
            directFetchingModels = false
        }
    }

    /// 按后端返回对应配置卡（一体化列表展开时就地显示）。
    /// HTTP 类后端（directAPI/hermes/qwenCode）顶部加「配置档案」条 —— 多套配置一键切换。
    @ViewBuilder
    private func configCard(for mode: AgentMode) -> some View {
        switch mode {
        case .hermes:
            VStack(alignment: .leading, spacing: 12) { aiProfileBar(for: .hermes); hermesConfig }
        case .directAPI:
            VStack(alignment: .leading, spacing: 12) { aiProfileBar(for: .directAPI); directAPIConfig }
        case .qwenCode:
            VStack(alignment: .leading, spacing: 12) { aiProfileBar(for: .qwenCode); qwenCodeConfig }
        case .openclaw:   openclawConfig
        case .claudeCode: claudeCard
        case .codex:      codexCard
        }
    }

    /// 「配置档案」条：某后端的多套命名配置，点击切换激活、＋新建（从预设/自定义）、删除。
    /// 切换前先把当前档的表单改动同步回档（syncActiveFromFields），避免切走丢改动。
    @ViewBuilder
    private func aiProfileBar(for backend: AgentMode) -> some View {
        let store = AIProfileStore.shared
        let list = store.profiles(for: backend)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("settings.backend.profiles.title"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(ProviderPreset.all) { preset in
                        Button(preset.localizedDisplayName) {
                            let p = store.makeProfile(from: preset, backend: backend)
                            store.add(p); store.activate(p, viewModel: viewModel)
                            configViewingMode = backend
                        }
                    }
                    Divider()
                    Button(L("settings.backend.profiles.custom")) {
                        let p = store.makeCustomProfile(backend: backend)
                        store.add(p); store.activate(p, viewModel: viewModel)
                        configViewingMode = backend
                    }
                } label: {
                    Label(L("settings.backend.profiles.new"), systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            ForEach(list) { p in
                HStack(spacing: 8) {
                    Image(systemName: store.isActive(p) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(store.isActive(p) ? backendTint(backend) : Color.secondary)
                    Text(p.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if !(backend == .directAPI && list.count <= 1) {
                        Button {
                            store.delete(p)
                            if let a = store.activeProfile(for: backend) {
                                store.activate(a, viewModel: viewModel)
                            }
                            configViewingMode = backend
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(L("common.delete"))
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.isActive(p) ? backendTint(backend).opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    store.syncActiveFromFields(backend: backend, viewModel: viewModel)
                    store.activate(p, viewModel: viewModel)
                    configViewingMode = backend
                }
            }
            Divider().padding(.top, 4)
        }
    }

    private func backendTint(_ m: AgentMode) -> Color {
        switch m {
        case .hermes:    return .green
        case .directAPI: return .indigo
        case .qwenCode:  return .teal
        default:         return .secondary
        }
    }

    // MARK: - 在线 AI 配置（直连第三方 OpenAI 兼容服务商）

    private var directAPIConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 服务商预设 Picker（去掉了"opencode 引擎"诊断卡片和重复说明 —— 小白只需要填 Key 就能用）
            settingRow(L("settings.backend.direct.provider")) {
                Picker(selection: $selectedProvider) {
                    ForEach(ProviderPreset.all) { preset in
                        Text(preset.localizedDisplayName).tag(preset)
                    }
                    Divider()
                    Text(ProviderPreset.custom.localizedDisplayName).tag(ProviderPreset.custom)
                } label: { EmptyView() }
                    .labelsHidden()
                    .onChange(of: selectedProvider) { _, newPreset in
                        applyProviderPreset(newPreset)
                    }
            }

            // 自定义时才显示完整 URL 编辑框；预设隐藏避免误改
            if selectedProvider.id == "custom" {
                settingRow(L("settings.backend.direct.apiURL")) {
                    TextField(L("settings.backend.direct.urlPlaceholder"), text: $viewModel.directAPIBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            settingRow(L("settings.backend.direct.apiKey")) {
                HStack(spacing: 4) {
                    Group {
                        if showKey { TextField(keyPlaceholder, text: $viewModel.directAPIKey) }
                        else { SecureField(keyPlaceholder, text: $viewModel.directAPIKey) }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? L("settings.backend.key.hide") : L("settings.backend.key.show"))
                }
            }
            if selectedProvider.id == "custom" {
                settingRow(L("settings.backend.direct.model")) {
                    HStack(spacing: 6) {
                        TextField(L("settings.backend.direct.modelPlaceholder"), text: $viewModel.directAPIModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        // 已拉取到模型 → 给个下拉一键选（不用记模型名）
                        if !directAvailableModels.isEmpty {
                            Menu {
                                ForEach(directAvailableModels, id: \.self) { name in
                                    Button(name) { viewModel.directAPIModel = name }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                            .help(L("settings.backend.model.pickFromList"))
                        }

                        // 一键从该服务商 /v1/models 拉取可用模型
                        Button {
                            fetchDirectModels()
                        } label: {
                            if directFetchingModels {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .controlSize(.small)
                        .disabled(directFetchingModels)
                        .help(L("settings.backend.model.fetchHelp"))
                    }
                }
                if let err = directModelFetchError {
                    hermesModelFetchErrorRow(err)
                }
            } else {
                settingRow(L("settings.backend.direct.responsePref")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(selection: $viewModel.directAPIResponsePreference) {
                            ForEach(DirectResponsePreference.allCases) { preference in
                                Text(preference.localizedLabel).tag(preference)
                            }
                        } label: { EmptyView() }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: viewModel.directAPIResponsePreference) { _, _ in
                            syncDirectModelWithPreference()
                        }

                        Text(viewModel.directAPIResponsePreference.caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                settingRow(L("settings.backend.direct.currentModel")) {
                    Text(selectedProvider.model(for: viewModel.directAPIResponsePreference))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            testConnectionRow

            // 底部提示：服务商注册入口 + 备选模型
            providerHint
        }
    }

    // MARK: - QwenCode 配置（直连阿里 DashScope OpenAI 兼容端点；纯模型，可进舰队多路并发分担负载）

    private var qwenCodeConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeInfoCard(
                icon: "q.circle.fill",
                iconColor: .teal,
                title: L("settings.backend.qwen.title"),
                body: L("settings.backend.qwen.hint"),
                tint: .teal
            )
            // 可选的傻瓜填 Key（没在终端登录过 qwen 的用户用）：选服务商 + 填 Key 即可
            settingRow(L("settings.backend.direct.provider")) {
                Picker(selection: $qwenProviderName) {
                    ForEach(qwenProviders, id: \.name) { p in Text(p.name).tag(p.name) }
                } label: { EmptyView() }
                    .labelsHidden()
                    .onChange(of: qwenProviderName) { _, n in
                        if let p = qwenProviders.first(where: { $0.name == n }), !p.url.isEmpty {
                            viewModel.qwenBaseURL = p.url
                            viewModel.qwenModel = p.model
                        }
                    }
            }
            settingRow(L("settings.backend.direct.apiKey")) {
                HStack(spacing: 4) {
                    Group {
                        if showKey { TextField("sk-...", text: $viewModel.qwenAPIKey) }
                        else { SecureField("sk-...", text: $viewModel.qwenAPIKey) }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? L("settings.backend.key.hide") : L("settings.backend.key.show"))
                }
            }
            settingRow(L("settings.backend.direct.apiURL")) {
                TextField("https://api.deepseek.com/v1", text: $viewModel.qwenBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            settingRow(L("settings.backend.direct.model")) {
                TextField("deepseek-chat", text: $viewModel.qwenModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    /// 应用预设到「在线 AI」配置：写入 baseURL + 按当前回复偏好映射模型。
    /// 预设模式不让用户手填模型名，避免“选了服务商但模型/API 地址没真正写入”的错觉。
    private func applyProviderPreset(_ preset: ProviderPreset) {
        guard preset.id != "custom" else {
            UserDefaults.standard.set(preset.id, forKey: "directAPIProviderID")
            loadDirectAPIKey(for: preset)
            return
        }
        UserDefaults.standard.set(preset.id, forKey: "directAPIProviderID")
        if !preset.baseURL.isEmpty {
            viewModel.directAPIBaseURL = preset.baseURL
        }
        loadDirectAPIKey(for: preset)
        syncDirectModelWithPreference(for: preset)
        testResult = nil
    }

    /// API Key 按服务商独立保存。切到没配置过的服务商时显示空，避免拿 DeepSeek key 去测智谱造成误导。
    private func loadDirectAPIKey(for preset: ProviderPreset,
                                  allowLegacyMigration: Bool = false) {
        let keyName = ChatViewModel.directAPIKeyStorageKey(providerID: preset.id)
        if UserDefaults.standard.object(forKey: keyName) != nil {
            viewModel.directAPIKey = UserDefaults.standard.string(forKey: keyName) ?? ""
            return
        }

        let legacyKey = UserDefaults.standard.string(forKey: "directAPIKey") ?? ""
        if allowLegacyMigration,
           !legacyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.directAPIKey = legacyKey
        } else {
            viewModel.directAPIKey = ""
        }
    }

    /// 设置页首次打开时，如果 directAPIBaseURL 为空，Picker 会默认显示 DeepSeek。
    /// 必须同时把 DeepSeek 的 baseURL/model 真写入 ViewModel，否则测试连接会拿空 URL 报“不支持的 URL”。
    private func ensureDirectProviderConfig() {
        guard selectedProvider.id != "custom" else { return }
        if viewModel.directAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.directAPIBaseURL = selectedProvider.baseURL
        }
        if viewModel.directAPIModel.isEmpty || selectedProvider.preference(for: viewModel.directAPIModel) == nil {
            syncDirectModelWithPreference()
        }
    }

    private func syncDirectModelWithPreference(for preset: ProviderPreset? = nil) {
        let resolved = preset ?? selectedProvider
        guard resolved.id != "custom" else { return }
        viewModel.directAPIModel = resolved.model(for: viewModel.directAPIResponsePreference)
        testResult = nil
    }

    private var keyPlaceholder: String {
        switch selectedProvider.id {
        case "deepseek": return "sk-xxxxxx (DeepSeek)"
        case "zhipu":    return "xxxxx.xxxxx (Zhipu)"
        case "moonshot": return "sk-xxxxxx (Moonshot)"
        case "minimax":  return "sk-xxxxxx (MiniMax)"
        case "openai":   return "sk-xxxxxx (OpenAI)"
        default: return L("settings.backend.direct.keyPlaceholder.default")
        }
    }

    @ViewBuilder
    private var providerHint: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 92)
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
            switch selectedProvider.id {
            case "custom":
                Text(L("settings.backend.direct.hint.custom"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                if viewModel.directAPIKey.isEmpty {
                    Text(L("settings.backend.direct.hint.noKey"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let urlStr = selectedProvider.signupURL, let url = URL(string: urlStr) {
                    Text(L("settings.backend.direct.hint.needKey"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(L("settings.backend.direct.hint.getKey"), destination: url)
                        .font(.caption)
                }
                if !selectedProvider.altModels.isEmpty {
                    Text(L("settings.backend.direct.hint.altModels", selectedProvider.altModels.joined(separator: " / ")))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    /// v1.2.0+：在线 AI 模式底层用 bundled opencode agent runtime（MIT，anomalyco/opencode）。
    /// 卡片告诉用户：① 不只是 chat completion，能读写文件 / 跑命令 / 联网 ② 当前 server 状态
    /// ③ 没配 key 也能用免费模型
    private var opencodeEngineCard: some View {
        let isReady = OpenCodeServerManager.shared.isReady
        let portText: String = {
            if let url = OpenCodeServerManager.shared.serverURL,
               let port = url.port {
                return ":\(port)"
            }
            return ""
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.indigo)
                Text(L("settings.backend.opencode.title"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle()
                    .fill(isReady ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(isReady ? L("settings.backend.opencode.running", portText) : L("settings.backend.opencode.starting"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(L("settings.backend.opencode.desc"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !OpenCodeConfigGenerator.hasConfiguredKey {
                HStack(spacing: 4) {
                    Image(systemName: "gift.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(L("settings.backend.opencode.freeModel"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if OpenCodeConfigGenerator.isReasoningModelKnownUnstable {
                // 推理模型（DeepSeek V4 / Kimi K2.x / OpenAI o1+ 等）的 reasoning_content
                // 字段 opencode v1.15.1 还没完全适配，可能"偶尔无响应"。明确告知 + 给出 fallback
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.backend.opencode.reasoningWarn.title"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(L("settings.backend.opencode.reasoningWarn.body"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.indigo.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.indigo.opacity(0.2), lineWidth: 0.5)
        )
    }

    /// 共用的"测试连接"按钮行 —— Hermes / 在线 AI 都用它，按 configViewingMode 决定测哪一组配置
    private var testConnectionRow: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 92)
            Button(action: testConnection) {
                HStack(spacing: 4) {
                    if testing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text(testing ? L("settings.backend.test.testing") : L("settings.backend.test.button"))
                }
            }
            .controlSize(.small)
            .disabled(testing)

            if let result = testResult {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? .green : .red)
                Text(result.success ? L("settings.backend.test.connected") : result.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
    }

    private var claudeCard: some View {
        cliConfigCard(
            mode: .claudeCode,
            icon: "terminal.fill",
            tint: .orange,
            title: L("settings.backend.claude.title"),
            body: L("settings.backend.claude.body"),
            installURL: "https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview"
        )
    }

    private var codexCard: some View {
        cliConfigCard(
            mode: .codex,
            icon: "wand.and.stars",
            tint: .cyan,
            title: L("settings.backend.codex.title"),
            body: L("settings.backend.codex.body"),
            installURL: "https://github.com/openai/codex"
        )
    }

    /// CLI 模式（Claude / Codex）的配置卡 —— 说明 + 当前探测到的路径 + 重新检测按钮
    @ViewBuilder
    private func cliConfigCard(mode: AgentMode,
                               icon: String,
                               tint: Color,
                               title: String,
                               body: String,
                               installURL: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .background(tint.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 当前检测到的路径 + 重新检测按钮
            cliDetectionRow(mode: mode, tint: tint)

            // 订阅月费（仅用于灵动岛「Token 消耗」的省钱对比，不影响 token 计费）
            subscriptionFeeRow(mode: mode, tint: tint)

            // 自动探测失败时的兜底：手动指定可执行路径（issue #23）
            CLIManualPathField(mode: mode) { redetectCLI(mode: mode) }

            // 安装指南链接
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(L("settings.backend.cli.notInstalledQ"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(L("settings.backend.cli.installGuide"), destination: URL(string: installURL)!)
                    .font(.caption)
            }
        }
    }

    /// 订阅月费输入（Claude Code / Codex）—— 填了之后灵动岛「Token 消耗」卡片会按
    /// "这些 token 走 API 要花多少" 对比你的月费，算出省了多少。只影响"省钱"统计，不影响计费本身。
    @ViewBuilder
    private func subscriptionFeeRow(mode: AgentMode, tint: Color) -> some View {
        let key = (mode == .claudeCode) ? TokenUsageStore.claudeFeeKey : TokenUsageStore.codexFeeKey
        HStack(spacing: 8) {
            Image(systemName: "creditcard")
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(L("settings.backend.cli.subFee"))
                .font(.caption)
            Spacer()
            TextField("0", text: Binding(
                get: {
                    let v = UserDefaults.standard.double(forKey: key)
                    return v > 0 ? String(format: "%g", v) : ""
                },
                set: { UserDefaults.standard.set(Double($0.trimmingCharacters(in: .whitespaces)) ?? 0, forKey: key) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .multilineTextAlignment(.trailing)
            Text(L("settings.backend.cli.subFeeUnit"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(L("settings.backend.cli.subFee.help"))
    }

    /// 单行 UI：左侧显示当前检测状态（路径 / "未找到" / "检测中…"），右侧"重新检测"按钮
    @ViewBuilder
    private func cliDetectionRow(mode: AgentMode, tint: Color) -> some View {
        HStack(spacing: 8) {
            // 当前 UserDefaults 里的路径就是 CLIAvailability 探测后写入的真实路径
            let key = (mode == .claudeCode) ? "claudeExecutablePath" : "codexExecutablePath"
            let storedPath = UserDefaults.standard.string(forKey: key) ?? ""

            Image(systemName: storedPath.isEmpty ? "questionmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(storedPath.isEmpty ? Color.secondary : Color.green)

            if cliDetectingMode == mode {
                Text(L("settings.backend.cli.detecting"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else if storedPath.isEmpty {
                Text(L("settings.backend.cli.notDetected"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(storedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                redetectCLI(mode: mode)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text(L("settings.backend.cli.redetect"))
                }
            }
            .controlSize(.small)
            .disabled(cliDetectingMode == mode)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// 手动指定 CLI 路径的输入框（issue #23）—— 自动探测失败 / 用户想强制指定时用。
    /// 存到 `claudeExecutablePathManual` / `codexExecutablePathManual`，CLIAvailability 检测时最高优先级。
    private struct CLIManualPathField: View {
        let mode: AgentMode
        /// 应用后回调（父视图触发重新检测 + 刷新连接状态）
        let onApply: () -> Void

        @State private var path: String = ""

        private var key: String {
            (mode == .claudeCode) ? "claudeExecutablePathManual" : "codexExecutablePathManual"
        }
        private var placeholder: String {
            "/usr/local/bin/" + (mode == .claudeCode ? "claude" : "codex")
        }

        var body: some View {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField(placeholder, text: $path)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit(apply)
                        Button(L("settings.backend.cli.manualApply"), action: apply)
                            .controlSize(.small)
                    }
                    Text(L("settings.backend.cli.manualHint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text(L("settings.backend.cli.manualPath"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { path = UserDefaults.standard.string(forKey: key) ?? "" }
        }

        private func apply() {
            UserDefaults.standard.set(
                path.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: key
            )
            onApply()
        }
    }

    /// 上下文窗口手动覆盖输入框 —— 留空走 models.dev 自动查；自部署/冷门模型查不到时手填。
    /// 存 UserDefaults（按 mode），0 = 清除覆盖（回到自动）。
    private struct ContextWindowOverrideField: View {
        let mode: AgentMode
        @State private var text: String = ""

        private var key: String { TokenEstimator.overrideKey(for: mode) }

        var body: some View {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField(L("settings.backend.ctxWindow.placeholder"), text: $text)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: 150)
                            .onSubmit(apply)
                        Text("tokens").font(.caption2).foregroundStyle(.secondary)
                        Button(L("settings.backend.cli.manualApply"), action: apply)
                            .controlSize(.small)
                    }
                    Text(L("settings.backend.ctxWindow.hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text(L("settings.backend.ctxWindow.label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                let v = UserDefaults.standard.integer(forKey: key)
                text = v > 0 ? "\(v)" : ""
            }
        }

        private func apply() {
            let n = Int(text.filter { $0.isNumber }) ?? 0
            UserDefaults.standard.set(n, forKey: key)   // 0 = 清除覆盖
        }
    }

    /// 当前正在检测哪个 mode 的 CLI（用于按钮 disable / "检测中…"显示）
    @State private var cliDetectingMode: AgentMode?

    private func redetectCLI(mode: AgentMode) {
        cliDetectingMode = mode
        Task { @MainActor in
            await CLIAvailability.invalidateCache()
            let key = (mode == .claudeCode) ? "claudeExecutablePath" : "codexExecutablePath"
            // 清掉旧路径，让探测重新写入
            UserDefaults.standard.removeObject(forKey: key)

            let found: Bool
            switch mode {
            case .claudeCode: found = await CLIAvailability.claudeAvailable()
            case .codex:      found = await CLIAvailability.codexAvailable()
            default:          found = false
            }

            cliDetectingMode = nil
            if found {
                viewModel.checkConnection()  // 重新检测连接 → 状态点变绿
            }
        }
    }

    private func modeInfoCard(icon: String, iconColor: Color, title: String, body: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 桌宠

    private var petSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 养成卡（第 0 步地基的可见出口：等级 / 经验 / 心情 / 战绩随干活增长）
            PetProgressCard()

            Divider()

            captionToggle(
                icon: "sparkles",
                iconColor: .pink,
                title: L("settings.pet.animation.title"),
                caption: L("settings.pet.animation.caption"),
                isOn: Binding(
                    get: { !viewModel.quietMode },
                    set: { viewModel.quietMode = !$0 }
                )
            )

            Divider()

            // 灵动岛系统信息 —— 右耳轮播 内存/CPU/网速/温度，hover 展开看全部
            captionToggle(
                icon: "gauge.with.dots.needle.bottom.50percent",
                iconColor: .teal,
                title: L("settings.pet.systemStats.title"),
                caption: L("settings.pet.systemStats.caption"),
                isOn: $systemStatsEnabled
            )

            // 控制中心子分区：展开面板里要不要「应用启动器」/「宠物乐园」标签（系统状态恒在）
            if systemStatsEnabled {
                captionToggle(
                    icon: "square.grid.2x2.fill",
                    iconColor: .indigo,
                    title: L("settings.pet.islandApps.title"),
                    caption: L("settings.pet.islandApps.caption"),
                    isOn: $islandHubApps
                )
                // Token 消耗「计费 + 省钱」标签：发版前暂封印(token 估算先不暴露给终端用户)。
                // 恢复：放开下面 + 把 islandHubTokens 两处 default 改回 true。
                // captionToggle(
                //     icon: "dollarsign.circle.fill",
                //     iconColor: .green,
                //     title: L("settings.pet.islandTokens.title"),
                //     caption: L("settings.pet.islandTokens.caption"),
                //     isOn: $islandHubTokens
                // )
                // 乐园（宠物养成/形象）暂封印（2026-06-06）：方案未达满意，先不暴露开关。
                // 恢复：放开下面 + SystemStatsViews.sections 里的 .pets。
                // captionToggle(
                //     icon: "pawprint.fill",
                //     iconColor: .pink,
                //     title: L("settings.pet.islandPets.title"),
                //     caption: L("settings.pet.islandPets.caption"),
                //     isOn: $islandHubPets
                // )
                let _ = islandHubPets
            }

            Divider()

            // 桌面漫步统一区 —— 覆盖四种桌宠（每个 mode 一种形象）
            VStack(alignment: .leading, spacing: 6) {
                Label(L("settings.pet.walk.sectionTitle"), systemImage: "figure.walk")
                    .font(.system(size: 13, weight: .medium))
                Text(L("settings.pet.walk.sectionCaption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            captionToggle(
                icon: "figure.walk",
                iconColor: petColor,
                title: L("settings.pet.walk.enableTitle"),
                caption: L("settings.pet.walk.enableCaption"),
                isOn: $viewModel.clawdWalkEnabled
            )

            captionToggle(
                icon: "pin.fill",
                iconColor: petColor,
                title: L("settings.pet.pinned.title"),
                caption: L("settings.pet.pinned.caption"),
                isOn: $viewModel.petPinnedEnabled,
                disabled: !viewModel.clawdWalkEnabled
            )

            captionToggle(
                icon: "infinity",
                iconColor: petColor,
                title: L("settings.pet.freeRoam.title"),
                caption: L("settings.pet.freeRoam.caption"),
                isOn: $viewModel.clawdFreeRoamEnabled,
                disabled: !viewModel.clawdWalkEnabled || viewModel.petPinnedEnabled
            )

            captionToggle(
                icon: "sparkles.rectangle.stack",
                iconColor: petColor,
                title: L("settings.pet.patrol.title"),
                caption: L("settings.pet.patrol.caption"),
                isOn: $viewModel.clawdDesktopPatrolEnabled,
                disabled: !viewModel.clawdWalkEnabled || viewModel.petPinnedEnabled
            )

            Divider()

            // 桌宠形象调色 —— 主色定制（派生色自动跟随）
            VStack(alignment: .leading, spacing: 10) {
                Label(L("settings.pet.palette.title"), systemImage: "paintpalette.fill")
                    .font(.system(size: 13, weight: .medium))
                Text(L("settings.pet.palette.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                paletteRow(label: L("settings.pet.palette.claude"), mode: .claudeCode)
                paletteRow(label: L("settings.pet.palette.directAPI"), mode: .directAPI)
                paletteRow(label: L("settings.pet.palette.openclaw"), mode: .openclaw)
                paletteRow(label: L("settings.pet.palette.hermes"), mode: .hermes)
                paletteRow(label: L("settings.pet.palette.codex"), mode: .codex)
                paletteRow(label: L("settings.pet.palette.qwen"), mode: .qwenCode)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)

            // 桌宠大小档位
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("settings.pet.size.title"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(petWalkSizeScale * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Picker(L("settings.pet.size.title"), selection: $petWalkSizeScale) {
                    ForEach(PetWalkSizeScale.presets, id: \.self) { scale in
                        Text(petSizeLabel(scale)).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: petWalkSizeScale) { _, _ in
                    // 通知 ClawdWalkController：已显示中的桌宠 setFrame 跟随新尺寸
                    NotificationCenter.default.post(name: PetWalkSizeScale.didChangeNotification, object: nil)
                }

                Text(L("settings.pet.size.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label(L("settings.pet.interaction.title"), systemImage: "hand.tap")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                interactionTip(L("settings.pet.interaction.click.trigger"), L("settings.pet.interaction.click.effect"))
                interactionTip(L("settings.pet.interaction.hover.trigger"), L("settings.pet.interaction.hover.effect"))
                interactionTip(L("settings.pet.interaction.drag.trigger"), L("settings.pet.interaction.drag.effect"))
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    /// 单个 mode 的调色行：ColorPicker + 重置默认
    @ViewBuilder
    private func paletteRow(label: String, mode: AgentMode) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 170, alignment: .leading)
            ColorPicker(
                "",
                selection: Binding<Color>(
                    get: { paletteStore.palette(for: mode).primary },
                    set: { newColor in paletteStore.updatePrimary(for: mode, color: newColor) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 44)

            Button(L("settings.pet.palette.resetDefault")) {
                paletteStore.resetToDefault(for: mode)
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()
        }
    }

    /// 桌宠区主色 —— 用偏中性的灰蓝避免暗示只服务某一只宠物
    private var petColor: Color {
        Color(red: 110.0/255, green: 130.0/255, blue: 165.0/255)
    }

    private func captionToggle(icon: String, iconColor: Color, title: String, caption: String,
                               isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                Label {
                    Text(title).font(.system(size: 13))
                } icon: {
                    Image(systemName: icon).foregroundStyle(disabled ? Color.secondary : iconColor)
                }
            }
            .disabled(disabled)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(disabled ? 0.6 : 1)
    }

    private func interactionTip(_ trigger: String, _ effect: String) -> some View {
        HStack(spacing: 6) {
            Text(trigger)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(effect)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    // MARK: - 音效

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部提示卡 —— 让用户秒懂"每行可以独立开关 / 换音 / 用自己的音频文件"
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("settings.sound.intro.title"))
                        .font(.system(size: 12, weight: .medium))
                    Text(L("settings.sound.intro.caption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
            )

            soundRow(event: .voiceStart,  binding: $viewModel.voiceStartSound)
            Divider()
            soundRow(event: .voiceFinish, binding: $viewModel.voiceFinishSound)
            Divider()
            soundRow(event: .dragIn,      binding: $viewModel.dragInSound)
            Divider()
            soundRow(event: .send,        binding: $viewModel.sendSound)
            Divider()
            soundRow(event: .error,       binding: $viewModel.errorSound)
        }
    }

    private func soundRow(event: SoundEvent, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(event.titleKey)).font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                // 当前选的是自定义文件 —— 显示文件名 chip + ✕（移回静音）
                if binding.wrappedValue.hasPrefix("/") {
                    customFileChip(path: binding.wrappedValue) {
                        binding.wrappedValue = ""
                    }
                } else {
                    // 系统音 Picker（含 "🔇 静音" 在最上）
                    Picker("", selection: binding) {
                        ForEach(Self.systemSounds, id: \.0) { (value, labelKey) in
                            Text(L(labelKey)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                Button {
                    pickCustomSoundFile(for: binding)
                } label: {
                    Label(L("settings.sound.custom"), systemImage: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .help(L("settings.sound.customHelp"))

                Button {
                    SoundManager.play(rawValue: binding.wrappedValue)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("settings.sound.preview"))
                .disabled(binding.wrappedValue.isEmpty)

                Spacer()
            }

            Text(L(event.captionKey)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 自定义音频文件的 chip —— 显示文件名 + ✕ 移除按钮
    private func customFileChip(path: String, onRemove: @escaping () -> Void) -> some View {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return HStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help(L("settings.sound.removeCustomHelp"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.orange.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
        .frame(maxWidth: 220, alignment: .leading)
    }

    /// 弹出 macOS 文件选择面板让用户选一个音频文件，写入 binding（用绝对路径，约定 `/` 开头 = 自定义文件）
    @MainActor
    private func pickCustomSoundFile(for binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.title = L("settings.sound.picker.title")
        panel.prompt = L("settings.sound.picker.prompt")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // NSSound 支持 aiff / wav / mp3 / m4a / caf 等常见格式
        if let audioType = UTType(filenameExtension: "mp3") {
            panel.allowedContentTypes = [.audio, audioType]
        } else {
            panel.allowedContentTypes = [.audio]
        }

        if panel.runModal() == .OK, let url = panel.url {
            // 路径必须以 / 开头 —— SoundManager 用这个判断走系统音还是文件加载
            binding.wrappedValue = url.path
        }
    }

    // MARK: - 系统

    // MARK: - 隐私（活动记录）

    @State private var activityTodayStats: [AppDailyStat] = []
    @State private var showClearActivityConfirm = false
    /// 意图感知（v1.3 Phase 1）—— 总开关 + 最近样本计数（每次打开设置刷一次）
    @AppStorage("userIntentEnabled") private var userIntentEnabled: Bool = false
    @State private var userIntentTodayCount: Int = 0
    @State private var showClearIntentConfirm = false

    /// Wave C4：主出场偏好 —— "auto" / "pet" / "island"
    @AppStorage("intentChannelPreference") private var intentChannelPreferenceRaw: String = "auto"
    /// Wave C5：每分钟最多反馈次数 —— 1=安静 / 2=适中 / 4=频繁（v1.3「不刻意」默认安静）
    @AppStorage("intentFeedbackPerMinute") private var intentFeedbackPerMinute: Int = 1

    /// Wave E1：今日观察列表数据。每次打开设置 / 用户操作（删除/拉黑/刷新）后重新拉
    @State private var intentObservations: [UserIntent] = []
    @State private var showObservationList: Bool = false
    /// Wave E2/E3：用户软黑名单（bundle ID 数组）。@State 镜像 + UserDefaults.array(forKey:) 同步
    @State private var userBlacklist: [String] = []

    /// v1.3 Phase 3：成长轨迹（daily_journal 时间线）
    @State private var journalEntries: [DailyJournalEntry] = []
    @State private var showGrowthTimeline: Bool = false
    @State private var expandedJournalDate: String? = nil
    @State private var showClearJournalConfirm: Bool = false

    /// v1.3 Phase 4-B：日报 / 回顾风格（全局单选，默认温暖陪伴）
    @AppStorage("briefingStyle") private var briefingStyleRaw: String = BriefingStyle.warm.rawValue

    /// v1.3 Phase 4a：跨模式共享记忆（user-memory.md）。默认关，纯 opt-in。
    @AppStorage("userMemoryEnabled") private var userMemoryEnabled: Bool = false
    @State private var userMemoryText: String = ""
    @State private var userMemoryDirty: Bool = false
    @State private var showClearMemoryConfirm: Bool = false

    private var arenaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "flag.checkered").foregroundStyle(.yellow)
                Text(L("settings.arena.intro"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("settings.arena.meeting.title")).font(.system(size: 13, weight: .medium))
                Text(L("settings.arena.meeting.caption"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NotificationCenter.default.post(name: .init("HermesPetOpenArena"), object: nil)
                } label: {
                    Label(L("settings.arena.open"), systemImage: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部说明：实验性功能默认全关，不开则日常使用完全不涉及
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(.pink)
                Text(L("settings.experimental.intro"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 屏幕接管 / AI 操作软件
            captionToggle(
                icon: "macwindow.on.rectangle",
                iconColor: .pink,
                title: L("settings.experimental.takeover.title"),
                caption: L("settings.experimental.takeover.caption"),
                isOn: Binding(
                    get: { ExperimentalStore.shared.screenTakeoverEnabled },
                    set: { ExperimentalStore.shared.screenTakeoverEnabled = $0 }
                )
            )

            Divider()

            // 全量模式 / AI 公司舰队（一句话派活 → 满屏 agent 并发 → 质检 → 收进博物馆）
            captionToggle(
                icon: "bolt.fill",
                iconColor: .pink,
                title: L("settings.experimental.fleet.title"),
                caption: L("settings.experimental.fleet.caption"),
                isOn: Binding(
                    get: { ExperimentalStore.shared.fleetModeEnabled },
                    set: { ExperimentalStore.shared.fleetModeEnabled = $0 }
                )
            )

            Divider()

            // 画布模式（从「系统」分栏移过来，实验性功能集中管理）
            captionToggle(
                icon: "rectangle.3.group",
                iconColor: .pink,
                title: L("settings.system.canvas.title"),
                caption: L("settings.system.canvas.caption"),
                isOn: $canvasModeEnabled
            )

            Spacer()
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 在线 AI 工具调用前是否要用户审批 —— 默认关（行为同 v1.2.x），开了之后
            // 灵动岛会在 AI 想跑 Edit/Write/Bash 等工具时弹卡片让 Allow/Always/Deny
            captionToggle(
                icon: "checkmark.shield.fill",
                iconColor: .orange,
                title: L("settings.privacy.permissionUI.title"),
                caption: L("settings.privacy.permissionUI.caption"),
                isOn: $viewModel.permissionUIEnabled
            )

            Divider()

            captionToggle(
                icon: "eye.fill",
                iconColor: .indigo,
                title: L("settings.privacy.activity.title"),
                caption: L("settings.privacy.activity.caption"),
                isOn: $viewModel.activityRecordingEnabled
            )

            // 隐私保障说明卡片
            VStack(alignment: .leading, spacing: 6) {
                privacyTip(icon: "lock.fill", text: L("settings.privacy.activity.tip.local"))
                privacyTip(icon: "keyboard", text: L("settings.privacy.activity.tip.keyboard"))
                privacyTip(icon: "bubble.left.and.bubble.right.fill", text: L("settings.privacy.activity.tip.chat"))
                privacyTip(icon: "key.fill", text: L("settings.privacy.activity.tip.sensitive"))
                privacyTip(icon: "trash", text: L("settings.privacy.activity.tip.cleanup"))
            }
            .padding(12)
            .background(Color.indigo.opacity(0.06))
            .cornerRadius(8)

            Divider()

            // 早报后端选择 —— 早报会汇总你昨天的活动 + 跟 AI 的对话主题给某个 AI 处理，
            // 让用户明确选择哪家服务商能看到这些数据
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("settings.privacy.briefing.backendLabel"), systemImage: "newspaper.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $viewModel.morningBriefingBackend) {
                        // M5: 早报后端只能选 enabled 的 mode（选 disabled 的也用不了）
                        ForEach(AgentMode.allCases.filter { EnabledModesStore.shared.isEnabled($0) }) { mode in
                            Text(L(mode.labelKey)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                Text(L("settings.privacy.briefing.backendCaption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 会议纪要整理后端 —— 整理是纯文本任务，默认「在线 AI」最快（Claude/Codex 起子进程慢）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("settings.privacy.meeting.backendLabel"), systemImage: "waveform.badge.mic")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $viewModel.meetingSummaryBackend) {
                        ForEach(AgentMode.allCases.filter { EnabledModesStore.shared.isEnabled($0) }) { mode in
                            Text(L(mode.labelKey)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                Text(L("settings.privacy.meeting.backendCaption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 日报 / 回顾风格（Phase 4-B）—— 全局口吻，早报和周期回顾共用
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L("settings.privacy.briefing.styleLabel"), systemImage: "paintpalette.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { BriefingStyle(rawValue: briefingStyleRaw) ?? .warm },
                        set: { briefingStyleRaw = $0.rawValue }
                    )) {
                        ForEach(BriefingStyle.allCases) { style in
                            Text(L(style.labelKey)).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                Text(L("settings.privacy.briefing.styleCaption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 今日统计（实时）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("settings.privacy.todayActivity.label"), systemImage: "chart.bar.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        refreshActivityStats()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(L("settings.common.refresh"))
                }

                if activityTodayStats.isEmpty {
                    Text(viewModel.activityRecordingEnabled
                         ? L("settings.privacy.todayActivity.noDataEnabled")
                         : L("settings.privacy.todayActivity.recordingOff"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(activityTodayStats.prefix(5)) { stat in
                        HStack {
                            Text(stat.appName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Text(formatDuration(stat.totalSeconds))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if activityTodayStats.count > 5 {
                        Text(L("settings.privacy.todayActivity.moreApps", activityTodayStats.count - 5))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // 清空按钮
            HStack {
                Spacer()
                Button(role: .destructive) {
                    showClearActivityConfirm = true
                } label: {
                    Label(L("settings.privacy.clearActivity.button"), systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    L("settings.privacy.clearActivity.confirmTitle"),
                    isPresented: $showClearActivityConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L("settings.common.confirmClear"), role: .destructive) {
                        ActivityRecorder.shared.clearAll()
                        refreshActivityStats()
                    }
                    Button(L("settings.common.reset"), role: .cancel) {}
                } message: {
                    Text(L("settings.privacy.clearActivity.confirmMessage"))
                }
            }

            // —— v1.3 意图感知 ——
            Divider()
            userIntentSection

            // —— v1.3 成长轨迹（日报归档时间线）——
            Divider()
            growthTimelineSection

            // —— v1.3 共享记忆（跨模式 user-memory.md）——
            Divider()
            userMemorySection
        }
        .onAppear {
            refreshActivityStats()
            refreshIntentStats()
            loadBlacklist()
            loadObservations()
            loadJournals()
            loadUserMemory()
        }
    }

    /// 意图感知开关 + 简介 + 今日采样数 + 清空按钮（v1.3 Phase 1）
    private var userIntentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            captionToggle(
                icon: "brain.head.profile",
                iconColor: .purple,
                title: L("settings.privacy.intent.title"),
                caption: L("settings.privacy.intent.caption"),
                isOn: Binding(
                    get: { userIntentEnabled },
                    set: { newVal in
                        userIntentEnabled = newVal
                        UserIntentRecorder.shared.setEnabled(newVal)
                        refreshIntentStats()
                    }
                )
            )

            // 隐私说明卡片 —— Wave E4 扩到 6 条，覆盖"存储 / 网络 / 黑名单 / 单条删 / 反馈可关 / 自动过期"
            VStack(alignment: .leading, spacing: 6) {
                privacyTip(icon: "lock.fill", text: L("settings.privacy.intent.tip.local"))
                privacyTip(icon: "wifi.slash", text: L("settings.privacy.intent.tip.offline"))
                privacyTip(icon: "eye.slash.fill", text: L("settings.privacy.intent.tip.sensitive"))
                privacyTip(icon: "hand.raised.fill", text: L("settings.privacy.intent.tip.delete"))
                privacyTip(icon: "speaker.slash.fill", text: L("settings.privacy.intent.tip.feedback"))
                privacyTip(icon: "clock.arrow.circlepath", text: L("settings.privacy.intent.tip.expire"))
            }
            .padding(12)
            .background(Color.purple.opacity(0.06))
            .cornerRadius(8)

            // Wave C4：只有功能启用时才显示运行时数据 + 反馈偏好。
            // 关闭功能时这些 UI 隐藏，避免给"功能关着却显示统计"的错觉
            if userIntentEnabled {
                Divider().padding(.vertical, 2)

                // 主出场偏好（Wave C4）
                HStack {
                    Label(L("settings.privacy.intent.channelLabel"), systemImage: "rectangle.3.group.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $intentChannelPreferenceRaw) {
                        Text(L("settings.privacy.intent.channel.auto")).tag("auto")
                        Text(L("settings.privacy.intent.channel.pet")).tag("pet")
                        Text(L("settings.privacy.intent.channel.island")).tag("island")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .labelsHidden()
                }

                // 反馈频率（Wave C5）
                HStack {
                    Label(L("settings.privacy.intent.freqLabel"), systemImage: "speedometer")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $intentFeedbackPerMinute) {
                        Text(L("settings.privacy.intent.freq.quiet")).tag(1)
                        Text(L("settings.privacy.intent.freq.medium")).tag(2)
                        Text(L("settings.privacy.intent.freq.frequent")).tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .labelsHidden()
                }

                // 今日采样数
                HStack {
                    Label(L("settings.privacy.intent.todaySampled"), systemImage: "camera.viewfinder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(L("settings.privacy.intent.todaySampled.count", userIntentTodayCount))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                    Button {
                        refreshIntentStats()
                        loadObservations()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }

                // Wave E1：今日观察折叠列表
                observationListSection

                // Wave E3：黑名单管理（仅在有自定义黑名单时显示，避免 UI 冗余）
                if !userBlacklist.isEmpty {
                    blacklistSection
                }

                // 清空 + 导出（Wave E5）按钮组
                HStack {
                    Spacer()
                    Button {
                        exportIntentsToJSON()
                    } label: {
                        Label(L("settings.privacy.intent.exportJSON"), systemImage: "square.and.arrow.up")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        showClearIntentConfirm = true
                    } label: {
                        Label(L("settings.privacy.intent.clearButton"), systemImage: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        L("settings.privacy.intent.clearConfirmTitle"),
                        isPresented: $showClearIntentConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L("settings.common.confirmClear"), role: .destructive) {
                            ActivityRecorder.shared.queryStore.clearUserIntents()
                            refreshIntentStats()
                            loadObservations()
                        }
                        Button(L("settings.common.reset"), role: .cancel) {}
                    } message: {
                        Text(L("settings.privacy.intent.clearConfirmMessage"))
                    }
                }
            }
        }
    }

    /// 刷新"今日意图采样次数"
    private func refreshIntentStats() {
        // 直接走 SELECT COUNT(*)，不再拉全表行 + 整屏 OCR 文本（旧写法在采样多时主线程卡顿）。
        // COUNT 还更准（当日凌晨起算，而非近 24h 近似）
        userIntentTodayCount = ActivityRecorder.shared.queryStore.todayIntentCount()
    }

    // MARK: - Wave E1：今日观察列表

    /// 折叠的观察列表区块（点击标题展开，限高 240pt 内部滚动）
    private var observationListSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题行：可点击展开 / 收起
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showObservationList.toggle()
                    if showObservationList { loadObservations() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showObservationList ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Label(L("settings.privacy.observation.title"), systemImage: "list.bullet.below.rectangle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showObservationList && !intentObservations.isEmpty {
                        Text(observationSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showObservationList {
                if intentObservations.isEmpty {
                    Text(L("settings.privacy.observation.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(intentObservations, id: \.id) { item in
                                observationRow(item)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 240)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(6)
                }
            }
        }
    }

    /// 单条观察记录（时间 + app 名 + window title + OCR 摘要 + 操作菜单）
    private func observationRow(_ item: UserIntent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(observationTime(item))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.appName ?? "?")
                        .font(.system(size: 11, weight: .medium))
                    if item.isBlacklisted {
                        Text(L("settings.privacy.observation.metaOnly"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let title = item.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let ocr = item.ocrText, !ocr.isEmpty {
                    Text(ocr.prefix(60))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                if let bid = item.appBundleID, !bid.isEmpty,
                   !userBlacklist.contains(bid) {
                    Button {
                        addToBlacklist(bundleID: bid, appName: item.appName)
                    } label: {
                        Label(L("settings.privacy.observation.dontRecord", item.appName ?? bid), systemImage: "eye.slash")
                    }
                }
                Button(role: .destructive) {
                    deleteObservation(id: item.id)
                } label: {
                    Label(L("settings.privacy.observation.deleteThis"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(4)
    }

    /// "今天 X 次 · 跨 Y 个应用"
    private var observationSummary: String {
        let count = intentObservations.count
        let uniqueApps = Set(intentObservations.compactMap { $0.appBundleID }).count
        return L("settings.privacy.observation.summary", count, uniqueApps)
    }

    private func observationTime(_ item: UserIntent) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: item.timestamp)
    }

    private func loadObservations() {
        // 取今天的所有意图记录（按 timestamp 倒序）
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let all = ActivityRecorder.shared.queryStore.recentUserIntents(limit: 500)
        intentObservations = all.filter { $0.timestamp >= startOfDay }
    }

    private func deleteObservation(id: Int) {
        ActivityRecorder.shared.queryStore.deleteUserIntent(id: id)
        loadObservations()
        refreshIntentStats()
    }

    // MARK: - v1.3 Phase 3：成长轨迹（daily_journal 时间线）

    /// 折叠的"成长轨迹"区块 —— 每天的回顾会存成一条日报，攒成使用轨迹。
    /// 点日期行展开看当天回顾全文；可单条删 / 一键清空。全部本地存储。
    private var growthTimelineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showGrowthTimeline.toggle()
                    if showGrowthTimeline { loadJournals() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showGrowthTimeline ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Label(L("settings.privacy.growth.title"), systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showGrowthTimeline && !journalEntries.isEmpty {
                        Text(L("settings.privacy.growth.days", journalEntries.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showGrowthTimeline {
                Text(L("settings.privacy.growth.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if journalEntries.isEmpty {
                    Text(L("settings.privacy.growth.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(journalEntries) { entry in
                                journalRow(entry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(6)

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            showClearJournalConfirm = true
                        } label: {
                            Label(L("settings.privacy.growth.clearButton"), systemImage: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .confirmationDialog(
                            L("settings.privacy.growth.clearConfirmTitle"),
                            isPresented: $showClearJournalConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(L("settings.common.confirmClear"), role: .destructive) {
                                ActivityRecorder.shared.queryStore.clearDailyJournal()
                                loadJournals()
                            }
                            Button(L("settings.common.reset"), role: .cancel) {}
                        } message: {
                            Text(L("settings.privacy.growth.clearConfirmMessage"))
                        }
                    }
                }
            }
        }
    }

    /// 单条日报行：日期 + 一行预览，点开展开当天回顾全文；尾部菜单可删这天
    private func journalRow(_ entry: DailyJournalEntry) -> some View {
        let expanded = expandedJournalDate == entry.date
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.date)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                Text(journalPreview(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 1)
                Spacer(minLength: 4)
                Menu {
                    Button(role: .destructive) {
                        deleteJournal(date: entry.date)
                    } label: {
                        Label(L("settings.privacy.growth.deleteThisDay"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
            if expanded {
                Text(strippedJournal(entry.summaryMarkdown))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 82)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedJournalDate = expanded ? nil : entry.date
            }
        }
    }

    /// 去掉正文里的 ```docs 围栏（那是给聊天渲染可点卡片用的，纯文本预览里不显示）
    private func strippedJournal(_ md: String) -> String {
        guard let start = md.range(of: "```docs") else {
            return md.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = String(md[..<start.lowerBound])
        // 跳过到对应的结尾 ``` 之后（若有）
        if let end = md.range(of: "```", range: start.upperBound..<md.endIndex) {
            result += String(md[end.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一行预览：取首个非空行，去掉 markdown 标记符号，截 60 字
    private func journalPreview(_ entry: DailyJournalEntry) -> String {
        let text = strippedJournal(entry.summaryMarkdown)
        let firstLine = text
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*-· "))
            .replacingOccurrences(of: "**", with: "")
        return String(cleaned.prefix(60))
    }

    private func loadJournals() {
        journalEntries = ActivityRecorder.shared.queryStore.recentDailyJournals(limit: 60)
    }

    private func deleteJournal(date: String) {
        ActivityRecorder.shared.queryStore.deleteDailyJournal(date: date)
        loadJournals()
    }

    // MARK: - v1.3 Phase 4a：共享记忆（跨模式 user-memory.md）

    /// 共享记忆区：总开关 + 可编辑全文 + 保存 / 清空。
    /// 一份所有 AI 共享的"用户记忆"，每天早报时自动修订；用户也可手写让所有 AI 都知道的事。
    private var userMemorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            captionToggle(
                icon: "brain.fill",
                iconColor: .teal,
                title: L("settings.privacy.memory.title"),
                caption: L("settings.privacy.memory.caption"),
                isOn: Binding(
                    get: { userMemoryEnabled },
                    set: { userMemoryEnabled = $0 }
                )
            )

            if userMemoryEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L("settings.privacy.memory.contentLabel"), systemImage: "doc.text")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L("settings.privacy.memory.charCount", userMemoryText.count, UserMemoryStore.maxChars))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    TextEditor(text: $userMemoryText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 160)
                        .padding(6)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.primary.opacity(0.1), lineWidth: 0.5)
                        )
                        .onChange(of: userMemoryText) { _, _ in userMemoryDirty = true }

                    if userMemoryText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(L("settings.privacy.memory.empty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    HStack {
                        Button {
                            saveUserMemory()
                        } label: {
                            Label(L("settings.privacy.memory.save"), systemImage: "checkmark")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!userMemoryDirty)

                        Spacer()

                        Button(role: .destructive) {
                            showClearMemoryConfirm = true
                        } label: {
                            Label(L("settings.privacy.memory.clear"), systemImage: "trash")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .confirmationDialog(
                            L("settings.privacy.memory.clearConfirmTitle"),
                            isPresented: $showClearMemoryConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(L("settings.common.confirmClear"), role: .destructive) {
                                UserMemoryStore.shared.clear()
                                loadUserMemory()
                            }
                            Button(L("settings.common.reset"), role: .cancel) {}
                        } message: {
                            Text(L("settings.privacy.memory.clearConfirmMessage"))
                        }
                    }
                }
            }
        }
    }

    private func loadUserMemory() {
        userMemoryText = UserMemoryStore.shared.load()
        userMemoryDirty = false
    }

    private func saveUserMemory() {
        UserMemoryStore.shared.save(userMemoryText)
        loadUserMemory()   // 回读（应用了截断等），并清 dirty
    }

    // MARK: - Wave E2 + E3：黑名单

    /// 黑名单管理 section（仅有自定义黑名单时显示）
    private var blacklistSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(L("settings.privacy.blacklist.title"), systemImage: "eye.slash.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("settings.privacy.blacklist.count", userBlacklist.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 3) {
                ForEach(userBlacklist, id: \.self) { bundleID in
                    HStack {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(bundleID)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeFromBlacklist(bundleID: bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(4)
                }
            }
        }
    }

    private func loadBlacklist() {
        userBlacklist = UserDefaults.standard.array(forKey: "userIntentAppBlacklist") as? [String] ?? []
    }

    private func addToBlacklist(bundleID: String, appName: String?) {
        var arr = userBlacklist
        guard !arr.contains(bundleID) else { return }
        arr.append(bundleID)
        UserDefaults.standard.set(arr, forKey: "userIntentAppBlacklist")
        userBlacklist = arr
        NSLog("[UserIntent] 已加黑名单：\(appName ?? bundleID)")
    }

    private func removeFromBlacklist(bundleID: String) {
        let arr = userBlacklist.filter { $0 != bundleID }
        UserDefaults.standard.set(arr, forKey: "userIntentAppBlacklist")
        userBlacklist = arr
    }

    // MARK: - Wave E5：导出 JSON

    private func exportIntentsToJSON() {
        // 拉今日所有意图记录
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let all = ActivityRecorder.shared.queryStore.recentUserIntents(limit: 5000)
        let today = all.filter { $0.timestamp >= startOfDay }

        // 构造可读 JSON
        struct ExportRow: Codable {
            let timestamp: String
            let trigger: String
            let app: String?
            let windowTitle: String?
            let ocrText: String?
            let isBlacklisted: Bool
        }
        let fmt = ISO8601DateFormatter()
        let rows = today.map { item in
            ExportRow(
                timestamp: fmt.string(from: item.timestamp),
                trigger: item.triggerType.rawValue,
                app: item.appName,
                windowTitle: item.windowTitle,
                ocrText: item.ocrText,
                isBlacklisted: item.isBlacklisted
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rows) else {
            NSLog("[UserIntent] 导出 JSON 编码失败")
            return
        }

        // NSSavePanel 让用户选保存位置
        let panel = NSSavePanel()
        panel.title = L("settings.privacy.export.panelTitle")
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "HermesPet-intents-\(fileFmt.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                NSLog("[UserIntent] 已导出到 \(url.path) (\(rows.count) 条)")
            } catch {
                NSLog("[UserIntent] 导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func privacyTip(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.indigo)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshActivityStats() {
        // 在主 actor 取 store 引用（ActivityStore 是 @unchecked Sendable，可跨线程），
        // SQLite 聚合 + 查询挪到后台跑，结果回主 actor 赋值，避免打开隐私页时主线程同步阻塞（perf）
        let store = ActivityRecorder.shared.queryStore
        Task {
            let stats = await Task.detached(priority: .userInitiated) { () -> [AppDailyStat] in
                store.aggregateDailyStats(for: Date())   // async 入队，串行队列保序，dailyStats 读到聚合后的数据
                return store.dailyStats(for: Date())
            }.value
            activityTodayStats = stats
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - 灵动岛 / 灵动胶囊

    /// 独立分类：所有跟「顶部胶囊形态 + 摆位」相关的设置。
    /// 后续灵动岛功能扩展（特效开关、动效强度等）都加到这里，跟系统设置解耦。
    private var islandSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // —— 显示模式（刘海 / 悬浮胶囊 / 自动）——
            displayModeRow

            Divider()

            // —— 多显示器：固定到哪块屏 ——
            islandScreenRow
        }
    }

    // MARK: - 系统

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // —— 手机连接地址（测试用：实时显示手机 App 该填的局域网地址）——
            phoneLinkRow

            Divider()

            // —— 语言（v1.4 中英双语，应用内即时切换）——
            languageRow

            Divider()

            // —— 聊天字号 ——
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.indigo)
                    Text(L("settings.system.fontSize.title"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(chatFontScale * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // 滑块（左右拖拽，比 10 档 segmented 省空间）—— 映射到 presets 的离散档位
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: {
                                Double(ChatFontScale.presets.enumerated()
                                    .min(by: { abs($0.element - chatFontScale) < abs($1.element - chatFontScale) })?.offset ?? 3)
                            },
                            set: { chatFontScale = ChatFontScale.presets[min(max(Int($0.rounded()), 0), ChatFontScale.presets.count - 1)] }
                        ),
                        in: 0...Double(ChatFontScale.presets.count - 1),
                        step: 1
                    )
                    Image(systemName: "textformat.size").font(.system(size: 17)).foregroundStyle(.secondary)
                }

                Text(L("settings.system.fontSize.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            captionToggle(
                icon: "power.circle.fill",
                iconColor: .blue,
                title: L("settings.system.launchAtLogin.title"),
                caption: L("settings.system.launchAtLogin.caption"),
                isOn: Binding(
                    get: { viewModel.isLaunchAtLoginOn },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )

            Divider()

            captionToggle(
                icon: "dock.rectangle",
                iconColor: .indigo,
                title: L("settings.system.dockIcon.title"),
                caption: L("settings.system.dockIcon.caption"),
                isOn: $viewModel.showDockIcon
            )

            Divider()

            captionToggle(
                icon: "hand.tap.fill",
                iconColor: .purple,
                title: L("settings.system.haptic.title"),
                caption: L("settings.system.haptic.caption"),
                isOn: $viewModel.hapticEnabled
            )
        }
    }

    // MARK: - 手机连接地址（测试辅助）
    //
    // 测试阶段手机要连电脑，但电脑 Wi-Fi 的 IP 是动态的、会变。
    // 这里实时显示「手机该填的地址」，IP 变了 3 秒内自动更新，省得每次去查文件。

    private var phoneLinkRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .foregroundStyle(.green)
                Text("手机连接地址（测试）")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            // 每 3 秒重算一次：换了 Wi-Fi、IP 变了，这里会自动跟着变
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let addr = phoneEndpoint()
                HStack(spacing: 10) {
                    Text(addr)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(addr, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制地址")
                }
                .padding(10)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("在手机 App「设置 → 我的电脑」里填这个地址。换了 Wi-Fi 地址会变，这里实时显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 当前手机该连的局域网地址（IP:端口）。端口为 0 表示服务还没起来。
    @MainActor private func phoneEndpoint() -> String {
        let ip = CommandServer.localIPAddress() ?? "未联网"
        let port = CommandServer.shared.port
        return port > 0 ? "\(ip):\(port)" : "\(ip)（服务未启动）"
    }

    /// 语言选择（中文 / English）—— 切换即时生效。
    /// 在 body 调 L(...) → Observation 自动追踪 LocaleManager.language → 切语言自动重渲染。
    private var languageRow: some View {
        @Bindable var locale = LocaleManager.shared
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.teal)
                Text(L("system.language.title"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            Picker(L("system.language.title"), selection: $locale.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(L("system.language.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 字号档位 segmented Picker 的显示文字
    private func scaleLabel(_ scale: Double) -> String {
        switch scale {
        case 0.85: return L("settings.system.fontSize.small")
        case 1.0:  return L("settings.system.fontSize.standard")
        case 1.15: return L("settings.system.fontSize.large")
        case 1.30: return L("settings.system.fontSize.larger")
        case 1.50: return L("settings.system.fontSize.huge")
        default:   return "\(Int(scale * 100))%"
        }
    }

    // MARK: - 显示模式（灵动岛 / 悬浮胶囊 切换）

    private var displayModeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "macbook.gen2")
                    .foregroundStyle(.purple)
                Text(L("settings.system.display.title"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            Picker(L("settings.system.display.title"), selection: $displayModeRaw) {
                Text(L("settings.system.display.auto")).tag(DisplayMode.auto.rawValue)
                Text(L("settings.system.display.notch")).tag(DisplayMode.notch.rawValue)
                Text(L("settings.system.display.floating")).tag(DisplayMode.floating.rawValue)
                Text(L("settings.system.display.mini")).tag(DisplayMode.mini.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: displayModeRaw) { _, _ in
                pendingRestartFromDisplayMode = true
            }

            Text(L("settings.system.display.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(L("settings.system.display.restartTitle"), isPresented: $pendingRestartFromDisplayMode) {
            Button(L("settings.system.display.restartLater")) {
                pendingRestartFromDisplayMode = false
            }
            Button(L("settings.system.display.restartNow")) {
                relaunchApp()
            }
        } message: {
            Text(L("settings.system.display.restartMessage"))
        }
    }

    /// 「灵动岛显示在哪块屏」选择器（多显示器）。
    /// 第一项「跟随我所在的屏幕」= 鼠标在哪块屏灵动岛就在哪块；后面把当前接着的每块屏列出来供固定。
    /// 即时生效（无需重启）：选完发通知，DynamicIslandController 立即重摆位。
    private var islandScreenRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.purple)
                Text(L("settings.system.islandScreen.title"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            Picker(L("settings.system.islandScreen.title"), selection: $islandScreenChoiceRaw) {
                Text(L("settings.system.islandScreen.follow")).tag(IslandScreenChoice.followRaw)
                ForEach(islandScreenOptions, id: \.id) { opt in
                    Text(opt.name).tag(opt.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: islandScreenChoiceRaw) { _, _ in
                NotificationCenter.default.post(name: IslandScreenChoice.changedNotification, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                islandScreenListVersion += 1   // 插拔屏 → 刷新下拉
            }

            Text(L("settings.system.islandScreen.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 当前可固定的屏幕项（随插拔屏刷新）。若用户当前固定的屏已断开，额外补一项占位，保持 Picker 选中态不丢。
    private var islandScreenOptions: [(id: String, name: String)] {
        _ = islandScreenListVersion   // 读一下建立依赖，插拔屏时强制重算
        var opts: [(id: String, name: String)] = NSScreen.screens.compactMap { screen in
            guard let did = screen.displayID else { return nil }
            return (id: String(did), name: islandScreenDisplayName(screen))
        }
        // 固定的屏被拔掉 → 补占位项，避免下拉显示空白（用户能看到"之前选的屏断了"再改）
        if islandScreenChoiceRaw != IslandScreenChoice.followRaw,
           !opts.contains(where: { $0.id == islandScreenChoiceRaw }) {
            opts.append((id: islandScreenChoiceRaw, name: L("settings.system.islandScreen.disconnected")))
        }
        return opts
    }

    /// 屏幕显示名：优先系统 localizedName（macOS 14+），否则按是否带刘海给个友好名。
    private func islandScreenDisplayName(_ screen: NSScreen) -> String {
        if #available(macOS 14.0, *) {
            let n = screen.localizedName
            if !n.isEmpty { return n }
        }
        return screen.safeAreaInsets.top > 0
            ? L("settings.system.islandScreen.builtin")
            : L("settings.system.islandScreen.external")
    }

    /// 重启 app：用 NSWorkspace 重新打开自己 + terminate 当前进程
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .cornerRadius(12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.blue, .purple],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "pawprint.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                        )
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("HermesPet").font(.system(size: 16, weight: .semibold))
                    Text("v\(UpdateChecker.shared.currentVersion)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(L("settings.about.tagline"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            updateSection

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                aboutRow(icon: "folder.fill", label: L("settings.about.storageLocation"), value: "~/.hermespet/")
            }

            Divider()

            feedbackSection

            Divider()

            authenticitySection

            Divider()

            creditsSection
        }
        .onAppear {
            CrashReporter.shared.scan()
        }
    }

    /// **官方版本验证 / 防伪段（U8）**
    /// 读 app 自身的 codesign Team ID，跟原作者已知 Team ID 比对。
    /// 让用户能识别"我装的是不是从原作者那下载的正版"
    @ViewBuilder
    private var authenticitySection: some View {
        let result = CodeSignVerifier.verify()
        let (dotColor, headlineColor): (Color, Color) = {
            switch result {
            case .officialSignature: return (.green,  .green)
            case .adHocSignature:    return (.orange, .secondary)
            case .thirdPartySignature, .unsigned: return (.red, .red)
            case .unknown:           return (.gray, .secondary)
            }
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(dotColor)
                    .frame(width: 16)
                Text(L("settings.about.auth.title"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(authShortLabel(result))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(headlineColor)
            }

            Text(authDetailText(result))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 官方下载源提示 + 跳转按钮
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.indigo)
                Text(L("settings.about.auth.officialSource"))
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Link("GitHub Releases", destination: URL(string: CodeSignVerifier.officialReleasesURL)!)
                    .font(.system(size: 11))
            }

            // 防伪提醒
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(L("settings.about.auth.disclaimer"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(dotColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(dotColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    /// 官方版本验证的状态短标签（i18n）—— 对应 CodeSignVerifier.Result
    private func authShortLabel(_ r: CodeSignVerifier.Result) -> String {
        switch r {
        case .officialSignature:   return L("settings.about.auth.status.official.short")
        case .adHocSignature:      return L("settings.about.auth.status.adhoc.short")
        case .thirdPartySignature: return L("settings.about.auth.status.thirdParty.short")
        case .unsigned:            return L("settings.about.auth.status.unsigned.short")
        case .unknown:             return L("settings.about.auth.status.unknown.short")
        }
    }

    /// 官方版本验证的详细说明（i18n，动态 Team ID / 原因用 %@ 占位）
    private func authDetailText(_ r: CodeSignVerifier.Result) -> String {
        switch r {
        case .officialSignature:
            return L("settings.about.auth.status.official.detail", CodeSignVerifier.officialTeamID)
        case .adHocSignature:
            return L("settings.about.auth.status.adhoc.detail")
        case .thirdPartySignature(let id):
            return L("settings.about.auth.status.thirdParty.detail", id)
        case .unsigned:
            return L("settings.about.auth.status.unsigned.detail")
        case .unknown(let reason):
            return L("settings.about.auth.status.unknown.detail", reason)
        }
    }

    /// 问题反馈区 —— 扫描 ~/Library/Logs/DiagnosticReports/ 找 HermesPet 崩溃日志，
    /// 一键复制 + 跳转 GitHub issue 让用户提交（零后端 / 零隐私顾虑）
    @ViewBuilder
    private var feedbackSection: some View {
        let reporter = CrashReporter.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 16)
                Text(L("settings.about.feedback.title"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }

            if let crash = reporter.latestCrash {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("settings.about.feedback.crashDetected"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("v\(crash.appVersion) · \(crash.exceptionType)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(relativeTime(from: crash.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            reporter.reportToGitHub(crash)
                        } label: {
                            Label(L("settings.about.feedback.reportGitHub"), systemImage: "paperplane.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            reporter.revealInFinder(crash)
                        } label: {
                            Label(L("settings.about.feedback.revealFinder"), systemImage: "folder")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if reporter.allCrashes.count > 1 {
                        Text(L("settings.about.feedback.history", reporter.allCrashes.count, relativeTime(from: reporter.allCrashes.last!.date)))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L("settings.about.feedback.noCrash"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        reporter.openBlankIssue()
                    } label: {
                        Label(L("settings.about.feedback.openIssue"), systemImage: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text(L("settings.about.feedback.note"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// 作者署名 + 社区贡献者致谢。点击贡献者可跳到对应 GitHub 主页。
    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(L("settings.about.credits.author"))
                    .font(.system(size: 12))
                Spacer()
                Link("Basion", destination: URL(string: "https://github.com/basionwang-bot")!)
                    .font(.system(size: 12, weight: .medium))
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink.opacity(0.85))
                    .frame(width: 16)
                Text(L("settings.about.credits.contributors"))
                    .font(.system(size: 12))
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Link("Heartcoolman",
                             destination: URL(string: "https://github.com/Heartcoolman")!)
                        Text("·").foregroundStyle(.secondary)
                        Link("simpledavid",
                             destination: URL(string: "https://github.com/simpledavid")!)
                        Text("·").foregroundStyle(.secondary)
                        Link("CoimgRain",
                             destination: URL(string: "https://github.com/CoimgRain")!)
                    }
                    .font(.system(size: 11, weight: .medium))
                    Link(L("settings.about.credits.allContributors"),
                         destination: URL(string: "https://github.com/basionwang-bot/HermesPet/graphs/contributors")!)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "star.bubble.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(L("settings.about.credits.repo"))
                    .font(.system(size: 12))
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/basionwang-bot/HermesPet")!)
                    .font(.system(size: 12))
            }

            Text(L("settings.about.credits.thanks"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.top, 4)
        }
    }

    /// 更新检查区。GitHub Release API 拉最新 tag 对比 + 一键下载 DMG 引导安装
    @ViewBuilder
    private var updateSection: some View {
        let checker = UpdateChecker.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: checker.hasUpdate ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(checker.hasUpdate ? .orange : .green)
                    .frame(width: 16)
                if checker.hasUpdate, let latest = checker.latestVersion {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.about.update.available", latest))
                            .font(.system(size: 13, weight: .medium))
                        Text(L("settings.about.update.current", checker.currentVersion))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.about.update.upToDate"))
                            .font(.system(size: 13))
                        if let at = checker.lastCheckedAt {
                            Text(L("settings.about.update.lastChecked", relativeTime(from: at)))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if checker.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView(value: checker.downloadProgress)
                            .frame(width: 80)
                        Text("\(Int(checker.downloadProgress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else if checker.hasUpdate {
                    Button {
                        Task { await checker.downloadAndInstall() }
                    } label: {
                        Label(L("settings.about.update.downloadInstall"), systemImage: "arrow.down.app.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await checker.check(silently: false) }
                    } label: {
                        Label(checker.isChecking ? L("settings.about.update.checking") : L("settings.about.update.checkUpdate"),
                              systemImage: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(checker.isChecking)
                }
            }

            if let err = checker.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }

            if checker.hasUpdate, !checker.latestNotes.isEmpty {
                DisclosureGroup {
                    Text(checker.latestNotes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    Text(L("settings.about.update.notes"))
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.leading, 26)
            }
        }
    }

    /// "刚刚" / "5 分钟前" / "2 小时前" / "昨天" 相对时间
    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        // Phase 5-4：相对时间跟随界面语言（原硬编码 zh_CN，英文界面也会输出中文「3分钟前」）
        f.locale = Locale(identifier: LocaleManager.currentLanguage() == .zh ? "zh_CN" : "en_US")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// 桌宠尺寸档位名（i18n）—— PetWalkSizeScale.label 是中文，UI 这里走 L()
    private func petSizeLabel(_ scale: Double) -> String {
        switch scale {
        case 0.7:  return L("settings.pet.size.mini")
        case 0.85: return L("settings.pet.size.small")
        case 1.0:  return L("settings.pet.size.default")
        case 1.2:  return L("settings.pet.size.large")
        case 1.5:  return L("settings.pet.size.huge")
        default:   return "\(Int(scale * 100))%"
        }
    }

    // MARK: - 快捷键栏（v1.3.1：从「关于」栏独立出来 + 冲突提示 + 恢复默认）

    /// 快捷键设置栏：说明 + 6 个动作的录制行（带冲突提示）+ 恢复默认按钮
    private var hotkeysSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.hotkey.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(HotkeyAction.allCases) { action in
                    hotkeyRow(action)
                }
            }
            .id(hotkeyRefreshID)

            HStack {
                Spacer()
                Button {
                    for action in HotkeyAction.allCases {
                        action.save(action.defaultHotkey)
                    }
                    hotkeyRefreshID = UUID()
                    NotificationCenter.default.post(name: .hermesPetHotkeysChanged, object: nil)
                } label: {
                    Label(L("settings.hotkey.reset"), systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// 当前哪些动作的快捷键彼此重复 —— 按 storageValue 分组，出现 ≥2 次的组内动作都标冲突。
    /// 用 hotkeyRefreshID 触发的 view 重建天然重算（设置面板只有 6 个动作，O(n²) 可忽略）。
    private func conflictingHotkeyActions() -> Set<HotkeyAction> {
        var byValue: [String: [HotkeyAction]] = [:]
        for action in HotkeyAction.allCases {
            byValue[action.currentHotkey.storageValue, default: []].append(action)
        }
        var result: Set<HotkeyAction> = []
        for (_, actions) in byValue where actions.count > 1 {
            result.formUnion(actions)
        }
        return result
    }

    private func hotkeyRow(_ action: HotkeyAction) -> some View {
        let isConflict = conflictingHotkeyActions().contains(action)
        return HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(L(action.titleKey))
                .font(.system(size: 12))
            if isConflict {
                Text(L("settings.hotkey.conflict"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            HotkeyRecorderButton(
                hotkey: action.currentHotkey,
                onChange: { hotkey in
                    action.save(hotkey)
                    hotkeyRefreshID = UUID()
                    NotificationCenter.default.post(name: .hermesPetHotkeysChanged, object: nil)
                }
            )
        }
    }

    private func aboutRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 通用工具

    private func settingRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    /// 第二项是 L10n key —— 在 Picker 的 ForEach 里用 L(key) 翻译（static let 无法直接调 @MainActor 的 L()）
    static let systemSounds: [(String, String)] = [
        ("",          "settings.sound.option.mute"),
        ("Funk",      "settings.sound.option.funk"),
        ("Hero",      "settings.sound.option.hero"),
        ("Glass",     "settings.sound.option.glass"),
        ("Tink",      "settings.sound.option.tink"),
        ("Ping",      "settings.sound.option.ping"),
        ("Pop",       "settings.sound.option.pop"),
        ("Submarine", "settings.sound.option.submarine"),
        ("Sosumi",    "settings.sound.option.sosumi"),
        ("Bottle",    "settings.sound.option.bottle"),
        ("Blow",      "settings.sound.option.blow"),
        ("Frog",      "settings.sound.option.frog"),
        ("Purr",      "settings.sound.option.purr"),
        ("Basso",     "settings.sound.option.basso"),
        ("Morse",     "settings.sound.option.morse")
    ]

    private var modeFooterText: String {
        switch configViewingMode {
        case .hermes:
            return L("settings.backend.footer.hermes")
        case .directAPI:
            return L("settings.backend.footer.directAPI")
        case .openclaw:
            return L("settings.backend.footer.openclaw")
        case .claudeCode:
            return L("settings.backend.footer.claudeCode")
        case .codex:
            return L("settings.backend.footer.codex")
        case .qwenCode:
            return L("settings.backend.qwen.hint")
        }
    }

    /// 测试连接 —— 按当前查看的 configViewingMode 决定测哪一组配置。
    /// Hermes 走 /health；在线 AI 必须真实发一条 chat/completions ping，
    /// 这样才能校验 API Key 是否属于当前服务商、模型是否可用。
    private func testConnection() {
        testing = true
        testResult = nil
        let source: APIClient.ConfigSource = (configViewingMode == .directAPI) ? .direct : .hermes
        let client = APIClient(source: source)
        Task {
            if source == .direct {
                if viewModel.directAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testResult = (false, L("settings.backend.test.needProvider"))
                } else if viewModel.directAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testResult = (false, L("settings.backend.test.needKey"))
                } else if viewModel.directAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testResult = (false, L("settings.backend.test.needModel"))
                } else {
                    do {
                        _ = try await client.sendMessage(messages: [
                            ChatMessage(role: .user, content: "ping")
                        ])
                        testResult = (true, L("settings.backend.test.keyModelOK"))
                    } catch {
                        testResult = (false, directTestErrorMessage(error))
                    }
                }
            } else {
                do {
                    let ok = try await client.checkHealth()
                    testResult = (ok, ok ? L("settings.backend.test.hermesOnline") : L("settings.backend.test.healthFailed"))
                } catch {
                    // 健康检查不通 → 退一步发一条 ping 试试。有些自部署的 Hermes /health 没开
                    do {
                        _ = try await client.sendMessage(messages: [
                            ChatMessage(role: .user, content: "ping")
                        ])
                        testResult = (true, L("settings.backend.test.success"))
                    } catch {
                        testResult = (false, error.localizedDescription)
                    }
                }
            }
            testing = false
        }
    }

    private func directTestErrorMessage(_ error: Error) -> String {
        if case APIError.httpError(let code, let body) = error {
            switch code {
            case 401, 403:
                return L("settings.backend.test.err.keyInvalid")
            case 404:
                return L("settings.backend.test.err.modelNotFound")
            case 429:
                return L("settings.backend.test.err.rateLimited")
            default:
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return "HTTP \(code): \(String(trimmed.prefix(80)))"
                }
                return "HTTP \(code)"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - 快捷键录制按钮

private struct HotkeyRecorderButton: NSViewRepresentable {
    let hotkey: Hotkey
    let onChange: (Hotkey) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSButton {
        let button = HotkeyRecorderNSButton()
        button.bezelStyle = .rounded
        button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        button.setButtonType(.momentaryPushIn)
        button.onCapture = onChange
        button.hotkey = hotkey
        return button
    }

    func updateNSView(_ nsView: HotkeyRecorderNSButton, context: Context) {
        nsView.onCapture = onChange
        nsView.hotkey = hotkey
    }
}

private final class HotkeyRecorderNSButton: NSButton {
    var onCapture: ((Hotkey) -> Void)?
    private var localKeyMonitor: Any?

    var hotkey: Hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey)) {
        didSet {
            if !isRecording {
                title = hotkey.displayText
            }
        }
    }

    private var isRecording = false {
        didSet {
            title = isRecording ? L("settings.about.hotkey.recording") : hotkey.displayText
            contentTintColor = isRecording ? NSColor.controlAccentColor : nil
            if isRecording {
                installKeyMonitor()
            } else {
                removeKeyMonitor()
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        capture(event)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func capture(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        if keyCode == UInt32(kVK_Escape) {
            isRecording = false
            return
        }

        let mods = HotkeyFormatter.carbonModifiers(from: event.modifierFlags)
        // 全局热键必须至少含一个 ⌘ / ⌃ / ⌥，否则普通打字会被劫持。
        // 缺少硬修饰键（裸键 / 仅 ⇧）→ 忽略本次按键、继续录制，等用户按上修饰键。
        let hasHardModifier = (mods & (UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey))) != 0
        guard hasHardModifier else { return }

        let next = Hotkey(keyCode: keyCode, modifiers: mods)
        hotkey = next
        isRecording = false
        onCapture?(next)
    }

}

// MARK: - ModeEnableRow（U1+U2+U3）

/// 一行 mode 开关 + 状态副标题 + 检测结果。
///
/// - 在线 AI：永久 ON 灰掉，副标题"永久启用 · 兜底 AI"
/// - 其他 4 个：Toggle 控制 EnabledModesStore + 自动检测本机状态
/// - 未装时显示"未安装"+ 复制命令按钮
struct ModeEnableRow: View {
    let mode: AgentMode
    /// 一体化列表：是否当前展开（控制箭头方向）
    var isExpanded: Bool = false
    /// 点击行（图标/名字/状态/箭头区，非 Toggle）→ 展开/收起配置卡
    var onTapRow: () -> Void = {}

    @State private var isEnabled: Bool = false
    @State private var statusText: String = ""
    @State private var statusColor: Color = .secondary
    @State private var isDetecting: Bool = false
    @State private var notInstalled: Bool = false
    @State private var installing: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // 点击区（图标 + 名字状态 + 箭头）→ 展开/收起该后端的配置卡
            HStack(spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(modeColor)
                    .background(modeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

                // 名称 + 状态副标题
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(mode.labelKey)).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 4) {
                        if isDetecting {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                        }
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                        if installing {
                            ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 10, height: 10)
                            Text(L("settings.backend.mode.installing"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else if notInstalled, let cmd = installCommand {
                            // ⭐ 一键安装：App 内 spawn 安装命令，免去用户开终端
                            Button { runInstall(cmd) } label: {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .help(L("settings.backend.mode.installHelp"))
                            // 复制命令（手动装的 fallback）
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .help(L("settings.backend.mode.copyInstallHelp", cmd))
                        }
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTapRow() }

            // Toggle 开关（独立，点它只开关、不展开）
            if mode == .directAPI {
                Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
            } else {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        isEnabled = newValue
                        if newValue {
                            EnabledModesStore.shared.enable(mode)
                            detect()
                        } else {
                            EnabledModesStore.shared.disable(mode)
                            statusText = L("settings.backend.mode.disabled")
                            statusColor = .secondary
                            notInstalled = false
                        }
                    }
                )).labelsHidden()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isEnabled ? 0.6 : 0.3))
        )
        .onAppear {
            isEnabled = EnabledModesStore.shared.isEnabled(mode)
            if mode == .directAPI {
                statusText = L("settings.backend.mode.alwaysOn")
                statusColor = .green
            } else if isEnabled {
                detect()
            } else {
                statusText = L("settings.backend.mode.notEnabled")
                statusColor = .secondary
            }
        }
    }

    /// mode 主色（跟其它 UI 一致）
    private var modeColor: Color {
        switch mode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        case .qwenCode:   return .teal
        }
    }

    /// 安装命令（用户没装 CLI/daemon 时：一键安装 spawn 它，或复制到终端手动装）
    private var installCommand: String? {
        switch mode {
        case .directAPI: return nil   // 永远可用
        case .qwenCode:  return "npm install -g @qwen-code/qwen-code"
        case .openclaw:  return "npm install -g openclaw@latest && openclaw onboard --install-daemon"
        case .hermes:    return "pip install hermes-agent"
        case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
        case .codex:     return "npm install -g @openai/codex"
        }
    }

    /// 一键安装：HermesPet 内 spawn 安装命令跑完，再自动重检测 → 变"已连接✓"。
    /// 没 npm / 失败时给提示并保留"复制命令手动装"的兜底。
    private func runInstall(_ cmd: String) {
        installing = true
        Task {
            let result = await CLIInstaller.run(command: cmd)
            installing = false
            switch result {
            case .success:
                await CLIAvailability.invalidateCache()
                detect()   // 重测 → 装好了就变 已连接✓
            case .missingNpm:
                statusText = L("settings.backend.mode.installNeedNode")
                statusColor = .orange
                notInstalled = true
            case .failed:
                statusText = L("settings.backend.mode.installFailed")
                statusColor = .red
                notInstalled = true
            }
        }
    }

    /// 触发检测：根据 mode 调对应的检测器（小白文案：只用"已连接 / 连接中 / 未安装"）
    private func detect() {
        isDetecting = true
        notInstalled = false
        Task { @MainActor in
            switch mode {
            case .directAPI:
                statusText = L("settings.backend.mode.alwaysOn")
                statusColor = .green
            case .openclaw:
                if OpenClawGatewayManager.shared.status == .binaryMissing ||
                   OpenClawGatewayManager.shared.status == .starting {
                    Task.detached { await OpenClawGatewayManager.shared.startIfAvailable() }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                renderOpenClawStatus()
            case .hermes:
                if HermesGatewayManager.shared.status == .binaryMissing {
                    statusText = L("settings.backend.mode.status.notInstalled")
                    statusColor = .orange
                    notInstalled = true
                } else {
                    Task.detached { await HermesGatewayManager.shared.startIfAvailable() }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    renderHermesStatus()
                }
            case .claudeCode:
                let ok = await CLIAvailability.claudeAvailable()
                if ok {
                    statusText = L("settings.backend.mode.ready")
                    statusColor = .green
                } else {
                    statusText = L("settings.backend.mode.status.notInstalled")
                    statusColor = .orange
                    notInstalled = true
                }
            case .codex:
                let ok = await CLIAvailability.codexAvailable()
                if ok {
                    statusText = L("settings.backend.mode.ready")
                    statusColor = .green
                } else {
                    statusText = L("settings.backend.mode.status.notInstalled")
                    statusColor = .orange
                    notInstalled = true
                }
            case .qwenCode:
                // 本机 qwen CLI：跟 Claude/Codex 一样探测是否装好
                let ok = await CLIAvailability.qwenAvailable()
                if ok {
                    statusText = L("settings.backend.mode.ready")
                    statusColor = .green
                } else {
                    statusText = L("settings.backend.mode.status.notInstalled")
                    statusColor = .orange
                    notInstalled = true
                }
            }
            isDetecting = false
        }
    }

    private func renderOpenClawStatus() {
        switch OpenClawGatewayManager.shared.status {
        case .running:
            statusText = L("settings.common.status.connected")
            statusColor = .green
        case .starting:
            statusText = L("settings.common.status.connecting")
            statusColor = .secondary
        case .binaryMissing:
            statusText = L("settings.common.status.notInstalled")
            statusColor = .orange
            notInstalled = true
        case .configMissing:
            statusText = L("settings.backend.openclaw.status.needInit")
            statusColor = .orange
        case .endpointDisabled:
            statusText = L("settings.backend.openclaw.status.autoConfiguring")
            statusColor = .orange
        case .failed:
            statusText = L("settings.common.status.connectFailed")
            statusColor = .red
        case .disabled:
            statusText = L("settings.common.status.autoConnectOff")
            statusColor = .secondary
        }
    }

    private func renderHermesStatus() {
        switch HermesGatewayManager.shared.status {
        case .running, .external:
            statusText = L("settings.common.status.connected")
            statusColor = .green
        case .starting:
            statusText = L("settings.common.status.connecting")
            statusColor = .secondary
        case .binaryMissing:
            statusText = L("settings.common.status.notInstalled")
            statusColor = .orange
            notInstalled = true
        case .failed:
            statusText = L("settings.common.status.connectFailed")
            statusColor = .red
        case .disabled:
            statusText = L("settings.common.status.autoConnectOff")
            statusColor = .secondary
        }
    }
}
