import SwiftUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - Message Bubble

/// 消息正文基础字号（13pt）—— scale 应用到此基数上。Header / 代码块等用各自基数也走同一 scale
private let kMessageBaseFontSize: CGFloat = 13

struct MessageBubbleView: View {
    let message: ChatMessage
    /// 当前对话对象，用来决定 assistant 头像和角色名
    var agentMode: AgentMode = .hermes
    /// 所属对话 ID，pin 时记录来源以便点击卡片跳回原消息
    var conversationID: String? = nil
    /// 出错消息底部"重试"按钮的回调（仅 isError 时显示）
    var onRetry: (() -> Void)? = nil
    /// AI 给出编号选项时，点击卡片回调（把那项内容作为新消息发送）
    var onChoiceSelected: ((String) -> Void)? = nil
    /// AI 输出任务清单时，点击 📌 Pin → 把这一项转成桌面任务 Pin
    var onPinTask: ((PlannedTask) -> Void)? = nil
    /// AI 输出任务清单时，点击 🤖 让 AI 做 → 新对话派发该任务
    var onDispatchTask: ((PlannedTask) -> Void)? = nil

    @State private var isHovering = false
    @State private var didCopy = false
    @State private var didPin = false
    @State private var pinShake = false

    /// 字号缩放（由 ChatView 经 Environment 注入）—— 应用到正文 Text / Markdown / 代码块
    @Environment(\.chatFontScale) private var fontScale: Double

