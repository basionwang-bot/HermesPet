import SwiftUI
import Carbon
import UniformTypeIdentifiers

/// 设置面板 —— macOS Sonoma 系统设置风格：
/// - 左侧 156pt 侧栏分类列表
/// - 右侧 ScrollView 详情区，分类标题 + 内容卡片
/// - 5 类：AI 后端 / 桌宠 / 音效 / 系统 / 关于
struct SettingsView: View {
    @Bindable var viewModel: ChatViewModel

    @State private var selectedCategory: Category = .backend
    @State private var showKey = false
    @State private var testing = false
    @State private var testResult: (success: Bool, message: String)?
    @State private var hotkeyRefreshID = UUID()
    /// 画布模式开关（实验性功能）—— ChatView 的 + 菜单根据这个 flag 决定是否显示"新建画布"
    @AppStorage("canvasModeEnabled") private var canvasModeEnabled: Bool = false
    @AppStorage(ChatFontScale.storageKey) private var chatFontScale: Double = ChatFontScale.default
    @AppStorage(DisplayMode.storageKey) private var displayModeRaw: String = DisplayMode.auto.rawValue
    @State private var pendingRestartFromDisplayMode = false
    /// 桌宠桌面漫步大小档位（5 档：迷你 / 小 / 默认 / 大 / 特大）
    @AppStorage(PetWalkSizeScale.storageKey) private var petWalkSizeScale: Double = PetWalkSizeScale.default
    /// 当前正在"查看 / 编辑配置"的 mode。
    /// **不绑定 viewModel.agentMode** —— 设置里调这个 Picker 不会切换正在进行的对话的 mode，
    /// 仅决定下面 hermesConfig / claudeCard / codexCard 显示哪一个。
    /// 之前直接 bind viewModel.agentMode 会破坏"对话 mode 锁死"的语义（已发消息的对话被设置面板改了 mode）
    @State private var configViewingMode: AgentMode = .hermes
    /// 全局调色板存储 —— ColorPicker 改色后通过它更新 + 持久化
    @State private var paletteStore = PetPaletteStore.shared

    enum Category: String, CaseIterable, Identifiable {
        case backend, pet, sound, privacy, system, about
        var id: String { rawValue }

