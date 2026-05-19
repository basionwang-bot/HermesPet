import AppKit
import SwiftUI

/// Spotlight 风快问浮窗 —— ⌘⇧Space 唤起。
/// 屏幕中央偏上一个 680pt 宽毛玻璃浮窗，外圈 Apple Intelligence 6 色光环（呼应语音输入）。
/// 流程：唤起 → 输入问题 → 回车流式回答 → Pin / 转聊天窗 / 关。
/// 不写 conversations.json，沿用当前激活对话的 mode
@MainActor
final class QuickAskWindowController {
    static let shared = QuickAskWindowController()

    private var window: QuickAskPanel?
    private var hostingView: NSHostingView<QuickAskView>?
    private let state = QuickAskState()
    private weak var viewModel: ChatViewModel?
    private weak var chatWindow: ChatWindowController?
    /// 第一次唤起 widget 时弹一次系统 Accessibility 引导窗，之后不重复（避免烦扰）
    private var hasRequestedAccessibility = false

    private init() {}

    func attach(viewModel: ChatViewModel, chatWindow: ChatWindowController?) {
        self.viewModel = viewModel
        self.chatWindow = chatWindow
    }

    /// 全局热键调用 —— 切换显示。
    /// 唤起前先读取当前 frontmost app 的选中文本（AX 失败则回退到模拟 ⌘C，覆盖 Electron 等），
    /// 然后再打开浮窗。AX 路径 0 延迟，剪贴板路径 ~150ms 延迟
    func toggle() {
        if let w = window, w.isVisible {
            hide()
            return
        }
        Task { @MainActor in
            // 第一次唤起时弹一次 Accessibility 引导窗（已授权则静默）
            if !hasRequestedAccessibility {
                hasRequestedAccessibility = true
                _ = AccessibilityReader.requestTrustWithPrompt()
            }
            // ⚠️ 必须在 NSApp.activate 之前读：一旦激活快问窗，frontmost 就变成桌宠，
            //    模拟 ⌘C 也会复制桌宠自己的内容
            let sourceApp = AccessibilityReader.frontmostApp
            let selected = await AccessibilityReader.readSelectedTextAsync()
            self.show(sourceApp: sourceApp, selectedText: selected)
        }
    }

    private func show(sourceApp: NSRunningApplication?, selectedText: String?) {
        if window == nil { createWindow() }
        state.reset()
        state.sourceApp = sourceApp
        state.sourceAppName = sourceApp?.localizedName ?? ""
        state.selectedContext = selectedText ?? ""
        // 把当前 mode 同步进 state，供 view 显示 mode icon / cursor / 主按钮主色
        if let vm = viewModel {
            state.currentMode = vm.agentMode
        }
        positionWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        state.streamTask?.cancel()
        state.streamTask = nil
        state.isStreaming = false
        window?.orderOut(nil)
    }

    // MARK: - Actions from view

    fileprivate func handleSubmit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let vm = viewModel else { return }
        // 切到展开态显示回答区
        state.lastQuestion = trimmed
        state.answer = ""
        state.isExpanded = true
        state.isStreaming = true
        state.input = ""
        positionWindow()

        // 把 selectedContext 拼成上下文 + 指令的双段 prompt
        let composedPrompt = composePrompt(instruction: trimmed, context: state.selectedContext)

