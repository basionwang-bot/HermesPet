import AppKit
import SwiftUI

/// 任务完成后灵动岛下方弹出的「迷你回复预览卡片」。
///
/// 触发条件（4 个门禁同时满足才弹）：
///   - HermesPetTaskFinished, success=true
///   - 完成的对话是当前 active 对话（避免跟 ConversationPill 后台呼吸光线重复透出）
///   - preview 非空
///   - 聊天窗当前未显示（已显示用户已经能看到回复，不必再弹）
///
/// 行为：
///   - 灵动岛正下方 320×150pt 卡片，3.5s 自动淡出
///   - hover 卡片本身 → 暂停淡出；移开 → 1.5s 后继续淡出
///   - "展开聊天" 按钮：打开聊天窗 + 立即收掉卡片
///   - "复制" 按钮：复制 preview 到剪贴板（1.2s 反馈"已复制"）
///   - ✕ 立即收掉
///
/// 实现：照搬 [[ClawdBubbleOverlayController]] 模式（独立 NSWindow + 状态对象 + 通知触发）。
/// canBecomeKey=false → 不抢焦点；level=auxiliary → 永不挡灵动岛
@MainActor
final class MiniReplyCardController {
    static let shared = MiniReplyCardController()

    /// 由 AppDelegate 注入：检查聊天窗是否已显示（已显示则不弹卡片）
    var chatWindowIsVisible: () -> Bool = { false }
    /// 由 AppDelegate 注入：用户点「展开聊天」时打开聊天窗
    var onOpenChat: () -> Void = {}

    private var window: NSWindow?
    private let viewState = MiniReplyState()
    private var hideTask: Task<Void, Never>?
    /// show() 启动的"等 1 frame 再翻 isVisible=true"task —— 快速重复 show 时要先 cancel
    /// 旧的，否则两个 task 都会写 viewState.isVisible/scheduleHide，造成多余卡片状态切换
    private var insertionTask: Task<Void, Never>?

    private init() {
        registerNotifications()
    }

    // MARK: - 通知

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetTaskFinished"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let success = (note.userInfo?["success"] as? Bool) ?? false
            let isActive = (note.userInfo?["isActive"] as? Bool) ?? false
            let preview = (note.userInfo?["preview"] as? String) ?? ""
            let modeRaw = (note.userInfo?["mode"] as? String) ?? ""
            let mode = AgentMode(rawValue: modeRaw) ?? .hermes
            guard success && isActive && !preview.isEmpty else { return }
            Task { @MainActor in
                // 门禁 1：聊天窗已显示 → 用户已经能看到完整回复，不再弹卡片
                if self.chatWindowIsVisible() { return }
                // 门禁 2：选项菜单已弹出（AI 给了编号列表，ChoiceMenuOverlay 接管显示）
                // 让位给 ChoiceMenuOverlay —— 点选项卡片直接发送回复，比 mini card 的"展开/复制"更直接
                if ChoiceMenuOverlayController.shared.isShowing { return }
                self.show(preview: preview, mode: mode)
            }
        }
    }

    // MARK: - Show / Hide

    private func show(preview: String, mode: AgentMode) {
        if window == nil { createWindow() }
        // 先把内容塞好但 isVisible 仍是 false，定位 + orderFront 让 NSWindow 显示
        viewState.preview = preview
        viewState.mode = mode
        viewState.isVisible = false
        positionWindow()
        window?.orderFront(nil)
        // 下一帧再把 isVisible 翻到 true —— SwiftUI 此时才会监测到 false→true 变化，
        // 触发 transition.insertion（从上方掉下 + scale + fade），否则窗口直接 fade in 没层次感
        insertionTask?.cancel()
        insertionTask = Task { @MainActor [weak self] in
            // 一个 runloop（60Hz=16ms / 120Hz=8ms）就足够让 SwiftUI 完成 false 状态的 commit
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
            guard let self = self else { return }
            self.viewState.isVisible = true
            self.scheduleHide(after: 3.5)
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            viewState.isVisible = false
            try? await Task.sleep(nanoseconds: 360_000_000)
            if Task.isCancelled { return }
            window?.orderOut(nil)
            viewState.preview = ""
        }
    }

    fileprivate func pauseHide() {
        hideTask?.cancel()
    }

    fileprivate func resumeHide() {
        scheduleHide(after: 1.5)
    }

    fileprivate func hideNow() {
        insertionTask?.cancel()  // show 还没翻 isVisible=true，先吃掉，避免它复活卡片
        hideTask?.cancel()
        viewState.isVisible = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 360_000_000)
            self?.window?.orderOut(nil)
            self?.viewState.preview = ""
        }
    }

    /// 公开版：聊天窗打开时由 AppDelegate 调用，避免 mini card 跟聊天窗同时显示。
    /// 仅在 mini card 正悬浮时才执行，已隐藏时是 no-op
    func hideIfVisible() {
        guard viewState.isVisible else { return }
        hideNow()
    }

    // MARK: - Window

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.auxiliary
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false   // SwiftUI 内 shadow 已经给了
        w.ignoresMouseEvents = false
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: MiniReplyCardView(
            state: viewState,
            onHover: { [weak self] hovering in
                guard let self = self else { return }
                if hovering { self.pauseHide() } else { self.resumeHide() }
            },
            onOpenChat: { [weak self] in
                guard let self = self else { return }
                self.hideNow()
                self.onOpenChat()
            },
            onCopy: { [weak self] in
                guard let preview = self?.viewState.preview, !preview.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preview, forType: .string)
            },
            onClose: { [weak self] in
                self?.hideNow()
            }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 150)
        host.autoresizingMask = [.width, .height]
        w.contentView = host

        self.window = w
    }

    /// 灵动岛胶囊正下方居中
    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }
        let frame = screen.frame
        let safeArea = screen.safeAreaInsets
        let notchHeight: CGFloat = safeArea.top > 0 ? safeArea.top : 28

        let cardWidth: CGFloat = 320
        let cardHeight: CGFloat = 150
        // 🔑 横向跟灵动岛对齐 —— 用刘海实际中心（auxiliaryTop* 反推），不是 screen.frame.midX。
        // MacBook 14"/16" 刘海**不一定在屏幕几何正中**（实测会偏移几 pt），用 screen.midX 算的话
        // mini card 会跟灵动岛错位 → 用户视觉上感觉"灵动岛左移"（实际是 mini card 不对中）。
        // 跟 DynamicIslandController.positionWindow 用同一套算法
        let centerX: CGFloat
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            centerX = (l.maxX + r.minX) / 2
        } else {
            centerX = frame.midX
        }
        let x = centerX - cardWidth / 2
        // 灵动岛下方 18pt（idle 4pt 露出 + 14pt 间距）
        let y = frame.maxY - notchHeight - 4 - 14 - cardHeight

        window.setFrame(
            NSRect(x: x, y: y, width: cardWidth, height: cardHeight),
            display: true
        )
    }
}

