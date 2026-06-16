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
    private var hostingView: NSHostingController<QuickAskView>?
    private let state = QuickAskState()
    private weak var viewModel: ChatViewModel?
    private weak var chatWindow: ChatWindowController?
    /// 第一次唤起 widget 时弹一次系统 Accessibility 引导窗，之后不重复（避免烦扰）
    private var hasRequestedAccessibility = false

    /// 弹窗代次 —— 每次 present / hide 自增。慢路径的异步 ⌘C 回填任务捕获当时的代次，
    /// 完成时若代次已变（用户中途又关了/重开了）就放弃回填，避免"已关闭的窗口被重新激活"
    private var presentGeneration = 0
    /// 最近一次弹窗时刻 —— 用于 didResignKey 自动隐藏的 grace period（避免 activate 抢焦点瞬时 resignKey 误杀）
    private var presentedAt: Date = .distantPast
    /// 正在圈选截图中 —— 此时浮窗被故意 orderOut，必须挡住 didResignKey 自动隐藏 + 热键 toggle，
    /// 否则收起浮窗触发的 resignKey 会调 hide() 把窗永久收走（"圈完对话框没了"的根因）
    private var isCapturingRegion = false

    private init() {}

    func attach(viewModel: ChatViewModel, chatWindow: ChatWindowController?) {
        self.viewModel = viewModel
        self.chatWindow = chatWindow
    }

    /// 全局热键调用 —— 切换显示。
    ///
    /// **"有时不弹"修复**：旧版先 `await` 读完选中文字才 show 窗口（⌘C 回退要等 ~150ms+），
    /// 这段空窗期里用户手快再按一下就把它当成"关闭"了、或 activate 抢焦点时的瞬时 resignKey
    /// 把刚弹的窗口收回去 → 表现成"按了没反应"。现在改成 **按下立刻弹窗**：
    ///   - 快路径（AX 同步直读到选区，原生 app）：直接弹窗 + 抢焦点，0 延迟。
    ///   - 慢路径（AX 没读到，需 ⌘C 回退覆盖 Electron/网页）：先**无焦点**弹窗（源 app 保持前台，
    ///     ⌘C 才会复制对地方），异步读完再回填上下文卡片 + 抢焦点给输入框。
    /// 两条路窗口都秒出，连按竞态消失。
    func toggle() {
        guard !isCapturingRegion else { return }   // 圈选模态进行中，忽略热键
        if let w = window, w.isVisible {
            hide()
            return
        }
        // 第一次唤起时弹一次 Accessibility 引导窗（已授权则静默）
        if !hasRequestedAccessibility {
            hasRequestedAccessibility = true
            _ = AccessibilityReader.requestTrustWithPrompt()
        }

        // ⚠️ 必须在 NSApp.activate 之前抓"来源 app" + 试 AX 直读，否则 frontmost 变成桌宠自己
        let sourceApp = AccessibilityReader.frontmostApp
        presentGeneration &+= 1
        let gen = presentGeneration

        // 快路径：AX 同步直读（原生 app，0 延迟）—— 读到就直接弹窗带上下文
        if let viaAX = AccessibilityReader.readSelectedTextViaAX() {
            present(sourceApp: sourceApp, selectedText: viaAX, focusNow: true)
            return
        }

        // 慢路径：AX 没读到 → 先无焦点弹窗（源 app 仍前台，⌘C 回退才读得对），再异步回填
        present(sourceApp: sourceApp, selectedText: "", focusNow: false)
        Task { @MainActor in
            let viaClipboard = await AccessibilityReader.readSelectedTextViaClipboardAsync()
            // 代次已变（用户中途关了/重开了）或窗口已不可见 → 放弃回填，避免重新激活已关窗口
            guard gen == self.presentGeneration, self.window?.isVisible == true else { return }
            self.fillContextAndFocus(selectedText: viaClipboard)
        }
    }

    /// 弹窗。`focusNow=true` 立刻抢焦点（快路径）；`false` 只 orderFrontRegardless 不抢焦点（慢路径，
    /// 让源 app 保持前台供 ⌘C 回退读取，之后再由 fillContextAndFocus 抢焦点）
    private func present(sourceApp: NSRunningApplication?, selectedText: String, focusNow: Bool) {
        if window == nil { createWindow() }
        state.reset()
        state.sourceApp = sourceApp
        state.sourceAppName = sourceApp?.localizedName ?? ""
        state.selectedContext = selectedText
        // 把当前 mode 同步进 state，供 view 显示 mode icon / cursor / 主按钮主色
        if let vm = viewModel {
            state.currentMode = vm.agentMode
        }
        positionWindow()
        presentedAt = Date()
        if focusNow {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // 只显示、不抢焦点 —— 源 app 保持前台，⌘C 回退才会复制到正确的地方
            window?.orderFrontRegardless()
        }
    }

    /// 慢路径回填：⌘C 读完后把选中文字灌进上下文卡片 + 抢焦点给输入框
    private func fillContextAndFocus(selectedText: String?) {
        if let t = selectedText, !t.isEmpty {
            state.selectedContext = t
            positionWindow()   // 上下文卡片出现 → 高度变 → 重新摆位
        }
        presentedAt = Date()   // 重置 grace period（这次 activate 也别被自动隐藏误杀）
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        presentGeneration &+= 1   // 让在途的异步回填任务作废
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

    /// 📷 圈选屏幕 → OCR → 把识别到的文字灌进上下文卡片。
    /// 先把浮窗收起（让圈选 overlay 独占屏幕、不被拍进冻结图），圈完再弹回 + 抢焦点。
    fileprivate func handleRegionCapture() {
        guard !isCapturingRegion else { return }
        isCapturingRegion = true             // 挡住 orderOut 触发的 resignKey 自动隐藏（否则窗会被永久收走）
        window?.orderOut(nil)                 // 收起浮窗，让圈选 overlay 独占屏幕、不被拍进冻结图
        Task { @MainActor in
            let image = await RegionCaptureController.shared.capture()
            if let image,
               let text = await VisionOCR.recognizeText(in: image, quality: .accurate),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.state.selectedContext = text
                self.state.sourceApp = nil                       // OCR 内容无来源 app → 隐藏"粘回去"
                self.state.sourceAppName = L("region.sourceLabel")
            }
            // 弹回浮窗 + 抢焦点。先清标志，再 makeKey（这次 resignKey 已不需要被挡了）
            self.isCapturingRegion = false
            self.positionWindow()
            self.presentedAt = Date()
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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
        let toast = L("island.quickask.copied")
        state.lastQuestion = toast
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.state.lastQuestion == toast {
                self.state.lastQuestion = original
            }
        }
    }

    fileprivate func handlePin() {
        guard !state.answer.isEmpty, !state.isStreaming else { return }
        let result = PinCardController.pin(content: state.answer, mode: state.currentMode)
        let original = state.lastQuestion
        if result == .added {
            state.lastQuestion = L("island.quickask.pinnedToast")
        } else if result == .duplicate {
            state.lastQuestion = L("island.quickask.pinnedDup")
        } else {
            state.lastQuestion = L("island.quickask.pinnedFull", PinStore.maxPins)
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 64),
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
                // 圈选期间浮窗是故意 orderOut 的，别把这次 resignKey 当成"用户点外面"去自动收
                if self.isCapturingRegion { return }
                if !self.state.isExpanded {
                    // grace period：刚弹出 0.6s 内不自动收 —— 慢路径 activate 抢焦点时会有
                    // 一次瞬时 resignKey，旧逻辑会把刚弹的窗口立刻收回（"按了没反应"的元凶之一）
                    if Date().timeIntervalSince(self.presentedAt) < 0.6 { return }
                    self.hide()
                }
            }
        }

        // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
        let host = NSHostingController(rootView: QuickAskView(
            state: state,
            onSubmit: { [weak self] text in self?.handleSubmit(text) },
            onPin: { [weak self] in self?.handlePin() },
            onMigrate: { [weak self] in self?.handleMigrateToChat() },
            onClose: { [weak self] in self?.hide() },
            onPasteBack: { [weak self] in self?.handlePasteBack() },
            onCopyAnswer: { [weak self] in self?.handleCopyAnswer() },
            onRegionCapture: { [weak self] in self?.handleRegionCapture() }
        ))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        w.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
        w.setContentSize(NSSize(width: 680, height: 64))

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
        let h: CGFloat
        if state.isExpanded {
            h = 400
        } else if state.hasContext {
            // 输入条 64 + 上下文卡片（文本区 + 标签行/内边距约 46）
            h = 64 + 46 + state.contextTextDisplayHeight
        } else {
            h = 64   // Gemini 式单行胶囊
        }
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

    /// 输入态上下文卡片「文本区」的显示高度（自适应）：短选区只占需要的几行，
    /// 长内容（圈选 OCR 一大段）最多展开到约 7 行高、再多就在卡片内滚动。
    /// 窗口高度（positionWindow）和卡片视图（selectionContextCard）共用这个值，保持一致。
    var contextTextDisplayHeight: CGFloat {
        guard hasContext else { return 0 }
        let lineH: CGFloat = 18
        let maxLines = 7
        let newlineCount = selectedContext.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        // 按宽度粗估折行数（13pt 字号、卡片有效宽 ≈ 590pt，每行约容 40 字）
        let wrapLines = max(1, Int(ceil(Double(selectedContext.count) / 40.0)))
        let lines = min(maxLines, max(wrapLines, newlineCount + 1))
        return CGFloat(lines) * lineH
    }

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

