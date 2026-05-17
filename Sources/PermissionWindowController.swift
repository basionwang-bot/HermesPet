import AppKit
import SwiftUI

/// 专门承载 permission 卡片的独立 NSWindow。
///
/// **为什么独立窗口而非灵动岛复用**：灵动岛 NSWindow 一旦 setFrame 改变大小，
/// macOS 26 上的 NSHostingView 就会触发 invalidateSafeAreaInsets → 嵌套 setNeedsUpdate
/// → NSException 必崩。即便 sizingOptions=[]、setFrame 瞬切、SwiftUI 内部不动画，
/// 只要灵动岛 window frame 变化就崩。
/// 所以 permission 卡片必须用独立 window，灵动岛 window 永远保持原尺寸不动。
///
/// **视觉融合**：window 紧贴灵动岛底部（无间隙），黑色背景延续灵动岛黑色凹槽，
/// 视觉上像"灵动岛在变大"，但代码上两个 window 完全独立、独立动画、互不干扰。
///
/// **生命周期**：app 启动时创建（监听通知），permission 来时 orderFront + SwiftUI 内部动画，
/// 用户决策后 orderOut。窗口尺寸创建后永不变化，所以不会触发任何嵌套 layout 问题
@MainActor
final class PermissionWindowController {

    private let window: NSWindow
    private let hosting: NSHostingView<PermissionWindowRoot>

    /// 卡片宽度 = **动态**跟随灵动岛 NSWindow 宽度（notchWidth + idleExtraWidth）。
    /// HermesPetGeometry 通知更新这两个字段后 positionUnderIsland 重算 cardWidth。
    /// 默认值是 14" MacBook Pro 的典型值，HermesPetGeometry 通知一到立即被覆盖。
    ///
    /// **+8pt 视觉补偿**：NotchShape path 边缘 antialias 让灵动岛视觉宽度比 NSWindow.width
    /// 多 ~4-6pt，卡片用纯 RoundedRectangle 没这个边缘 → 严格等 NSWindow 宽会看起来卡片窄一点。
    /// 加 8pt 两侧各 4pt 补偿 antialias 视觉差
    private var dynamicNotchWidth: CGFloat = 200
    private var dynamicIdleExtra: CGFloat = 80
    private var cardWidth: CGFloat { dynamicNotchWidth + dynamicIdleExtra + 10 }
    private let cardHeight: CGFloat = 260

    /// SwiftUI 那边的可观察状态 holder（通过 NotificationCenter 同步）
    private let viewState = PermissionViewState()

    init() {
        // init 期间 cardWidth (computed) 还不能访问，先用默认值算
        let initialWidth: CGFloat = 280
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        win.level = HermesWindowLevel.dynamicIsland   // 跟灵动岛同层
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.alphaValue = 0   // 默认隐藏，permission 来时 fade in
        self.window = win

        let host = NSHostingView(rootView: PermissionWindowRoot(state: viewState))
        host.frame = NSRect(x: 0, y: 0, width: initialWidth, height: cardHeight)
        host.autoresizingMask = [.width, .height]
        // 跟灵动岛 hosting 一样的 trick：阻止 SwiftUI 反向请求 window setFrame
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }
        win.contentView = host
        self.hosting = host

        positionUnderIsland()

