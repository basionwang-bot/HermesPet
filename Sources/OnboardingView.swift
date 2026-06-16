import SwiftUI

/// 新用户首次引导（v1.3，卡片化版）。
///
/// 设计：桌宠当主角（真实 `ModeSpriteView` 像素精灵，Clawd 领衔群像）；配色取 Clawd 主色；
/// 内容**卡片化**让显示更充分、看着舒服；入场全屏呼吸灯；欢迎页宠物**持续呼吸光环**；
/// 快捷键卡片**鼠标悬停时呼吸光环**；像素点缀 + HIG 干净正文；底部放大的作者署名。
struct OnboardingView: View {
    let viewModel: ChatViewModel

    @State private var step = 0
    private let totalSteps = 4

    @State private var providerIndex = 0
    @State private var apiKey = ""
    @State private var keySaved = false

    /// 远程 presets.json 可在运行时收缩，providerIndex 可能越界 → 安全取值，越界回退首项
    private var currentPreset: ProviderPreset? {
        let all = ProviderPreset.all
        return all.indices.contains(providerIndex) ? all[providerIndex] : all.first
    }

    @AppStorage("userIntentEnabled") private var intentEnabled = false
    @AppStorage("userMemoryEnabled") private var memoryEnabled = false

    private var accent: Color { PetPaletteStore.shared.palette(for: .claudeCode).primary }
    private let supportingModes: [AgentMode] = [.directAPI, .hermes, .codex, .openclaw]

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    languagePicker
                    Spacer()
                    Button(L("onboarding.nav.skip")) { viewModel.completeOnboarding() }
                        .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.top, 14)

                // 品牌头 —— 贯穿每一页固定在顶部
                brandMark
                    .padding(.top, 2).padding(.bottom, 10)

                ScrollView {
                    stepContent
                        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                }

                navBar
            }
        }
        // 全屏彩色光环：停在第 1 屏就一直亮着呼吸，点「下一步」离开第 1 屏才收
        .onAppear { updateEntranceGlow() }
        .onChange(of: step) { _, _ in updateEntranceGlow() }
        .onDisappear { IntelligenceOverlayController.shared.hide() }
    }

    private func updateEntranceGlow() {
        if step == 0 {
            IntelligenceOverlayController.shared.show(playSound: false)
        } else {
            IntelligenceOverlayController.shared.hide()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: providerStep
        case 2: capabilitiesStep
        default: shortcutsStep
        }
    }

    // MARK: - ① 欢迎（Clawd 领衔群像 + 持续呼吸光环）

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            WelcomeHero(supportingModes: supportingModes)

            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    pixelStar
                    Text(L("onboarding.welcome.greeting"))
                        .font(.system(size: 20, weight: .semibold))
                    pixelStar
                }

                (
                    Text(L("onboarding.welcome.body.prefix"))
                        .foregroundStyle(.secondary)
                    + Text("⌘⇧H").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    + Text(L("onboarding.welcome.body.suffix")).foregroundStyle(.secondary)
                )
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(cardBG)

            Text(L("onboarding.welcome.hint"))
                .font(.system(size: 14)).foregroundStyle(.tertiary)
        }
    }

    /// 语言选择（中文 / English）—— 新用户首屏顶栏就能选，切了整个引导即时切换（Observation 自动重渲染）
    private var languagePicker: some View {
        @Bindable var locale = LocaleManager.shared
        return Picker("", selection: $locale.language) {
            ForEach(AppLanguage.allCases) { lang in
                Text(lang.displayName).tag(lang)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
    }

    /// HermesPet 字标（品牌头，贯穿每一页固定在顶部）
    private var brandMark: some View {
        VStack(spacing: 6) {
            (Text("Hermes").foregroundStyle(.primary.opacity(0.92))
             + Text("Pet").foregroundStyle(accent))
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .tracking(0.5)
            Text(L("onboarding.brand.tagline"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .tracking(7)
        }
    }

    // MARK: - ② 选 AI 配 Key

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(icon: "cloud.fill", title: L("onboarding.provider.title"))

            VStack(alignment: .leading, spacing: 14) {
                Text(L("onboarding.provider.intro"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    ModeSpriteView(mode: .directAPI, isWorking: false, size: 28, animated: true)
                        .frame(width: 32, height: 32)
                    Text(L("onboarding.provider.label")).font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $providerIndex) {
                        ForEach(Array(ProviderPreset.all.enumerated()), id: \.offset) { idx, p in
                            Text(p.localizedDisplayName).tag(idx)
                        }
                    }
                    .labelsHidden().frame(width: 150)
                    .onChange(of: providerIndex) { _, _ in keySaved = false }
                }

                if let preset = currentPreset,
                   let signup = preset.signupURL,
                   let url = URL(string: signup) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text(L("onboarding.provider.applyKey", preset.displayName))
                        }.font(.system(size: 13))
                    }
                }

                SecureField(L("onboarding.provider.keyPlaceholder"), text: $apiKey)
                    .textFieldStyle(.roundedBorder).font(.system(size: 14))
                    .onChange(of: apiKey) { _, _ in keySaved = false }

                HStack {
                    Button { saveProviderConfig() } label: {
                        Label(keySaved ? L("onboarding.provider.saved") : L("onboarding.provider.save"), systemImage: keySaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if keySaved {
                        Text(L("onboarding.provider.savedHint")).font(.system(size: 13)).foregroundStyle(.green)
                    }
                    Spacer()
                }

                Text(L("onboarding.provider.footnote"))
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(cardBG)
        }
    }

    // MARK: - ③ 懂你能力（4 个 opt-in 开关，每个一张卡）

    private var capabilitiesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(icon: "heart.text.square.fill", title: L("onboarding.capabilities.title"))

            Text(L("onboarding.capabilities.intro"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            optInCard(title: L("onboarding.capabilities.activity.title"),
                      desc: L("onboarding.capabilities.activity.desc"),
                      isOn: Binding(get: { viewModel.activityRecordingEnabled },
                                    set: { viewModel.activityRecordingEnabled = $0 }))
            optInCard(title: L("onboarding.capabilities.intent.title"),
                      desc: L("onboarding.capabilities.intent.desc"),
                      isOn: $intentEnabled)
            optInCard(title: L("onboarding.capabilities.memory.title"),
                      desc: L("onboarding.capabilities.memory.desc"),
                      isOn: $memoryEnabled)
            optInCard(title: L("onboarding.capabilities.launch.title"),
                      desc: L("onboarding.capabilities.launch.desc"),
                      isOn: Binding(get: { viewModel.isLaunchAtLoginOn },
                                    set: { viewModel.setLaunchAtLogin($0) }))
        }
    }

    // MARK: - ④ 快捷键（每个一张卡，hover 呼吸光环）

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(icon: "keyboard.fill", title: L("onboarding.shortcuts.title"))

            ShortcutCard(key: "⌘⇧H", desc: L("onboarding.shortcuts.toggleChat"))
            ShortcutCard(key: "⌘⇧V", desc: L("onboarding.shortcuts.voice"))
            ShortcutCard(key: "⌘⇧Space", desc: L("onboarding.shortcuts.quickAsk"))
            ShortcutCard(key: "⌘⇧J", desc: L("onboarding.shortcuts.capture"))

            Text(L("onboarding.shortcuts.footnote"))
                .font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top, 2)
        }
    }

    // MARK: - 小组件

    private var pixelStar: some View {
        RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 7, height: 7).opacity(0.85)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func stepHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(accent)
            Text(title).font(.system(size: 18, weight: .semibold))
        }
    }

    private func optInCard(title: String, desc: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(desc).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // 开关统一靠右、垂直居中，几张卡右边对齐
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(accent)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(cardBG)
    }

    // MARK: - 底部导航 + 署名

    private var navBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle().fill(i == step ? accent : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }

            HStack {
                if step > 0 {
                    Button(L("onboarding.nav.prev")) { withAnimation(.easeInOut(duration: 0.18)) { step -= 1 } }
                        .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                if step < totalSteps - 1 {
                    Button(L("onboarding.nav.next")) { withAnimation(.easeInOut(duration: 0.18)) { step += 1 } }
                        .buttonStyle(.borderedProminent).tint(accent).font(.system(size: 14))
                } else {
                    Button(L("onboarding.nav.start")) { viewModel.completeOnboarding() }
                        .buttonStyle(.borderedProminent).tint(accent).font(.system(size: 14, weight: .semibold))
                }
            }

            // 作者署名（放大）
            (Text(L("onboarding.credit.prefix")).foregroundStyle(.secondary)
             + Text("王百琛").foregroundStyle(.primary).bold())
                .font(.system(size: 15))
                .padding(.top, 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: - 保存服务商配置

    private func saveProviderConfig() {
        guard let preset = currentPreset else { return }
        UserDefaults.standard.set(preset.id, forKey: "directAPIProviderID")
        viewModel.directAPIBaseURL = preset.baseURL
        viewModel.directAPIModel = preset.model(for: viewModel.directAPIResponsePreference)
        viewModel.directAPIKey = apiKey.trimmingCharacters(in: .whitespaces)
        viewModel.morningBriefingBackend = .directAPI
        withAnimation(AnimTok.snappy) { keySaved = true }
    }
}

// MARK: - 欢迎页 hero（Clawd 领衔群像 + 持续呼吸光环）

private struct WelcomeHero: View {
    let supportingModes: [AgentMode]
    @State private var breathe = false
    @State private var hue: Double = 0
    private var colors: [Color] { IntelligenceGlowView.appleAIColors }

    var body: some View {
        ZStack {
            // 持续呼吸的彩色光环
            Circle()
                .fill(AngularGradient(gradient: Gradient(colors: colors), center: .center))
                .frame(width: 200, height: 200)
                .blur(radius: 38)
                .opacity(breathe ? 0.5 : 0.26)
                .scaleEffect(breathe ? 1.06 : 0.9)
                .hueRotation(.degrees(hue))

            VStack(spacing: 12) {
                ModeSpriteView(mode: .claudeCode, isWorking: false, size: 66, animated: true)
                    .frame(height: 58)
                HStack(spacing: 16) {
                    ForEach(supportingModes, id: \.self) { m in
                        ModeSpriteView(mode: m, isWorking: false, size: 32, animated: true)
                            .frame(width: 36, height: 36).opacity(0.92)
                    }
                }
            }
        }
        .frame(height: 168)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) { breathe = true }
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { hue = 360 }
        }
    }
}

// MARK: - 快捷键卡片（hover 呼吸光环）

private struct ShortcutCard: View {
    let key: String
    let desc: String
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.primary.opacity(0.07)))
                .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
            Text(desc).font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .background {
            if hovered { CardGlow().padding(-3) }
        }
        .scaleEffect(hovered ? 1.01 : 1.0)
        .animation(AnimTok.snappy, value: hovered)
        .onHover { hovered = $0 }
    }
}

/// 卡片悬停时的"动态光环呼吸"—— 多色描边 + 持续呼吸 + 缓慢色相流动（一直亮的呼吸效果）
private struct CardGlow: View {
    @State private var breathe = false
    @State private var hue: Double = 0
    private var colors: [Color] { IntelligenceGlowView.appleAIColors }

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                AngularGradient(gradient: Gradient(colors: colors), center: .center),
                lineWidth: 3
            )
            .blur(radius: 6)
            .hueRotation(.degrees(hue))
            .opacity(breathe ? 0.95 : 0.4)
            .scaleEffect(breathe ? 1.015 : 0.99)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { breathe = true }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { hue = 360 }
            }
    }
}
