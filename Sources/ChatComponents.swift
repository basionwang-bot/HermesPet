import SwiftUI
import UniformTypeIdentifiers

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
    var onDispatchTask: ((PlannedTask, AgentMode) -> Void)? = nil
    /// hover 操作栏「✨ 生成网页」回调（仅 assistant）—— 取代旧的常驻智能动作条，改成每条回答自己的非常驻操作
    var onMakeWebpage: (() -> Void)? = nil
    /// 工作流运行记录的「查看运行过程」回调（仅 message.workflowRunID 非空时）—— 重开 RunPanel
    var onOpenRun: ((String) -> Void)? = nil

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
    /// 共享 DateFormatter —— 流式输出时每条气泡每次重渲都会重算 timeString，旧写法每次
    /// new DateFormatter()（内部 locale/calendar 初始化不便宜）纯属浪费；复用单例 +
    /// 每次按需改 dateFormat（赋值很便宜）。只在主线程渲染时访问（body @MainActor）。
    @MainActor private static let timeFormatter = DateFormatter()
    /// 时间戳格式：今天显示 HH:mm，昨天显示 "昨天 HH:mm"，更早显示 "M月D日 HH:mm"
    private var timeString: String {
        let cal = Calendar.current
        let f = Self.timeFormatter
        if cal.isDateInToday(message.timestamp) {
            f.dateFormat = "HH:mm"
            return f.string(from: message.timestamp)
        }
        if cal.isDateInYesterday(message.timestamp) {
            f.dateFormat = "HH:mm"
            return L("chat.bubble.time.yesterday", f.string(from: message.timestamp))
        }
        // 同年只显示月日；跨年加年份
        if cal.component(.year, from: message.timestamp) == cal.component(.year, from: Date()) {
            f.dateFormat = L("chat.bubble.time.format.thisYear")
        } else {
            f.dateFormat = L("chat.bubble.time.format.otherYear")
        }
        return f.string(from: message.timestamp)
    }
    /// assistant 头像图标（hermes 用兔子，claude 用终端）
    private var assistantIcon: String { agentMode.iconName }
    /// assistant 显示名（"Hermes" / "Claude Code"）
    private var assistantLabel: String { L(agentMode.labelKey) }
    /// assistant 主题色
    private var assistantTint: Color {
        switch agentMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        case .qwenCode:   return .teal
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
            if isUser {
                // 用户头像：自定义头像 > 昵称首字母 > person.fill 兜底（UserProfileStore，本地）
                let profile = UserProfileStore.shared
                if let avatar = profile.avatar {
                    Image(nsImage: avatar)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                } else if !profile.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(profile.initials)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            } else {
                // assistant 头像 = 当前 mode 的小宠物形象（在线 AI 红怪兽 / Claude 螃蟹 / Hermes 小马 …）
                // animated:false 让多气泡场景零额外 CPU（每个气泡都是一个 avatar）
                ModeSpriteView(mode: agentMode, isWorking: false, size: 16, animated: false)
            }
        }
    }

    private var roleLabel: some View {
        Text(isUser ? L("chat.bubble.role.user") : assistantLabel)
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
                        Text(L("chat.bubble.retry"))
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
                .help(L("chat.bubble.retry.help"))
            }
            // 工作流运行记录 → 「查看运行过程」按钮（关掉独立窗口后也能从这里重开）
            if let runID = message.workflowRunID {
                WorkflowRunChip(runID: runID) { onOpenRun?(runID) }
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
        // 写入端（ChatViewModel）用当前语言的 L() 文案，历史消息可能是另一语言存的，
        // 所以这里同时匹配翻译表的中英两版，切语言后旧消息也能正确隐藏占位气泡。
        let imgPH = [LocaleManager.zhTable["chat.placeholder.image"], LocaleManager.enTable["chat.placeholder.image"]]
        let docPH = [LocaleManager.zhTable["chat.placeholder.document"], LocaleManager.enTable["chat.placeholder.document"]]
        return (imgPH.contains(text) && !message.images.isEmpty)
            || (docPH.contains(text) && !message.documentPaths.isEmpty)
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
            // 这条回答生成过网页 → 留个可点链接，随时重开（Artifact，靠 ArtifactStore @Observable 自动出现）
            if !message.isStreaming, let rec = ArtifactStore.shared.recordForMessage(message.id) {
                ArtifactLinkChip(record: rec)
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
                .help(didCopy ? L("chat.bubble.copied.help") : L("chat.bubble.copy.help"))

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
                    .help(didPin ? L("chat.bubble.pinned.help") : L("chat.bubble.pin.help"))

                    // ✨ 生成网页 —— 取代旧的常驻动作条，每条回答 hover 时才出现（非常驻）
                    if let onMakeWebpage {
                        Button(action: onMakeWebpage) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.ultraThinMaterial))
                                .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("把这条回答做成网页")
                    }
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