        // 监听灵动岛 geometry 变化（屏幕切换 / 缩放 / 不同机型刘海宽度）
        // 拿到真实 notchWidth + idleExtraWidth → cardWidth 跟随重算 + 重新定位
        //
        // NotificationCenter block observer 闭包签名是 @Sendable，Swift 6 不能假设
        // queue:.main 等于 MainActor。但实际确实跑在 main thread，所以用
        // MainActor.assumeIsolated 桥过去 —— 比 Task @MainActor 更快（不开新任务）
        // 监听灵动岛 geometry 变化（屏幕切换 / 缩放 / 不同机型刘海宽度）
        // 拿到真实 notchWidth + idleExtraWidth → cardWidth 跟随重算 + 重新定位
        //
        // NotificationCenter block observer 闭包是 @Sendable，note 本身不是 Sendable。
        // 所以先在外层把 Sendable 字段拎出来（CGFloat / String / 自定义 Sendable struct），
        // 再用 MainActor.assumeIsolated 桥到 main actor 上调实例方法。
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetGeometry"),
            object: nil, queue: .main
        ) { [weak self] note in
            let w = note.userInfo?["notchWidth"] as? CGFloat
            let e = note.userInfo?["idleExtraWidth"] as? CGFloat
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if let w = w { self.dynamicNotchWidth = w }
                if let e = e { self.dynamicIdleExtra = e }
                self.positionUnderIsland()
            }
        }

        // permission 流程：
        //   asked → 显示卡片 + 设状态 → SwiftUI 内部 spring 动画
        //   replied / decisionMade → SwiftUI 内部退场动画 → 延时 orderOut
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetPermissionAsked"),
            object: nil, queue: .main
        ) { [weak self] note in
            let req = note.userInfo?["request"] as? PermissionRequest
            MainActor.assumeIsolated {
                if let req = req { self?.show(request: req) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetPermissionReplied"),
            object: nil, queue: .main
        ) { [weak self] note in
            let replyID = note.userInfo?["requestID"] as? String
            MainActor.assumeIsolated {
                self?.hide(matchingID: replyID)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetPermissionDecisionMade"),
            object: nil, queue: .main
        ) { [weak self] note in
            let id = note.userInfo?["requestID"] as? String
            MainActor.assumeIsolated {
                self?.hide(matchingID: id)
            }
        }

        // Question 卡片（AI 主动问问题）
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetQuestionAsked"),
            object: nil, queue: .main
        ) { [weak self] note in
            let req = note.userInfo?["request"] as? QuestionRequest
            MainActor.assumeIsolated {
                if let req = req { self?.show(question: req) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetQuestionAnswered"),
            object: nil, queue: .main
        ) { [weak self] note in
            let id = note.userInfo?["requestID"] as? String
            MainActor.assumeIsolated {
                self?.hide(matchingID: id)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetQuestionRejected"),
            object: nil, queue: .main
        ) { [weak self] note in
            let id = note.userInfo?["requestID"] as? String
            MainActor.assumeIsolated {
                self?.hide(matchingID: id)
            }
        }
    }

    private func show(question: QuestionRequest) {
        window.orderFront(nil)
        window.alphaValue = 1
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86, blendDuration: 0.3)) {
            viewState.question = question
        }
    }

    // MARK: - Position 计算（紧贴灵动岛下方）

    /// 把卡片放到灵动岛下方居中位置。
    /// 横向：跟刘海真实中心 x 对齐
    /// 纵向：卡片顶部 = 菜单栏底部（= 刘海凹槽底部 / 灵动岛 idle 形状底部），
    /// **不覆盖菜单栏**，菜单栏上的图标正常显示
    private func positionUnderIsland() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }

        let screenFrame = screen.frame
        let safeArea = screen.safeAreaInsets
        let hasNotch = safeArea.top > 0

        let notchCenterX: CGFloat = {
            if hasNotch,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                return (left.maxX + right.minX) / 2
            }
            return screenFrame.midX
        }()

        let notchHeight: CGFloat = hasNotch ? safeArea.top : 28
        // 卡片顶部 = 菜单栏底部，跟灵动岛底部直角形态完美衔接成一体（无缝过渡）
        let cardTopY = screenFrame.maxY - notchHeight

        // **左侧 -1pt 偏移**（用户视觉对齐微调，从 -2pt 调到 -1pt）：
        // 左边沿往右缩 1pt，右边沿保持原位
        let leftShrink: CGFloat = 1
        let adjustedWidth = cardWidth - leftShrink
        let x = notchCenterX - adjustedWidth / 2 + leftShrink / 2
        let y = cardTopY - cardHeight

        window.setFrame(
            NSRect(x: x, y: y, width: adjustedWidth, height: cardHeight),
            display: false
        )
    }

    // MARK: - 显示 / 隐藏

    private func show(request: PermissionRequest) {
        window.orderFront(nil)
        window.alphaValue = 1
        // 入场：柔和 spring 慢节奏，高 damping 不弹跳，给"灵动岛缓缓变形"的高级感
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86, blendDuration: 0.3)) {
            viewState.request = request
        }
    }

    /// 隐藏卡片。matchingID 非 nil 时只有当前 request/question id 匹配才隐藏（避免误关）
    private func hide(matchingID: String?) {
        // 检查 ID 匹配（permission 或 question 任一匹配就触发隐藏）
        if let mid = matchingID {
            let permMatch = viewState.request?.id == mid
            let questMatch = viewState.question?.id == mid
            if !permMatch && !questMatch { return }
        }
        // 退场：稍快但仍柔和，blendDuration 长让收回过程平滑
        withAnimation(.spring(response: 0.55, dampingFraction: 0.9, blendDuration: 0.25)) {
            viewState.request = nil
            viewState.question = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self else { return }
            if !self.viewState.isShowingCard {
                self.window.alphaValue = 0
                self.window.orderOut(nil)
            }
        }
    }
}

