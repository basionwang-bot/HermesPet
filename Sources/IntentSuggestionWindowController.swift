import AppKit
import SwiftUI

/// 意图建议卡片（v1.3 Phase 2 反向唤醒 UI 底座）
///
/// IntentPatternDetector 命中 pattern → IntentNotificationManager →
/// 本 controller 在灵动岛下方弹出一张"桌宠主动建议"卡片：
///   - 顶部一行 icon + 标题（"看到报错了" / "你回来了 3 次"）
///   - 中间 OCR 摘要 / app·窗口 副标题
///   - 底部两按钮："知道了" + "看看吧"
///
/// 8s 自动消失 = "知道了"（自然冷却 1h）。
/// 用户点"看看吧" → post HermesPetIntentSuggestionAccepted 通知，
///   AppDelegate 接收后打开聊天窗 + 自动新建对话 + 预填 promptDraft。
/// 用户点"知道了" → post HermesPetIntentSuggestionDismissed → detector 加 24h 冷却。
///
/// 跟 ResponseSummary / Permission 同款架构（决策 #16）：
///   - 独立 NSWindow + .borderless + .nonactivatingPanel
///   - 紧贴菜单栏底部，等宽于灵动岛
///   - 跟灵动岛同 z-order
@MainActor
final class IntentSuggestionWindowController {
    static weak var shared: IntentSuggestionWindowController?

    private let window: NSWindow
    private let hosting: NSHostingView<IntentSuggestionRoot>
    private let viewState = IntentSuggestionViewState()
    private var autoDismissTask: Task<Void, Never>?

    var isShowing: Bool { viewState.pattern != nil }

    /// 卡片宽度 = 灵动岛宽度 + idleExtra
    private var cardWidth: CGFloat {
        let screen = HermesIslandGeometry.targetScreen()
        let core: CGFloat = screen.map { HermesIslandGeometry.islandCoreWidth(on: $0) } ?? 200
        return core + 80
    }
    private let cardHeight: CGFloat = 140
    private let topGap: CGFloat = 10

    init() {
        let initialWidth: CGFloat = 280
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        win.level = HermesWindowLevel.dynamicIsland
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        self.window = win

        let host = NSHostingView(rootView: IntentSuggestionRoot(state: viewState))
        host.frame = NSRect(x: 0, y: 0, width: initialWidth, height: cardHeight)
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            host.sizingOptions = []   // 阻止 SwiftUI 反向请求 setFrame（决策 #6）
        }
        win.contentView = host
        self.hosting = host
        Self.shared = self

        viewState.onAccept   = { [weak self] in self?.handleAccept() }
        viewState.onDismiss  = { [weak self] in self?.handleDismiss() }
        viewState.onHover    = { [weak self] hovering in
            if hovering { self?.cancelAutoDismiss() }
            else { self?.scheduleAutoDismiss() }
        }

        positionUnderIsland()

        NotificationCenter.default.addObserver(
            forName: .init("HermesPetGeometry"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.positionUnderIsland()
            }
        }

        // 聊天窗被打开 → 立即收卡片（用户已经在聊天里了，卡片没必要再展示）
        NotificationCenter.default.addObserver(
            forName: .hermesPetChatWindowShown,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide(silent: true)
            }
        }
    }

    // MARK: - Public

    /// IntentNotificationManager 调用 —— 在灵动岛下方弹出建议
    func show(pattern: DetectedPattern, currentMode: AgentMode) {
        positionUnderIsland()
        window.orderFront(nil)
        window.alphaValue = 1

        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            viewState.pattern = pattern
            viewState.currentMode = currentMode
        }
        scheduleAutoDismiss()
    }

    /// 收卡片。silent=true 表示已被外部（如聊天窗打开）消化掉，不发"dismissed"通知
    func hide(silent: Bool = false) {
        cancelAutoDismiss()
        // 记下要 dismiss 的 pattern（hide 之后 state 会清）
        let pat = viewState.pattern

        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
            viewState.pattern = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.viewState.pattern == nil {
                self.window.alphaValue = 0
                self.window.orderOut(nil)
            }
        }

        // 自动 dismiss（"知道了" / 8s 超时）→ 通知 detector 加 24h 冷却的话由调用方决定
        // 这里只在非 silent 时发 dismissed（让 NotificationManager 决定是否加重冷却）
        if !silent, let pat {
            NotificationCenter.default.post(
                name: .init("HermesPetIntentSuggestionDismissed"),
                object: nil,
                userInfo: ["patternID": pat.patternID]
            )
        }
    }

    // MARK: - 内部

    private func handleAccept() {
        guard let pat = viewState.pattern else { return }
        // 通知外部"用户点了看看吧" —— 由 AppDelegate / NotificationManager 接管打开聊天窗
        NotificationCenter.default.post(
            name: .init("HermesPetIntentSuggestionAccepted"),
            object: nil,
            userInfo: [
                "patternID": pat.patternID,
                "promptDraft": pat.promptDraft,
                "intentID": pat.intent.id
            ]
        )
        hide(silent: true)   // silent：accepted 已经发过通知了
    }

    private func handleDismiss() {
        hide(silent: false)
    }

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Task.isCancelled { return }
            self?.hide(silent: false)
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    private func positionUnderIsland() {
        guard let screen = HermesIslandGeometry.targetScreen() else { return }
        let notchCenterX = HermesIslandGeometry.islandCenterX(on: screen)
        let cardTopY = HermesIslandGeometry.islandBottomY(on: screen)
                     - HermesIslandGeometry.cardTopGapBelowIsland(on: screen)
        let x = notchCenterX - cardWidth / 2
        let y = cardTopY - cardHeight - topGap
        window.setFrame(NSRect(x: x, y: y, width: cardWidth, height: cardHeight), display: false)
    }
}

