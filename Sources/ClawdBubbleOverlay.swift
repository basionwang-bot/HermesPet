import AppKit
import SwiftUI

/// Clawd 头顶/旁边的情绪气泡 —— 让 Claude 模式的桌宠有"内心独白"。
///
/// 触发时机（仅 Claude 模式生效）：
///   - 任务超过 30s：「等等，快好了…」
///   - 任务超过 90s：「emm，再花点时间」
///   - 任务出错（success=false）：「糟糕 😵」
///
/// 实现：单独 NSWindow，level .statusBar，浮在灵动岛胶囊**右下方**，
/// 1.8s 自动淡出。跟 VoiceTranscriptOverlay 同款轻量模式
///
/// **守决策 #1/#6（2026-06-10 改）**：窗口尺寸**恒定** 380×64，气泡宽度变化全在 SwiftUI 内部
/// 自适应；定位只 `setFrameOrigin` 不 resize。用 NSHostingController + sizingOptions=[]（照
/// 语音陪聊窗）——旧写法是裸 NSHostingView + 每次显示按文字宽 setFrame + `.animation` 内容
/// 同回合变化，正是 `updateAnimatedWindowSize → setFrame` 嵌套 layout 崩溃（6/9 .ips）的模式。
@MainActor
final class ClawdBubbleOverlayController {
    static let shared = ClawdBubbleOverlayController()

    /// 窗口恒定尺寸：宽 = 气泡最大宽 360 + 余量；高 = 气泡 38 + 阴影余量（决策 #1：绝不按内容 resize）
    private static let winW: CGFloat = 380
    private static let winH: CGFloat = 64

    private var window: NSWindow?
    private var hosting: NSHostingController<ClawdBubbleView>?
    private let viewState = BubbleState()
    private var hideTask: Task<Void, Never>?

    private init() {
        registerNotifications()
    }

    // MARK: - 公开入口（其他控件直接 post 通知触发）

    /// 触发气泡显示。text 是要展示的文字，duration 默认 1.8s
    static func show(_ text: String, duration: TimeInterval = 1.8) {
        NotificationCenter.default.post(
            name: .init("HermesPetClawdBubble"),
            object: nil,
            userInfo: ["text": text, "duration": duration]
        )
    }

    // MARK: - Notifications

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetClawdBubble"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            let dur = (note.userInfo?["duration"] as? TimeInterval) ?? 1.8
            Task { @MainActor in
                self?.showBubble(text: text, duration: dur)
            }
        }
    }

    // MARK: - Show / Hide

    private func showBubble(text: String, duration: TimeInterval) {
        guard !text.isEmpty else { return }
        if window == nil { createWindow() }
        viewState.text = text
        viewState.isVisible = true
        positionWindow()
        window?.orderFront(nil)

        // 取消上一个隐藏 task，重新计时
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            viewState.isVisible = false
            try? await Task.sleep(nanoseconds: 350_000_000)   // 等淡出动画
            if Task.isCancelled { return }
            window?.orderOut(nil)
            viewState.text = ""
        }
    }

    // MARK: - Window

    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.winW, height: Self.winH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.auxiliary   // 低于灵动岛，见 WindowLevels.swift
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        // NSHostingController + sizingOptions=[]（照语音陪聊窗，见类头注释）——
        // 根视图用固定 .frame(width:height:)，给 Auto Layout 确定尺寸，避免首帧反推崩
        let host = NSHostingController(rootView: ClawdBubbleView(
            state: viewState, width: Self.winW, height: Self.winH
        ))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }  // 决策 #1/#6
        w.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）

        self.window = w
        self.hosting = host
    }

    /// 浮在带刘海屏的左上方位置 —— 在灵动岛胶囊**右下方**，与 Clawd（在灵动岛左耳）斜对应
    /// 实际是给 Clawd 的"思考泡"感。
    /// ⚠️ 只挪原点（窗口尺寸恒定）——setFrameOrigin 无 resize 路径，不会与 SwiftUI 内容
    /// 动画在同一 CA commit 撞 layout（决策 #6）。气泡视觉锚点跟旧版完全一致。
    private func positionWindow() {
        guard let window = window else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }
        let frame = screen.frame
        let safeArea = screen.safeAreaInsets
        let notchHeight: CGFloat = safeArea.top > 0 ? safeArea.top : 28

        // 气泡（内容居中）水平中心：刘海中心左移 200 → 灵动岛左耳（Clawd 所在）的左下方
        let centerX = frame.midX - 200
        // 气泡顶边：灵动岛胶囊本体下方（维持旧版 maxY - notch - 26 的视觉位置）
        let topY = frame.maxY - notchHeight - 8 - 18

        window.setFrameOrigin(NSPoint(x: centerX - Self.winW / 2, y: topY - Self.winH))
    }
}

// MARK: - State

@Observable
@MainActor
final class BubbleState {
    var text: String = ""
    var isVisible: Bool = false
}

// MARK: - SwiftUI Bubble

/// Clawd 头顶气泡 —— 黑胶囊 + 白字。窗口尺寸恒定，气泡按文字在窗口**内部**自适应（决策 #1）
struct ClawdBubbleView: View {
    @Bindable var state: BubbleState
    /// 与窗口一致的固定尺寸 —— NSHostingController 下根视图必须定宽高（见控制器类头注释）
    let width: CGFloat
    let height: CGFloat

    /// Anthropic Clawd 品牌橘 #D77757
    private static let clawdOrange = Color(red: 215.0/255, green: 119.0/255, blue: 87.0/255)

    var body: some View {
        ZStack(alignment: .top) {
            if state.isVisible {
                Text(state.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 360)   // 维持旧版气泡最大宽
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.82))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Self.clawdOrange.opacity(0.35), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
                    .transition(.scale(scale: 0.7, anchor: .top)
                        .combined(with: .opacity))
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.isVisible)
    }
}