        state.streamTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let stream = vm.streamOneShotAsk(prompt: composedPrompt)
                var full = ""
                var lastUpdate = Date.distantPast
                for try await delta in stream {
                    try Task.checkCancellation()
                    full += delta
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) >= 0.032 {
                        self.state.answer = full
                        lastUpdate = now
                    }
                }
                self.state.answer = full
            } catch is CancellationError {
                // 用户主动取消 —— 静默
            } catch {
                self.state.answer = "❌ \(error.localizedDescription)"
            }
            self.state.isStreaming = false
        }
    }

    /// 拼接最终 prompt：有上下文时让 AI 知道"这是用户刚选中的内容 + 这是用户的指令"
    private func composePrompt(instruction: String, context: String) -> String {
        guard !context.isEmpty else { return instruction }
        return """
        下面是用户刚刚在某个 app 里选中的内容（用三重反引号包裹）：

        ```
        \(context)
        ```

        请按用户的指令处理这段内容：\(instruction)

        要求：直接输出处理结果本身，不要重复原文、不要加"以下是结果"之类的前后缀（除非用户明确要求保留原文对照）。
        """
    }

    /// 回填粘贴 —— 把当前 answer 粘贴回原 app 光标位置，替换原选中文字
    fileprivate func handlePasteBack() {
        guard !state.answer.isEmpty, !state.isStreaming else { return }
        let answer = state.answer
        let target = state.sourceApp
        // 先 hide 窗口（让原 app 可以拿回焦点），再切回 + 模拟 ⌘V
        hide()
        KeyboardSimulator.pasteText(answer, into: target)
    }

    /// 复制回答到剪贴板（不切换焦点，便于用户后续手动粘贴到任意位置）
    fileprivate func handleCopyAnswer() {
        guard !state.answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.answer, forType: .string)
        // 简短提示
        let original = state.lastQuestion
        state.lastQuestion = "📋 回答已复制"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.state.lastQuestion == "📋 回答已复制" {
                self.state.lastQuestion = original
            }
        }
    }

    fileprivate func handlePin() {
        guard !state.answer.isEmpty, !state.isStreaming else { return }
        let result = PinCardController.pin(content: state.answer, mode: state.currentMode)
        let original = state.lastQuestion
        if result == .added {
            state.lastQuestion = "📌 已 Pin 到桌面"
        } else if result == .duplicate {
            state.lastQuestion = "⚠️ 已经 Pin 过这条内容了"
        } else {
            state.lastQuestion = "⚠️ 桌面 Pin 已达 \(PinStore.maxPins) 张上限，请先关一张"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // 如果中间没被其他操作改写就还原
            if self.state.lastQuestion.hasPrefix("📌") || self.state.lastQuestion.hasPrefix("⚠️") {
                self.state.lastQuestion = original
            }
        }
    }

    fileprivate func handleMigrateToChat() {
        guard !state.answer.isEmpty, let vm = viewModel else { return }
        vm.migrateQuickAskToNewConversation(question: state.lastQuestion, answer: state.answer)
        hide()
        // 打开聊天窗
        if let cw = chatWindow {
            cw.show(near: nil)
        }
    }

    // MARK: - Window

    private func createWindow() {
        // contentRect 跟卡片视觉尺寸严格一致 —— 系统按 alpha mask 自动沿圆角绘制 shadow
        let w = QuickAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.intelligence
        w.isOpaque = false
        w.backgroundColor = .clear
        // ✅ true：交给 NSWindow 按毛玻璃 alpha mask 沿圆角精确绘制原生阴影。
        // 这是 Spotlight / Alfred / Raycast 等所有 macOS 浮窗的标准做法。
        // 不要在 SwiftUI 内再叠加 .shadow()，否则两套阴影会冲突 + 边缘留 hairline artifact
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false

        // 失焦行为：分两种状态处理
        //   - 输入态（state.isExpanded == false）：跟 Spotlight 一致，点外面立刻关（轻量）
        //   - 提交后（state.isExpanded == true）：自动"钉住"不关，保护回答不被切走时丢
        //     用户可能要切到原 app 对照内容、或者去查资料，回来还能看到回答
        //     只能 Esc / ✕ / 失焦后主动重新唤起一次（toggle 检测到 visible 就关）才关
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: w, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.state.isExpanded {
                    self.hide()
                }
            }
        }

        let host = NSHostingView(rootView: QuickAskView(
            state: state,
            onSubmit: { [weak self] text in self?.handleSubmit(text) },
            onPin: { [weak self] in self?.handlePin() },
            onMigrate: { [weak self] in self?.handleMigrateToChat() },
            onClose: { [weak self] in self?.hide() },
            onPasteBack: { [weak self] in self?.handlePasteBack() },
            onCopyAnswer: { [weak self] in self?.handleCopyAnswer() }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 80)
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) { host.sizingOptions = [] }  // 决策 #6
        w.contentView = host

        self.window = w
        self.hostingView = host
    }

    /// 位置：屏幕中央偏上 30% 处。展开时窗口高 → 整体上移让顶部对齐。
    /// window 尺寸 = 卡片视觉尺寸（680×80 输入 / 680×400 展开），系统 shadow 在 window 外绘制
    private func positionWindow() {
        guard let window = window else { return }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let w: CGFloat = 680
        let h: CGFloat = state.isExpanded ? 400 : 80
        let x = visible.midX - w / 2
        let topY = visible.maxY - visible.height * 0.30
        let y = topY - h
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

/// 需要 canBecomeKey=true 才能接收文本输入。默认 NSPanel 不接键盘焦点
final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - State

@Observable
@MainActor
final class QuickAskState {
    var input: String = ""
    var lastQuestion: String = ""
    var answer: String = ""
    var isStreaming: Bool = false
    var isExpanded: Bool = false
    var streamTask: Task<Void, Never>?

    /// 选中文本上下文 —— 用户在原 app 选中的文字。空字符串表示没上下文（退化为无脑快问）
    var selectedContext: String = ""
    /// 原 app 名（用于"已选中 N 字 · 来自 Safari"提示）
    var sourceAppName: String = ""
    /// 原 app 引用 —— 回填粘贴时切回该 app
    var sourceApp: NSRunningApplication?

    /// 当前 AI 模式 —— 用于输入框 mode icon / cursor color / 主按钮主色
    var currentMode: AgentMode = .hermes

    var hasContext: Bool { !selectedContext.isEmpty }

    func reset() {
        input = ""
        lastQuestion = ""
        answer = ""
        isStreaming = false
        isExpanded = false
        streamTask?.cancel()
        streamTask = nil
        selectedContext = ""
        sourceAppName = ""
        sourceApp = nil
        // currentMode 不 reset —— 让用户 toggle 多次保持模式一致
    }
}

// MARK: - SwiftUI 视图

struct QuickAskView: View {
    @Bindable var state: QuickAskState
    let onSubmit: (String) -> Void
    let onPin: () -> Void
    let onMigrate: () -> Void
    let onClose: () -> Void
    let onPasteBack: () -> Void
    let onCopyAnswer: () -> Void

    @FocusState private var inputFocused: Bool

    /// Apple Intelligence 6 色板（跟 IntelligenceOverlay 一致）
    private static let intelligenceColors: [Color] = [
        Color(red: 1.00, green: 0.18, blue: 0.33),   // pink
        Color(red: 1.00, green: 0.58, blue: 0.00),   // orange
        Color(red: 1.00, green: 0.80, blue: 0.00),   // yellow
        Color(red: 0.20, green: 0.78, blue: 0.35),   // green
        Color(red: 0.35, green: 0.78, blue: 0.98),   // teal
        Color(red: 0.69, green: 0.32, blue: 0.87),   // purple
        Color(red: 1.00, green: 0.18, blue: 0.33),   // 闭环
    ]

    /// 当前 mode 对应的 SF Symbol（跟聊天窗 mode badge 一致）
    private var modeIcon: String {
        switch state.currentMode {
        case .hermes:     return "sparkle"
        case .directAPI:  return "cloud.fill"
        case .openclaw:   return "bolt.circle.fill"
        case .claudeCode: return "terminal.fill"
        case .codex:      return "wand.and.stars"
        }
    }

    /// 当前 mode 对应的强调色（输入框光标 / 主按钮 / accent bar）
    private var modeTint: Color {
        switch state.currentMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if state.hasContext {
                selectionContextCard
            }
            inputRow
            if state.isExpanded {
                Divider().opacity(0.20).padding(.horizontal, 24)
                answerArea
                if !state.answer.isEmpty && !state.isStreaming {
                    answerActions
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(intelligenceBorder)
        // 阴影交给 NSWindow.hasShadow 系统级绘制（按 alpha mask 沿圆角精确），
        // 而不是 SwiftUI .shadow modifier —— 后者在 NSHostingView layer 边缘会留 hairline artifact
        .background(
            ZStack {
                // 隐形按钮接 Esc 关闭
                Button("") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                // ⌘↩ 粘贴回原位置（仅在有 answer 时生效）
                Button("") { onPasteBack() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .disabled(state.answer.isEmpty || state.isStreaming)
            }
        )
        .onAppear { inputFocused = true }
        .animation(AnimTok.smooth, value: state.isExpanded)
    }

    /// 选中上下文卡片 —— 左侧 mode 主色 accent bar + 灰底显示用户在原 app 选的那段文字
    private var selectionContextCard: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧 mode 主色细条 —— 视觉锚点（这段文字"属于"当前 AI 处理）
            Rectangle()
                .fill(modeTint.opacity(0.7))
                .frame(width: 2)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("选中 \(state.selectedContext.count) 字")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !state.sourceAppName.isEmpty {
                            Text("· \(state.sourceAppName)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(state.selectedContext)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    /// 流式结束后的回答操作栏：粘回去（主按钮，mode 主色填充）+ 复制（次按钮，ghost）
    private var answerActions: some View {
        HStack(spacing: 12) {
            Spacer()

            // 次按钮：复制（ghost 风格 —— 无背景，仅 hover 时显示）
            Button(action: onCopyAnswer) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text("复制").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 主按钮：粘回去（mode 主色 primary，渐变填充 + 内描边 + 微阴影）
            if state.sourceApp != nil {
                Button(action: onPasteBack) {
                    HStack(spacing: 6) {
                        Text("粘回去").font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 1) {
                            Image(systemName: "command").font(.system(size: 9))
                            Image(systemName: "return").font(.system(size: 9))
                        }
                        .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [modeTint.opacity(1.0), modeTint.opacity(0.85)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: modeTint.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: - 顶部行

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: Self.intelligenceColors,
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Text("Hermes 快问")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.3)

            // 提交后显示固定提示 —— 让用户知道"切走也不会消失，按 Esc 关"
            if state.isExpanded {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                    Text("已固定 · Esc 关")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(.primary.opacity(0.08))
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer()

            if state.isExpanded {
                actionButton(systemName: "pin", help: "Pin 到桌面") { onPin() }
                    .disabled(state.answer.isEmpty || state.isStreaming)
                actionButton(systemName: "bubble.left.and.text.bubble.right", help: "转到聊天窗") { onMigrate() }
                    .disabled(state.answer.isEmpty || state.isStreaming)
            }
            actionButton(systemName: "xmark", help: "关闭") { onClose() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func actionButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 输入行

    private var inputRow: some View {
        HStack(spacing: 12) {
            // 左侧 mode 标识图标 —— 让用户一眼看出"现在在跟哪个 AI 说话"
            Image(systemName: modeIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(modeTint)
                .frame(width: 20)

            TextField("问点什么…", text: $state.input)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($inputFocused)
                .tint(modeTint)   // 光标颜色跟随 mode（Hermes 绿 / Claude 橙 / Codex 青）
                .onSubmit {
                    onSubmit(state.input)
                }
                .disabled(state.isStreaming)

            // 回车键提示徽章
            HStack(spacing: 4) {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                Text("发送")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.08))
            )
            .opacity(state.input.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: - 回答区（Q chat bubble + A 页面渲染）

    private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 用户问题 —— chat bubble 风格（浅灰底圆角小方块）
                if !state.lastQuestion.isEmpty {
                    Text(state.lastQuestion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.78))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.primary.opacity(0.07))
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // AI 回答 —— 纯页面渲染（无背景，跟 Q 视觉分明）
                if state.answer.isEmpty && state.isStreaming {
                    ThinkingDots(color: modeTint.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                } else if !state.answer.isEmpty {
                    MarkdownTextView(content: state.answer, tint: modeTint)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
    }

    // MARK: - Apple Intelligence 边框（双层：外圈含蓄彩虹 + 内圈白色玻璃边）

    private var intelligenceBorder: some View {
        ZStack {
            // 外层：6 色彩虹 angular gradient —— 比之前更含蓄
            //   - opacity 静态 0.55 / 流式 0.85（原 0.75 / 0.95，明显降饱和）
            //   - blur 0.8（原 0.4，让色边"散"得更像真液体）
            //   - lineWidth 1.2（原 1.5，更细更轻）
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                let cycle: Double = state.isStreaming ? 3.0 : 8.0
                let date = timeline.date.timeIntervalSinceReferenceDate
                let angle = (date.truncatingRemainder(dividingBy: cycle) / cycle) * 360
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: Self.intelligenceColors,
                            center: .center,
                            angle: .degrees(angle)
                        ),
                        lineWidth: 1.2
                    )
                    .opacity(state.isStreaming ? 0.85 : 0.55)
                    .blur(radius: 0.8)
                    .blendMode(.plusLighter)
            }
            // 内层：白色 0.5pt 微透明描边 —— 跟外圈光环形成"双描边"玻璃质感
            //   这是 Apple Intelligence 真正的视觉技巧：光晕之内还有一层玻璃边沿
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }
}