    private var isUser: Bool { message.role == .user }
    /// assistant 内容以 "❌" 开头 → 出错消息，可重试
    private var isError: Bool {
        !isUser && message.content.hasPrefix("❌")
    }
    /// 时间戳格式：今天显示 HH:mm，昨天显示 "昨天 HH:mm"，更早显示 "M月D日 HH:mm"
    private var timeString: String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(message.timestamp) {
            f.dateFormat = "HH:mm"
            return f.string(from: message.timestamp)
        }
        if cal.isDateInYesterday(message.timestamp) {
            f.dateFormat = "HH:mm"
            return "昨天 \(f.string(from: message.timestamp))"
        }
        // 同年只显示月日；跨年加年份
        if cal.component(.year, from: message.timestamp) == cal.component(.year, from: Date()) {
            f.dateFormat = "M月d日 HH:mm"
        } else {
            f.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return f.string(from: message.timestamp)
    }
    /// assistant 头像图标（hermes 用兔子，claude 用终端）
    private var assistantIcon: String { agentMode.iconName }
    /// assistant 显示名（"Hermes" / "Claude Code"）
    private var assistantLabel: String { agentMode.label }
    /// assistant 主题色
    private var assistantTint: Color {
        switch agentMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Assistant: avatar + content on the left
            if !isUser {
                avatarView
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        roleLabel
                        timeLabel
                    }
                    bubbleContent
                }
                Spacer(minLength: 24)
            }
            // User: content + avatar on the right
            else {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        timeLabel
                        roleLabel
                    }
                    bubbleContent
                }
                avatarView
            }
        }
        .padding(.horizontal, 4)
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }

    /// 复制消息原始内容到剪贴板，2 秒内显示对勾反馈
    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            didCopy = false
        }
    }

    // MARK: - Avatar

    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.blue.opacity(0.2) : assistantTint.opacity(0.2))
                .frame(width: 28, height: 28)
            Image(systemName: isUser ? "person.fill" : assistantIcon)
                .font(.caption)
                .foregroundStyle(isUser ? .blue : assistantTint)
        }
    }

    private var roleLabel: some View {
        Text(isUser ? "你" : assistantLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var timeLabel: some View {
        Text(timeString)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Bubble

    private var bubbleContent: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            bubbleBody
            // 出错消息显示"重试"按钮
            if isError, let onRetry = onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("重试")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.07))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("重新发送上一条消息")
            }
        }
        .padding(.top, -2)
    }

    /// 气泡本体 + 右上角 hover 复制按钮
    @ViewBuilder
    private var bubbleBody: some View {
        if isUser {
            userBubble
                .overlay(alignment: .topLeading) { copyButtonOverlay }
        } else {
            assistantBubble
                .overlay(alignment: .topTrailing) { copyButtonOverlay }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // 用户上传的图片缩略图（截屏 / 粘贴 / 拖拽）—— 在文字气泡上方显示
            if !message.images.isEmpty {
                AssistantImagesGrid(images: message.images, tint: .blue)
            }
            // 拖入的文档附件 —— 显示在图片下方文字气泡上方，跟 input chip 同款样式
            if !message.documentPaths.isEmpty {
                AttachedDocumentsRow(
                    paths: message.documentPaths,
                    tint: .blue
                )
            }
            // 文本气泡（蓝色渐变）—— 仅在内容非占位时显示
            if !isPlaceholderText(message.content) {
                Text(message.content)
                    .font(.system(size: kMessageBaseFontSize * fontScale))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [.blue.opacity(0.2), .blue.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// ViewModel 在用户只发附件不带文字时填的占位文案 —— 气泡上方已经显示图片/文档附件，
    /// 占位文字纯属冗余，所以隐藏。
    private func isPlaceholderText(_ text: String) -> Bool {
        (text == "请分析这张图片。" && !message.images.isEmpty)
        || (text == "请查看我附带的文档。" && !message.documentPaths.isEmpty)
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 流式期间：MarkdownView + TypingCursor 包在 HStack(.lastTextBaseline) 让光标跟最后一行字 baseline 对齐
            // 流式结束：MarkdownView 自由布局 —— 让里面的 ChoiceCard 等"块状"组件不被 baseline 对齐挤压，点击区域恢复正常
            if message.isStreaming {
                if message.content.isEmpty {
                    // 内容还空白时显示三点呼吸 —— 消除冷启动空窗期的死气沉沉感
                    ThinkingDots(color: assistantTint.opacity(0.7))
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        MarkdownTextView(
                            content: message.content,
                            onChoiceSelected: nil,             // 流式期间不响应选项点击
                            tint: assistantTint
                        )
                        .font(.system(size: kMessageBaseFontSize * fontScale))
                        TypingCursor(color: assistantTint)
                    }
                }
            } else {
                MarkdownTextView(
                    content: message.content,
                    onChoiceSelected: onChoiceSelected,
                    onPinTask: onPinTask,
                    onDispatchTask: onDispatchTask,
                    tint: assistantTint
                )
                .font(.system(size: kMessageBaseFontSize * fontScale))
            }
            // assistant 返回的图片（主要来自 Codex 模式的生图）—— 网格展示
            if !message.images.isEmpty {
                AssistantImagesGrid(images: message.images, tint: assistantTint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// hover 时浮在气泡角上的操作按钮 —— 复制 (所有消息) + Pin 到桌面 (仅 assistant，跟当前 mode 联动)
    @ViewBuilder
    private var copyButtonOverlay: some View {
        if isHovering && !message.content.isEmpty && !message.isStreaming {
            HStack(spacing: 4) {
                // 复制按钮
                Button(action: copyContent) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : .secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(didCopy ? "已复制" : "复制内容")

                // Pin 到桌面（仅 assistant 消息显示，用户自己说的话没必要 pin）
                if !isUser {
                    Button(action: pinContent) {
                        Image(systemName: didPin ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(didPin ? Color.orange : pinShake ? Color.red : .secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: pinShake ? 4 : 0)
                    .animation(pinShake ? .default.repeatCount(4, autoreverses: true).speed(8) : .default, value: pinShake)
                    .help(didPin ? "已 Pin 到桌面" : "Pin 到桌面")
                }
            }
            .offset(x: isUser ? -6 : 6, y: -6)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
            .animation(AnimTok.snappy, value: didCopy)
            .animation(AnimTok.snappy, value: didPin)
        }
    }

    /// 把这条 assistant 消息 pin 到桌面右上角。已达 8 张上限时 didPin 短暂变红提示
    private func pinContent() {
        let result = PinCardController.pin(content: message.content, mode: agentMode, conversationID: conversationID, messageID: message.id)
        switch result {
        case .added:
            didPin = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                didPin = false
            }
        case .duplicate:
            Haptic.tap(.levelChange)
            pinShake = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                pinShake = false
            }
        case .full:
            didPin = false
        }
    }
}

// MARK: - 流式打字光标（闪烁的小竖条，颜色跟着 mode 走）

struct TypingCursor: View {
    var color: Color = .accentColor
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color)
            .frame(width: 2, height: 13)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                withAnimation(AnimTok.blink) { on = false }
            }
    }
}

/// 三点呼吸 —— assistant 气泡内容还空但已 isStreaming 时的占位反馈。
/// 消除"按下回车后气泡死气沉沉"的空窗期（claude 冷启动 200-500ms + 网络往返）。
/// 三个点错开 0.15s phase 循环淡入淡出，视觉上"AI 正在思考"
struct ThinkingDots: View {
    var color: Color = .secondary
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(phase ? 1.0 : 0.30)
                    .scaleEffect(phase ? 1.0 : 0.62)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .padding(.vertical, 3)
        .onAppear { phase = true }
    }
}


// MARK: - Chat Input Field (Robust approach)

struct ChatInputField: View {
    @Binding var text: String
    var isLoading: Bool
    var pendingImages: [Data] = []
    /// 待发送的文档附件路径（拖入的 PDF / txt / md 等，仅 Claude / Codex 模式下使用）
    var pendingDocuments: [URL] = []
    /// 跟随当前 mode 的强调色（绿 / 橙），让发送按钮和聚焦边框跟头部呼应
    var tint: Color = .accentColor
    var onSend: () -> Void
    var onCancel: () -> Void = {}
    var onPasteImage: (Data) -> Void = { _ in }
    var onRemoveImage: (Int) -> Void = { _ in }
    var onRemoveDocument: (Int) -> Void = { _ in }

    @State private var textHeight: CGFloat = 28
    @State private var isFocused: Bool = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
        || !pendingImages.isEmpty
        || !pendingDocuments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 极淡的顶部 hairline —— 跟 messages 区分隔
            Rectangle()
                .fill(.primary.opacity(0.06))
                .frame(height: 0.5)

            // 图片附件预览条
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, data in
                            ImageThumb(data: data) { onRemoveImage(idx) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }
                .frame(height: 66)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // 文档附件预览条（紧凑的水平 chip 列表）
            if !pendingDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(pendingDocuments.enumerated()), id: \.offset) { idx, url in
                            DocumentChip(url: url, tint: tint) { onRemoveDocument(idx) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, pendingImages.isEmpty ? 10 : 6)
                }
                .frame(height: 36)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputRow
        }
        .animation(AnimTok.smooth, value: pendingImages.count)
        .animation(AnimTok.smooth, value: pendingDocuments.count)
        // 单色背景，不喧宾夺主；让外层窗口的 ultraThinMaterial 透下来一点
        .background(Color.primary.opacity(0.025))
        // 拖拽 hover 反馈和文件处理都由 ChatView 顶层统一负责
    }

    /// iMessage 风格：空/单行时保持原来的小胶囊；多行时才展开成圆角输入面板。
    /// 发送按钮始终 overlay 固定在右侧，避免长文本挤到按钮下面。
    private var inputRow: some View {
        let measuredHeight = min(max(textHeight, 28), 112)
        let isExpanded = measuredHeight > 34 || text.contains("\n")
        let editorHeight = isExpanded ? measuredHeight : 28
        let cornerRadius: CGFloat = isExpanded ? 18 : 20

        return ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .topLeading) {
                // placeholder 永远在 ZStack 里（用 opacity 控制可见性），
                // 否则 text 由空变非空时 ZStack 子节点数从 2 变 1，
                // SwiftUI 会把 SendOnEnterTextEditor 当成"新位置的 view"重建 NSScrollView →
                // NSTextView 失 focus，导致用户输第一个字后无法继续输入（v1.3 用户反馈过）。
                Text(placeholderText)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
                    .opacity(text.isEmpty ? 1 : 0)

                SendOnEnterTextEditor(
                    text: $text,
                    isFocused: $isFocused,
                    idealHeight: $textHeight,
                    onSend: onSend,
                    onPasteImage: onPasteImage
                )
                // 单行 28pt 起步，进入多行后跟随内容长高，最高 112pt 后内部滚动
                .frame(height: editorHeight)
                .opacity(isLoading ? 0.5 : 1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 42)
            .padding(.vertical, 6)

            SendButton(
                isLoading: isLoading,
                canSend: canSend,
                tint: tint,
                action: { isLoading ? onCancel() : onSend() }
            )
            .keyboardShortcut(.defaultAction)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.primary.opacity(isExpanded ? 0.075 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(isFocused ? tint.opacity(0.45) : .primary.opacity(0.14), lineWidth: 0.7)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(AnimTok.snappy, value: isExpanded)
    }

    /// 跟随当前 mode 的简短 placeholder（HIG: 1-3 字名词）
    private var placeholderText: String {
        "消息"
    }

    private func recalcHeight() {
        let font = NSFont.systemFont(ofSize: 13)
        let size = CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        let bounding = (text as NSString).boundingRect(
            with: size,
            options: .usesLineFragmentOrigin,
            attributes: [.font: font],
            context: nil
        )
        textHeight = max(36, ceil(bounding.height) + 16)
    }
}