// MARK: - State

@Observable
@MainActor
final class MiniReplyState {
    var preview: String = ""
    var mode: AgentMode = .hermes
    var isVisible: Bool = false
}

// MARK: - SwiftUI View

struct MiniReplyCardView: View {
    @Bindable var state: MiniReplyState
    let onHover: (Bool) -> Void
    let onOpenChat: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>? = nil

    private var modeTint: Color {
        switch state.mode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    var body: some View {
        ZStack {
            if state.isVisible {
                card
                    // 跟灵动岛 task finished 时其他卡片完全统一的 transition：opacity + scale 0.96，
                    // anchor:.top 让卡片"从灵动岛下方长出来"。去掉之前的 .move(edge:.top) —— 那个 150pt
                    // 的从屏顶下滑动距离跟灵动岛原地切换不匹配，用户看到"一层一层"的分裂动画感
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // AnimTok.smooth（0.35/0.85）—— 跟灵动岛 task finished 时的 spring(0.35/0.85) 完全同步，
        // 两个动画一气呵成。之前 bouncy 0.42/0.78 比灵动岛慢 70ms 还更弹 → 视觉脱节
        .animation(AnimTok.smooth, value: state.isVisible)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: mode 图标 + 标题 + ✕
            HStack(spacing: 7) {
                Image(systemName: state.mode.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(modeTint)
                Text("\(state.mode.label) 回复完成")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.90))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 7)

            // Body: 预览
            Text(state.preview)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.86))
                .lineSpacing(2)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            // Footer: 展开 / 复制
            HStack(spacing: 8) {
                Button(action: onOpenChat) {
                    Text("展开聊天")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(
                            Capsule()
                                .fill(modeTint.opacity(0.92))
                                .shadow(color: modeTint.opacity(0.35), radius: 4, y: 2)
                        )
                }
                .buttonStyle(.plain)

                Button(action: handleCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 11)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
            }
        )
        .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .onHover(perform: onHover)
    }

    private func handleCopy() {
        onCopy()
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            copied = false
        }
    }
}
