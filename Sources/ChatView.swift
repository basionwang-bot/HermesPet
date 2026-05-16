import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    @State private var showClearConfirm = false
    @State private var isDropTargeted = false
    /// 聊天区是否贴近底部。用户手动上滑看历史时置 false，
    /// 流式输出就不再强行 scrollTo bottom 抢滚动。
    @State private var isMessagesNearBottom = true

    private static let messagesScrollSpace = "HermesPetMessagesScroll"
    private static let messagesBottomAnchorID = "HermesPetMessagesBottomAnchor"

    /// 新建画布的 Sheet 控制（点 + 菜单"新建画布"时打开）
    @State private var showCanvasCreator = false

    /// 当前激活对话是否是画布类型 —— 决定主区域渲染 CanvasView 还是 messagesView
    private var isActiveCanvas: Bool {
        viewModel.conversations.first(where: { $0.id == viewModel.activeConversationID })?.kind == .canvas
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // 主区域：画布 OR 消息列表
            if isActiveCanvas {
                CanvasView(viewModel: viewModel, conversationID: viewModel.activeConversationID)
            } else {
                messagesView
            }

            // Input —— 自带 hairline 分割 + 渐变背景，不再需要 Divider
            ChatInputField(
                text: $viewModel.inputText,
                isLoading: viewModel.isLoading,
                pendingImages: viewModel.pendingImages,
                pendingDocuments: viewModel.pendingDocuments,
                tint: headerTint,
                onSend: {
                    isMessagesNearBottom = true
                    viewModel.sendMessage()
                },
                onCancel: { viewModel.cancelCurrentRequest() },
                onPasteImage: { viewModel.addPendingImage($0) },
                onRemoveImage: { viewModel.removePendingImage(at: $0) },
                onRemoveDocument: { viewModel.removePendingDocument(at: $0) }
            )
        }
        // 错误 toast 从顶部浮现，3.5s 自动消失，点 × 立即关
        .overlay(alignment: .top) {
            if let err = viewModel.errorMessage {
                ErrorToast(message: err) { viewModel.dismissError() }
                    .padding(.top, 56)             // 避开 header
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(AnimTok.smooth, value: viewModel.errorMessage)
        // 隐藏按钮组：承载键盘快捷键，不参与视觉
        .background { keyboardShortcutsLayer }
        // 新建画布的 Sheet —— 让用户选模板 + 填主题 + 上传产品参考图
        .sheet(isPresented: $showCanvasCreator) {
            CanvasCreatorSheet { template, topic, refImages in
                viewModel.createCanvasConversation(template: template, topic: topic, referenceImageURLs: refImages)
                showCanvasCreator = false
            } onCancel: {
                showCanvasCreator = false
            }
        }
        // 全窗口拖拽接收 —— 图片走 pendingImages，文档只附加路径（Claude/Codex 自己 Read）
        .onDrop(of: DragDropUtil.acceptedUTTypes, isTargeted: $isDropTargeted) { providers in
            DragDropUtil.handleProviders(
                providers,
                onImage: { png in viewModel.addPendingImage(png) },
                onDocument: { url in viewModel.attachDocumentPath(url) }
            )
        }
        // 拖入悬浮时的全窗口高亮 + 提示文字
        .overlay {
            if isDropTargeted {
                DragOverlay(tint: headerTint)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(AnimTok.snappy, value: isDropTargeted)
        // 清空对话的确认弹窗
        .confirmationDialog(
            "清空当前对话？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                viewModel.clearChat()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这条对话的所有消息会被清掉，无法恢复。其他对话不受影响。")
        }
        // 不固定 frame，跟随 NSWindow 自适应。
        // ⚠️ 决策 #7：**不要写 minWidth/minHeight** —— ChatWindowController.hide() 把窗口缩到
        // 100×30 时，SwiftUI 的最小尺寸要求会反向请求 window 改 frame，触发 NSHostingView
        // 嵌套 layout cycle，macOS 26 直接抛 NSException 必崩（issue #3 的 .ips 就是这个）。
        // 最小尺寸由 NSWindow.contentMinSize 在动画外控制（ChatWindowController init 里设 360×360）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v1.0 的稳定窗口结构：SwiftUI 自己提供 material 背景，NSWindow 只承载 hosting controller。
        // 不再用 NSVisualEffectView 手动包 hosting view；那会在 transparent titlebar 下引入顶部空白/遮挡。
        .background(.ultraThinMaterial)
        // 圆角浮窗：clipShape + window.hasShadow=true 让阴影也跟着圆角走
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 极淡边框增强层次感
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 键盘快捷键

    /// 一组 0×0 隐藏按钮，专门承载键盘快捷键：
    ///   ⌘N      新对话
    ///   ⌘[ / ⌘] 上一个 / 下一个对话
    ///   ⌘1/⌘2/⌘3 直接切到对应序号
    ///   ⌘⌫      关闭当前对话（保留 ⌘W 给 macOS 关窗口默认行为）
    private var keyboardShortcutsLayer: some View {
        ZStack {
            Button("New Chat") { viewModel.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Prev Chat") { viewModel.switchToPreviousConversation() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Chat") { viewModel.switchToNextConversation() }
                .keyboardShortcut("]", modifiers: .command)
            // ⌘1~⌘8 直达对应序号对话（对应 kMaxConversations = 8）
            ForEach(1...8, id: \.self) { n in
                Button("Chat \(n)") { viewModel.switchToConversation(index: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("Close Chat") {
                if viewModel.conversations.count > 1 {
                    viewModel.closeCurrentConversation()
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 4) {
            // 画布对话：显示混合模式标签（规划走在线 AI，生图走 Codex），不可切换
            // 普通对话：显示 ModeSwitcherButton 可切 hermes / directAPI / claudeCode / codex
            if isActiveCanvas {
                CanvasModeBadge(tint: headerTint)
            } else {
                ModeSwitcherButton(
                    mode: viewModel.agentMode,
                    tint: headerTint,
                    isLocked: currentConversationLocked,
                    onTap: viewModel.toggleAgentMode,
                    onLockedTap: {
                        viewModel.errorMessage = "这个对话已锁定为 \(viewModel.agentMode.label)；想换模型请新建对话。"
                    }
                )
            }

            // 对话胶囊：最多 3 个，可切换 / 新建 / 关闭 / 右键重命名
            ConversationPills(
                conversations: viewModel.conversations,
                activeID: viewModel.activeConversationID,
                canAddMore: viewModel.conversations.count < kMaxConversations,
                tint: headerTint,
                onSelect: { viewModel.switchConversation(to: $0) },
                onClose: { viewModel.closeConversation(id: $0) },
                onAdd: { viewModel.newConversation() },
                onAddCanvas: { showCanvasCreator = true },
                onRename: { id, newTitle in viewModel.renameConversation(id: id, to: newTitle) }
            )
            .padding(.leading, 2)

            Spacer()

            // 连接状态点（connected 时呼吸）
            ConnectionDot(
                color: connectionDotColor,
                isPulsing: viewModel.connectionStatus.isConnected
            )
            // mode 切换时颜色平滑过渡
            .animation(AnimTok.smooth, value: viewModel.agentMode)
            .padding(.horizontal, 6)

            HeaderIconButton(systemName: "camera.viewfinder", help: "截屏并附加（隐藏窗口截全屏）") {
                viewModel.captureScreenAndAttach { hide in
                    if let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                        win.alphaValue = hide ? 0 : 1
                    }
                }
            }

            HeaderIconButton(systemName: "pin", help: "导出全部 Pin 为 Markdown") {
                PinCardController.shared.exportAllPinsToMarkdown()
            }
            .disabled(PinStore.shared.pins.isEmpty)

            HeaderIconButton(systemName: "gearshape.fill", help: "设置") {
                viewModel.showSettings.toggle()
            }
            .popover(isPresented: $viewModel.showSettings) {
                // SettingsView 内部自己控制 frame
                SettingsView(viewModel: viewModel)
            }

            HeaderIconButton(systemName: "square.and.arrow.up", help: "导出对话为 Markdown") {
                viewModel.exportChatToMarkdown()
            }

            HeaderIconButton(systemName: "trash", help: "清空当前对话") {
                showClearConfirm = true
            }

            HeaderIconButton(systemName: "doc.on.doc", help: "复制最后一条回复") {
                viewModel.copyLastResponse()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 极淡叠层 —— 跟主区域有微对比，但不喧宾夺主
        .background(Color.primary.opacity(0.03))
    }

    private var headerTint: Color {
        switch viewModel.agentMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    /// 当前对话是否已锁定 mode（发过 user 消息就锁）—— 用于 mode 切换器禁用判断
    private var currentConversationLocked: Bool {
        viewModel.conversations
            .first(where: { $0.id == viewModel.activeConversationID })?
            .hasUserMessages ?? false
    }

    private var connectionDotColor: Color {
        switch viewModel.connectionStatus {
        case .connected:    return .green
        case .disconnected: return .red
        case .unknown:      return .gray
        }
    }

    // MARK: - Messages

    /// 新对话欢迎状态：只有 1 条 assistant 欢迎消息、没有用户消息时显示快捷启动卡片
    private var showSuggestions: Bool {
        viewModel.messages.count == 1 &&
        viewModel.messages.first?.role == .assistant &&
        !viewModel.isLoading
    }

    /// 新用户引导卡显示条件：在线 AI 模式 + 没填 API Key（dmg 分发场景对方默认就在这个 mode）。
    /// 让对方第一次打开就知道"要去设置里选服务商 + 配置 Key 才能聊天"
    private var showOnboardingCard: Bool {
        viewModel.agentMode == .directAPI && viewModel.directAPIKey.isEmpty
    }

    private var suggestionItems: [(icon: String, text: String, prompt: String)] {
        switch viewModel.agentMode {
        case .hermes, .directAPI:
            return [
                ("camera.viewfinder", "分析这张截图", "帮我看看这张截图说的什么意思"),
                ("doc.text", "总结一段文字", "把下面这段帮我总结一下："),
                ("globe", "翻译成中文", "把下面这段翻译成中文："),
                ("lightbulb", "解释概念", "用通俗的话解释一下：")
            ]
        case .claudeCode:
            return [
                ("folder", "看下当前项目", "帮我看下这个项目的结构和大概在做什么"),
                ("doc.badge.plus", "生成 MD 文档", "帮我生成一份关于 xxx 的 Markdown 文档"),
                ("magnifyingglass", "排查问题", "帮我找一下 xxx 这个问题在哪里"),
                ("hammer", "写段代码", "帮我写一段 TypeScript 代码做：")
            ]
        case .codex:
            return [
                ("photo.on.rectangle", "生成一张图", "帮我生成一张「主题」的图，"),
                ("paintbrush", "修图", "把这张图改成「描述」风格"),
                ("rectangle.stack.badge.plus", "出多张概念图", "围绕「主题」给我 3 张不同风格的图"),
                ("text.below.photo", "图配文字海报", "做一张海报：主标题「」，副标题「」，风格「」")
            ]
        }
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // 新对话欢迎页：精致的 WelcomeView 替代纯文字欢迎语
                        if showSuggestions {
                            WelcomeView(mode: viewModel.agentMode, tint: headerTint)
                                .padding(.top, 12)
                                .padding(.bottom, 8)
                                .transition(.opacity)

                            // 轻量 Onboarding：Hermes 模式 + 没填 API Key 时显示"配置 Key"引导卡。
                            // 不弹窗、不挡住其他 UI，点击即打开设置面板
                            if showOnboardingCard {
                                OnboardingCard(
                                    tint: headerTint,
                                    onTap: { viewModel.showSettings = true }
                                )
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        ForEach(viewModel.messages) { message in
                            // 新对话状态下，"原始欢迎消息"由 WelcomeView 代替，不再显示这条 assistant 占位
                            if !(showSuggestions && message.role == .assistant) {
                                MessageBubbleView(
                                    message: message,
                                    agentMode: viewModel.agentMode,
                                    conversationID: viewModel.activeConversationID,
                                    onRetry: { viewModel.retryLastMessage() },
                                    onChoiceSelected: { choice in
                                        viewModel.submitVoiceInput(choice)
                                    },
                                    onPinTask: { task in
                                        // 📌 Pin → 创建任务 Pin 到桌面
                                        PinCardController.pinTask(task)
                                    },
                                    onDispatchTask: { task in
                                        // 🤖 让 AI 做 → 新建对话派发给推荐的 mode
                                        viewModel.dispatchTaskToNewConversation(task)
                                    }
                                )
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                                        removal: .opacity
                                    ))
                            }
                        }

                        // 新对话欢迎状态 —— 几个快捷启动卡片，点击即填入输入框
                        if showSuggestions {
                            SuggestionGrid(
                                items: suggestionItems,
                                tint: headerTint,
                                onTap: { prompt in
                                    viewModel.inputText = prompt
                                }
                            )
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.messagesBottomAnchorID)
                            .background(
                                GeometryReader { marker in
                                    Color.clear.preference(
                                        key: MessagesBottomYPreferenceKey.self,
                                        value: marker.frame(in: .named(Self.messagesScrollSpace)).maxY
                                    )
                                }
                            )
                    }
                    .padding(12)
                    .animation(AnimTok.smooth, value: viewModel.messages.count)
                    .animation(AnimTok.smooth, value: showSuggestions)
                }
                .coordinateSpace(name: Self.messagesScrollSpace)
                .onPreferenceChange(MessagesBottomYPreferenceKey.self) { bottomY in
                    let distanceToBottom = bottomY - viewport.size.height
                    isMessagesNearBottom = distanceToBottom < 72
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: viewModel.activeConversationID) { _, _ in
                    isMessagesNearBottom = true
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if isMessagesNearBottom {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: viewModel.messages.last?.content.count) { _, _ in
                    if viewModel.messages.last?.isStreaming == true, isMessagesNearBottom {
                        scrollToBottom(proxy)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetScrollToMessage"))) { note in
                    if let msgID = note.userInfo?["messageID"] as? String {
                        withAnimation(AnimTok.smooth) {
                            proxy.scrollTo(msgID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !viewModel.messages.isEmpty else { return }
        if animated {
            withAnimation(AnimTok.smooth) {
                proxy.scrollTo(Self.messagesBottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.messagesBottomAnchorID, anchor: .bottom)
        }
    }
}

private struct MessagesBottomYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 全窗口拖拽提示

struct DragOverlay: View {
    let tint: Color

    var body: some View {
        ZStack {
            // 半透明 tint 罩层
            tint.opacity(0.08)

            // 中央"释放以附加"卡片
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(tint)
                Text("释放以附加")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("图片走附件 · 文档传路径让 AI 自己读")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.2), radius: 14, y: 4)
        }
        .overlay(
            // 整个窗口的虚线框
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                .padding(6)
        )
    }
}

// MARK: - 错误 Toast

struct ErrorToast: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.4), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - 新对话欢迎页

struct WelcomeView: View {
    let mode: AgentMode
    let tint: Color

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            // 大号 mode 图标 + tint 渐变光晕 + 呼吸动画
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.25), tint.opacity(0.0)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 50
                        )
                    )
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle().stroke(tint.opacity(0.2), lineWidth: 0.5)
                    )
                Image(systemName: mode.iconName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(height: 100)

            VStack(spacing: 4) {
                Text(welcomeTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(welcomeSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var welcomeTitle: String {
        switch mode {
        case .hermes:     return "Hermes 桌宠"
        case .directAPI:  return "在线 AI"
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    private var welcomeSubtitle: String {
        switch mode {
        case .hermes:
            return "随时找我聊天 / 截图分析 / 翻译 / 写作\n语音问问题：按住 ⌘⇧V 说话"
        case .directAPI:
            return "直连第三方 AI 服务商\n只要 API Key 就能聊，零本地依赖"
        case .claudeCode:
            return "我能改文件、跑命令、读代码\n动手能力最强的 AI"
        case .codex:
            return "写代码 + 生成图片\n擅长视觉创作的 OpenAI 助手"
        }
    }
}

// MARK: - 新对话快捷启动卡片

struct SuggestionGrid: View {
    let items: [(icon: String, text: String, prompt: String)]
    let tint: Color
    let onTap: (String) -> Void

    // 两列网格
    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                SuggestionCard(
                    icon: item.icon,
                    text: item.text,
                    tint: tint,
                    onTap: { onTap(item.prompt) }
                )
            }
        }
    }
}

struct SuggestionCard: View {
    let icon: String
    let text: String
    let tint: Color
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}

// MARK: - 对话胶囊条（最多 3 个）

struct ConversationPills: View {
    let conversations: [Conversation]
    let activeID: String
    let canAddMore: Bool
    let tint: Color
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onAdd: () -> Void
    let onAddCanvas: () -> Void
    let onRename: (String, String) -> Void

    var body: some View {
        // 横向 ScrollView —— 对话上限提到 8 之后，header 装不下，超出可滑动
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(conversations.enumerated()), id: \.element.id) { (idx, conv) in
                        ConversationPill(
                            index: idx + 1,
                            title: conv.title,
                            isActive: conv.id == activeID,
                            hasUnread: conv.hasUnread && conv.id != activeID,
                            isBackgroundStreaming: conv.isStreaming && conv.id != activeID,
                            canClose: conversations.count > 1,
                            tint: tint,
                            onSelect: { onSelect(conv.id) },
                            onClose: { onClose(conv.id) },
                            onRename: { newTitle in onRename(conv.id, newTitle) }
                        )
                        .id(conv.id)
                    }
                    if canAddMore {
                        AddPillButton(onAdd: onAdd, onAddCanvas: onAddCanvas)
                    }
                }
                .padding(.vertical, 2)   // 留点空间给底部发光线和未读红点不被裁
            }
            .onChange(of: activeID) { _, newID in
                // 切换对话时自动滚到对应胶囊，确保超出视口的也能露面
                withAnimation(AnimTok.smooth) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .animation(AnimTok.smooth, value: conversations.count)
        .animation(AnimTok.smooth, value: activeID)
    }
}

struct ConversationPill: View {
    let index: Int
    let title: String
    let isActive: Bool
    let hasUnread: Bool
    /// 非激活对话正在后台流式 → 显示底部呼吸发光线
    var isBackgroundStreaming: Bool = false
    let canClose: Bool
    let tint: Color
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var streamPulse = false
    private let pillDiameter: CGFloat = 18
    private var expandedWidth: CGFloat { (isHovering && canClose) ? 34 : pillDiameter }

    var body: some View {
        HStack(spacing: isHovering && canClose ? 4 : 3) {
            Button(action: onSelect) {
                Text("\(index)")
                    .font(.system(size: 11, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.white : .secondary)
                    .frame(width: 10, height: pillDiameter)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering && canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isActive ? Color.white.opacity(0.9) : .secondary)
                        .frame(width: 10, height: pillDiameter)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭对话")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.72, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.72, anchor: .leading).combined(with: .opacity)
                ))
            }
        }
        .frame(width: expandedWidth, height: pillDiameter)
        .background(
            Capsule()
                .fill(isActive
                      ? AnyShapeStyle(tint.opacity(0.85))
                      : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.08 : 0)))
        )
        .overlay(
            Capsule()
                .stroke(isActive ? Color.clear : Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        // 后台对话完成时的未读红点 —— 浮在胶囊右上角
        .overlay(alignment: .topTrailing) {
            if hasUnread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                    .offset(x: 2, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // 后台流式中的发光线 —— 浮在胶囊底部，呼吸 (mode tint)
        .overlay(alignment: .bottom) {
            if isBackgroundStreaming {
                Capsule()
                    .fill(tint)
                    .frame(height: 1.5)
                    .shadow(color: tint.opacity(0.8), radius: 2)
                    .opacity(streamPulse ? 1.0 : 0.45)
                    .offset(y: 2)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            streamPulse = true
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(AnimTok.snappy, value: hasUnread)
        .animation(AnimTok.snappy, value: isBackgroundStreaming)
        .animation(AnimTok.snappy, value: isHovering)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
        .help(canClose ? "\(title) · 悬停可关闭，右键可重命名" : title)
        // 右键菜单：重命名、关闭
        .contextMenu {
            Button {
                renameDraft = title
                isRenaming = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            if canClose {
                Divider()
                Button(role: .destructive, action: onClose) {
                    Label("关闭对话", systemImage: "xmark")
                }
            }
        }
        // 重命名弹出层：小输入框，回车确认 / ESC 取消
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                TextField("新名称", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit {
                        onRename(renameDraft)
                        isRenaming = false
                    }
                Button("确定") {
                    onRename(renameDraft)
                    isRenaming = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
    }
}

struct AddPillButton: View {
    /// 单击：新建普通对话；画布模式开启时弹菜单可选画布
    let onAdd: () -> Void
    let onAddCanvas: () -> Void
    @State private var isHovering = false
    /// 画布模式是实验性功能，默认隐藏；用户在设置→系统→实验性功能里打开后才显示"新建画布"
    @AppStorage("canvasModeEnabled") private var canvasModeEnabled: Bool = false
    private let pillDiameter: CGFloat = 18

    var body: some View {
        Group {
            if canvasModeEnabled {
                Menu {
                    Button {
                        onAdd()
                    } label: { Label("新建对话", systemImage: "message") }
                    Button {
                        onAddCanvas()
                    } label: { Label("新建画布", systemImage: "rectangle.3.group") }
                } label: { plusIcon }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建（对话 / 画布）")
            } else {
                // 画布关闭时退化成简单按钮：点一下直接新建对话，不弹菜单
                Button(action: onAdd) { plusIcon }
                    .buttonStyle(.plain)
                    .help("新建对话")
            }
        }
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }

    private var plusIcon: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: pillDiameter, height: pillDiameter)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
    }
}

// MARK: - 画布模式 Badge（混合：规划用在线 AI，生图用 Codex）
//
// 画布对话本质是"混合 mode"，单一 mode 字段表达不准。这个 badge 明确告诉用户：
// - 这是画布工作区（不是普通聊天）
// - 文字规划用在线 AI（速度 + 中文好）
// - 图片生成用 Codex（GPT Image 2 中文渲染好）

struct CanvasModeBadge: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 0) {
                Text("画布")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("在线 AI · Codex")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.indigo.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(Color.indigo.opacity(0.25), lineWidth: 0.5)
        )
        .help("画布工作区 · 规划用在线 AI，图片生成走 Codex（GPT Image 2）")
    }
}

// MARK: - mode 切换按钮（带 hover 高亮 + tap 弹性反馈 + 颜色过渡）

struct ModeSwitcherButton: View {
    let mode: AgentMode
    let tint: Color
    /// 对话已发过 user 消息 → mode 锁死，按钮右侧的 chevron 变成锁图标，点击走 onLockedTap
    var isLocked: Bool = false
    let onTap: () -> Void
    var onLockedTap: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: mode.iconName)
                .foregroundStyle(tint)
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))
            Text(mode.label)
                .font(.headline)
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            // 锁定时显示小锁；未锁定时显示上下箭头表"可切换"
            Image(systemName: isLocked ? "lock.fill" : "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isLocked ? .secondary : .tertiary)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                // 锁定状态不再 hover 高亮（避免误以为可点）
                .fill(.primary.opacity(isHovering && !isLocked ? 0.06 : 0))
        )
        .scaleEffect(isPressed ? 0.94 : 1.0)
        .opacity(isLocked ? 0.85 : 1.0)
        .animation(AnimTok.snappy, value: isHovering)
        .animation(AnimTok.bouncy, value: isPressed)
        .animation(AnimTok.smooth, value: mode)
        .animation(AnimTok.smooth, value: isLocked)
        .onHover { hovering in isHovering = hovering }
        .onTapGesture {
            if isLocked {
                onLockedTap?()
                return
            }
            isPressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isPressed = false
            }
            onTap()
        }
        .help(isLocked
              ? "此对话已锁定为 \(mode.label)；想换模型请新建对话（⌘N）"
              : "点击切换：Hermes → Claude Code → Codex")
    }
}

// MARK: - 复用：带 hover 反馈的 header 小按钮

struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.primary.opacity(isHovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}

// MARK: - 新用户 Onboarding 卡片
//
// 出现条件（由 ChatView.showOnboardingCard 决定）：Hermes 模式 + apiKey 为空。
// 设计：轻量、可关闭（点击直接跳设置面板），不挡住快捷启动卡片。
// 给把 dmg 分享给朋友的场景做的 —— 对方第一次打开就能看到"该去哪儿配 Key"的提示

struct OnboardingCard: View {
    let tint: Color
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("先选个 AI 服务商再聊天")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("点这里打开设置 · 内置 DeepSeek / 智谱 / Kimi / OpenAI 预设")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(isHovering ? 0.14 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}

// MARK: - 连接状态点：connected 时呼吸；其他状态稳定显示

struct ConnectionDot: View {
    let color: Color
    let isPulsing: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            // 外圈光晕（呼吸）
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 1.4 : 1.0)
                    .opacity(pulse ? 0 : 0.6)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            if isPulsing {
                withAnimation(AnimTok.breathe) { pulse = true }
            }
        }
        .onChange(of: isPulsing) { _, newValue in
            if newValue {
                pulse = false
                withAnimation(AnimTok.breathe) { pulse = true }
            }
        }
    }
}