// MARK: - 发送按钮（独立组件 —— 跟 mode tint 联动 + hover/press 弹性反馈）

struct SendButton: View {
    let isLoading: Bool
    let canSend: Bool
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false
    private var isActive: Bool { isLoading || canSend }

    /// 直径按 HIG iMessage 实测：28pt。SF Symbol 占 ~57% (16pt) semibold medium。
    private let diameter: CGFloat = 28

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(backgroundFill)
                    .frame(width: diameter, height: diameter)

                if isLoading {
                    // 取消态：白色停止方块
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white)
                        .frame(width: 9, height: 9)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .imageScale(.medium)
                        .foregroundStyle(canSend ? Color.white : Color.primary.opacity(0.35))
                }
            }
            // hover/press 仅靠 opacity 表达 —— HIG 克制风格，不再做 scale 弹性
            .opacity(isHovering && isActive ? 0.82 : 1.0)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .help(isLoading ? "取消" : "发送")
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
        .animation(AnimTok.snappy, value: isLoading)
        .animation(AnimTok.snappy, value: canSend)
    }

    private var backgroundFill: AnyShapeStyle {
        if isLoading { return AnyShapeStyle(Color.red) }
        if canSend   { return AnyShapeStyle(tint) }
        // disabled：用极淡的灰，跟容器背景拉开层次但不抢眼
        return AnyShapeStyle(Color.primary.opacity(0.12))
    }
}

