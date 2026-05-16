import SwiftUI
import AppKit

/// 灵动岛 hover 进入「嵌入式聊天框」形态时渲染的 SwiftUI 视图。
///
/// 视觉策略：
/// - 容器是 `NotchShape`（上平下圆），跟刘海视觉延续
/// - 顶部留出 `notchHeight` 高的 padding，让"刘海本体"贴住屏幕顶
/// - 中段：最近一条 user 消息（单行）+ 最近一条 assistant 消息（2 行）
/// - 底部：紧凑输入框 + 发送按钮（复用 `SendOnEnterTextEditor` + `SendButton`）
///
/// 行为策略：
/// - 不自己持有状态：messages / inputText / 发送 全部走 `viewModel` 单一来源
/// - 发送时 `viewModel.inputText = text; viewModel.sendMessage()` —— 跟 ChatView 走完全同一条路径
/// - 不显示附件/AgentMode 切换/会话胶囊 —— 完整功能在主 ChatWindow，这里只是快回复入口
@MainActor
struct EmbeddedChatPanelView: View {
    /// 只读 + 局部 set inputText：不用 @Bindable（避免对 computed property 如 isLoading 走 dynamicMember
    /// 失败），SwiftUI 仍会因 viewModel 是 @Observable 而自动跟踪它的属性变更
    let viewModel: ChatViewModel
    /// 刘海实际高度，由 controller 通过 init 传入（用作顶部 padding）
    let notchHeight: CGFloat
    /// 用户点击右上角"打开完整窗口"图标时的回调（AppDelegate 注入）
    var onExpandToFullWindow: () -> Void = {}

    @State private var inputHeight: CGFloat = 28
    @State private var inputFocused: Bool = false

    /// 输入文字 binding 到 vm.inputText —— 跟主 ChatWindow 共享，两边都能看到半成品文本，
    /// embedded 收回后再次展开仍保留（@State 在视图重建时会 reset，绑到 vm 持久化）
    private var inputBinding: Binding<String> {
        Binding(
            get: { viewModel.inputText },
            set: { viewModel.inputText = $0 }
        )
    }

    /// 当前 mode tint —— 跟主 ChatWindow header / 灵动岛 idle 圆点保持同色
    private var tint: Color {
        switch viewModel.agentMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    /// 最近一条 user 消息内容（trim 后），没有就 nil
    private var lastUserMessage: ChatMessage? {
        viewModel.messages.last(where: { $0.role == .user })
    }
    /// 最近一条 assistant 消息（流式中也算）
    private var lastAssistantMessage: ChatMessage? {
        viewModel.messages.last(where: { $0.role == .assistant })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部留出"刘海实际高度 + 6pt 视觉气口"——避免 header 内容贴在刘海下沿，看着挤
            Color.clear.frame(height: notchHeight + 6)

            VStack(alignment: .leading, spacing: 8) {
                // 顶部 header 行：mode 标签 + 状态 + 展开图标
                headerRow
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                // 中段：最近对话预览（user + assistant 各一条）
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        if viewModel.messages.isEmpty {
                            emptyState
                        } else {
                            if let userMsg = lastUserMessage {
                                miniBubble(text: userMsg.content, role: .user)
                            }
                            if let aiMsg = lastAssistantMessage {
                                miniBubble(
                                    text: aiMsg.content.isEmpty
                                        ? (aiMsg.isStreaming ? "思考中…" : "")
                                        : aiMsg.content,
                                    role: .assistant,
                                    streaming: aiMsg.isStreaming
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                // 底部输入栏
                inputBar
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.agentMode.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(viewModel.agentMode.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .tracking(0.3)
            Circle()
                .fill(viewModel.connectionStatus.isConnected ? tint : .gray)
                .frame(width: 5, height: 5)
                .opacity(0.85)
            Spacer()
            Button {
                onExpandToFullWindow()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开完整聊天窗")
        }
    }

    /// 单条迷你气泡 —— 不复用 MessageBubbleView（那个有头像 / 时间戳 / pin 按钮太重），自己画
    @ViewBuilder
    private func miniBubble(text: String, role: MessageRole, streaming: Bool = false) -> some View {
        let isUser = role == .user
        HStack(alignment: .top, spacing: 6) {
            if !isUser {
                Image(systemName: viewModel.agentMode.iconName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 3)
            }
            Text(text)
                .font(.system(size: 11, weight: isUser ? .medium : .regular))
                .foregroundStyle(isUser ? Color.white.opacity(0.95) : Color.white.opacity(0.80))
                .lineLimit(isUser ? 1 : 2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if streaming {
                        // 流式三点
                        Text("…")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tint.opacity(0.7))
                    }
                }
            if isUser {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isUser ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
        )
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            Text("开始对话")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .padding(.vertical, 14)
    }

    /// 紧凑输入栏 —— 黑底 panel 专用配色（白文字 + 半透明灰底）
    private var inputBar: some View {
        let measuredHeight = min(max(inputHeight, 28), 60)
        return ZStack(alignment: .bottomTrailing) {
            SendOnEnterTextEditor(
                text: inputBinding,
                isFocused: $inputFocused,
                idealHeight: $inputHeight,
                placeholder: "消息",
                onSend: send,
                onPasteImage: { _ in /* embedded 模式不支持图片，引导用户去主窗口 */ }
            )
            .frame(height: measuredHeight)
            // leading 14：18pt 圆角下半径=9，避开左半圆弧让光标不贴边（CLAUDE.md 决策 #6）
            .padding(.leading, 14)
            .padding(.trailing, 38)
            .padding(.vertical, 4)
            .colorScheme(.dark)   // 让 NSTextView 文字默认走 dark scheme 配色（白光标 / 白字）

            SendButton(
                isLoading: viewModel.isLoading,
                canSend: !viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty,
                tint: tint,
                action: { viewModel.isLoading ? viewModel.cancelCurrentRequest() : send() }
            )
            .padding(.trailing, 4)
            .padding(.bottom, 2)
        }
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(inputFocused ? 0.16 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(inputFocused ? tint.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 1.0)
        )
    }

    // MARK: - Actions

    private func send() {
        let trimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.inputText = trimmed
        viewModel.sendMessage()
        // viewModel.sendMessage() 内部会清空 inputText —— 这里不再重复清
    }
}