// MARK: - 液态玻璃背景

/// 液态玻璃背景（macOS 26 Liquid Glass）：完全通透、自动折射 + 自适应壁纸明暗保证内容可读。
/// 自身不带任何底色（颜色全来自背后壁纸）。旧系统（< macOS 26）回退到 ultraThinMaterial。
private struct LiquidGlassBackground: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // .regular：通透液态玻璃。
            // ⚠️ glassEffect 会让整个 hosting view 矩形区域都算「有内容」，
            // NSWindow.hasShadow 的系统阴影就会沿矩形外接框画 → 圆角外四角露出直角黑线。
            // 补一个同形状 clipShape 把 alpha mask 重新裁成圆角，系统阴影才沿圆角走。
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
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
    let onRegionCapture: () -> Void

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
        case .qwenCode:   return "q.circle.fill"
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
        case .qwenCode:   return .teal
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 输入态像 Gemini 一样不放标题/关闭，纯输入条；展开态才出现顶部行
            if state.isExpanded {
                expandedHeaderRow
            }
            if state.hasContext {
                selectionContextCard
            }
            inputRow
            if state.isExpanded {
                Divider().opacity(0.25).padding(.horizontal, 24)
                answerArea
                if !state.answer.isEmpty && !state.isStreaming {
                    answerActions
                }
            }
        }
        // 真·液态玻璃（macOS 26 Liquid Glass）：通透折射背后壁纸。
        // 配合下方 .environment(.dark) 锁成「深色玻璃」—— 像 Gemini 一样，
        // 无论桌面深浅都恒定是「深灰玻璃 + 白字」，不会在浅背景下翻成白底黑字
        .modifier(LiquidGlassBackground(cornerRadius: cornerRadius))
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
        // 锁定深色外观 → Liquid Glass 恒渲染成深灰玻璃、文字 .primary 恒为白（同 Gemini）
        .environment(\.colorScheme, .dark)
        .onAppear { inputFocused = true }
        .animation(AnimTok.smooth, value: state.isExpanded)
    }

    /// 形态圆角：输入态全圆胶囊（高 64 → 半径 32）；展开态变高 → 大圆角矩形 28
    private var cornerRadius: CGFloat { state.isExpanded ? 28 : 32 }

    /// 选中上下文卡片 —— 左侧 mode 主色 accent bar + 灰底显示用户在原 app 选的那段文字
    private var selectionContextCard: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧细条 —— 视觉锚点
            Rectangle()
                .fill(.secondary)
                .frame(width: 2)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L("island.quickask.selectedChars", state.selectedContext.count))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !state.sourceAppName.isEmpty {
                            Text("· \(state.sourceAppName)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // 自适应高度：短内容只占几行；长内容（圈选 OCR 一大段）展开到上限后可滚动看全
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(state.selectedContext)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(height: state.contextTextDisplayHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        // 输入态卡片在最顶（无 expandedHeaderRow 垫高），多给点顶部留白
        .padding(.top, state.isExpanded ? 4 : 14)
    }

    /// 流式结束后的回答操作栏：粘回去（主按钮，mode 主色填充）+ 复制（次按钮，ghost）
    private var answerActions: some View {
        HStack(spacing: 12) {
            Spacer()

            // 次按钮：复制（ghost 风格 —— 无背景，仅 hover 时显示）
            Button(action: onCopyAnswer) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                    Text(L("island.quickask.copy")).font(.system(size: 12))
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
                        Text(L("island.quickask.pasteBack")).font(.system(size: 12, weight: .semibold))
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

    /// 展开态顶部行（输入态不显示）：mode 标识 + 钉住提示 + Pin/转聊天/关闭
    private var expandedHeaderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: modeIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            // 提交后显示固定提示 —— 让用户知道"切走也不会消失，按 Esc 关"
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                Text(L("island.quickask.pinned"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(.primary.opacity(0.1))
            )

            Spacer()

            actionButton(systemName: "pin", help: L("island.quickask.help.pin")) { onPin() }
                .disabled(state.answer.isEmpty || state.isStreaming)
            actionButton(systemName: "bubble.left.and.text.bubble.right", help: L("island.quickask.help.migrate")) { onMigrate() }
                .disabled(state.answer.isEmpty || state.isStreaming)
            actionButton(systemName: "xmark", help: L("island.quickask.help.close")) { onClose() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
        HStack(spacing: 14) {
            // 左侧 mode 圆形图标（呼应 Gemini 的 + 圈，一眼看出在跟哪个 AI 说话）
            Image(systemName: modeIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))

            // 输入框 + 自绘 placeholder（"问问 在线 AI"，跟随 mode）
            ZStack(alignment: .leading) {
                if state.input.isEmpty {
                    Text("\(L("island.quickask.askPrefix")) \(L(state.currentMode.labelKey))")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                TextField("", text: $state.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .focused($inputFocused)
                    .tint(modeTint)   // 光标跟随 mode 主色
                    .onSubmit {
                        onSubmit(state.input)
                    }
                    .disabled(state.isStreaming)
            }

            Spacer(minLength: 8)

            // 📷 圈选屏幕 → OCR 当上下文（按完快捷键后还能补一段屏幕内容给 AI）
            Button(action: onRegionCapture) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("island.quickask.help.region"))
            .disabled(state.isStreaming)

            // 发送圆钮（输入非空才出现）：mode 主色填充 + 白箭头
            if !state.input.isEmpty {
                Button(action: { onSubmit(state.input) }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(modeTint))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("island.quickask.send"))
                .disabled(state.isStreaming)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: state.isExpanded ? 56 : 64)   // 输入态撑成 64 高全圆胶囊
        .animation(AnimTok.snappy, value: state.input.isEmpty)
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
                    ThinkingDots(color: modeTint.opacity(0.8))
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
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: Self.intelligenceColors,
                            center: .center,
                            angle: .degrees(angle)
                        ),
                        lineWidth: 1.2
                    )
                    .opacity(state.isStreaming ? 0.9 : 0.6)
                    .blur(radius: 0.8)
                    .blendMode(.plusLighter)
            }
            // 内层：白色 0.5pt 微透明描边 —— 跟外圈光环形成"双描边"玻璃质感
            //   这是 Apple Intelligence 真正的视觉技巧：光晕之内还有一层玻璃边沿
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }
}