// MARK: - Custom Send Handler via NSTextView delegate (for Enter key interception)

/// A SwiftUI wrapper around NSTextView that intercepts Enter to send,
/// Shift+Enter / Cmd+Enter to insert a newline, and Cmd+V to capture image paste.
struct SendOnEnterTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// 内容变化时回传"理想高度"给上层，让输入框跟随内容长高（max 由 SwiftUI 端裁剪）
    @Binding var idealHeight: CGFloat
    var onSend: () -> Void
    var onPasteImage: (Data) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PasteAwareTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // documentView 理论上一定是 PasteAwareTextView（由 scrollableTextView() 工厂创建），
        // 但 AppKit 不在类型系统保证这一点，强制 cast 失败会崩，所以走安全路径。
        guard let textView = scrollView.documentView as? PasteAwareTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.onPasteImage = onPasteImage  // 拦截图片粘贴
        textView.font = NSFont.systemFont(ofSize: 14)      // HIG 14pt subhead
        textView.isRichText = false
        textView.drawsBackground = false
        // 光标位置 = textContainerInset + lineFragmentPadding。
        // NSTextView 默认 lineFragmentPadding=5pt（隐性偏移），导致 placeholder 与光标对不齐。
        // 把它清零，再用 textContainerInset 精确控制内边距，让 placeholder 和光标完全重合。
        // 28pt frame 内：top inset 5 + line height 18 = 23pt → 距底 5pt → 单行垂直居中
        textView.textContainerInset = NSSize(width: 8, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        // 进入 view tree 后主动抢 firstResponder。ChatWindowController.show() 同步调 makeFirstResponder
        // 时 NSHostingController 还没 mount 完 SwiftUI 子树 → NSTextView 不存在 → 设不上 → 0.34s 入场动画
        // 期间用户打的第一键无人响应被系统吞掉。这里在 NSTextView 真正进入 view hierarchy 后兜底。
        // 多个延迟兜底：window 可能在 makeNSView 时还没设上，第一次抢可能失败
        for delay in [0.0, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak textView] in
                guard let tv = textView, let window = tv.window else { return }
                // 已经是 firstResponder 就不动（避免抢走用户主动点击的其他控件焦点）
                if window.firstResponder !== tv {
                    window.makeFirstResponder(tv)
                }
            }
        }
        // 监听"外部要求 focus 输入框"的通知（用户点 ChoiceCard 后会发，让输入框抢回 firstResponder
        // 这样填入文字后用户可以立刻按回车发送，不用再点一下输入框）
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(
            forName: .init("HermesPetFocusInputField"),
            object: nil,
            queue: .main
        ) { [weak textView] _ in
            // queue: .main 决定了回调一定在主线程，但闭包本身是 Sendable，
            // 访问 NSTextView/NSWindow 的 @MainActor 属性需要显式 hop 到 MainActor
            MainActor.assumeIsolated {
                guard let tv = textView, let window = tv.window else { return }
                window.makeFirstResponder(tv)
                // 光标放到文末（填入的文字用户大概率是想直接发送或在末尾追加）
                let end = (tv.string as NSString).length
                tv.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteAwareTextView else { return }
        // 经典 race：用户按 'h' → NSTextView 显示 'h' → textDidChange 把 parent.text 设成 'h'，
        // 但是 SwiftUI 可能在收到这次 set 之前已经排队了一次 view update 带着 text="" 旧值进来。
        // 朴素地写 `if textView.string != text { textView.string = text }` 会在这种 update 里
        // 把 NSTextView 里用户刚输入的字符覆盖回空 → 用户看到"字符闪一下又没了 第一个键被吃"。
        //
        // 修复：用 coordinator 记录"上一次 NSTextView ↔ SwiftUI 同步过的值"。如果 SwiftUI 端
        // 的 text 等于 lastSyncedText（说明 SwiftUI 还在 echo 我们之前的更新，不是真的外部 set），
        // 就不要反向覆盖 NSTextView，让 textDidChange 那次 SwiftUI binding 写最终生效
        let coordinator = context.coordinator
        if textView.string != text && text != coordinator.lastSyncedText {
            // SwiftUI 端 text 是"真的"外部 set（点快捷卡片 / sendMessage 清空 / retry 等），同步给 NSTextView
            textView.string = text
            coordinator.lastSyncedText = text
            recomputeIdealHeight(textView)
        }
        textView.onPasteImage = onPasteImage
    }

    /// 用 layoutManager 测真实文本高度，加上 inset 总和 → idealHeight。
    /// 在 SwiftUI 端用 min(max(28, h), 100) clamp 一下，超过 max 内部会自动滚动。
    func recomputeIdealHeight(_ textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let textRect = lm.usedRect(for: tc)
        let h = ceil(textRect.height) + textView.textContainerInset.height * 2
        // async 避免在 SwiftUI view update 周期内同步 mutate state
        let bindingProxy = $idealHeight
        DispatchQueue.main.async {
            bindingProxy.wrappedValue = h
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SendOnEnterTextEditor
        /// 上次 NSTextView ↔ SwiftUI 同步过的 text 值。updateNSView 用它区分
        /// "SwiftUI 在 echo 我们的更新"（lastSyncedText == text）跟"真的外部 set"（!=），
        /// 避免在 race 期间把用户刚输入的字符覆盖回空（详见 updateNSView 注释）
        var lastSyncedText: String = ""
        /// HermesPetFocusInputField 通知的 observer token —— deinit 时移除避免泄漏
        var focusObserver: NSObjectProtocol?

        init(parent: SendOnEnterTextEditor) {
            self.parent = parent
        }

        deinit {
            if let obs = focusObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.command) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSend()
                return true
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            // 先记下"NSTextView 当前是这个值"，然后再写 SwiftUI binding —— 这样 updateNSView 即便
            // 因为 race 拿着旧 text 进来，也能识别出 SwiftUI 是在 echo（而非外部 set），跳过覆盖
            lastSyncedText = newText
            parent.text = newText
            // 同步算理想高度，回传给 SwiftUI → 输入框自动跟着内容长高
            parent.recomputeIdealHeight(textView)
        }

        // focus 状态回传给 SwiftUI（驱动外层边框 / 阴影动画）。
        // 用 async 避免在 view update 周期内同步 mutate state
        func textDidBeginEditing(_ notification: Notification) {
            let parent = self.parent
            DispatchQueue.main.async { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            let parent = self.parent
            DispatchQueue.main.async { parent.isFocused = false }
        }
    }
}

/// 自定义 NSTextView：粘贴时检测剪贴板有没有图片，有就走 onPasteImage 回调，文字才正常粘贴
final class PasteAwareTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // 优先尝试图片
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first,
           let tiff = img.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        // 否则按默认文字粘贴
        super.paste(sender)
    }
}