// MARK: - 工作流运行记录 chip（聊天里「查看运行过程」）

/// 挂在"运行了某工作流"那条消息下方的可点 chip —— 点了重开该 run 的 RunPanel。
/// 状态从 `WorkflowRunStore`（@Observable）实时读，运行中→完成会自动变图标/配色。
struct WorkflowRunChip: View {
    let runID: String
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        let run = WorkflowRunStore.shared.record(id: runID)
        let status = run?.status
        return Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon(status))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusTint(status))
                Text(run?.workflowName ?? "工作流")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                Text(L("chat.workflow.viewRun"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.primary.opacity(hover ? 0.10 : 0.06)))
            .overlay(Capsule().stroke(.primary.opacity(0.10), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("chat.workflow.viewRun.help"))
    }

    private func statusIcon(_ s: String?) -> String {
        switch s {
        case "succeeded": return "checkmark.seal.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "aborted": return "stop.circle"
        case "running", "awaitingConfirm": return "gearshape.2.fill"
        default: return "wand.and.stars"
        }
    }
    private func statusTint(_ s: String?) -> Color {
        switch s {
        case "succeeded": return .green
        case "failed": return .orange
        case "aborted": return .secondary
        default: return .indigo
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
    /// v1.5：mode 选择搬到输入栏右侧（学 Gemini 把模型选择塞进输入栏的体验）
    /// 当前对话的 mode —— picker 用它显示「现在发给谁」+ 当前 mini sprite
    var currentMode: AgentMode = .directAPI
    /// 用户在 picker 里选了新 mode 时的回调（外部决定是否要新建对话）
    var onSelectMode: (AgentMode) -> Void = { _ in }
    var onSend: () -> Void
    var onCancel: () -> Void = {}
    var onPasteImage: (Data) -> Void = { _ in }
    var onRemoveImage: (Int) -> Void = { _ in }
    var onRemoveDocument: (Int) -> Void = { _ in }
    /// 「+ → 分享窗口」选中某个窗口的回调（里程碑 0：截那个窗口给 AI 看）
    var onShareWindow: (ScreenCapture.ShareableWindow) -> Void = { _ in }

    // WTF 工作流(MVP)：加号选工作流 + 当前激活的 workflow chip
    var activeWorkflow: Workflow? = nil
    var workflows: [Workflow] = []
    var onPickWorkflow: (String) -> Void = { _ in }
    var onOpenWorkflowGallery: () -> Void = {}
    var onCancelWorkflow: () -> Void = {}

    // 全量模式（AI 公司舰队）
    var onPickFleet: () -> Void = {}
    var onCancelFleet: () -> Void = {}
    var fleetPending: Bool = false
    private let fleetChipColor = Color(red: 0.486, green: 0.424, blue: 1.0)

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
            // 选中的工作流 chip（点 × 取消）
            if let wf = activeWorkflow {
                HStack(spacing: 6) {
                    Image(systemName: wf.icon).font(.system(size: 11, weight: .semibold))
                    Text(wf.name).font(.system(size: 12, weight: .medium))
                    Button(action: onCancelWorkflow) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .foregroundStyle(wf.accentColor)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(wf.accentColor.opacity(0.12)))
                .overlay(Capsule().stroke(wf.accentColor.opacity(0.25), lineWidth: 0.5))
                .padding(.horizontal, 14).padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 全量模式 chip（点 × 取消）—— 照 workflow chip 同款
            if fleetPending {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 11, weight: .semibold))
                    Text("全量模式").font(.system(size: 12, weight: .medium))
                    Button(action: onCancelFleet) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .foregroundStyle(fleetChipColor)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(fleetChipColor.opacity(0.12)))
                .overlay(Capsule().stroke(fleetChipColor.opacity(0.25), lineWidth: 0.5))
                .padding(.horizontal, 14).padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            inputRow
        }
        .animation(AnimTok.smooth, value: pendingImages.count)
        .animation(AnimTok.smooth, value: pendingDocuments.count)
        .animation(AnimTok.smooth, value: activeWorkflow?.id)
        .animation(AnimTok.smooth, value: fleetPending)
        // 单色背景，不喧宾夺主；让外层窗口的 ultraThinMaterial 透下来一点
        .background(Color.primary.opacity(0.025))
        // 拖拽 hover 反馈和文件处理都由 ChatView 顶层统一负责
    }

    /// iMessage 风格：空/单行时保持原来的小胶囊；多行时才展开成圆角输入面板。
    /// 发送按钮始终 overlay 固定在右侧，避免长文本挤到按钮下面。
    /// v1.5：右侧 trailing 多让出 InputBarModePicker 的位置（mode 切换搬到输入栏）
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
            // 左下角统一「+」让出 40pt（不论实验性开关，始终一个按钮）
            .padding(.leading, 40)
            // 138pt 留给 mode picker + send button 的总宽度（picker ≈ 100pt，send 28pt + 间距）
            .padding(.trailing, 138)
            .padding(.vertical, 6)

            // mode picker + send button 同一行底部居右
            HStack(spacing: 6) {
                InputBarModePicker(
                    currentMode: currentMode,
                    onSelectMode: onSelectMode
                )
                SendButton(
                    isLoading: isLoading,
                    canSend: canSend,
                    tint: tint,
                    action: { isLoading ? onCancel() : onSend() }
                )
                .keyboardShortcut(.defaultAction)
            }
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
        .frame(minHeight: 40)
        // 左下角统一「+」=「增加」能力入口：点开展开 工作流 + 分享窗口（实验性）。overlay 定位不撑高
        .overlay(alignment: .bottomLeading) {
            InputPlusMenu(workflows: workflows, tint: tint,
                          onPick: onPickWorkflow, onOpenGallery: onOpenWorkflowGallery,
                          shareEnabled: ExperimentalStore.shared.screenTakeoverEnabled,
                          onShareWindow: onShareWindow,
                          onPickFleet: onPickFleet,
                          fleetEnabled: ExperimentalStore.shared.fleetModeEnabled)
                .padding(.leading, 6)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.primary.opacity(isExpanded ? 0.075 : 0.06))
        )
        // 全量模式通电特效（只在 fleetPending 时点亮；颜色跟随当前 mode；自身 clip 在圆角内不撑父视图）
        .background(
            FleetInputCharge(active: fleetPending, cornerRadius: cornerRadius, tint: tint)
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
        if fleetPending { return "给舰队一个任务，比如：做一个苹果农场的网页" }
        // 选了工作流就提示该喂什么（"粘贴要润色的文字…"）
        if let wf = activeWorkflow { return wf.inputHint }
        return L("chat.input.placeholder")
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

// MARK: - 输入栏 Mode Picker（v1.5 学 Gemini，mode 切换搬进输入栏右侧）

/// 输入栏右侧的 mode 切换器。
/// - trigger: 当前 mode mini sprite + 名字 + chevron.down，整体一个 capsule
/// - menu: 列出所有 enabled mode（按 EnabledModesStore），用 mode iconName + 名字
/// - 选了新 mode → 调用方 `onSelectMode` 处理（默认行为：新建对话，跟旧 mode rail 一致）
struct InputBarModePicker: View {
    let currentMode: AgentMode
    let onSelectMode: (AgentMode) -> Void

    /// EnabledModesStore 变化时重渲（设置里加/减 mode）
    @State private var refreshTick: Int = 0

    /// 跟随当前 mode 的调色板（trigger 染色用）
    @State private var paletteStore = PetPaletteStore.shared

    private var enabledModes: [AgentMode] {
        let s = EnabledModesStore.shared.enabledModes
        return AgentMode.allCases.filter { s.contains($0) }
    }

    private var tint: Color {
        paletteStore.palette(for: currentMode).primary
    }

    var body: some View {
        Menu {
            ForEach(enabledModes) { mode in
                Button {
                    onSelectMode(mode)
                } label: {
                    Label(L(mode.labelKey), systemImage: mode.iconName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                // 当前 mode 的 mini sprite —— 跟对话胶囊里的 mode icon 视觉对齐
                ModeSpriteView(mode: currentMode, isWorking: false, size: 14, animated: false)
                    .frame(width: 18, height: 16)
                Text(L(currentMode.labelKey))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                Capsule()
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.22), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("chat.input.modepicker.help"))
        .id(refreshTick)
        .onReceive(NotificationCenter.default.publisher(for: EnabledModesStore.didChangeNotification)) { _ in
            refreshTick &+= 1
        }
    }
}

// MARK: - 输入栏左下角统一「+」=「增加」入口（工作流 + 分享窗口，点开展开）

/// 一个「+」整合两类"增加"能力：① 工作流（选一个 / 全部工作流陈列页）② 分享窗口给 AI（实验性）。
/// 点开是个 Menu（展开看里面有什么）；"分享窗口"点了再弹窗口选择器 popover（异步列窗口）。
struct InputPlusMenu: View {
    let workflows: [Workflow]
    let tint: Color
    let onPick: (String) -> Void
    let onOpenGallery: () -> Void
    let shareEnabled: Bool
    let onShareWindow: (ScreenCapture.ShareableWindow) -> Void
    var onPickFleet: () -> Void = {}
    /// 全量模式（实验性）是否开启 —— 关闭时「🚀 全量模式」行整行隐藏
    var fleetEnabled: Bool = false

    @State private var isHovering = false
    @State private var showPlus = false
    @State private var content: PlusContent = .menu
    @State private var windows: [ScreenCapture.ShareableWindow] = []
    @State private var loading = false

    private enum PlusContent { case menu, workflows, share }
    /// 全量模式身份色（与 FleetTheaterView.accent 一致）
    private let accentFleet = Color(red: 0.486, green: 0.424, blue: 1.0)

    // 用 plain Button（不是 SwiftUI Menu）—— Menu 在输入栏 overlay 里基线会下偏、跟发送键不齐。
    var body: some View {
        Button {
            content = .menu
            showPlus = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHovering ? tint : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovering ? tint.opacity(0.12) : Color.primary.opacity(0.06)))
                .overlay(Circle().stroke(.primary.opacity(0.10), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("增加 · 工作流 / 分享")
        .popover(isPresented: $showPlus, arrowEdge: .top) {
            switch content {
            case .share:     sharePicker
            case .workflows: workflowsPanel
            case .menu:      menuPanel
            }
        }
    }

    /// 点开「+」展开的三件套主面板：① 工作流（▸ 二级）② 全量模式 ③ 分享屏幕。
    private var menuPanel: some View {
        VStack(alignment: .leading, spacing: 1) {
            plusRow(icon: "wave.3.right", title: "工作流", tint: .indigo, trailingChevron: true) {
                content = .workflows
            }
            if fleetEnabled {
                plusRow(icon: "bolt.fill", title: "全量模式", tint: accentFleet) {
                    onPickFleet(); showPlus = false
                }
            }
            if shareEnabled {
                plusRow(icon: "macwindow.on.rectangle", title: "分享屏幕", tint: .secondary) {
                    refresh(); content = .share
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
    }

    /// 二级页：各工作流 + 全部工作流…（顶部带返回箭头）
    private var workflowsPanel: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button { content = .menu } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Text("工作流").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(workflows) { wf in
                plusRow(icon: wf.icon, title: wf.name, tint: wf.accentColor) {
                    onPick(wf.id); showPlus = false
                }
            }
            plusRow(icon: "square.grid.2x2", title: "全部工作流…", tint: .secondary) {
                onOpenGallery(); showPlus = false
            }
        }
        .padding(.bottom, 6)
        .frame(width: 250)
    }

    @ViewBuilder
    private func plusRow(icon: String, title: String, tint: Color,
                         trailingChevron: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if trailingChevron {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var sharePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { content = .menu } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Text(L("chat.input.sharewindow.title"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            if loading && windows.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("chat.input.sharewindow.loading")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(12)
            } else if windows.isEmpty {
                Text(L("chat.input.sharewindow.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(windows) { w in
                            WindowPickerRow(window: w) { onShareWindow(w); showPlus = false }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 300)
    }

    private func refresh() {
        loading = true
        Task { @MainActor in
            windows = await ScreenCapture.listWindows()
            loading = false
        }
    }
}

/// 窗口选择弹层里的一行：app 图标 + 窗口标题 + app 名。
private struct WindowPickerRow: View {
    let window: ScreenCapture.ShareableWindow
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let icon = appIcon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "macwindow").resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(window.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(window.appName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: window.pid)?.icon
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
        .help(isLoading ? L("chat.input.send.cancel.help") : L("chat.input.send.help"))
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
        if let data = Self.imageData(from: .general) {
            onPasteImage?(data)
            return
        }
        // 否则按默认文字粘贴
        super.paste(sender)
    }

    /// 从剪贴板里尽力取出一张图片的 PNG/原始数据。覆盖两种常见情况：
    /// ① 访达里 ⌘C 拷的**图片文件**（剪贴板里是 file URL，不是图片数据）—— 优先，读原文件保真；
    /// ② 截图 / 从浏览器、预览里拷的图（剪贴板里直接是**图片数据**）。
    /// 拿不到图片返回 nil（让 super.paste 走正常文字粘贴）。
    static func imageData(from pb: NSPasteboard) -> Data? {
        // ① 图片文件 URL —— 只认图片类型的文件，文档类不会命中（落到文字粘贴）
        let urlOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: urlOptions) as? [URL],
           let url = urls.first {
            let ext = url.pathExtension.lowercased()
            // 模型原生支持的格式直接读原始字节，省去 decode + re-encode（跟 DragDropUtil 一致）
            if ["png", "jpg", "jpeg", "gif"].contains(ext), let data = try? Data(contentsOf: url) {
                return data
            }
            if let img = NSImage(contentsOf: url), let png = DragDropUtil.pngData(from: img) {
                return png
            }
        }
        // ② 剪贴板里直接是图片数据
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first, let png = DragDropUtil.pngData(from: img) {
            return png
        }
        return nil
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
                // 单图用 .fit：完整显示整张图、按比例缩放进 280×320 盒子内，
                // 竖图不会被 .fill 撑爆高度（旧 bug：竖图溢出到上千 pt，盖住下方文字气泡）
                imageThumb(images[0], index: 0, contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 320)
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
    private func imageThumb(_ data: Data, index: Int, contentMode: ContentMode = .fill) -> some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onTapGesture { previewIndex = index }
                .help(L("chat.image.zoom.help"))
                .contextMenu {
                    Button(L("chat.image.saveToDesktop")) { saveImageToDesktop(data) }
                    Button(L("chat.image.copy")) { copyImageToPasteboard(data) }
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

                Button(L("chat.image.preview.saveToDesktop")) { saveToDesktop(images[current]) }
                Button(L("chat.image.preview.close"), role: .cancel, action: onClose)
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