        var label: String {
            switch self {
            case .backend: return "AI 后端"
            case .pet:     return "桌宠"
            case .sound:   return "音效"
            case .privacy: return "隐私"
            case .system:  return "系统"
            case .about:   return "关于"
            }
        }
        var icon: String {
            switch self {
            case .backend: return "cpu"
            case .pet:     return "pawprint.fill"
            case .sound:   return "speaker.wave.2.fill"
            case .privacy: return "lock.shield.fill"
            case .system:  return "gearshape.fill"
            case .about:   return "info.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .backend: return .blue
            case .pet:     return .pink
            case .sound:   return .orange
            case .privacy: return .indigo
            case .system:  return .gray
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
        .frame(width: 620, height: 460)
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
                Text(selectedCategory.label)
                    .font(.system(size: 21, weight: .semibold))
                    .padding(.top, 2)

                Group {
                    switch selectedCategory {
                    case .backend: backendSection
                    case .pet:     petSection
                    case .sound:   soundSection
                    case .privacy: privacySection
                    case .system:  systemSection
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

    /// AI 模式总开关 + 检测状态卡片（U1+U2+U3）。
    /// 5 行 toggle：在线 AI 永久 ON，其他 4 个用户按需开。打开时自动检测本机有没有装对应 CLI/daemon
    private var aiModeToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 模式")
                .font(.system(size: 13, weight: .medium))
            Text("默认只开「在线 AI」。装了其他 AI 后，在这里启用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                // 显示顺序：在线 AI 永远第一（兜底），然后 OpenClaw / Hermes / Claude Code / Codex
                ForEach([AgentMode.directAPI, .openclaw, .hermes, .claudeCode, .codex]) { mode in
                    ModeEnableRow(mode: mode)
                }
            }
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            // U1: AI 模式总开关 5 行 toggle（新加在最顶部）
            aiModeToggles

            Divider()

            // 配置查看器：选哪个 mode 就显示哪个 mode 的配置项（不切换正在进行的对话）
            VStack(alignment: .leading, spacing: 8) {
                Text("查看配置")
                    .font(.system(size: 13, weight: .medium))
                Picker(selection: $configViewingMode) {
                    ForEach(AgentMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.iconName).tag(mode)
                    }
                } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                Text(modeFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 提示用户「这里不切换对话 mode」
                Text("提示：每个对话独立绑定 mode，发出第一条消息后就锁定。如需用其他模型，按 ⌘N 新建对话。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 选中的 mode 的配置项
            switch configViewingMode {
            case .hermes:     hermesConfig
            case .directAPI:  directAPIConfig
            case .openclaw:   openclawConfig    // U4: Hermes 同款 Gateway 状态卡片 + 高级折叠区
            case .claudeCode: claudeCard
            case .codex:      codexCard
            }
        }
        // 进入设置时把"查看配置"默认设到当前对话的 mode，方便用户直接编辑当前在用的那个
        .onAppear {
            configViewingMode = viewModel.agentMode
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

    // MARK: - OpenClaw 配置（U4：跟 Hermes 同款 Gateway 状态卡片 + 高级折叠区，不再沿用 directAPI 表单）
    @State private var openclawAvailableAgents: [String] = []
    @State private var openclawFetchingAgents = false
    @State private var openclawAgentFetchError: String?
    @State private var openclawAdvancedExpanded: Bool = false
    @AppStorage(OpenClawGatewayManager.autoStartKey) private var openclawAutoStart: Bool = true
    @AppStorage("openclawAgentId") private var openclawAgentId: String = "openclaw"
    /// 用户手填的 token 覆盖（默认空 = 自动从 ~/.openclaw/openclaw.json 读）
    @AppStorage("openclawToken") private var openclawTokenOverride: String = ""
    @State private var showOpenclawToken = false

    private var hermesConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 预设 Picker：本地 / 云端 / 自定义，跟 directAPI 体验对齐
            settingRow("部署方式") {
                Picker(selection: $selectedHermesPreset) {
                    ForEach(ProviderPreset.hermesPresets) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                    Divider()
                    Text(ProviderPreset.custom.displayName).tag(ProviderPreset.custom)
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
                settingRow("API 地址") {
                    TextField("https://your-gateway.example.com/v1", text: $viewModel.apiBaseURL)
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
        let status = HermesGatewayManager.shared.status
        let (dotColor, statusText, tone): (Color, String, Color) = {
            switch status {
            case .starting:       return (.orange, "连接中…",       .secondary)
            case .running:        return (.green,  "已连接",         .secondary)
            case .external:       return (.green,  "已连接",         .secondary)
            case .binaryMissing:  return (.gray,   "未安装",         .secondary)
            case .failed:         return (.red,    "连接失败",       .red)
            case .disabled:       return (.gray,   "已关闭自动连接",  .secondary)
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                Text("Hermes")
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
                .help("重新连接")
            }

            // 未安装时给安装入口
            if case .binaryMissing = status {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("电脑上还没安装 Hermes。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Link("查看安装方法 ›", destination: URL(string: "https://github.com/anomalyco/hermes-agent")!)
                        .font(.caption2)
                }
            }

            Toggle(isOn: $hermesAutoStart) {
                Text("打开 HermesPet 时自动连接 Hermes")
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
        // 1s tick 刷新 status（spawn 中的状态变化通过 @State 重新读 manager）
        .id(gatewayStatusTick)
        .onAppear {
            startGatewayStatusTimer()
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
            Text("高级（API 密钥 / 模型名）")
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
                Text("OpenClaw 是装在你电脑上的本地 AI，HermesPet 启动时会自动连接。免费、不联网、不需要密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// OpenClaw 连接状态卡片（小白文案：只显"已连接/连接中/未连接"，不显端口、不显技术词）
    private var openclawGatewayStatusCard: some View {
        let status = OpenClawGatewayManager.shared.status
        let (dotColor, statusText, tone): (Color, String, Color) = {
            switch status {
            case .starting:          return (.orange, "连接中…",        .secondary)
            case .running:           return (.green,  "已连接",          .secondary)
            case .binaryMissing:     return (.gray,   "未连接",          .secondary)
            case .configMissing:     return (.orange, "需要完成初始化",   .orange)
            case .endpointDisabled:  return (.orange, "正在自动配置…",    .orange)
            case .failed:            return (.red,    "连接失败",        .red)
            case .disabled:          return (.gray,   "已关闭自动连接",   .secondary)
            }
        }()
        let fomoTint = Color(red: 0.706, green: 0.773, blue: 0.910)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(fomoTint)
                Text("OpenClaw")
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
                .help("重新连接")
            }

            // 状态分支：给具体修复指引（小白能懂的语言）
            switch status {
            case .binaryMissing:
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("电脑上还没安装 OpenClaw。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("npm install -g openclaw@latest && openclaw onboard --install-daemon", forType: .string)
                    } label: {
                        Text("复制安装命令")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            case .configMissing:
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("已安装，但还没完成初始化。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("openclaw onboard --install-daemon", forType: .string)
                    } label: {
                        Text("复制初始化命令")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            case .endpointDisabled:
                HStack(spacing: 4) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("正在自动配置，可点右上角刷新重试。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }

            Toggle(isOn: $openclawAutoStart) {
                Text("打开 HermesPet 时自动连接 OpenClaw")
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
        .id(gatewayStatusTick)
        .onAppear {
            startGatewayStatusTimer()
        }
    }

    /// OpenClaw 高级设置（默认折叠 —— 一般用户不用打开）
    private var openclawAdvancedSection: some View {
        DisclosureGroup(isExpanded: $openclawAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                settingRow("密钥（一般不用填）") {
                    HStack(spacing: 4) {
                        Group {
                            if showOpenclawToken {
                                TextField("留空会自动读取", text: $openclawTokenOverride)
                            } else {
                                SecureField("留空会自动读取", text: $openclawTokenOverride)
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

                settingRow("AI 角色") {
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
                            .help("从可用列表选")
                        }

                        Button {
                            fetchOpenclawAgents()
                        } label: {
                            if openclawFetchingAgents {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            } else {
                                Text("刷新").font(.caption)
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
            Text("高级设置")
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
                openclawAgentFetchError = "拉取失败：\(error.localizedDescription)"
                openclawFetchingAgents = false
            }
        }
    }

    /// 拆出 Key 行 + 模型行 + 错误行作为独立组件，本地档高级区 + 云端档都共用
    private var hermesKeyRow: some View {
        settingRow("API 密钥（选填）") {
            HStack(spacing: 4) {
                Group {
                    if showKey { TextField("未启用鉴权可留空", text: $viewModel.apiKey) }
                    else { SecureField("未启用鉴权可留空", text: $viewModel.apiKey) }
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
                .help(showKey ? "隐藏密钥" : "显示密钥")
            }
        }
    }

    private var hermesModelRow: some View {
        settingRow("模型") {
            HStack(spacing: 6) {
                TextField("hermes-agent", text: $viewModel.modelName)
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
                    .help("从可用模型列表选")
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
                .help("从 /v1/models 拉取可用模型")
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
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            // 离开当前 mode 就停（避免后台一直 tick）
            if selectedHermesPreset.id != "hermes-local" {
                timer.invalidate()
                return
            }
            gatewayStatusTick &+= 1
        }
    }

    /// Hermes 底部说明文字，按预设档位区分
    private var hermesHintText: String {
        switch selectedHermesPreset.id {
        case "hermes-local":
            return "Hermes 是装在你电脑上的本地 AI，HermesPet 启动时会自动连接。免费、不联网、不需要密钥。"
        case "hermes-cloud":
            return "填上你服务器上 Hermes 的地址 + 模型名即可。鉴权方式按你部署时设的。"
        default:
            return "任意 OpenAI 兼容服务都能用 —— 自部署 vLLM / Ollama / LM Studio / 中转代理皆可。"
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
                    hermesModelFetchError = "服务端 /v1/models 返回空列表"
                } else if viewModel.modelName.isEmpty || !models.contains(viewModel.modelName) {
                    // 当前 modelName 不在列表里 → 自动选第一个
                    viewModel.modelName = models[0]
                }
            } catch {
                hermesModelFetchError = "拉取失败：\(error.localizedDescription)"
            }
            hermesFetchingModels = false
        }
    }

    // MARK: - 在线 AI 配置（直连第三方 OpenAI 兼容服务商）

    private var directAPIConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 服务商预设 Picker（去掉了"opencode 引擎"诊断卡片和重复说明 —— 小白只需要填 Key 就能用）
            settingRow("服务商") {
                Picker(selection: $selectedProvider) {
                    ForEach(ProviderPreset.all) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                    Divider()
                    Text(ProviderPreset.custom.displayName).tag(ProviderPreset.custom)
                } label: { EmptyView() }
                    .labelsHidden()
                    .onChange(of: selectedProvider) { _, newPreset in
                        applyProviderPreset(newPreset)
                    }
            }

            // 自定义时才显示完整 URL 编辑框；预设隐藏避免误改
            if selectedProvider.id == "custom" {
                settingRow("API 地址") {
                    TextField("https://api.example.com/v1", text: $viewModel.directAPIBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            settingRow("API 密钥") {
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
                    .help(showKey ? "隐藏密钥" : "显示密钥")
                }
            }
            if selectedProvider.id == "custom" {
                settingRow("模型") {
                    TextField("gpt-4o-mini", text: $viewModel.directAPIModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            } else {
                settingRow("回复偏好") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(selection: $viewModel.directAPIResponsePreference) {
                            ForEach(DirectResponsePreference.allCases) { preference in
                                Text(preference.label).tag(preference)
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

                settingRow("当前模型") {
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
        case "zhipu":    return "xxxxx.xxxxx (智谱)"
        case "moonshot": return "sk-xxxxxx (Moonshot)"
        case "minimax":  return "sk-xxxxxx (MiniMax)"
        case "openai":   return "sk-xxxxxx (OpenAI)"
        default: return "your-secret-key"
        }
    }

    @ViewBuilder
    private var providerHint: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 92)
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
            switch selectedProvider.id {
            case "custom":
                Text("自定义 OpenAI 兼容服务（自部署 / 中转代理）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                if viewModel.directAPIKey.isEmpty {
                    Text("当前服务商尚未配置 Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let url = selectedProvider.signupURL {
                    Text("还没 API Key？")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("点这里获取 ›", destination: URL(string: url)!)
                        .font(.caption)
                }
                if !selectedProvider.altModels.isEmpty {
                    Text("· 备选：\(selectedProvider.altModels.joined(separator: " / "))")
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
                Text("opencode 引擎 v1.15.1")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle()
                    .fill(isReady ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(isReady ? "运行中\(portText)" : "启动中…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("在线 AI 模式现已升级为 agent runtime —— 能读写本地文件 / 跑命令 / 联网搜索，跟 Claude Code / Codex 同档。装上 HermesPet 即可使用，不依赖任何外部 CLI。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !OpenCodeConfigGenerator.hasConfiguredKey {
                HStack(spacing: 4) {
                    Image(systemName: "gift.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("还没配 Key？现在用 opencode 内置免费模型 deepseek-v4-flash-free")
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
                        Text("当前模型有 reasoning_content 字段，可能偶尔无响应")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("opencode v1.15.1 跟 DeepSeek V4 / Kimi K2.x / OpenAI o1+ 等推理模型的 reasoning_content 字段适配中（PR #25110）。建议先用「moonshot-v1-32k」/「gpt-5.4」这类非推理模型，agent 能力完整稳定。后续 HermesPet 会内置 ReasoningProxy 彻底修。")
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
                    Text(testing ? "测试中…" : "测试连接")
                }
            }
            .controlSize(.small)
            .disabled(testing)

            if let result = testResult {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? .green : .red)
                Text(result.success ? "已连接" : result.message)
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
            title: "通过 claude CLI 调用 Claude Code",
            body: "能读写文件、运行命令、分析图片。需要先在终端用 npm / brew 等装好 claude CLI。",
            installURL: "https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview"
        )
    }

    private var codexCard: some View {
        cliConfigCard(
            mode: .codex,
            icon: "wand.and.stars",
            tint: .cyan,
            title: "通过 codex CLI 调用 OpenAI Codex",
            body: "强项是写代码 + 生成图片。生图自动显示在对话气泡里。需要装好 codex CLI 并用 codex login 登录 OpenAI 账号。",
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

            // 安装指南链接
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("还没装？")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("安装指南 ›", destination: URL(string: installURL)!)
                    .font(.caption)
            }
        }
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
                Text("检测中…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else if storedPath.isEmpty {
                Text("未检测到")
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
                    Text("重新检测")
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
            captionToggle(
                icon: "sparkles",
                iconColor: .pink,
                title: "桌宠动效",
                caption: "灵动岛图标的呼吸、眨眼、完成跳跃等微动画",
                isOn: Binding(
                    get: { !viewModel.quietMode },
                    set: { viewModel.quietMode = !$0 }
                )
            )

            Divider()

            // 桌面漫步统一区 —— 覆盖四种桌宠（每个 mode 一种形象）
            VStack(alignment: .leading, spacing: 6) {
                Label("桌面漫步", systemImage: "figure.walk")
                    .font(.system(size: 13, weight: .medium))
                Text("从灵动岛跳出，沿菜单栏正下方左右走动。Claude 🦞 / 在线 AI ☁️ / OpenClaw 🦊 / Hermes 🐴 / Codex 💻 五种桌宠，跟着当前 AI 模式切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            captionToggle(
                icon: "figure.walk",
                iconColor: petColor,
                title: "启用桌面漫步",
                caption: "总开关。关掉后四种桌宠都不会出现",
                isOn: $viewModel.clawdWalkEnabled
            )

            captionToggle(
                icon: "infinity",
                iconColor: petColor,
                title: "Claude / Hermes / Codex · 自由活动",
                caption: "Claude / Hermes / Codex 模式下跳过 3 分钟空闲等待，桌宠一直在屏幕上玩。在线 AI / OpenClaw 模式云朵和 fomo 切过去就立刻出来，不受此项影响",
                isOn: $viewModel.clawdFreeRoamEnabled,
                disabled: !viewModel.clawdWalkEnabled
            )

            captionToggle(
                icon: "sparkles.rectangle.stack",
                iconColor: petColor,
                title: "桌面巡视（嗅文件）",
                caption: "漫步期间偶尔下到桌面，挑个图标用 Hermes 给一句短评。四种桌宠都会参与，需要 Finder 自动化权限",
                isOn: $viewModel.clawdDesktopPatrolEnabled,
                disabled: !viewModel.clawdWalkEnabled
            )

            Divider()

            // 桌宠形象调色 —— 主色定制（派生色自动跟随）
            VStack(alignment: .leading, spacing: 10) {
                Label("桌宠形象调色", systemImage: "paintpalette.fill")
                    .font(.system(size: 13, weight: .medium))
                Text("调主色 → 顶高光 / 底阴影自动派生。鬃毛 / 翅膀 / 火焰 / LED 等保留默认色不变。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                paletteRow(label: "Claude · Clawd 🦞", mode: .claudeCode)
                paletteRow(label: "在线 AI · 云朵 ☁️", mode: .directAPI)
                paletteRow(label: "OpenClaw · fomo 🦊", mode: .openclaw)
                paletteRow(label: "Hermes · 小马 🐴", mode: .hermes)
                paletteRow(label: "Codex · coco 🤖", mode: .codex)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)

            // 桌宠大小档位
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("桌宠大小", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(petWalkSizeScale * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Picker("桌宠大小档位", selection: $petWalkSizeScale) {
                    ForEach(PetWalkSizeScale.presets, id: \.self) { scale in
                        Text(PetWalkSizeScale.label(for: scale)).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: petWalkSizeScale) { _, _ in
                    // 通知 ClawdWalkController：已显示中的桌宠 setFrame 跟随新尺寸
                    NotificationCenter.default.post(name: PetWalkSizeScale.didChangeNotification, object: nil)
                }

                Text("仅作用于桌面漫步形象。灵动岛桌宠受刘海物理高度约束，大小不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("交互（四种桌宠通用）", systemImage: "hand.tap")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                interactionTip("单击 / 双击", "打开聊天窗（不切换模式）")
                interactionTip("鼠标 hover", "暂停漫步")
                interactionTip("拖文件给它", "桌宠吃掉并交给 AI 看（仅 Claude 模式）")
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

            Button("重置默认") {
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
                    Text("每个事件可独立选音效或关闭")
                        .font(.system(size: 12, weight: .medium))
                    Text("默认是 macOS 系统内置音，也可以点「自定义…」选你自己的 mp3 / wav / m4a / aiff。选「🔇 静音」即可关掉某事件。")
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
            Text(event.displayTitle).font(.system(size: 13, weight: .medium))

            HStack(spacing: 8) {
                // 当前选的是自定义文件 —— 显示文件名 chip + ✕（移回静音）
                if binding.wrappedValue.hasPrefix("/") {
                    customFileChip(path: binding.wrappedValue) {
                        binding.wrappedValue = ""
                    }
                } else {
                    // 系统音 Picker（含 "🔇 静音" 在最上）
                    Picker("", selection: binding) {
                        ForEach(Self.systemSounds, id: \.0) { (value, label) in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                Button {
                    pickCustomSoundFile(for: binding)
                } label: {
                    Label("自定义…", systemImage: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .help("从本地选择一个音频文件（mp3 / wav / m4a / aiff）")

                Button {
                    SoundManager.play(rawValue: binding.wrappedValue)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("试听")
                .disabled(binding.wrappedValue.isEmpty)

                Spacer()
            }

            Text(event.displayCaption).font(.caption).foregroundStyle(.secondary)
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
            .help("移除自定义音效（恢复静音，可再选系统音）")
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
        panel.title = "选择提示音"
        panel.prompt = "选择"
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
    /// Wave C5：每分钟最多反馈次数 —— 1=安静 / 2=适中 / 4=频繁
    @AppStorage("intentFeedbackPerMinute") private var intentFeedbackPerMinute: Int = 2

    /// Wave E1：今日观察列表数据。每次打开设置 / 用户操作（删除/拉黑/刷新）后重新拉
    @State private var intentObservations: [UserIntent] = []
    @State private var showObservationList: Bool = false
    /// Wave E2/E3：用户软黑名单（bundle ID 数组）。@State 镜像 + UserDefaults.array(forKey:) 同步
    @State private var userBlacklist: [String] = []

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 在线 AI 工具调用前是否要用户审批 —— 默认关（行为同 v1.2.x），开了之后
            // 灵动岛会在 AI 想跑 Edit/Write/Bash 等工具时弹卡片让 Allow/Always/Deny
            captionToggle(
                icon: "checkmark.shield.fill",
                iconColor: .orange,
                title: "工具调用前向我确认",
                caption: "AI 想读写文件 / 跑命令时，灵动岛展开卡片让你点 Allow / Always / Deny。\n默认关（AI 全部放行）；开启后下一次新对话生效。仅「在线 AI」模式生效（v1.3）。",
                isOn: $viewModel.permissionUIEnabled
            )

            Divider()

            captionToggle(
                icon: "eye.fill",
                iconColor: .indigo,
                title: "记录我的活动",
                caption: "持续记录在用什么 app、窗口、键盘节奏，让 AI 能真正知道你在做什么。\n所有数据本地存储，不上传任何云。首次启用会请求 macOS 辅助功能权限。",
                isOn: $viewModel.activityRecordingEnabled
            )

            // 隐私保障说明卡片
            VStack(alignment: .leading, spacing: 6) {
                privacyTip(icon: "lock.fill", text: "数据仅本地存储于 ~/.hermespet/activity.sqlite")
                privacyTip(icon: "keyboard", text: "只统计按键次数，不记录键盘内容")
                privacyTip(icon: "bubble.left.and.bubble.right.fill", text: "你跟 AI 说的话被记下来给早报用（AI 回答不记）")
                privacyTip(icon: "key.fill", text: "1Password / 钥匙串等敏感 app 自动跳过")
                privacyTip(icon: "trash", text: "可随时一键清空，原始事件 48h 自动清理")
            }
            .padding(12)
            .background(Color.indigo.opacity(0.06))
            .cornerRadius(8)

            Divider()

            // 早报后端选择 —— 早报会汇总你昨天的活动 + 跟 AI 的对话主题给某个 AI 处理，
            // 让用户明确选择哪家服务商能看到这些数据
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("早报由谁生成", systemImage: "newspaper.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $viewModel.morningBriefingBackend) {
                        // M5: 早报后端只能选 enabled 的 mode（选 disabled 的也用不了）
                        ForEach(AgentMode.allCases.filter { EnabledModesStore.shared.isEnabled($0) }) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                Text("早报会把你昨天的活动摘要发给这个 AI 总结。Hermes 模式可走自托管，最隐私；Claude/Codex 智能更强但数据会过它们的服务器。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 今日统计（实时）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("今日活动", systemImage: "chart.bar.fill")
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
                    .help("刷新")
                }

                if activityTodayStats.isEmpty {
                    Text(viewModel.activityRecordingEnabled
                         ? "还没有数据 —— 用一会儿电脑再回来看"
                         : "活动记录已关闭")
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
                        Text("还有 \(activityTodayStats.count - 5) 个 app...")
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
                    Label("清空所有活动记录", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "确定清空所有活动记录吗？",
                    isPresented: $showClearActivityConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清空", role: .destructive) {
                        ActivityRecorder.shared.clearAll()
                        refreshActivityStats()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会删除所有原始事件、会话块和每日统计。此操作不可撤销。")
                }
            }

            // —— v1.3 意图感知 ——
            Divider()
            userIntentSection
        }
        .onAppear {
            refreshActivityStats()
            refreshIntentStats()
            loadBlacklist()
            loadObservations()
        }
    }

    /// 意图感知开关 + 简介 + 今日采样数 + 清空按钮（v1.3 Phase 1）
    private var userIntentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            captionToggle(
                icon: "brain.head.profile",
                iconColor: .purple,
                title: "意图感知（实验性）",
                caption: "按回车 / ⌘S / ⌘C / ⌘V / 切应用 / Spotlight 时静默截当前屏 OCR，记录你在做什么。\n同 app 同窗口 5 分钟只采 1 次。所有 OCR 走本地 Vision，不联网。30 天后自动压缩。",
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
                privacyTip(icon: "lock.fill", text: "OCR 文本仅本地存储于 ~/.hermespet/activity.sqlite")
                privacyTip(icon: "wifi.slash", text: "OCR 走本地 Vision Framework，零网络请求，零 token 消耗")
                privacyTip(icon: "eye.slash.fill", text: "1Password / 微信 / 支付宝等敏感 app 自动跳过")
                privacyTip(icon: "hand.raised.fill", text: "可逐条删除单次观察 / 可把任意 app 加入黑名单")
                privacyTip(icon: "speaker.slash.fill", text: "AI 反馈通道可关、可调频率，桌宠永远静默观察")
                privacyTip(icon: "clock.arrow.circlepath", text: "30 天后 OCR 全文 gzip 压缩 / 180 天后整条删除")
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
                    Label("AI 出场偏好", systemImage: "rectangle.3.group.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $intentChannelPreferenceRaw) {
                        Text("自动").tag("auto")
                        Text("桌宠优先").tag("pet")
                        Text("灵动岛优先").tag("island")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .labelsHidden()
                }

                // 反馈频率（Wave C5）
                HStack {
                    Label("反馈频率", systemImage: "speedometer")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $intentFeedbackPerMinute) {
                        Text("安静").tag(1)
                        Text("适中").tag(2)
                        Text("频繁").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .labelsHidden()
                }

                // 今日采样数
                HStack {
                    Label("今天已采样", systemImage: "camera.viewfinder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(userIntentTodayCount) 次")
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
                        Label("导出 JSON", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        showClearIntentConfirm = true
                    } label: {
                        Label("清空意图记录", systemImage: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "确定清空所有意图记录吗？",
                        isPresented: $showClearIntentConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("清空", role: .destructive) {
                            ActivityRecorder.shared.queryStore.clearUserIntents()
                            refreshIntentStats()
                            loadObservations()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("会删除所有屏幕 OCR 采样记录。此操作不可撤销。")
                    }
                }
            }
        }
    }

    /// 刷新"今日意图采样次数"
    private func refreshIntentStats() {
        // 复用最近 24h 查询（够近似今日，省得加一个新 SQL）
        let intents = ActivityRecorder.shared.queryStore.recentUserIntents(withinMinutes: 24 * 60, limit: 10000)
        userIntentTodayCount = intents.count
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
                    Label("今日观察", systemImage: "list.bullet.below.rectangle")
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
                    Text("今天还没有观察记录")
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
                        Text("· 仅 meta")
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
                        Label("以后别记 \(item.appName ?? bid)", systemImage: "eye.slash")
                    }
                }
                Button(role: .destructive) {
                    deleteObservation(id: item.id)
                } label: {
                    Label("删除这条", systemImage: "trash")
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
        return "\(count) 次 · 跨 \(uniqueApps) 个应用"
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

    // MARK: - Wave E2 + E3：黑名单

    /// 黑名单管理 section（仅有自定义黑名单时显示）
    private var blacklistSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("已屏蔽的应用", systemImage: "eye.slash.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(userBlacklist.count) 个")
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
        panel.title = "导出今日意图记录"
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
        // 让 recorder 先把当前会话和当天 stats 落盘，再查
        ActivityRecorder.shared.queryStore.aggregateDailyStats(for: Date())
        activityTodayStats = ActivityRecorder.shared.queryStore.dailyStats(for: Date())
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - 系统

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // —— 灵动岛显示模式 ——
            displayModeRow

            Divider()

            // —— 聊天字号 ——
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.indigo)
                    Text("聊天字号")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(chatFontScale * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Picker("聊天字号档位", selection: $chatFontScale) {
                    ForEach(ChatFontScale.presets, id: \.self) { scale in
                        Text(scaleLabel(scale)).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("仅缩放消息正文、代码块、表格、选项卡片。也可在聊天窗口里用 ⌘+ / ⌘- / ⌘0 直接调。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            captionToggle(
                icon: "power.circle.fill",
                iconColor: .blue,
                title: "开机自动启动",
                caption: "登录系统后自动以菜单栏 app 形式启动",
                isOn: Binding(
                    get: { viewModel.isLaunchAtLoginOn },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )

            Divider()

            captionToggle(
                icon: "dock.rectangle",
                iconColor: .indigo,
                title: "在 Dock 显示图标",
                caption: "默认菜单栏 agent 风格不占 Dock。打开后会显示应用图标，Cmd+Tab 也能切到 HermesPet。切换即时生效，无需重启。",
                isOn: $viewModel.showDockIcon
            )

            Divider()

            captionToggle(
                icon: "hand.tap.fill",
                iconColor: .purple,
                title: "触觉反馈",
                caption: "切 mode / 截屏 / 按住语音 / 任务完成时给 trackpad 一次轻微震动",
                isOn: $viewModel.hapticEnabled
            )

            Divider()
                .padding(.vertical, 4)

            // 实验性功能区
            HStack(spacing: 6) {
                Image(systemName: "flask.fill").font(.caption2).foregroundStyle(.orange)
                Text("实验性功能")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.bottom, 2)

            captionToggle(
                icon: "rectangle.3.group",
                iconColor: .pink,
                title: "画布模式",
                caption: "用 Codex 自动批量生成产品图集（电商主图风格）。生成需 5~10 分钟，依赖 codex CLI。功能仍在打磨，不需要可保持关闭。",
                isOn: $canvasModeEnabled
            )
        }
    }

    /// 字号档位 segmented Picker 的显示文字
    private func scaleLabel(_ scale: Double) -> String {
        switch scale {
        case 0.85: return "小"
        case 1.0:  return "标准"
        case 1.15: return "大"
        case 1.30: return "更大"
        case 1.50: return "巨大"
        default:   return "\(Int(scale * 100))%"
        }
    }

    // MARK: - 显示模式（灵动岛 / 悬浮胶囊 切换）

    private var displayModeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "macbook.gen2")
                    .foregroundStyle(.purple)
                Text("灵动岛显示")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            Picker("灵动岛显示", selection: $displayModeRaw) {
                Text("跟随屏幕").tag(DisplayMode.auto.rawValue)
                Text("刘海").tag(DisplayMode.notch.rawValue)
                Text("悬浮胶囊").tag(DisplayMode.floating.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: displayModeRaw) { _, _ in
                pendingRestartFromDisplayMode = true
            }

            Text("无刘海屏（Air / Intel Mac / 外接显示器）建议选「悬浮胶囊」，胶囊会浮在菜单栏下方 + 跟当前桌宠主色发光。切换后需要重启应用生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("需要重启应用", isPresented: $pendingRestartFromDisplayMode) {
            Button("稍后") {
                pendingRestartFromDisplayMode = false
            }
            Button("立刻重启") {
                relaunchApp()
            }
        } message: {
            Text("灵动岛显示模式切换需要重启应用才能生效。")
        }
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
                    Text("macOS 顶部刘海桌宠 · AI 聊天客户端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            updateSection

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(HotkeyAction.allCases) { action in
                    hotkeyRow(action)
                }
                aboutRow(icon: "folder.fill", label: "存储位置", value: "~/.hermespet/")
            }
            .id(hotkeyRefreshID)

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
                Text("官方版本验证")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(result.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(headlineColor)
            }

            Text(result.detailText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 官方下载源提示 + 跳转按钮
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.indigo)
                Text("官方下载源")
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
                Text("HermesPet 由 Basion 独立开发并开源，原作者 GitHub: @basionwang-bot。除官方仓库的 Releases 外，其他渠道（个人转发 / 第三方网盘）的 DMG 不保证安全和正版，建议核对上方签名。")
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
                Text("问题反馈")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }

            if let crash = reporter.latestCrash {
                VStack(alignment: .leading, spacing: 6) {
                    Text("检测到最近一次崩溃")
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
                            Label("一键上报到 GitHub", systemImage: "paperplane.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            reporter.revealInFinder(crash)
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if reporter.allCrashes.count > 1 {
                        Text("（共 \(reporter.allCrashes.count) 条历史崩溃，最早 \(relativeTime(from: reporter.allCrashes.last!.date))）")
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
                    Text("暂未检测到崩溃日志 ✨")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        reporter.openBlankIssue()
                    } label: {
                        Label("直接提 issue", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("点「一键上报」会自动复制完整崩溃日志到剪贴板 + 打开 GitHub issue 页面，粘贴后描述一下崩溃前的操作就能发出。日志只发到你看到的 GitHub issue，不会上传任何第三方后端。")
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
                Text("作者")
                    .font(.system(size: 12))
                Spacer()
                Link("Basion", destination: URL(string: "https://github.com/basionwang-bot")!)
                    .font(.system(size: 12, weight: .medium))
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink.opacity(0.85))
                    .frame(width: 16)
                Text("社区贡献者")
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
                    Link("查看全部贡献者",
                         destination: URL(string: "https://github.com/basionwang-bot/HermesPet/graphs/contributors")!)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "star.bubble.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("代码仓库")
                    .font(.system(size: 12))
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/basionwang-bot/HermesPet")!)
                    .font(.system(size: 12))
            }

            Text("感谢所有提交 issue / PR 的朋友。如果这个项目对你有用，欢迎在 GitHub 给个 Star ⭐️")
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
                        Text("有新版本 v\(latest) 可用")
                            .font(.system(size: 13, weight: .medium))
                        Text("当前 v\(checker.currentVersion)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已是最新版本")
                            .font(.system(size: 13))
                        if let at = checker.lastCheckedAt {
                            Text("最近检查：\(relativeTime(from: at))")
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
                        Label("下载并安装", systemImage: "arrow.down.app.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await checker.check(silently: false) }
                    } label: {
                        Label(checker.isChecking ? "检查中..." : "检查更新",
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
                    Text("更新内容")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.leading, 26)
            }
        }
    }

    /// "刚刚" / "5 分钟前" / "2 小时前" / "昨天" 相对时间
    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func hotkeyRow(_ action: HotkeyAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(action.title)
                .font(.system(size: 12))
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

    static let systemSounds: [(String, String)] = [
        ("",          "🔇 静音"),
        ("Funk",      "Funk · 低音 duang"),
        ("Hero",      "Hero · 上扬咚叮"),
        ("Glass",     "Glass · 清脆叮"),
        ("Tink",      "Tink · 短叮"),
        ("Ping",      "Ping · 清脆乒"),
        ("Pop",       "Pop · 爆破"),
        ("Submarine", "Submarine · 低沉钟"),
        ("Sosumi",    "Sosumi · 经典"),
        ("Bottle",    "Bottle · 瓶口"),
        ("Blow",      "Blow · 吹气"),
        ("Frog",      "Frog · 蛙鸣"),
        ("Purr",      "Purr · 猫呼噜"),
        ("Basso",     "Basso · 低沉错误"),
        ("Morse",     "Morse · 电报")
    ]

    private var modeFooterText: String {
        switch configViewingMode {
        case .hermes:
            return "Hermes 是装在你电脑上的本地 AI，免费、不联网"
        case .directAPI:
            return "直接用云端 AI（DeepSeek / 智谱 / Kimi 等），需要填密钥"
        case .openclaw:
            return "OpenClaw 是装在你电脑上的本地 AI，免费、不联网"
        case .claudeCode:
            return "用 Claude Code 帮你改文件、跑命令、读代码"
        case .codex:
            return "用 Codex 帮你写代码 + 生成图片"
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
                    testResult = (false, "请先选择服务商")
                } else if viewModel.directAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testResult = (false, "请先填写 API Key")
                } else if viewModel.directAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testResult = (false, "请先选择模型")
                } else {
                    do {
                        _ = try await client.sendMessage(messages: [
                            ChatMessage(role: .user, content: "ping")
                        ])
                        testResult = (true, "Key 与模型可用")
                    } catch {
                        testResult = (false, directTestErrorMessage(error))
                    }
                }
            } else {
                do {
                    let ok = try await client.checkHealth()
                    testResult = (ok, ok ? "Hermes API 在线" : "健康检查未通过")
                } catch {
                    // 健康检查不通 → 退一步发一条 ping 试试。有些自部署的 Hermes /health 没开
                    do {
                        _ = try await client.sendMessage(messages: [
                            ChatMessage(role: .user, content: "ping")
                        ])
                        testResult = (true, "连接成功")
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
                return "API Key 不属于当前服务商或无权限"
            case 404:
                return "模型不存在或 API 地址不正确"
            case 429:
                return "请求过于频繁或额度不足"
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
            title = isRecording ? "按下新快捷键…" : hotkey.displayText
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

        let next = Hotkey(
            keyCode: keyCode,
            modifiers: HotkeyFormatter.carbonModifiers(from: event.modifierFlags)
        )
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

    @State private var isEnabled: Bool = false
    @State private var statusText: String = "检测中…"
    @State private var statusColor: Color = .secondary
    @State private var isDetecting: Bool = false
    @State private var notInstalled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // mini icon
            Image(systemName: mode.iconName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(modeColor)
                .background(modeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

            // 名称 + 状态副标题
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.label).font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    if isDetecting {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    if notInstalled, let cmd = installCommand {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("复制安装命令：\(cmd)")
                    }
                }
            }

            Spacer()

            // Toggle 开关
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
                            statusText = "已关闭"
                            statusColor = .secondary
                            notInstalled = false
                        }
                        // 上面 statusText 在 setter 闭包里改，但 .onAppear 已经把 statusText 锁到 onAppear 那一刻的值。
                        // 实际生效路径在 setter 外（每次 toggle 切换都触发 onAppear 重渲）—— 不动逻辑
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
                statusText = "总是开启"
                statusColor = .green
            } else if isEnabled {
                detect()
            } else {
                statusText = "未启用"
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
        }
    }

    /// 安装命令（用户没装 CLI/daemon 时点复制按钮拿到）
    private var installCommand: String? {
        switch mode {
        case .directAPI: return nil   // 永远可用
        case .openclaw:  return "npm install -g openclaw@latest && openclaw onboard --install-daemon"
        case .hermes:    return "pip install hermes-agent"
        case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
        case .codex:     return "npm install -g @openai/codex"
        }
    }

    /// 触发检测：根据 mode 调对应的检测器（小白文案：只用"已连接 / 连接中 / 未安装"）
    private func detect() {
        isDetecting = true
        notInstalled = false
        Task { @MainActor in
            switch mode {
            case .directAPI:
                statusText = "总是开启"
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
                    statusText = "未安装"
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
                    statusText = "已就绪"
                    statusColor = .green
                } else {
                    statusText = "未安装"
                    statusColor = .orange
                    notInstalled = true
                }
            case .codex:
                let ok = await CLIAvailability.codexAvailable()
                if ok {
                    statusText = "已就绪"
                    statusColor = .green
                } else {
                    statusText = "未安装"
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
            statusText = "已连接"
            statusColor = .green
        case .starting:
            statusText = "连接中…"
            statusColor = .secondary
        case .binaryMissing:
            statusText = "未安装"
            statusColor = .orange
            notInstalled = true
        case .configMissing:
            statusText = "需要完成初始化"
            statusColor = .orange
        case .endpointDisabled:
            statusText = "正在自动配置…"
            statusColor = .orange
        case .failed:
            statusText = "连接失败"
            statusColor = .red
        case .disabled:
            statusText = "已关闭自动连接"
            statusColor = .secondary
        }
    }

    private func renderHermesStatus() {
        switch HermesGatewayManager.shared.status {
        case .running, .external:
            statusText = "已连接"
            statusColor = .green
        case .starting:
            statusText = "连接中…"
            statusColor = .secondary
        case .binaryMissing:
            statusText = "未安装"
            statusColor = .orange
            notInstalled = true
        case .failed:
            statusText = "连接失败"
            statusColor = .red
        case .disabled:
            statusText = "已关闭自动连接"
            statusColor = .secondary
        }
    }
}