// MARK: - ViewState

@MainActor
@Observable
final class IntentSuggestionViewState {
    var pattern: DetectedPattern? = nil
    /// 当前激活的 mode —— 决定卡片上 sprite 是哪只桌宠
    var currentMode: AgentMode = .hermes

    var onAccept: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
}

// MARK: - SwiftUI

private struct IntentSuggestionRoot: View {
    @Bindable var state: IntentSuggestionViewState

    var body: some View {
        ZStack {
            // 显式 unwrap pattern 再传入 CardView，避免 dismiss 动画期间 force-unwrap 崩溃。
            // 之前 if state.pattern != nil + pattern!  在 transition 中 SwiftUI 多次评估 body，
            // 期间 state.pattern 已被 hide() 置 nil 但 view 还在 fade out → nil unwrap → SIGTRAP
            //
            // transition 只能用 opacity —— 决策 #6 同源教训：几何 transition（.move/.scale/.slide）
            // 在独立 NSWindow 的 NSHostingView 里会触发 invalidateTransform →
            // setNeedsUpdateConstraints → NSException 必崩。
            // 即便 sizingOptions=[] 也挡不住 transform 路径，只能从 SwiftUI 这一侧不发起几何动画。
            if let pat = state.pattern {
                IntentSuggestionCardView(state: state, pattern: pat)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct IntentSuggestionCardView: View {
    @Bindable var state: IntentSuggestionViewState
    /// pattern 由父 View 在 unwrap 后显式传入 —— 整个 CardView 生命周期内非 nil
    let pattern: DetectedPattern
    @State private var paletteStore = PetPaletteStore.shared
    @AppStorage("quietMode") private var quietMode: Bool = false

    private var palette: PetPalette { paletteStore.palette(for: state.currentMode) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(Color.black)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            // 顶部薄薄一道主色高光，让卡片视觉上有桌宠 mode 色彩
            shape.fill(LinearGradient(
                colors: [palette.primary.opacity(0.18), .clear],
                startPoint: .top, endPoint: .bottom
            ))
            VStack(spacing: 0) {
                headerRow
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                if !pattern.subtitle.isEmpty {
                    HStack {
                        Text(pattern.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                Spacer(minLength: 0)

                buttonRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .clipShape(shape)
        }
        .onHover { state.onHover($0) }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            // mini sprite
            miniSprite(mode: state.currentMode, height: 22, palette: palette)
                .frame(width: 32, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(pattern.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            // 关闭按钮 = dismiss（跟"知道了"等价）
            Button {
                state.onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            // 知道了 = dismiss，加 24h 冷却
            Button {
                state.onDismiss()
            } label: {
                Text("知道了")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(.plain)

            // 看看吧 = 接受 → 打开聊天窗 + 预填 prompt
            Button {
                state.onAccept()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11))
                    Text("看看吧")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.primary.opacity(0.85))
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// 按 mode 渲染对应桌宠迷你 sprite（复用 ResponseSummary 同款逻辑）
    @ViewBuilder
    private func miniSprite(mode: AgentMode, height: CGFloat, palette: PetPalette) -> some View {
        let anim = !quietMode
        Group {
            switch mode {
            case .claudeCode:
                ClawdView(pose: .rest, height: height, isWalking: false,
                          palette: palette, animated: anim)
            case .directAPI:
                CloudPetView(pose: .rest, height: height, isWalking: false,
                             glassesProgress: 0, palette: palette, animated: anim)
            case .openclaw:
                FomoView(pose: .rest, height: height, isWalking: false,
                         palette: palette, animated: anim)
            case .hermes:
                HorseView(pose: .rest, height: height, isWalking: false,
                          palette: palette, animated: anim)
            case .codex:
                TerminalView(pose: .rest, height: height, isWalking: false,
                             isWorking: false, palette: palette, animated: anim)
            }
        }
    }
}
