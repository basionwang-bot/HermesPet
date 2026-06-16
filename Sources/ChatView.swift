import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    @State private var showClearConfirm = false
    @State private var isDropTargeted = false

    /// 聊天正文字号缩放（⌘+ / ⌘- / ⌘0 控制）—— 持久化在 UserDefaults
    @AppStorage(ChatFontScale.storageKey) private var chatFontScale: Double = ChatFontScale.default
    /// 写作模式：中间文档画布**独立**字号（与右侧聊天分开缩放，按鼠标所在区域路由）
    @AppStorage("notesDocFontScale") private var docFontScale: Double = ChatFontScale.default
    /// 写作模式里鼠标当前所在区域 —— ⌘+/⌘- 缩放鼠标所在那块（用户要的"放大指定区域"）
    @State private var wmHoverRegion: ScaleRegion = .chat
    /// ⌘+/⌘- 触发后短暂显示当前档位 toast（"字号 115%"），2s 自动消失
    @State private var fontScaleToast: String? = nil

    private static let messagesBottomAnchorID = "HermesPetMessagesBottomAnchor"

    /// 新建画布的 Sheet 控制（点 + 菜单"新建画布"时打开）
    @State private var showCanvasCreator = false

    /// 历史对话面板（点 header 时钟图标打开）—— 窗内覆盖层，可翻可搜可重开
    @State private var showHistory = false

    /// 流式时是否自动贴底跟随。用户往上翻看历史 → 置 false 暂停跟随（不再被拽回底部）；
    /// 滚回接近底部 / 切对话 / 发新消息 → 重新置 true。
    /// 由 onScrollGeometryChange（macOS 15+）按"是否接近底部"驱动；macOS 14 无该 API 时恒为 true（始终跟随）。
    @State private var autoFollow = true

    // 写作模式三栏：可拖宽 + 可收起 + 窄窗自适应折叠
    // 左侧文件栏**默认收起**（只留窄条，点开才显示完整文件列表）—— 进写作先专注写，找文件再展开
    @State private var wmSidebarCollapsed = true
    @State private var wmChatCollapsed = false
    @State private var wmSidebarWidth: CGFloat = 240
    @State private var wmChatWidth: CGFloat = 360
    /// 当前三栏区域可用宽度（由 ChatWindowController 在窗口 resize 时广播）—— 驱动自适应折叠 + 动态夹宽
    @State private var wmAvailWidth: CGFloat = 1080
    /// 鼠标在对话栏内 —— 顶角的「收起对话」chevron 才浮现（极简：默认不常驻）
    @State private var wmChatHover = false

    /// 中间文档至少保留这么宽，否则宁可收边栏也不让文字溢出
    private static let wmMinMiddle: CGFloat = 340
    /// 收起态图标条占位宽（rail 52 + divider 1）
    private static let wmRailWidth: CGFloat = 53

    /// 当前激活对话是否是画布类型 —— 决定主区域渲染 CanvasView 还是 messagesView
    private var isActiveCanvas: Bool {
        viewModel.conversations.first(where: { $0.id == viewModel.activeConversationID })?.kind == .canvas
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部桌宠状态条 —— 占据 NSWindow titlebar 透明区 (28pt)，
            // 让用户能看到"是哪只小宠物在帮我处理" + 实时工具进度
            PetHeaderStrip(viewModel: viewModel)

            // Header —— 写作模式走极简顶栏（‹ · 文档标题 · ⋯，双击最大化），普通聊天走原 header
            if viewModel.isWritingMode {
                writingHeader
            } else {
                headerView
            }

            Divider()

            // 主区域：写作模式三栏 / 普通对话内容（对话内容含 messagesView+contextBar+输入栏，
            // 普通模式直接铺、写作模式当 HSplitView 右栏，messagesView 原地复用不搬）
            if viewModel.isWritingMode {
                writingLayout
            } else {
                chatContentColumn
            }
        }
        // 底部 mode 色光晕（学 Gemini 蓝光，但跟我们的系统状态联动）：
        // - 欢迎页：稳态 0.22 主色 → 切 mode 时 0.4s 平滑变色
        // - 流式中：呼吸 0.18 ↔ 0.32，跟胶囊执行流同步节奏
        // - 完成时：闪烁 +0.33 → 0.5s 内淡回，给"任务完成了"视觉锚点
        // - 其它时候：完全透明（不干扰阅读静态消息）
        .background(alignment: .bottom) {
            ModeAmbientGlow(
                tint: PetPaletteStore.shared.palette(for: viewModel.agentMode).primary,
                isWelcomePage: showSuggestions && !isActiveCanvas,
                isStreaming: viewModel.isLoading
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
        // 字号 toast —— ⌘+/⌘-/⌘0 触发后 2s 自动消失
        .overlay(alignment: .top) {
            if let label = fontScaleToast {
                FontScaleToast(label: label)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(101)
            }
        }
        .animation(AnimTok.smooth, value: fontScaleToast)
        // 把 scale 注入 Environment，MessageBubble / MarkdownTextView 用它来算字号
        .environment(\.chatFontScale, chatFontScale)
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
            // ⚠️ 决策 #22：handleProviders 的回调参数是 @Sendable（非 @MainActor），
            // 这里用 mainActorForwarder 把 @MainActor 的 viewModel 调用包成可后台传递的转发器
            // （内部 DispatchQueue.main.async 跳主线程，避开 Task{@MainActor} 的执行器断言崩溃）。
            DragDropUtil.handleProviders(
                providers,
                onImage: DragDropUtil.mainActorForwarder { png in viewModel.addPendingImage(png) },
                onDocument: DragDropUtil.mainActorForwarder { url in viewModel.attachDocumentPath(url) }
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
        // 拖拽悬停时冻结桌宠 sprite，把主线程让给拖拽追踪，避免拖文件卡顿（松手/移出自动恢复）
        .onChange(of: isDropTargeted) { _, targeted in
            NotificationCenter.default.post(
                name: .init("HermesPetDragInProgress"),
                object: nil,
                userInfo: ["active": targeted]
            )
        }
        // 清空对话的确认弹窗
        .confirmationDialog(
            L("chat.clear.title"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L("chat.clear.confirm"), role: .destructive) {
                viewModel.clearChat()
            }
            Button(L("chat.clear.cancel"), role: .cancel) {}
        } message: {
            Text(L("chat.clear.message"))
        }
        // 不固定 frame，跟随 NSWindow 自适应。
        // ⚠️ 决策 #7：**不要写 minWidth/minHeight** —— ChatWindowController.hide() 把窗口缩到
        // 100×30 时，SwiftUI 的最小尺寸要求会反向请求 window 改 frame，触发 NSHostingView
        // 嵌套 layout cycle，macOS 26 直接抛 NSException 必崩（issue #3 的 .ips 就是这个）。
        // 最小尺寸由 NSWindow.contentMinSize 在动画外控制（ChatWindowController init 里设 360×360）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 新用户首次引导 —— 覆盖在聊天内容上（clipShape 之前，跟随圆角裁剪）
        .overlay {
            if viewModel.showOnboarding {
                OnboardingView(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(200)
            }
        }
        .animation(AnimTok.smooth, value: viewModel.showOnboarding)
        // 历史对话面板 —— 覆盖在聊天内容上（clipShape 之前，跟随圆角裁剪）
        .overlay {
            if showHistory {
                ConversationHistoryView(viewModel: viewModel) { showHistory = false }
                    .transition(.opacity)
                    .zIndex(150)
            }
        }
        .animation(AnimTok.smooth, value: showHistory)
        // v1.0 的稳定窗口结构：SwiftUI 自己提供 material 背景，NSWindow 只承载 hosting controller。
        // 不再用 NSVisualEffectView 手动包 hosting view；那会在 transparent titlebar 下引入顶部空白/遮挡。
        // legibleGlass：材质 + 对比兜底 scrim，保证文字可读；尊重系统「减弱透明度」
        .legibleGlass(scrim: 0.5)
        // 圆角浮窗：clipShape + window.hasShadow=true 让阴影也跟着圆角走
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 极淡边框增强层次感
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 对话内容列（普通模式直接用 / 写作模式当右栏）

    /// 消息列表 + 上下文进度条 + 输入栏。messagesView 是 ChatView 现成 computed property，原地复用、不外搬（守决策 #21）。
    @ViewBuilder
    private var chatContentColumn: some View {
        if isActiveCanvas {
            CanvasView(viewModel: viewModel, conversationID: viewModel.activeConversationID)
        } else {
            messagesView
        }

        if !isActiveCanvas {
            let usage = viewModel.contextUsage
            if usage.used > 0 {
                ContextUsageBar(
                    used: usage.used,
                    window: usage.window,
                    tint: PetPaletteStore.shared.palette(for: viewModel.agentMode).primary
                )
            }
        }

        ChatInputField(
            text: $viewModel.inputText,
            isLoading: viewModel.isLoading,
            pendingImages: viewModel.pendingImages,
            pendingDocuments: viewModel.pendingDocuments,
            tint: headerTint,
            currentMode: viewModel.agentMode,
            onSelectMode: { mode in
                guard mode != viewModel.agentMode else { return }
                _ = viewModel.newConversation(mode: mode)
            },
            onSend: { viewModel.sendMessage() },
            onCancel: { viewModel.cancelCurrentRequest() },
            onPasteImage: { viewModel.addPendingImage($0) },
            onRemoveImage: { viewModel.removePendingImage(at: $0) },
            onRemoveDocument: { viewModel.removePendingDocument(at: $0) },
            onShareWindow: { window in
                viewModel.shareWindowSnapshot(id: window.id, title: window.title)
            },
            activeWorkflow: viewModel.pendingWorkflow,
            workflows: WorkflowRegistry.shared.workflows,
            onPickWorkflow: { viewModel.activateWorkflow($0) },
            onOpenWorkflowGallery: { WorkflowGalleryController.shared.show() },
            onCancelWorkflow: { viewModel.cancelWorkflow() },
            onPickFleet: { viewModel.activateFleet() },
            onCancelFleet: { viewModel.cancelFleet() },
            fleetPending: viewModel.pendingFleet
        )
    }

    // MARK: - 写作模式三栏（文件侧栏 | 文档画布 | 对话）

    /// 切栏瞬切无 `.animation`/`.transition`（守决策 #21，照 isActiveCanvas 现状）。
    /// ⚠️ 三栏用 `HStack + Divider` 而**不是** HSplitView：右栏是聊天 messagesView，自带"自动贴底跟随"
    /// 滚动逻辑，跟 NSSplitView 的动态重测互相打架 → 右栏元素持续上下抖。HStack 是确定性布局，不抖
    /// （代价：外层分隔条暂不可拖；中栏内部编辑/预览的 HSplitView 保留，那个没聊天滚动不受影响）。
    /// 外面绝不套 GeometryReader（决策 #21）。
    private var writingLayout: some View {
        HStack(spacing: 0) {
            // 左：文件栏（可收起成图标条）
            if wmSidebarCollapsed {
                CollapsedFileRail(store: NotesStore.shared, tint: headerTint,
                                  onExpand: { wmSidebarCollapsed = false })
                    .frame(width: 52)
                Divider()
            } else {
                NotesFileSidebar(store: NotesStore.shared,
                                 onCollapse: { wmSidebarCollapsed = true })
                    .frame(width: wmSidebarWidth)
                WMResizeHandle(width: $wmSidebarWidth, minW: 180, maxW: sidebarHandleMaxW, direction: 1)
                    .frame(width: 10).frame(maxHeight: .infinity)
            }

            // 中：文档画布（内容居中，两侧留白）—— 用独立的 docFontScale，鼠标移入即设为缩放目标
            NotesDocumentCanvas(store: NotesStore.shared, fontScale: docFontScale)
                .frame(maxWidth: .infinity)
                .onHover { if $0 { wmHoverRegion = .doc } }

            // 右：对话栏（可收起成桌宠图标）
            if wmChatCollapsed {
                Divider()
                CollapsedChatRail(mode: viewModel.agentMode,
                                  isThinking: viewModel.isLoading,
                                  onExpand: { wmChatCollapsed = false })
                    .frame(width: 52)
            } else {
                WMResizeHandle(width: $wmChatWidth, minW: 300, maxW: chatHandleMaxW, direction: -1)
                    .frame(width: 10).frame(maxHeight: .infinity)
                VStack(spacing: 0) { chatContentColumn }
                    .frame(width: wmChatWidth)
                    // 收起键不再常驻 —— 鼠标移进对话栏才在右上角浮现
                    .overlay(alignment: .topTrailing) {
                        if wmChatHover {
                            Button { wmChatCollapsed = true } label: {
                                Image(systemName: "sidebar.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(.regularMaterial))
                                    .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .help(L("notes.chat.collapse"))
                            .padding(.top, 6).padding(.trailing, 8)
                            .transition(.opacity)
                        }
                    }
                    .onHover { hovering in
                        withAnimation(AnimTok.snappy) { wmChatHover = hovering }
                        if hovering { wmHoverRegion = .chat }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, LocaleManager.shared.language == .en ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN"))
        // 窗口 resize 时由 ChatWindowController 广播实际内容宽度 → 自适应折叠 + 动态夹宽。
        // ⚠️ 用通知拿宽度而非 GeometryReader：决策 #21 铁律(ScrollView 不被 GeometryReader 包裹)。
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetWritingWidthChanged"))) { note in
            if let w = note.userInfo?["w"] as? CGFloat { reflowWriting(w) }
        }
    }

    // MARK: - 写作三栏自适应折叠 + 动态夹宽

    /// 拖宽把手的动态上限：保证中间文档始终留够 `wmMinMiddle`，所以侧栏最宽 = 可用宽 − 中间 − 对侧。
    private var sidebarHandleMaxW: CGFloat {
        let rightW = wmChatCollapsed ? Self.wmRailWidth : (wmChatWidth + 10)
        return max(180, min(360, wmAvailWidth - Self.wmMinMiddle - rightW - 10))
    }
    private var chatHandleMaxW: CGFloat {
        let leftW = wmSidebarCollapsed ? Self.wmRailWidth : (wmSidebarWidth + 10)
        return max(300, min(480, wmAvailWidth - Self.wmMinMiddle - leftW - 10))
    }

    /// 按当前窗口可用宽度自适应折叠（带迟滞防边界抖动）+ 夹住两侧栏宽，保证中间文档不被挤到溢出。
    /// 阈值依据：两栏都展开需 ≥840、仅文件栏展开需 ≥583、都收起需 ≥446（含 340 中间兜底）。
    private func reflowWriting(_ w: CGFloat) {
        wmAvailWidth = w
        // 对话栏：窄于 840 收起，宽于 900 展开（中间留迟滞带，避免边界来回抖）
        if w < 840 { if !wmChatCollapsed { wmChatCollapsed = true } }
        else if w > 900 { if wmChatCollapsed { wmChatCollapsed = false } }
        // 文件栏：默认收起、由用户手动展开 → 这里**只在过窄时强制收起**，绝不自动展开
        //（否则进写作就被自动拉开，违背"默认收起"）。
        if w < 583 { if !wmSidebarCollapsed { wmSidebarCollapsed = true } }
        // 夹住展开态两侧栏宽，保证中间 ≥ wmMinMiddle（窗口缩小时侧栏先让位）
        if !wmChatCollapsed {
            let leftW = wmSidebarCollapsed ? Self.wmRailWidth : (wmSidebarWidth + 10)
            wmChatWidth = max(300, min(480, min(wmChatWidth, w - Self.wmMinMiddle - leftW - 10)))
        }
        if !wmSidebarCollapsed {
            let rightW = wmChatCollapsed ? Self.wmRailWidth : (wmChatWidth + 10)
            wmSidebarWidth = max(180, min(360, min(wmSidebarWidth, w - Self.wmMinMiddle - rightW - 10)))
        }
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

            // 字号缩放（Chrome 风格）—— ⌘+ / ⌘= / ⌘- / ⌘0
            // ⌘+ 和 ⌘= 都触发放大（=/+ 是同一物理键，US/CN 键盘 shift 与否的区别）
            Button("Bigger Font") { bumpFontScale(.up) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Bigger Font (=)") { bumpFontScale(.up) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller Font") { bumpFontScale(.down) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Font Scale") { bumpFontScale(.reset) }
                .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// 字号缩放动作 —— 改 AppStorage + 弹 toast 2s 自动消失
    private enum FontScaleAction { case up, down, reset }
    /// 写作模式下 ⌘+/⌘- 作用的区域（按鼠标位置路由）
    private enum ScaleRegion { case doc, chat }
    private func bumpFontScale(_ action: FontScaleAction) {
        // 写作模式 + 鼠标在中间文档区 → 只缩放文档；否则缩放聊天正文（用户要的"放大鼠标所在区域"）
        let scaleDoc = viewModel.isWritingMode && wmHoverRegion == .doc
        let oldScale = scaleDoc ? docFontScale : chatFontScale
        let newScale: Double = switch action {
        case .up:    ChatFontScale.cycleUp(from: oldScale)
        case .down:  ChatFontScale.cycleDown(from: oldScale)
        case .reset: ChatFontScale.default
        }
        if newScale != oldScale {
            if scaleDoc { docFontScale = newScale } else { chatFontScale = newScale }
        }
        // 即使档位没变也弹 toast（让用户知道已经到顶/底了）；写作模式标明是文档还是对话
        let prefix = scaleDoc ? "文档·" : (viewModel.isWritingMode ? "对话·" : "")
        fontScaleToast = prefix + ChatFontScale.displayLabel(for: newScale)
        // 2s 后自动清空（用 task ID 防多次触发竞态）
        let snapshot = fontScaleToast
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if fontScaleToast == snapshot { fontScaleToast = nil }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 6) {
            // 画布对话：显示混合模式标签（规划走在线 AI，生图走 Codex）
            // 普通对话：mode 表达由 ConversationTab 的 mini icon + 输入栏 Mode Picker 承担
            if isActiveCanvas {
                CanvasModeBadge(tint: headerTint)
            }

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

            Spacer()

            // 右侧液态玻璃胶囊：设置 / 历史 / ⋯ 更多（截屏 / 置顶 / 清空）
            // 学 Gemini 的"高频 3 颗 + 次要折叠"模型，macOS 26 上 .regularMaterial 自动液态玻璃
            headerActionCluster
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 极淡叠层 —— 跟主区域有微对比，但不喧宾夺主
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - 写作模式极简顶栏（‹ · 文档标题 · ⋯）

    /// 写作模式专用顶栏：只剩「退出 ‹」「居中文档标题」「⋯ 更多」三件，**双击顶栏=最大化/还原**。
    /// 对话标签整排撤掉（写作=专注一篇）；设置/历史/最大化/截屏/置顶/清空全折进 ⋯。
    private var writingHeader: some View {
        ZStack {
            // 居中：当前文档标题（+ 未保存小圆点）
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(writingDocTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary).lineLimit(1)
                if NotesStore.shared.isDirty {
                    Circle().fill(.secondary.opacity(0.7)).frame(width: 5, height: 5)
                        .help(L("notes.unsaved"))
                }
            }
            .frame(maxWidth: 360)

            // 两侧：退出 + 更多
            HStack(spacing: 0) {
                Button { viewModel.isWritingMode = false } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("notes.exit.help"))
                Spacer()
                writingMoreMenu
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        // 双击顶栏空白处 = 最大化/还原（原生习惯，替代常驻最大化按钮）
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .init("HermesPetWritingWindowZoom"), object: nil)
        }
    }

    /// 写作顶栏右侧「⋯」—— 把原本散开的设置/历史/最大化/截屏/置顶/清空全收进来
    private var writingMoreMenu: some View {
        Menu {
            Button {
                NotificationCenter.default.post(name: .init("HermesPetWritingWindowZoom"), object: nil)
            } label: { Label(L("notes.maximize.help"), systemImage: "arrow.up.left.and.arrow.down.right") }

            Button { viewModel.showSettings.toggle() } label: {
                Label(L("chat.header.settings.help"), systemImage: "gearshape")
            }
            Button { showHistory = true } label: {
                Label(L("chat.header.history.help"), systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                viewModel.captureScreenAndAttach { hide, done in
                    if let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                        win.alphaValue = hide ? 0 : 1
                    }
                    done()
                }
            } label: { Label(L("chat.header.capture.menu"), systemImage: "camera.viewfinder") }

            Toggle(isOn: $viewModel.chatWindowAlwaysOnTop) {
                Label(L("chat.header.pin.menu"), systemImage: "pin.fill")
            }

            Divider()

            Button(role: .destructive) { showClearConfirm = true } label: {
                Label(L("chat.header.clear.help"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("chat.header.more.help"))
        // 设置在写作模式没有常驻齿轮按钮当锚点了 —— 把 popover 挂在 ⋯ 上
        .popover(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
    }

    /// 当前文档标题（写作顶栏居中显示）
    private var writingDocTitle: String {
        let s = NotesStore.shared
        return s.notes.first(where: { $0.id == s.selectedNoteID })?.title ?? L("notes.noSelection")
    }

    /// 右上角液态玻璃胶囊：3 颗常驻 + 「⋯」下拉收剩余功能
    private var headerActionCluster: some View {
        HStack(spacing: 2) {
            HeaderToggleButton(
                isOn: viewModel.isWritingMode,
                systemNameOn: "square.split.2x1.fill",
                systemNameOff: "square.split.2x1",
                help: L("chat.header.writing.help")
            ) {
                viewModel.isWritingMode.toggle()
            }

            // 会议纪要快捷入口 —— 免得每次从菜单栏翻（点一下开始/结束录音）
            HeaderIconButton(systemName: "waveform.badge.mic", help: L("chat.header.meeting.help")) {
                NotificationCenter.default.post(name: .init("HermesPetToggleMeeting"), object: nil)
            }

            // HermesPet 博物馆 —— 生成过的网页 + 跑完的全量模式产出，统一收藏/回看/复用
            HeaderIconButton(systemName: "building.columns.fill", help: L("chat.header.gallery.help")) {
                MuseumController.shared.show(vm: viewModel)
            }

            HeaderIconButton(systemName: "gearshape.fill", help: L("chat.header.settings.help")) {
                viewModel.showSettings.toggle()
            }
            .popover(isPresented: $viewModel.showSettings) {
                SettingsView(viewModel: viewModel)
            }

            HeaderIconButton(systemName: "clock.arrow.circlepath", help: L("chat.header.history.help")) {
                showHistory = true
            }

            Menu {
                Button {
                    viewModel.captureScreenAndAttach { hide, done in
                        if let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                            win.alphaValue = hide ? 0 : 1
                        }
                        done()
                    }
                } label: {
                    Label(L("chat.header.capture.menu"), systemImage: "camera.viewfinder")
                }

                Toggle(isOn: $viewModel.chatWindowAlwaysOnTop) {
                    Label(L("chat.header.pin.menu"), systemImage: "pin.fill")
                }

                Divider()

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(L("chat.header.clear.help"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("chat.header.more.help"))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        // 液态玻璃容器：macOS 26 自动渲染为 Liquid Glass，早期系统降级为半透磨砂
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var headerTint: Color {
        switch viewModel.agentMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        case .qwenCode:   return .teal
        }
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
        case .hermes, .directAPI, .openclaw, .qwenCode:
            return [
                ("camera.viewfinder", L("chat.suggestion.chat.analyzeShot"), "帮我看看这张截图说的什么意思"),
                ("doc.text", L("chat.suggestion.chat.summarize"), "把下面这段帮我总结一下："),
                ("globe", L("chat.suggestion.chat.translate"), "把下面这段翻译成中文："),
                ("lightbulb", L("chat.suggestion.chat.explain"), "用通俗的话解释一下：")
            ]
        case .claudeCode:
            return [
                ("folder", L("chat.suggestion.code.viewProject"), "帮我看下这个项目的结构和大概在做什么"),
                ("doc.badge.plus", L("chat.suggestion.code.genDoc"), "帮我生成一份关于 xxx 的 Markdown 文档"),
                ("magnifyingglass", L("chat.suggestion.code.debug"), "帮我找一下 xxx 这个问题在哪里"),
                ("hammer", L("chat.suggestion.code.writeCode"), "帮我写一段 TypeScript 代码做：")
            ]
        case .codex:
            return [
                ("photo.on.rectangle", L("chat.suggestion.codex.genImage"), "帮我生成一张「主题」的图，"),
                ("paintbrush", L("chat.suggestion.codex.editImage"), "把这张图改成「描述」风格"),
                ("rectangle.stack.badge.plus", L("chat.suggestion.codex.concepts"), "围绕「主题」给我 3 张不同风格的图"),
                ("text.below.photo", L("chat.suggestion.codex.poster"), "做一张海报：主标题「」，副标题「」，风格「」")
            ]
        }
    }

    private var messagesView: some View {
        // ⚠️ 决策 #21 续篇（issue #46/#48/#49 三连崩 + #50「切屏幕就卡/崩」）：
        // 这里**绝不能**再套外层 `GeometryReader { _ in ScrollView }`。
        // 切显示器 / 切 Space / 改分辨率时窗口几何突变 → GeometryReader 报新尺寸 →
        // ScrollView.updateContext 改 frameSize → 几何再变 → 反复 setNeedsUpdateConstraints，
        // 在 CA transaction commit 期间永不收敛 → AppKit 抛 NSException 必崩（跨 macOS 15 & 26）。
        // 决策 #21 当时只删了底部"测是否到底"的 GeometryReader+preference，漏了这层外包装。
        // ScrollView 在 VStack 里本就贪婪占满剩余高度，根本不需要 GeometryReader 包一层。
        ScrollViewReader { proxy in
            ScrollView {
                // ⭐ 用 VStack 而非 LazyVStack（2026-06-01，修"往上滚跳到顶+空白"）：
                // LazyVStack 屏幕外气泡只估高、不实测，往上滚实测时高度对不上 → SwiftUI 纠偏把滚动
                // 猛拽到顶、那一帧没渲染好 = 空白。聊天气泡高度参差(代码/图片/长短)放大此误差，普通窗
                // 和写作窄列都中招。VStack 全量测准高度 → 无估算误差 → 不跳；锚点永远在 → 贴底/流式滚动也更准。
                // 代价=超长对话首屏渲染略重(对话有长度上限+压缩，可接受)。守决策 #21：不套 GeometryReader、
                // 不 .animation 包裹、单一数据驱动 scrollTo —— VStack 比 LazyVStack 更不易触发那类布局反馈。
                VStack(spacing: 10) {
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
                                    // 仅"填入输入框"，由用户手动按回车发送 —— 避免叙述性
                                    // 编号列表（"先做 A / 再做 B / 最后 C"）被当成可点选项误触发送。
                                    viewModel.inputText = choice
                                    // 通知输入框抢回 firstResponder，让用户可以立即按回车
                                    NotificationCenter.default.post(
                                        name: .init("HermesPetFocusInputField"), object: nil)
                                },
                                onPinTask: { task in
                                    // 📌 Pin → 创建任务 Pin 到桌面
                                    PinCardController.pinTask(task)
                                },
                                onDispatchTask: { task, mode in
                                    // 🤖 让 AI 做 → 新建对话，派发给用户在卡片菜单里选的 mode
                                    viewModel.dispatchTaskToNewConversation(task, mode: mode)
                                },
                                onMakeWebpage: {
                                    // ✨ 把这条回答做成网页（hover 操作栏触发，取代旧的常驻动作条）
                                    let title = viewModel.conversations.first { $0.id == viewModel.activeConversationID }?.title ?? "AI 回答"
                                    ArtifactWindowController.shared.present(markdown: message.content, title: title,
                                                                            mode: viewModel.agentMode, vm: viewModel,
                                                                            sourceMessageID: message.id)
                                },
                                onOpenRun: { runID in viewModel.reopenWorkflowRun(runID) }
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

                    // 底部锚点：仅供切换会话 / 窗口显示时 proxy.scrollTo 落底用。
                    // 不再挂 GeometryReader+preference —— 那套"测量是否到底 + 流式每 token
                    // 手动 scrollTo"会形成布局反馈环导致 100% 卡死/崩溃（见决策 #21）。
                    // 自动贴底由下方单一数据驱动 proxy.scrollTo + autoFollow 门控接管
                    // （已移除 .defaultScrollAnchor，避免与手动 scrollTo 双套并存导致流式抖动，见决策 #21 续篇）。
                    Color.clear
                        .frame(height: 1)
                        .id(Self.messagesBottomAnchorID)
                }
                .padding(12)
                // 决策 #21 铁律：不要 .animation 包裹 LazyVStack（与"读布局结果"的几何量一旦同现即成反馈环）。
                // 已移除原 .animation(value: messages.count / showSuggestions)：新消息/建议网格改为瞬间出现，
                // 不再驱动 488 行 MessageBubble 的进出场过渡（取舍：保合规 + 零反馈环风险，放弃滑入动画）。
            }
            // ⭐ 决策 #21 续篇 · 流式抖动修复（2026-05-27）：贴底**只保留一套机制** = 数据驱动 proxy.scrollTo。
            // 之前 `.defaultScrollAnchor(.bottom)`（系统在 content size 变化时自动重锚到底）与下面"每个
            // token 手动 scrollTo"**两套并存、互相修正** → 流式时肉眼可见上下抖动；且手动 scrollTo 无条件
            // 执行 → 用户想往上翻看历史会被每 32ms 拽回底部。现去掉 defaultScrollAnchor，单一机制 + autoFollow
            // 门控（往上翻 → 暂停跟随；滚回底部 / 切对话 / 发新消息 → 恢复）。
            // autoFollow 由 `userScrollFollowGate`（onScrollPhaseChange，macOS 15+）**只在用户主动滚动时**
            // 按落点更新；内容增长 / 程序化贴底是 .animating 不在此列，不会误关跟随，也绝不在回调里 scrollTo
            // → 不构成"滚动→布局→再滚动"反馈环（区别于决策 #21 那个 GeometryReader+preference）。
            .userScrollFollowGate { nearBottom in
                autoFollow = nearBottom
            }
            .onAppear {
                autoFollow = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.activeConversationID) { _, _ in
                // 切换会话：内容整体重建，恢复跟随并明确落到最新
                autoFollow = true
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // 新消息进来（用户发送 / AI 新起一条）：恢复跟随并滚到底让它立刻显现
                autoFollow = true
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.messages.last?.content.count) { _, _ in
                // 流式逐字：仅当用户仍停在底部时 instant 贴底跟随（不带动画，避免 token 间动画互相打断颤抖）；
                // 用户往上翻看历史时 autoFollow=false → 不打扰
                if viewModel.messages.last?.isStreaming == true, autoFollow {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetScrollToMessage"))) { note in
                if let msgID = note.userInfo?["messageID"] as? String {
                    withAnimation(AnimTok.smooth) {
                        proxy.scrollTo(msgID, anchor: .center)
                    }
                }
            }
            // 窗口从灵动岛展开 → 强制滚到底部（确保看到最新消息，而非停在上次/顶部位置）。
            .onReceive(NotificationCenter.default.publisher(for: .hermesPetChatWindowShown)) { _ in
                autoFollow = true
                scrollToBottom(proxy, animated: false)
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

// MARK: - 滚动跟随门控

private extension View {
    /// 流式自动贴底的"跟随开关"门控：**只在用户主动滚动**（手指/触控板 tracking·惯性 decelerating·
    /// 用户拖完落到 idle）时，按当前落点离底部的距离更新 `setFollow`；接近底部 → true（继续跟随），
    /// 明显上翻 → false（暂停跟随，不再被流式拽回底部）。
    ///
    /// 关键：**内容增长 / 程序化 scrollTo 是 `.animating` 相，不在判定之列** —— 所以流式逐字增长
    /// 不会被误判成"用户上翻"而关掉跟随；回调本身也绝不调用 scrollTo，不构成布局反馈环（守决策 #21）。
    /// `onScrollPhaseChange` 仅 macOS 15+；更低版本不挂该修饰符（autoFollow 恒为初始 true = 始终跟随）。
    @ViewBuilder
    func userScrollFollowGate(threshold: CGFloat = 48, _ setFollow: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollPhaseChange { oldPhase, newPhase, context in
                let userDriven = newPhase == .interacting
                    || newPhase == .decelerating
                    || (newPhase == .idle && oldPhase != .animating && oldPhase != .idle)
                guard userDriven else { return }
                let g = context.geometry
                let nearBottom = g.contentOffset.y + g.containerSize.height
                    >= g.contentSize.height - threshold
                setFollow(nearBottom)
            }
        } else {
            self
        }
    }
}

// MARK: - 全窗口拖拽提示

/// 输入框上方智能动作条里的小药丸按钮 —— 图标 + 短词，hover 微亮，取 action 主色。
struct SmartActionChip: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(hovering ? 0.18 : 0.10)))
            .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

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
                Text(L("chat.drag.title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(L("chat.drag.subtitle"))
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

// MARK: - 字号 Toast

/// ⌘+ / ⌘- / ⌘0 后短暂显示当前档位 —— 紧凑胶囊，2s 自动消失
struct FontScaleToast: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.size")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
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
            .help(L("chat.error.dismiss.help"))
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
                // 欢迎页大号宠物形象（替代 SF 图标，让在线 AI=红怪兽、Claude=螃蟹、Hermes=小马 …直接亮相）
                ModeSpriteView(mode: mode, isWorking: false, size: 40, animated: true)
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
        case .hermes:     return L("chat.welcome.title.hermes")
        case .directAPI:  return L("chat.welcome.title.directAPI")
        case .openclaw:   return L("chat.welcome.title.openclaw")
        case .claudeCode: return L("chat.welcome.title.claudeCode")
        case .codex:      return L("chat.welcome.title.codex")
        case .qwenCode:   return L("chat.welcome.title.qwenCode")
        }
    }

    private var welcomeSubtitle: String {
        switch mode {
        case .hermes:     return L("chat.welcome.subtitle.hermes")
        case .directAPI:  return L("chat.welcome.subtitle.directAPI")
        case .openclaw:   return L("chat.welcome.subtitle.openclaw")
        case .claudeCode: return L("chat.welcome.subtitle.claudeCode")
        case .codex:      return L("chat.welcome.subtitle.codex")
        case .qwenCode:   return L("chat.welcome.subtitle.qwenCode")
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

/// 对话 Tab 栏 —— 矩形 tab 横排，每个 tab 显示 mode mini icon + title + 序号。
/// 这是之前圆形 `ConversationPill` 的替代品（圆形太小易误点，看不出哪条是哪条 mode）。
///
/// 设计要点：
/// - tab 形态：8pt 圆角矩形，32pt 高，固定 max width 160pt（避免长 title 撑爆 header）
/// - active tab：mode 主色 0.18 底 + 顶部 2pt 主色条 + title 加粗
/// - 后台流式中：底部 1.5pt mode tint 呼吸条（保留原圆形胶囊行为）
/// - hover 时右侧出现 × 关闭按钮（仅 canClose 时）
/// - 最右侧 `[+]` 按钮：常驻显示；canAddMore=false 时灰掉 disabled
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(conversations.enumerated()), id: \.element.id) { (idx, conv) in
                        ConversationTab(
                            index: idx + 1,
                            title: conv.title,
                            mode: conv.mode,
                            isActive: conv.id == activeID,
                            hasUnread: conv.hasUnread && conv.id != activeID,
                            isBackgroundStreaming: conv.isStreaming && conv.id != activeID,
                            isForegroundStreaming: conv.isStreaming && conv.id == activeID,
                            canClose: conversations.count > 1,
                            onSelect: { onSelect(conv.id) },
                            onClose: { onClose(conv.id) },
                            onRename: { newTitle in onRename(conv.id, newTitle) }
                        )
                        .id(conv.id)
                    }
                    AddTabButton(canAdd: canAddMore, onAdd: onAdd, onAddCanvas: onAddCanvas)
                }
                .padding(.vertical, 2)
            }
            .onChange(of: activeID) { _, newID in
                withAnimation(AnimTok.smooth) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .animation(AnimTok.smooth, value: conversations.count)
        .animation(AnimTok.smooth, value: activeID)
    }
}

/// 单个对话 tab（矩形）。
///
/// **前台流式拉长**（v1.5）：当 isForegroundStreaming=true 时，tab 横向拉长（maxWidth 150 → 320），
/// 把标题替换成「工具图标 · 动作 · 文件 · 计时」执行流，让"对话本身在工作"。完成时短暂
/// 显示「✓ 已改 N 文件」2.5s 再缩回。数据来源：ExecutionStateStore.shared（订阅决策 #13 的通知 schema）。
struct ConversationTab: View {
    let index: Int
    let title: String
    let mode: AgentMode
    let isActive: Bool
    let hasUnread: Bool
    var isBackgroundStreaming: Bool = false
    /// 当前对话 == active && 正在 streaming → tab 拉长展示执行状态
    var isForegroundStreaming: Bool = false
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var streamPulse = false
    /// 订阅全局执行状态机（@Observable → SwiftUI 自动追踪字段变化）
    @State private var execStore = ExecutionStateStore.shared

    private static let tabHeight: CGFloat = 28
    private static let tabMaxWidth: CGFloat = 150
    /// 流式拉长后的上限
    private static let tabStreamingMaxWidth: CGFloat = 320

    /// mode tint —— tab 视觉主色（active 底 / 顶条 / 流式发光线）
    private var modeTint: Color {
        switch mode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        case .qwenCode:   return .teal
        }
    }

    /// 当前是否在"流式 + 有真东西可展示"的状态。
    /// 没东西展示时回到普通标题（避免空 tab 拉长占地）
    private var showsExecutionState: Bool {
        guard isForegroundStreaming else { return false }
        return execStore.isWorking || execStore.doneFlashFileCount != nil
    }

    var body: some View {
        Button(action: onSelect) {
            tabContent
                .padding(.horizontal, 8)
                .frame(height: Self.tabHeight)
                .frame(maxWidth: showsExecutionState ? Self.tabStreamingMaxWidth : Self.tabMaxWidth,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive
                      ? modeTint.opacity(0.16)
                      : Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isActive ? modeTint.opacity(0.45) : Color.primary.opacity(0.10),
                    lineWidth: isActive ? 1.0 : 0.6
                )
        )
        // 后台对话完成的未读红点 —— 浮在 tab 右上角
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
        // 后台流式中的呼吸发光线
        .overlay(alignment: .bottom) {
            if isBackgroundStreaming {
                Capsule()
                    .fill(modeTint)
                    .frame(height: 1.5)
                    .shadow(color: modeTint.opacity(0.8), radius: 2)
                    .opacity(streamPulse ? 1.0 : 0.45)
                    .padding(.horizontal, 4)
                    .offset(y: 1.5)
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
        .animation(AnimTok.smooth, value: isActive)
        // 拉长/缩回执行流：spring 拍出"对话本身在工作"的感觉
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showsExecutionState)
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
        .help(canClose ? L("chat.tab.hover.help", title) : title)
        .contextMenu {
            Button {
                renameDraft = title
                isRenaming = true
            } label: {
                Label(L("chat.tab.rename"), systemImage: "pencil")
            }
            if canClose {
                Divider()
                Button(role: .destructive, action: onClose) {
                    Label(L("chat.tab.close.help"), systemImage: "xmark")
                }
            }
        }
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                TextField(L("chat.tab.rename.placeholder"), text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit {
                        onRename(renameDraft)
                        isRenaming = false
                    }
                Button(L("chat.tab.rename.confirm")) {
                    onRename(renameDraft)
                    isRenaming = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
    }

    /// tab 内容 —— 在「标题模式」和「执行流模式」之间切换。
    /// 切换有 spring 动画（外层 .animation 监听 showsExecutionState）
    @ViewBuilder
    private var tabContent: some View {
        if isForegroundStreaming, let n = execStore.doneFlashFileCount {
            // 完成态：✓ 已改 N 文件（2.5s 后自动收回）
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text(L("chat.tab.done.files", n))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else if isForegroundStreaming, let kind = execStore.currentToolKind {
            // 工具执行中：[图标] 动作 · 文件 · M/N · 3s
            HStack(spacing: 4) {
                Image(systemName: kind.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kind.iconColor)
                Text(kind.verb)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                if !execStore.shortArg.isEmpty {
                    Text("· \(execStore.shortArg)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let step = execStore.stepText {
                    Text("· \(step)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("· \(execStore.elapsedText)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .transition(.opacity)
        } else if isForegroundStreaming, execStore.isWorking {
            // 在跑但无工具事件（纯文本思考态）：mode 图标 + "思考中" + 计时
            HStack(spacing: 5) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(modeTint)
                Text(L("chat.tab.thinking"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("· \(execStore.elapsedText)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .transition(.opacity)
        } else {
            // 默认：mode 图标 + 标题（+ hover 关闭按钮）
            HStack(spacing: 5) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? modeTint : Color.secondary)
                Text(title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isHovering && canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("chat.tab.close.help"))
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .transition(.opacity)
        }
    }
}

/// 加号按钮 —— 矩形 tab 风格，跟普通 tab 视觉对齐。
/// canAdd=false 时灰掉 disabled，hover 显示"对话数已达上限"。
struct AddTabButton: View {
    let canAdd: Bool
    let onAdd: () -> Void
    let onAddCanvas: () -> Void
    @State private var isHovering = false
    @AppStorage("canvasModeEnabled") private var canvasModeEnabled: Bool = false
    private static let tabHeight: CGFloat = 28

    var body: some View {
        Group {
            if canvasModeEnabled && canAdd {
                Menu {
                    Button {
                        onAdd()
                    } label: { Label(L("chat.tab.addChat"), systemImage: "message") }
                    Button {
                        onAddCanvas()
                    } label: { Label(L("chat.tab.addCanvas"), systemImage: "rectangle.3.group") }
                } label: { plusIcon }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("chat.tab.add.help"))
            } else {
                Button(action: { if canAdd { onAdd() } }) { plusIcon }
                    .buttonStyle(.plain)
                    .disabled(!canAdd)
                    .help(canAdd
                          ? L("chat.tab.add.inherit.help")
                          : L("chat.tab.add.full.help", kMaxConversations))
            }
        }
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }

    private var plusIcon: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(canAdd ? Color.secondary : Color.secondary.opacity(0.35))
            .frame(width: Self.tabHeight, height: Self.tabHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(canAdd && isHovering ? 0.06 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(canAdd ? 0.10 : 0.05), lineWidth: 0.6)
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
                Text(L("chat.canvas.badge.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L("chat.canvas.badge.subtitle"))
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
        .help(L("chat.canvas.badge.help"))
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

/// 二态切换按钮（pin 置顶 / 取消置顶）。
/// on 态用蓝色 + 实心图标提示当前生效，off 态走 .secondary 灰色，跟其他 header 按钮一致
struct HeaderToggleButton: View {
    let isOn: Bool
    let systemNameOn: String
    let systemNameOff: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? systemNameOn : systemNameOff)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
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
                    Text(L("chat.onboardingCard.title"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(L("chat.onboardingCard.subtitle"))
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