// MARK: - Assistant 生成的图片网格（Codex 生图主要用）

struct AssistantImagesGrid: View {
    let images: [Data]
    let tint: Color

    @State private var previewIndex: Int?

    /// 单图大显示，多图 2 列网格
    var body: some View {
        Group {
            if images.count == 1 {
                imageThumb(images[0], index: 0)
                    .frame(maxWidth: 280, maxHeight: 280)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { idx, data in
                        imageThumb(data, index: idx)
                            .frame(height: 110)
                    }
                }
                .frame(maxWidth: 280)
            }
        }
        // 点击任一图打开全屏预览
        .sheet(item: Binding(
            get: { previewIndex.map { IdentifiedIndex(id: $0) } },
            set: { previewIndex = $0?.id }
        )) { wrapper in
            AssistantImagePreview(
                images: images,
                startIndex: wrapper.id,
                tint: tint,
                onClose: { previewIndex = nil }
            )
        }
    }

    @ViewBuilder
    private func imageThumb(_ data: Data, index: Int) -> some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { previewIndex = index }
                .help("点击放大查看 / 右键保存")
                .contextMenu {
                    Button("保存到桌面…") { saveImageToDesktop(data) }
                    Button("拷贝") { copyImageToPasteboard(data) }
                }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.gray.opacity(0.3))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func saveImageToDesktop(_ data: Data) {
        let desktop = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        let stamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: desktop).appendingPathComponent("codex-\(stamp).png")
        try? data.write(to: url)
    }

    private func copyImageToPasteboard(_ data: Data) {
        guard let img = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

/// SwiftUI .sheet(item:) 需要 Identifiable 包装一个 Int
private struct IdentifiedIndex: Identifiable {
    let id: Int
}

/// 全屏图片预览 —— 大图 + 左右切换 + ESC 关闭
struct AssistantImagePreview: View {
    let images: [Data]
    let startIndex: Int
    let tint: Color
    let onClose: () -> Void

    @State private var current: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            if let img = NSImage(data: images[current]) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 720, maxHeight: 540)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 16) {
                if images.count > 1 {
                    Button { current = (current - 1 + images.count) % images.count } label: {
                        Image(systemName: "chevron.left.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain)

                    Text("\(current + 1) / \(images.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40)

                    Button { current = (current + 1) % images.count } label: {
                        Image(systemName: "chevron.right.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain)
                }

                Button("保存到桌面") { saveToDesktop(images[current]) }
                Button("关闭", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear { current = startIndex }
    }

    private func saveToDesktop(_ data: Data) {
        let desktop = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        let stamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: desktop).appendingPathComponent("codex-\(stamp).png")
        try? data.write(to: url)
    }
}

// MARK: - 图片缩略图（带 × 删除按钮）

struct ImageThumb: View {
    let data: Data
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.primary.opacity(0.15), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.3))
                    .frame(width: 56, height: 56)
            }
            // hover 时露出删除按钮
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(2)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}

// MARK: - 文档附件 chip（icon + 文件名 + hover × 删除）

struct DocumentChip: View {
    let url: URL
    let tint: Color
    /// 历史消息里展示用 —— 不显示删除按钮（已发出去，没法 cancel）
    var isReadOnly: Bool = false
    let onRemove: () -> Void

    @State private var isHovering = false

    /// 根据扩展名挑一个语义化的 SF Symbol
    private var iconName: String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "doc.plaintext"
        case "txt", "log": return "doc.text"
        case "json", "yml", "yaml", "toml", "ini", "conf": return "curlybraces"
        case "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java",
             "c", "cpp", "h", "rb", "php", "kt", "scala", "lua", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "csv": return "tablecells"
        case "html", "xml": return "globe"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            // hover 时显示删除按钮（仅 pending 队列里能删；历史里只读）
            if isHovering && !isReadOnly {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary, .primary.opacity(0.15))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.primary.opacity(0.06))
        )
        .overlay(
            Capsule()
                .stroke(.primary.opacity(0.14), lineWidth: 0.5)
        )
        .help(url.path)   // tooltip 显示完整路径
        .onHover { hovering in
            withAnimation(AnimTok.snappy) { isHovering = hovering }
        }
    }
}

// MARK: - 历史消息里展示文档附件列表（只读，跟输入栏 chip 同款样式）

/// user 气泡上方的"附带文档"行。父容器 VStack 是 .trailing 对齐，
/// 所以这里前置一个 Spacer 让 chip 整体靠右贴齐文字气泡，跟 AssistantImagesGrid 视觉对齐。
/// chip 多到溢出 maxWidth 时 Spacer 长度变 0，chip 自然占满整行
struct AttachedDocumentsRow: View {
    let paths: [String]
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                DocumentChip(
                    url: URL(fileURLWithPath: path),
                    tint: tint,
                    isReadOnly: true,
                    onRemove: {}
                )
            }
        }
        .frame(maxWidth: 320)
    }
}
