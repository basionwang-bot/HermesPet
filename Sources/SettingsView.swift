import SwiftUI
import Carbon

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
    /// 当前正在"查看 / 编辑配置"的 mode。
    /// **不绑定 viewModel.agentMode** —— 设置里调这个 Picker 不会切换正在进行的对话的 mode，
    /// 仅决定下面 hermesConfig / claudeCard / codexCard 显示哪一个。
    /// 之前直接 bind viewModel.agentMode 会破坏"对话 mode 锁死"的语义（已发消息的对话被设置面板改了 mode）
    @State private var configViewingMode: AgentMode = .hermes

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

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 18) {
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
        }
    }

    /// 当前选中的服务商预设（仅给「在线 AI」配置区用）。
    /// 初值在 .onAppear 里根据 viewModel.directAPIBaseURL 反查赋值
    @State private var selectedProvider: ProviderPreset = ProviderPreset.all[0]

    // MARK: - Hermes 配置（本地 Gateway）

    private var hermesConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingRow("API 地址") {
                TextField("http://localhost:8642/v1", text: $viewModel.apiBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            settingRow("API 密钥") {
                HStack(spacing: 4) {
                    Group {
                        if showKey { TextField("your-secret-key", text: $viewModel.apiKey) }
                        else { SecureField("your-secret-key", text: $viewModel.apiKey) }
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
            settingRow("模型") {
                TextField("hermes-agent", text: $viewModel.modelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            testConnectionRow

            HStack(spacing: 6) {
                Spacer().frame(width: 92)
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text("需要先在终端运行 hermes gateway 启动 API Server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 在线 AI 配置（直连第三方 OpenAI 兼容服务商）

    private var directAPIConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部一行说明，告诉用户这就是"只用 API Key"的简单模式
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.indigo)
                Text("选一家服务商 + 填 API Key 就能聊，不依赖任何本地命令行工具")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 服务商预设 Picker
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

            captionToggle(
                icon: "figure.walk",
                iconColor: clawdColor,
                title: "Clawd 桌面漫步",
                caption: "Claude 模式 + 3 分钟无操作 → Clawd 从灵动岛跳出，沿菜单栏漫步",
                isOn: $viewModel.clawdWalkEnabled
            )

            captionToggle(
                icon: "infinity",
                iconColor: clawdColor,
                title: "自由活动",
                caption: "跳过 idle 等待，Claude 模式下 Clawd 一直在屏幕上玩",
                isOn: $viewModel.clawdFreeRoamEnabled,
                disabled: !viewModel.clawdWalkEnabled
            )

            captionToggle(
                icon: "sparkles.rectangle.stack",
                iconColor: clawdColor,
                title: "桌面巡视（Clawd 嗅文件）",
                caption: "漫步期间偶尔下到桌面，挑个图标用 Hermes 给一句短评。需要 Finder 自动化权限",
                isOn: $viewModel.clawdDesktopPatrolEnabled,
                disabled: !viewModel.clawdWalkEnabled
            )

            Divider()

            // 鼠标悬停灵动岛 500ms 的行为 —— 三选一 Picker（off / embedded / chatWindow）
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cursorarrow.rays")
                        .foregroundStyle(.indigo)
                        .frame(width: 18)
                    Text("鼠标悬停灵动岛")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $viewModel.hoverExpandMode) {
                        ForEach(HoverExpandMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 160)
                }
                Text(viewModel.hoverExpandMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.hoverExpandMode == .embedded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• 焦点临时给到灵动岛，不会切走当前 app")
                        Text("• 鼠标离开 500ms 后自动收回（打字途中不收）")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.75))
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("交互", systemImage: "hand.tap")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                interactionTip("单击", "打开聊天")
                interactionTip("双击", "切到 Claude 模式")
                interactionTip("拖文件给它", "Clawd 吃掉并交给 AI 看")
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private var clawdColor: Color {
        Color(red: 215.0/255, green: 119.0/255, blue: 87.0/255)
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
        VStack(alignment: .leading, spacing: 18) {
            soundRow("启动语音", caption: "按住 ⌘⇧V 触发录音时", binding: $viewModel.voiceStartSound)
            Divider()
            soundRow("任务完成", caption: "AI 回复完成时", binding: $viewModel.voiceFinishSound)
        }
    }

    private func soundRow(_ title: String, caption: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            HStack(spacing: 6) {
                Picker("", selection: binding) {
                    ForEach(Self.systemSounds, id: \.0) { (value, label) in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)

                Button {
                    playPreview(binding.wrappedValue)
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
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 系统

    // MARK: - 隐私（活动记录）

    @State private var activityTodayStats: [AppDailyStat] = []
    @State private var showClearActivityConfirm = false

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        ForEach(AgentMode.allCases) { mode in
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
        }
        .onAppear { refreshActivityStats() }
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
                icon: "hand.tap.fill",
                iconColor: .purple,
                title: "触觉反馈",
                caption: "切 mode / 截屏 / 按住语音 / 任务完成时给 trackpad 一次轻微震动",
                isOn: $viewModel.hapticEnabled
            )
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
                    Text("v1.0").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("macOS 顶部刘海桌宠 · AI 聊天客户端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(HotkeyAction.allCases) { action in
                    hotkeyRow(action)
                }
                aboutRow(icon: "folder.fill", label: "存储位置", value: "~/.hermespet/")
            }
            .id(hotkeyRefreshID)
        }
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

    private func playPreview(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    private var modeFooterText: String {
        switch configViewingMode {
        case .hermes:
            return "通过 Hermes API Server 调用大模型，需要自部署 OpenAI 兼容服务"
        case .directAPI:
            return "直连第三方 AI 服务商 —— 只要 API Key 就能用，无需任何本地依赖"
        case .claudeCode:
            return "通过本地 claude 命令调用 Claude Code Agent，支持文件读写与命令执行"
        case .codex:
            return "通过本地 codex 命令调用 OpenAI Codex Agent，擅长写代码 + 生成图片"
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