// MARK: - SwiftUI 状态 holder

/// PermissionWindow 的 SwiftUI 顶层状态。
/// `@Observable` 让 SwiftUI 自动响应 request 变化触发 .transition。
/// 同时间只显示 permission 或 question 之一，两者互斥
@MainActor
@Observable
final class PermissionViewState {
    var request: PermissionRequest?
    var question: QuestionRequest?

    /// 卡片是否正在显示（两者任一非 nil）
    var isShowingCard: Bool { request != nil || question != nil }
}

// MARK: - SwiftUI Root

/// 整个 PermissionWindow 的 SwiftUI 内容。
/// 当 state.request 非 nil 时显示卡片，nil 时空（用 .transition 退场）。
struct PermissionWindowRoot: View {
    @Bindable var state: PermissionViewState

    var body: some View {
        ZStack {
            if let req = state.request {
                permissionCard(req)
            } else if let q = state.question {
                questionCard(q)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 动画由 PermissionWindowController.show/hide 用 withAnimation 包起来控制
    }

    private func permissionCard(_ req: PermissionRequest) -> some View {
        ZStack {
            // 卡片背景：顶部直角 + 底部 22pt 圆角，跟灵动岛底部无缝衔接
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: 0,
                    bottomLeading: 22,
                    bottomTrailing: 22,
                    topTrailing: 0
                ),
                style: .continuous
            )
            .fill(Color.black)
            .overlay(
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: 0,
                        bottomLeading: 22,
                        bottomTrailing: 22,
                        topTrailing: 0
                    ),
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 6)

            PermissionCardView(request: req) { decision in
                NotificationCenter.default.post(
                    name: .init("HermesPetPermissionDecisionMade"),
                    object: nil,
                    userInfo: ["requestID": req.id, "decision": decision.rawValue]
                )
                state.request = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(cardTransition)
    }

    /// AI 主动问问题卡片 —— 复用同一套黑色背景 + transition，内部换 QuestionCardView
    private func questionCard(_ req: QuestionRequest) -> some View {
        ZStack {
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0),
                style: .continuous
            )
            .fill(Color.black)
            .overlay(
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0),
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 6)

            QuestionCardView(
                request: req,
                onAnswer: { answers in
                    NotificationCenter.default.post(
                        name: .init("HermesPetQuestionAnswered"),
                        object: nil,
                        userInfo: ["requestID": req.id, "answers": answers]
                    )
                    state.question = nil
                },
                onReject: {
                    NotificationCenter.default.post(
                        name: .init("HermesPetQuestionRejected"),
                        object: nil,
                        userInfo: ["requestID": req.id]
                    )
                    state.question = nil
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(cardTransition)
    }

    /// 卡片入场 / 退场动画 —— permission 和 question 共用同一套 mask + offset 双重
    private var cardTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PermissionCardTransition(progress: 0, cardHeight: 260),
                identity: PermissionCardTransition(progress: 1, cardHeight: 260)
            ),
            removal: .modifier(
                active: PermissionCardTransition(progress: 0, cardHeight: 260),
                identity: PermissionCardTransition(progress: 1, cardHeight: 260)
            )
        )
    }
}

/// **mask + offset 双重作用** —— 让卡片"被拉回灵动岛"的动画。
///
/// 两条动画同时执行：
/// 1. **mask 顶部锚定**：卡片从底部往上被"擦掉"，按钮原样消失不变形
/// 2. **整体 offset 上滑**：卡片整体往灵动岛方向位移
///
/// 双重作用叠加，给用户清晰的"被拉回灵动岛"走向感（不是简单消失也不是简单压缩），
/// 让用户感受到这是灵动岛在"变形 / 复原"，而不是独立卡片在出现 / 消失
struct PermissionCardTransition: ViewModifier {
    /// 0 = 完全收起到灵动岛位置，1 = 完全展开
    let progress: CGFloat
    /// 卡片总高度（用于计算 offset 距离）
    let cardHeight: CGFloat

    func body(content: Content) -> some View {
        content
            // mask: 从顶部锚定，按 progress 比例显示
            .mask(alignment: .top) {
                Rectangle()
                    .scaleEffect(x: 1.0, y: progress, anchor: .top)
            }
            // offset: progress=0 时卡片整体上移 cardHeight 距离（贴在灵动岛位置）
            // progress=1 时归位到正常位置
            .offset(y: -cardHeight * (1 - progress))
    }
}
