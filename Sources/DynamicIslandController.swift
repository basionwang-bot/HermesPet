import AppKit
import SwiftUI

/// 灵动岛专用 NSPanel —— `borderless + nonactivatingPanel` 的 NSWindow 默认
/// `canBecomeKey = false`，导致 hover 进入「嵌入式聊天框」形态时 NSTextView 收不到键盘事件。
///
/// 解法：子类化 NSPanel + override `canBecomeKey` 返回 true。配合：
/// - `isFloatingPanel = true` → 接收键盘输入但**不切换前台 app**（用户在 Safari，hover 灵动岛打字
///   不应让 Safari 失去 active 状态）
/// - `becomesKeyOnlyIfNeeded = true` → idle 态下点击胶囊不会"自动 makeKey 抢焦点"，
///   只有内部子视图（NSTextView）主动请求 firstResponder 时才 becomeKey
///
/// 已踩过的相关坑（CLAUDE.md 决策 #4 #5 #7）：
/// - @MainActor 类的 closure 被后台线程回调 → SIGTRAP，但 NSPanel 子类本身不涉及（系统调用都在 main）
/// - 跨窗口 setFrame 嵌套 layout → embedded 切换时 setFrame **只**在 controller 主动调用，
///   SwiftUI 内用 `.frame(maxWidth: .infinity, maxHeight: .infinity)` 不反推
final class EmbeddableIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // borderless panel 默认 canBecomeMain = false 即可，不要让它抢主窗口语义
    override var canBecomeMain: Bool { false }

    /// 🔑 不让系统调整 panel frame —— macOS 26 默认 `constrainFrameRect` 会把 panel 约束到
    /// `screen.visibleFrame`（避开 menu bar），即使 `level = .statusBar` 也被约束。
    /// 我们要 panel 顶贴**物理屏顶**（盖住刘海两侧 + idle/embedded 都靠这个），所以原样返回。
    /// 经验：早期 NSHostingView 时这个约束被某种内部机制绕过；换 NSHostingController 后失效暴露
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// 与刘海融合的桌宠胶囊。
/// 默认（idle）：刘海两侧探出来一段，像 iPhone 灵动岛常驻态显示信息。
/// 悬停（hover）：横向收紧到刘海宽度、纵向也变短，像一个紧凑的可点击按钮。
/// 嵌入式聊天（embedded）：刘海"长出"一个 420×280pt 的迷你聊天卡（仅当 vm.hoverExpandMode == .embedded）
@MainActor
final class DynamicIslandController {
    private(set) var pillWindow: EmbeddableIslandPanel
    /// 用 NSHostingController 而非 NSHostingView —— 两者的 `sizingOptions` 语义不同：
    /// - NSHostingView.sizingOptions = [] 在 macOS 26 仍**不能**完全阻止 windowDidLayout 期间
    ///   `updateAnimatedWindowSize` 反推 NSWindow.setFrame（实测 SIGABRT，嵌套 layout cycle）
    /// - NSHostingController.sizingOptions = [] **能**真正禁用反推（ChatWindowController 用同样套路从未崩过）
    private let hostingController: NSHostingController<DynamicIslandPillView>

    /// 由 HermesPetApp 调 `attach(viewModel:)` 注入，用于嵌入式聊天框访问消息/发送
    private(set) weak var viewModel: ChatViewModel?

    /// 当前是不是嵌入式聊天形态（pillWindow 已扩大到 420×280）
    private(set) var isEmbeddedExpanded: Bool = false

    /// embedded 模式打开主聊天窗的回调（由 AppDelegate 注入）
    var onRequestFullChatWindow: (() -> Void)?

    /// pillWindow 在 idle 态的"最大尺寸" frame（含 hover 展开余量），用于从 embedded 收回
    private var idleMaxFrame: NSRect = .zero
    /// 嵌入式聊天框的目标 frame（每次进入 embedded 重算，确保位置跟着刘海中心）
    private var embeddedTargetFrame: NSRect = .zero
    /// embedded → idle 收回时延迟 ~320ms 的 setFrame 任务（让 SwiftUI fade out 先完成）。
    /// 用户在 fade out 期间又 hover 回来时，下一次 setEmbeddedExpanded(true) 会 cancel 它
    private var collapseFrameTask: Task<Void, Never>?

    private weak var statusItem: NSStatusItem?
    /// 点击灵动岛胶囊时回调（由 AppDelegate 注册）
    var onTapped: (() -> Void)?

    // MARK: - 形态参数（要改观感就调这四个）

    /// 默认（idle）状态：露在刘海下方的高度（极少，让耳朵"融入"刘海高度）
    private let idleDrop: CGFloat = 4
    /// 默认（idle）状态：横向比刘海多出多少（两侧各加一半 = 每个"耳朵"的宽度）
    private let idleExtraWidth: CGFloat = 80

    /// 悬停（hover）状态：向下展开的高度
    private let hoverDrop: CGFloat = 36
    /// 悬停（hover）状态：横向比刘海多出多少
    private let hoverExtraWidth: CGFloat = 80

    init() {
        // panel 始终是 idle 尺寸（也就是最大尺寸），命中区域 = 整个 panel
        // 这样 hover 后形状收缩，鼠标若仍在 idle 范围内，hover 状态依然保持，不抖
        // 🔑 styleMask **初始化时**就含 `.nonactivatingPanel` —— 后改是私有 API，会留下"视觉 key 但事件失效"的状态
        let panel = EmbeddableIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        // 浮动 panel + 输入型 panel 双开关：让 NSTextView 能接收键盘，但不抢前台 app
        panel.isFloatingPanel = true
        // 🔑 = true（按需 becomeKey）—— idle 态点击灵动岛**不能**让 panel 抢前台 app 焦点。
        // - idle 态：用户点灵动岛只触发 click gesture → toggleChat()，不能让 Safari/Xcode 丢 firstResponder
        // - embedded 态：controller 主动 `pillWindow.makeKey()` 覆盖 onlyIfNeeded（主动 makeKey 永远生效）
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        // 🔑 level 必须设在 `isFloatingPanel = true` **之后** —— 后者副作用会把 level 强制改回 .floating(3)，
        // 导致 panel 在 menu bar (layer 24) 之下，menu bar 区域的鼠标 hover/click 事件被系统截走，
        // 用户在贴顶的灵动岛区域 hover 没反应。statusBar=25 高于 menu bar 才能正常接收事件
        panel.level = HermesWindowLevel.dynamicIsland
        self.pillWindow = panel

        // 🔑 用 NSHostingController：它的 `sizingOptions = []` 能真正禁用 SwiftUI 反推 window setFrame
        let hosting = NSHostingController(rootView: DynamicIslandPillView())
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.hostingController = hosting

        // hostingController.view 是 NSHostingView 实例（私有类型），但 NSView 接口足够挂 gesture
        let hostingNSView = hosting.view
        hostingNSView.autoresizingMask = [.width, .height]
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleChat))
        hostingNSView.addGestureRecognizer(click)
        hostingNSView.wantsLayer = true

        positionWindow()
    }

    // MARK: - 嵌入式聊天框形态

    /// 让 SwiftUI PillView 拿到 ChatViewModel 引用（嵌入式聊天框需要访问 messages / sendMessage）。
    /// HermesPetApp.applicationDidFinishLaunching 创建 vm 后立刻调一次。
    /// 替换 hostingController.rootView 重建 SwiftUI 树 —— PillView 接受 vm 作为 init 参数后状态保留通过 @State
    func attach(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        // 用 closure 把"切换嵌入式聊天形态"的指令从 SwiftUI view 回传给 controller。
        // weak self 避免循环（hostingController 持有 rootView，rootView 持有 closure，closure 不能再持有 self）
        let setEmbeddedFromView: @MainActor (Bool) -> Void = { [weak self] expanded in
            self?.setEmbeddedExpanded(expanded)
        }
        let expandToFullWindow: @MainActor () -> Void = { [weak self] in
            self?.onRequestFullChatWindow?()
        }
        let hasPendingInputQuery: @MainActor () -> Bool = { [weak self] in
            self?.hasPendingInput() ?? false
        }
        let newRoot = DynamicIslandPillView(
            viewModel: viewModel,
            setEmbeddedExpanded: setEmbeddedFromView,
            expandToFullChatWindow: expandToFullWindow,
            hasPendingInput: hasPendingInputQuery
        )
        hostingController.rootView = newRoot

        // 监听 panel 失去 key → 用户切去别的 app 时自动收回 embedded（兜底，防止 panel 留在屏幕上无法输入）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: pillWindow,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self, self.isEmbeddedExpanded else { return }
                self.setEmbeddedExpanded(false)
                // 同步告诉 SwiftUI view 切回 idle 渲染分支
                NotificationCenter.default.post(
                    name: .init("HermesPetEmbeddedDismissed"),
                    object: nil
                )
            }
        }
    }

    /// PillView 通过 setEmbeddedExpanded closure 通知这里要切到嵌入式聊天形态。
    /// true → 扩大 panel frame 到 420×280 并 makeKey 让 NSTextView 能输入；
    /// false → 等 SwiftUI 内容 fade out 完后再缩 panel（避免内容挤爆抖动）
    ///
    /// **不对称的展开/缩回时序**（关键 fix）：
    /// - 展开：立即 setFrame(420×280) → SwiftUI NotchShape `.frame` bouncy spring 从 (260,64) 长到
    ///   (420,280)，同时 EmbeddedChatPanelView .transition(.opacity) fade in
    /// - 缩回：先 resignKey → SwiftUI NotchShape 立即开始 bouncy spring 缩回 (260,64) → 等 ~420ms
    ///   动画完 → 再 setFrame(idleMax)。此时 NotchShape 已 collapse 到 idle 尺寸 + panel 同步到
    ///   idle 尺寸，视觉上无任何跳变
    ///
    /// 关键解耦：NotchShape 用显式 `.frame(width:height:)` + `notchVisualSize` 计算属性，
    /// 跟 panel.contentView 完全解耦。SwiftUI bouncy spring 接管所有尺寸过渡，
    /// panel.setFrame 的瞬时跳藏在 NotchShape spring 动画背后用户不可见。
    func setEmbeddedExpanded(_ expanded: Bool) {
        guard expanded != isEmbeddedExpanded else { return }
        isEmbeddedExpanded = expanded

        // ⚠️ **绝对不能**用 `pillWindow.animator().setFrame` 或 `setFrame(_:display:animate:true)`。
        // 即使换了 NSHostingController + sizingOptions=[] 也不行 —— **实测 2026-05-16 仍崩**：
        // NSHostingView.updateAnimatedWindowSize 在 CA Transaction commit 期间反推 setFrame
        // → 嵌套 layout cycle → NSException SIGABRT（CLAUDE.md 决策 #5 #7 第三次踩坑）。
        // sizingOptions=[] 不能断这条路径，因为 updateAnimatedWindowSize 是 NSHostingView 跟
        // CA Transaction 在 animator 上下文里的死结，跟 sizingOptions 无关。
        // **结论：panel.setFrame 永远只用瞬时同步**，视觉平滑靠 SwiftUI 内 NotchShape.cornerRadius
        // 动画 + 内容元素位置预对齐 + 缩回延迟 setFrame 三层合力达成
        if expanded {
            let targetFrame = computeEmbeddedFrame()
            embeddedTargetFrame = targetFrame
            // 取消任何 pending 的「延迟缩回」—— 用户 fade out 期间又 hover 回来的边界
            collapseFrameTask?.cancel()
            collapseFrameTask = nil
            pillWindow.setFrame(targetFrame, display: true)

            // 跟灵动岛同区竞争的辅助 overlay 让位 —— 避免视觉叠加
            ChoiceMenuOverlayController.shared.hide()
            MiniReplyCardController.shared.hideIfVisible()

            // 主动 makeKey 覆盖 becomesKeyOnlyIfNeeded=true 的限制 —— floatingPanel + nonactivatingPanel
            // 保证前台 app 不被切换，但 panel 自己拿到 keyboard / IME。
            // 隔一帧 dispatch 避免跟 setFrame 在同一 layout pass（CLAUDE.md 决策 #5）。
            // 然后再隔一帧把 firstResponder 设到 NSTextView —— 让用户 hover 进入立刻能打字，
            // 不必先点输入框。两步分开是因为 SwiftUI mount NSTextView 需要至少 1 runloop tick
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.pillWindow.makeKey()
                DispatchQueue.main.async { [weak self] in
                    self?.focusEmbeddedInputField()
                }
            }
        } else {
            // 立即 resignKey 让 NSTextView 失焦（光标消失），但 panel 几何**先不动**
            pillWindow.resignKey()

            // 延迟 ~420ms 后再缩 panel —— AnimTok.bouncy(spring 0.42/0.78) 是 NotchShape 收缩用的
            // spring，response=0.42s 约 380-420ms 接近收敛。等 NotchShape 在 SwiftUI 内 spring
            // 缩回 idle 尺寸 (260×64) 后，再让 panel.setFrame(idleMax) 跟上 —— 此时两者尺寸一致,
            // panel 瞬时跳完全无视觉。
            // 防边界：若用户在 fade out 期间又 hover 回来，isEmbeddedExpanded 会被设回 true,
            // pending 任务里 `!isEmbeddedExpanded` 检查会跳过缩 panel；下次展开调用还会主动 cancel
            collapseFrameTask?.cancel()
            let pendingTargetFrame = idleMaxFrame
            collapseFrameTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 420_000_000)
                if Task.isCancelled { return }
                guard let self = self, !self.isEmbeddedExpanded else { return }
                self.pillWindow.setFrame(pendingTargetFrame, display: true)
            }
        }
    }

    /// 当前是不是有"未发送的输入内容"。
    /// hover leave 防抖时用这个判定 —— 用户在写半成品 → 不收；已经 send / 没写过 → 允许收回。
    ///
    /// 不再用 "NSTextView 是 firstResponder" 当信号，因为 send 之后 textView 仍 focused 但用户已经发完，
    /// 用 focus 当锁会让 panel **永不收回**（用户实际反馈的 bug）。inputText 非空才是真正的"用户活跃"信号
    func hasPendingInput() -> Bool {
        guard let vm = viewModel else { return false }
        return !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 计算嵌入式聊天框的目标 frame：宽 420 / 高 280 / **顶部跟 idle 灵动岛同一行**（贴屏顶）。
    /// 关键：y 用 `idleMaxFrame.maxY - embeddedHeight`，跟 idle 共享顶部锚点 —— 避免独立算 maxY 时
    /// 系统可能对高 panel 做的 visibleFrame constraint，保证 embedded 跟 idle 顶部齐平。
    private func computeEmbeddedFrame() -> NSRect {
        let embeddedWidth: CGFloat = 420
        let embeddedHeight: CGFloat = 280
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = screen else {
            // 极端兜底（外接屏全拔了 / NSScreen 全空）
            return NSRect(x: 0, y: 0, width: embeddedWidth, height: embeddedHeight)
        }

        let screenFrame = screen.frame

        // 横向：刘海真实中心（auxiliaryTop* 反推），否则 screen midX
        let centerX: CGFloat
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            centerX = (l.maxX + r.minX) / 2
        } else {
            centerX = screenFrame.midX
        }

        // 🔑 横向用 idleMaxFrame.origin.x（positionWindow 算好的 idle panel 左边缘），
        // 保证 idle ↔ embedded 切换时 panel.origin.x 完全不变，避免 setFrame 时 panel 向左跳。
        // 兜底：idleMaxFrame 还没初始化时，用 centerX - embeddedWidth/2 算（跟 positionWindow 一致）
        let x = idleMaxFrame.origin.x > 0
            ? idleMaxFrame.origin.x
            : centerX - embeddedWidth / 2
        // 用 idleMaxFrame.maxY 作 panel 顶基准 —— idle 形态是贴顶的（positionWindow 已对齐刘海），
        // embedded 用同一顶部 → 跟 idle 视觉连续
        let topY = idleMaxFrame.maxY > 0 ? idleMaxFrame.maxY : screenFrame.maxY
        let y = topY - embeddedHeight
        return NSRect(x: x, y: y, width: embeddedWidth, height: embeddedHeight)
    }

    // MARK: - Public

    func setStatusItem(_ item: NSStatusItem) { self.statusItem = item }

    func show() {
        positionWindow()
        pillWindow.orderFront(nil)
    }

    func hide() {
        pillWindow.orderOut(nil)
    }

    func updateStatus(_ status: ChatViewModel.ConnectionStatus) {
        NotificationCenter.default.post(
            name: .init("HermesPetStatusChanged"),
            object: nil,
            userInfo: ["status": status]
        )
    }

    // MARK: - Positioning

    private func positionWindow() {
        // 优先选「带刘海」的屏（外接显示器场景下 NSScreen.main 不一定是 MacBook 自带屏）
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
        guard let screen = screen else { return }

        let screenFrame = screen.frame
        let safeArea = screen.safeAreaInsets
        let hasNotch = safeArea.top > 0

        // 用 auxiliary 两块「耳朵」反推刘海的真实左右边界与中心 X
        let notchLeftX:  CGFloat?
        let notchRightX: CGFloat?
        if hasNotch,
           let left  = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchLeftX  = left.maxX
            notchRightX = right.minX
        } else {
            notchLeftX  = nil
            notchRightX = nil
        }

        let actualNotchWidth: CGFloat = {
            if let l = notchLeftX, let r = notchRightX { return r - l }
            return 180
        }()
        let actualNotchHeight: CGFloat = hasNotch ? safeArea.top : 28

        // 🔑 panel 始终用 embedded 等宽 (420)，**不让 panel.origin.x 在 embedded 切换时跳变**。
        // 之前 idle panel 260 宽 / embedded panel 420 宽 → setFrame 时 panel.origin.x 向左跳 80pt,
        // panel.contentView size 同帧变化但 SwiftUI layout pass 滞后一帧 → NotchShape 在新 panel 内
        // 旧位置导致屏幕坐标向左偏 80pt（"卡一下"）。
        // 现在 panel 永远 420 宽，origin.x 固定，只 height 跟 origin.y 变 → 水平方向零跳变。
        // idle 时 panel 视觉两侧 80pt 是透明区域；用 SwiftUI .contentShape(NotchShape) 把 hit-test
        // 限制到 NotchShape 视觉路径内，透明区域不响应 hover/click（视觉边界 = 交互边界）。
        let windowWidth  = max(actualNotchWidth + idleExtraWidth, 420)
        let windowHeight = actualNotchHeight + hoverDrop

        // 水平：用「刘海真实中心」对齐
        let notchCenterX: CGFloat = {
            if let l = notchLeftX, let r = notchRightX {
                return (l + r) / 2
            }
            return screenFrame.midX
        }()
        let x = notchCenterX - windowWidth / 2
        let y = screenFrame.maxY - windowHeight

        let idleFrame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
        self.idleMaxFrame = idleFrame   // 保存供 embedded 退出时 setFrame 回去
        // 处于 embedded 形态时不要被 positionWindow 拉回 idle —— 让它保持 embedded frame
        if !isEmbeddedExpanded {
            pillWindow.setFrame(idleFrame, display: true)
        }

        NotificationCenter.default.post(
            name: .init("HermesPetGeometry"),
            object: nil,
            userInfo: [
                "notchWidth": actualNotchWidth,
                "notchHeight": actualNotchHeight,
                "idleDrop": idleDrop,
                "idleExtraWidth": idleExtraWidth,
                "hoverDrop": hoverDrop,
                "hoverExtraWidth": hoverExtraWidth
            ]
        )
    }

    // MARK: - Actions

    @objc private func toggleChat() {
        if isEmbeddedExpanded {
            // embedded 形态下点击 panel 空白处 → 收回 embedded + 展开主聊天窗（跟右上角"展开"图标语义一致）。
            // SwiftUI 子视图（输入框 / SendButton / 右上角展开图标）会优先消费 click，所以这里
            // 只在用户点击非交互区域（NotchShape 头部贴刘海段、消息气泡留白处等）时触发。
            // 通知 SwiftUI 切回 idle 渲染分支 + 同步 cancel hoverLeaveTask（避免双重 setEmbeddedExpanded(false)）
            setEmbeddedExpanded(false)
            NotificationCenter.default.post(name: .init("HermesPetEmbeddedDismissed"), object: nil)
            onRequestFullChatWindow?()
            return
        }
        onTapped?()
    }

    /// 递归查 panel 内第一个 NSTextView 并 makeFirstResponder —— 进入 embedded 时让用户直接打字
    @discardableResult
    private func focusEmbeddedInputField() -> Bool {
        guard let root = pillWindow.contentView,
              let tv = Self.findFirstTextView(in: root) else { return false }
        return pillWindow.makeFirstResponder(tv)
    }

    private static func findFirstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findFirstTextView(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - SwiftUI Pill View

struct DynamicIslandPillView: View {
    /// 由 controller.attach(viewModel:) 注入。`nil` 时嵌入式聊天形态不可用（保护性兜底）
    var viewModel: ChatViewModel? = nil
    /// 让 controller 切换 panel frame + makeKey 的回调（hover 500ms 后调 true，离开后调 false）
    var setEmbeddedExpanded: @MainActor (Bool) -> Void = { _ in }
    /// embedded 形态右上角图标 → 打开主聊天窗的回调
    var expandToFullChatWindow: @MainActor () -> Void = {}
    /// 返回是否有"未发送的输入内容"——hover leave 防抖时跳过收回的信号。
    /// 比"NSTextView 是 firstResponder"准：send 之后 textView 仍 focused 但 inputText 已清空 → 允许收回
    var hasPendingInput: @MainActor () -> Bool = { false }

    @State private var status: ConnectionStatusDisplay = .unknown
    @State private var isHovering = false

    /// 截图成功通知态（短暂展开 1.6s）
    @State private var isShowingNotification = false
    @State private var notificationText: String = "截图已添加"
    @State private var notificationCount: Int = 0
    @State private var notificationTask: Task<Void, Never>?

    /// 右耳任务指示（loading 圈 / 完成对勾 / 听写中），由 ChatViewModel 与 VoiceInputController 通过通知驱动
    @State private var taskStatus: RightEarTaskStatus = .idle
    @State private var taskResetTask: Task<Void, Never>?

    enum RightEarTaskStatus {
        case idle       // 默认，显示连接状态图标
        case working    // 旋转加载圈（Claude 风三点脉冲）
        case success    // Face ID 风格画线对勾，1.2s 后自动回 idle
        case listening  // 按住说话中，红色脉冲麦克风
    }

    @State private var notchWidth: CGFloat = 200
    @State private var notchHeight: CGFloat = 32
    @State private var idleDrop: CGFloat = 24
    @State private var idleExtraWidth: CGFloat = 70
    @State private var hoverDrop: CGFloat = 14
    @State private var hoverExtraWidth: CGFloat = 4

    /// 当前 AgentMode（驱动左耳精灵），通过 NotificationCenter 跟 ChatViewModel 同步
    @State private var currentMode: AgentMode = {
        if let raw = UserDefaults.standard.string(forKey: "agentMode"),
           let mode = AgentMode(rawValue: raw) {
            return mode
        }
        return .hermes
    }()

    /// 桌宠生命感动画开关（设置 → 安静模式开启时此项为 false）
    @State private var petAnimationsEnabled: Bool = {
        // 默认 true（首次启动 UserDefaults 没值 = false，所以反向存 "quietMode"）
        !UserDefaults.standard.bool(forKey: "quietMode")
    }()

    /// 任务工作中 → 左耳精灵播放各 mode 专属动画
    private var spriteIsWorking: Bool {
        taskStatus == .working
    }

    /// 当前 Claude Code 正在调用的工具（Read/Write/Bash/...）。
    /// nil = 没有工具在跑（或非 Claude 模式），灵动岛回到常规 idle/hover 形态。
    /// 通过 HermesPetToolStarted 通知更新；HermesPetTaskFinished 时清空
    @State private var currentToolKind: ToolKind? = nil
    @State private var currentToolArg: String = ""

    // MARK: - 工具进度状态机（a + b + c 共用）
    /// 任务开始时间，用于 b) 长思考耗时显示
    @State private var taskStartTime: Date? = nil
    /// 任务运行秒数（每秒被 elapsedTimer 自增）。仅 ≥10s 才显示
    @State private var elapsedSeconds: Int = 0
    @State private var elapsedTask: Task<Void, Never>? = nil
    /// 已开始的工具步骤数（HermesPetToolStarted 累计）
    @State private var stepStarted: Int = 0
    /// 已结束的工具步骤数（HermesPetToolEnded 累计）—— 用于 a) 第 M/N 步
    @State private var stepEnded: Int = 0
    /// Edit/Write/MultiEdit 工具的 file_path 集合，用于 c) 已修改 N 个文件
    @State private var changedFilePaths: Set<String> = []
    /// c) diff 摘要卡片 —— TaskFinished 时显示 2.5s 再消失
    @State private var diffSummaryVisible: Bool = false
    @State private var diffSummaryCount: Int = 0
    @State private var diffSummaryTask: Task<Void, Never>? = nil

    // MARK: - d) 后台对话发光（右耳计数）
    @State private var backgroundStreamingCount: Int = 0

    // MARK: - e) 错误态（持续显示，点灵动岛触发重试）
    /// 连接断开时为 true —— 由 HermesPetStatusChanged 直接判定
    private var isInErrorState: Bool { status == .disconnected }

    // MARK: - h) 截屏快门动效
    @State private var shutterFlash: Bool = false
    @State private var shutterScale: CGFloat = 1.0
    @State private var shutterTask: Task<Void, Never>? = nil

    // MARK: - o) 5 段音量条实时电平
    @State private var voiceLevel: Float = 0

    // MARK: - hoverCard 增强：最近 AI 回复预览 + 未读后台对话数
    /// 由 ChatViewModel.broadcastHoverContext 通过 HermesPetHoverContextChanged 推送
    @State private var latestAssistantPreview: String = ""
    @State private var unreadConversationCount: Int = 0

    // MARK: - hover 展开三态（off / embedded / chatWindow）
    /// 从 ChatViewModel.hoverExpandMode 同步。默认 .off（跟 ViewModel.init fallback 一致）。
    /// 老用户从旧 `hoverExpandChatEnabled: Bool` 迁移：true → .chatWindow，false / 未设置 → .off
    @State private var hoverExpandMode: HoverExpandMode = {
        if let raw = UserDefaults.standard.string(forKey: "hoverExpandMode"),
           let mode = HoverExpandMode(rawValue: raw) {
            return mode
        }
        if let legacy = UserDefaults.standard.object(forKey: "hoverExpandChatEnabled") as? Bool,
           legacy == true {
            return .chatWindow
        }
        return .off
    }()
    /// 500ms 防误触 task —— hover 进入立刻启动；hover 离开 + 未到 500ms → cancel
    @State private var hoverExpandTask: Task<Void, Never>? = nil
    /// embedded 形态切换：true = 当前展开为迷你聊天框形态
    @State private var embeddedActive: Bool = false
    /// 离开 embedded 形态的 500ms 防抖 task —— 鼠标离开 + 没立刻回来才真收回
    @State private var hoverLeaveTask: Task<Void, Never>? = nil

    /// 通知态 / hover / 工具调用中 / diff 摘要中 / 错误态都让胶囊"展开"
    private var isExpanded: Bool {
        isHovering || isShowingNotification
            || currentToolKind != nil
            || diffSummaryVisible
            || isInErrorState
    }

    enum ConnectionStatusDisplay {
        case connected, disconnected, unknown
        var color: Color {
            switch self {
            case .connected:    return .green
            case .disconnected: return .red
            case .unknown:      return .gray
            }
        }
        var label: String {
            switch self {
            case .connected:    return "已连接"
            case .disconnected: return "未连接"
            case .unknown:      return "待配置"
            }
        }
        /// 用于 idle 时右耳的小图标（对号 / 叉 / 问号）
        var iconName: String {
            switch self {
            case .connected:    return "checkmark"
            case .disconnected: return "xmark"
            case .unknown:      return "questionmark"
            }
        }
    }

    private var currentWidth: CGFloat {
        notchWidth + (isExpanded ? hoverExtraWidth : idleExtraWidth)
    }
    private var currentHeight: CGFloat {
        notchHeight + (isExpanded ? hoverDrop : idleDrop)
    }
    private var currentRadius: CGFloat {
        isExpanded ? 22 : 14
    }

    /// NotchShape 的视觉尺寸 —— **跟 panel.contentView 解耦**，让 SwiftUI 能独立 spring 动画。
    ///
    /// 之前 NotchShape 没有显式 .frame，铺满 panel.contentView → panel.setFrame 瞬时跳那一帧
    /// NotchShape 视觉尺寸跟着瞬时跳 → 用户看到的不是「岛长出来」而是「panel 突变」。
    ///
    /// 现在 NotchShape 用 `.frame(width: notchVisualSize.width, height: notchVisualSize.height)`，
    /// embeddedActive 切换时这个 CGSize 变化 → SwiftUI bouncy spring 插值 → 视觉是岛"弹性长大/缩回"。
    /// panel.setFrame 的瞬时跳藏在 NotchShape spring 背后 —— panel 透明区域用户看不到。
    ///
    /// - idle / hover: (currentWidth, currentHeight) = (260, 64)
    /// - embedded: (420, 280)
    private var notchVisualSize: CGSize {
        if embeddedActive {
            return CGSize(width: 420, height: 280)
        } else {
            return CGSize(width: currentWidth, height: currentHeight)
        }
    }

    var body: some View {
        pillBodyWithStateObservers
            // 用 bouncy(spring 0.42/0.78) 而非 smooth —— bouncy 略弹性 + 持续略长，让
            // NotchShape 从 idle 长出 embedded 时有"岛在生长"的物理感（iOS 灵动岛设计语义）。
            // 这条 .animation 同时驱动：NotchShape.size（embeddedActive 切换时 frame 变化）+
            // NotchShape.cornerRadius（14/22 → 28）+ shadow opacity，三者用同一 spring 同步插值。
            .animation(AnimTok.bouncy, value: embeddedActive)
            .onHover { hovering in
            // 用 spring 做"流畅过渡"：response 越小越快，dampingFraction 越大越稳重
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                isHovering = hovering
            }
            handleHoverForExpand(hovering: hovering)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetScreenshotAdded"))) { note in
            // 取消上次未结束的通知 task，重新计时
            notificationTask?.cancel()
            let count = (note.userInfo?["count"] as? Int) ?? 0
            notificationCount = count
            // 自定义文字（错误时也用这个通道）
            notificationText = (note.userInfo?["text"] as? String) ?? "截图已添加"
            withAnimation(AnimTok.bouncy) {
                isShowingNotification = true
            }
            // 错误提示停留更久，方便用户读
            let isError = notificationText.contains("⚠️") || notificationText.contains("失败")
            let durationNs: UInt64 = isError ? 3_000_000_000 : 1_600_000_000
            notificationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: durationNs)
                if !Task.isCancelled {
                    withAnimation(AnimTok.exit) {
                        isShowingNotification = false
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetVoiceStarted"))) { _ in
            taskResetTask?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                taskStatus = .listening
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetVoiceFinished"))) { _ in
            // 听写结束 → 由后续 sendMessage 触发的 HermesPetTaskStarted 接管显示状态。
            // 这里短暂淡出 listening，等下一个状态进来。
            voiceLevel = 0
            withAnimation(AnimTok.snappy) {
                taskStatus = .idle
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetVoiceCancelled"))) { _ in
            voiceLevel = 0
            withAnimation(AnimTok.snappy) {
                taskStatus = .idle
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskStarted"))) { _ in
            taskResetTask?.cancel()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                taskStatus = .working
            }
            // 新任务开始 → 清空残留工具状态 + 重置进度状态机
            currentToolKind = nil
            currentToolArg = ""
            stepStarted = 0
            stepEnded = 0
            changedFilePaths = []
            elapsedSeconds = 0
            taskStartTime = Date()
            // 启动每秒刷新的 elapsed 计时器
            elapsedTask?.cancel()
            elapsedTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    if let start = taskStartTime {
                        elapsedSeconds = Int(Date().timeIntervalSince(start))
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            let kind = ToolKind.from(toolName: name)
            let arg = (note.userInfo?["arg"] as? String) ?? ""
            // 计数 +1（已开始的工具数）
            stepStarted += 1
            // Edit/Write/MultiEdit 收集 file_path，给 diff 摘要去重
            if let path = note.userInfo?["file_path"] as? String,
               !path.isEmpty,
               ["Write", "Edit", "MultiEdit"].contains(name) {
                changedFilePaths.insert(path)
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                currentToolKind = kind
                currentToolArg = arg
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolEnded"))) { _ in
            // 计数 +1（已结束的工具数）—— 通知本身已按 toolId 去重
            stepEnded += 1
        }
        // C) 长任务情绪气泡 —— 仅 Claude 模式触发（其他 mode 的桌宠没"性格"）
        .onChange(of: elapsedSeconds) { _, secs in
            guard currentMode == .claudeCode else { return }
            switch secs {
            case 30:  ClawdBubbleOverlayController.show("等等，快好了…")
            case 90:  ClawdBubbleOverlayController.show("emm，再花点时间")
            case 180: ClawdBubbleOverlayController.show("这个真的有点复杂…")
            default:  break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetTaskFinished"))) { note in
            // 任务结束 → 停 elapsed 计时器
            elapsedTask?.cancel()
            elapsedTask = nil
            taskStartTime = nil
            // 收回工具状态卡片
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                currentToolKind = nil
                currentToolArg = ""
            }
            taskResetTask?.cancel()
            let success = (note.userInfo?["success"] as? Bool) ?? false
            // c) 成功且有修改文件时，展示 diff 摘要 2.5s
            if success && !changedFilePaths.isEmpty {
                diffSummaryCount = changedFilePaths.count
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    diffSummaryVisible = true
                }
                diffSummaryTask?.cancel()
                diffSummaryTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !Task.isCancelled {
                        withAnimation(AnimTok.exit) {
                            diffSummaryVisible = false
                        }
                    }
                }
            }
            if success {
                // 成功 → 先展示对勾，1.2s 后回到默认状态图标
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    taskStatus = .success
                }
                taskResetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if !Task.isCancelled {
                        withAnimation(AnimTok.smooth) {
                            taskStatus = .idle
                        }
                    }
                }
            } else {
                // 失败 / 取消 → 直接静默回 idle
                withAnimation(AnimTok.snappy) {
                    taskStatus = .idle
                }
                // Claude 模式 + 失败 → Clawd 冒一个"糟糕 😵"气泡
                if currentMode == .claudeCode {
                    ClawdBubbleOverlayController.show("糟糕 😵", duration: 2.2)
                }
            }
        }
    }

    /// 第二层：把状态 / mode / 几何 / shutter / voiceLevel 等订阅挂在 pillBody 上，
    /// 切断 body 的超长 modifier chain，让 SwiftUI 编译器分两次 type-check
    private var pillBodyWithStateObservers: some View {
        pillBody
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetStatusChanged"))) { note in
            if let raw = note.userInfo?["status"] as? ChatViewModel.ConnectionStatus {
                switch raw {
                case .connected:    status = .connected
                case .disconnected: status = .disconnected
                case .unknown:      status = .unknown
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetModeChanged"))) { note in
            if let raw = note.userInfo?["mode"] as? String,
               let mode = AgentMode(rawValue: raw) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    currentMode = mode
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPetAnimationsChanged"))) { note in
            if let enabled = note.userInfo?["enabled"] as? Bool {
                petAnimationsEnabled = enabled
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetGeometry"))) { note in
            if let v = note.userInfo?["notchWidth"]      as? CGFloat { notchWidth = v }
            if let v = note.userInfo?["notchHeight"]     as? CGFloat { notchHeight = v }
            if let v = note.userInfo?["idleDrop"]        as? CGFloat { idleDrop = v }
            if let v = note.userInfo?["idleExtraWidth"]  as? CGFloat { idleExtraWidth = v }
            if let v = note.userInfo?["hoverDrop"]       as? CGFloat { hoverDrop = v }
            if let v = note.userInfo?["hoverExtraWidth"] as? CGFloat { hoverExtraWidth = v }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetBackgroundStreamingChanged"))) { note in
            let c = (note.userInfo?["count"] as? Int) ?? 0
            withAnimation(AnimTok.snappy) {
                backgroundStreamingCount = c
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetCaptureShutter"))) { _ in
            // 快门动效：scale 1.0 → 1.06 → 1.0 反弹 + 0.18s 白色闪光
            shutterTask?.cancel()
            shutterFlash = true
            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
                shutterScale = 1.06
            }
            shutterTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90_000_000)
                if Task.isCancelled { return }
                withAnimation(AnimTok.snappy) {
                    shutterFlash = false
                }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    shutterScale = 1.0
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetVoiceLevel"))) { note in
            if let lvl = note.userInfo?["level"] as? Float {
                voiceLevel = lvl
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetHoverContextChanged"))) { note in
            if let p = note.userInfo?["preview"] as? String { latestAssistantPreview = p }
            if let c = note.userInfo?["unreadCount"] as? Int { unreadConversationCount = c }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetEmbeddedDismissed"))) { _ in
            // controller 兜底收回（panel didResignKey / toggleChatWindow 等外部路径）：同步切回 idle 渲染
            embeddedActive = false
            hoverLeaveTask?.cancel()
            hoverLeaveTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetHoverExpandSettingChanged"))) { note in
            // 新 payload：userInfo["mode"] = String (HoverExpandMode.rawValue)
            // 老 payload：userInfo["enabled"] = Bool（向后兼容，迁移期不会触发但留着不影响）
            if let raw = note.userInfo?["mode"] as? String,
               let mode = HoverExpandMode(rawValue: raw) {
                hoverExpandMode = mode
            } else if let enabled = note.userInfo?["enabled"] as? Bool {
                hoverExpandMode = enabled ? .chatWindow : .off
            }
            if hoverExpandMode == .off {
                // 关到"不动"时清掉 pending task + 收回 embedded（如果当前展开着）
                hoverExpandTask?.cancel()
                hoverExpandTask = nil
                if embeddedActive {
                    embeddedActive = false
                    setEmbeddedExpanded(false)
                }
            }
        }
        .onAppear {
            let hasKey = !(UserDefaults.standard.string(forKey: "apiKey") ?? "").isEmpty
            status = hasKey ? .connected : .unknown
        }
    }

    /// hover 500ms 防误触后按 mode 分发：
    /// - `.off`：什么都不做（保留 hoverCard 预览原有行为）
    /// - `.embedded`：调 setEmbeddedExpanded(true) 让 controller 把 panel 扩大成迷你聊天框形态
    /// - `.chatWindow`：post HermesPetHoverExpandRequested，AppDelegate 接住开主聊天窗（原 PR3）
    private func handleHoverForExpand(hovering: Bool) {
        guard hoverExpandMode != .off else {
            hoverExpandTask?.cancel()
            hoverExpandTask = nil
            return
        }
        if hovering {
            // 鼠标回到 hover 区 → 取消 pending 的"离开收回"
            hoverLeaveTask?.cancel()
            hoverLeaveTask = nil

            hoverExpandTask?.cancel()
            hoverExpandTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                // 拖放保护：鼠标左键按下 = 用户在拖东西（Finder 文件 / 桌面图标 / 任意 OS 拖放对象），
                // 此时展开会让 NSDraggingSession 找不到 drop target，
                // 导致 Finder 拖放状态机卡死（桌面文件后续无法拖动，需 killall Finder 才能恢复）
                if NSEvent.pressedMouseButtons & 1 != 0 { return }

                switch hoverExpandMode {
                case .embedded:
                    guard viewModel != nil else { return }   // 没注入 vm 时降级，啥都不做
                    embeddedActive = true
                    setEmbeddedExpanded(true)
                case .chatWindow:
                    NotificationCenter.default.post(
                        name: .init("HermesPetHoverExpandRequested"),
                        object: nil
                    )
                case .off:
                    break
                }
            }
        } else {
            hoverExpandTask?.cancel()
            hoverExpandTask = nil
            // embedded 形态下：鼠标离开 500ms 后真收回（防抖，让用户能短暂离开胶囊回来）。
            // 关键：若 viewModel.inputText 仍非空（hasPendingInput），即使鼠标飘走也**不收回**
            // —— 否则打字到一半窗口消失，体验崩。由 NSWindow.didResignKey 兜底（用户切去别的 app 自动收回）
            if embeddedActive {
                hoverLeaveTask?.cancel()
                hoverLeaveTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                    if hasPendingInput() { return }   // 有未发送的输入 → 跳过收回
                    embeddedActive = false
                    setEmbeddedExpanded(false)
                }
            }
        }
    }

    /// 当前 mode 对应的强调色（跟聊天窗 headerTint 一致）
    private func modeTint(_ mode: AgentMode) -> Color {
        switch mode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    // MARK: - 各形态卡片（拆出来让 SwiftUI 编译器能 type-check 大 body）

    /// 胶囊本体。**关键架构**：NotchShape 用**显式 .frame(width:, height:)**，size 由
    /// `notchVisualSize` 控制 —— SwiftUI 在 embeddedActive 切换时 bouncy spring 插值这个 size，
    /// **让"刘海长出聊天框"成为真正的尺寸动画，跟 panel.setFrame 瞬时跳变完全解耦**。
    ///
    /// 视觉路径（展开）：
    ///   1. controller 调 `pillWindow.setFrame(420×280)` 瞬时同步 → panel 跳大但透明区域无视觉
    ///   2. embeddedActive=true 触发 SwiftUI animation → NotchShape `.frame` 从 (260,64) bouncy
    ///      spring 长到 (420,280)，cornerRadius 同步 14→28
    ///   3. 用户看到「岛弹性长大」，panel 几何跳完全藏在动画背后
    ///
    /// 视觉路径（收回）：
    ///   1. embeddedActive=false → NotchShape `.frame` bouncy spring 缩回 (260,64)
    ///   2. ~420ms 后 controller 调 `pillWindow.setFrame(idleMax)` —— 此时 NotchShape 已收回，
    ///      panel 跟 NotchShape 大小一致，无视觉跳
    ///
    /// 内容层（idleAndHoverContent / EmbeddedChatPanelView）跟 NotchShape 用同样 .frame，
    /// 配 `.clipShape(NotchShape)` 让内容被裁到形状内。Group 内 if-else 用 .transition(.opacity)
    /// 做内容切换的 fade。
    @ViewBuilder
    private var pillBody: some View {
        // 用 `HStack + Spacer ... NotchShape ... Spacer` + `VStack + ... + Spacer` 标准 layout
        // 让 NotchShape 水平居中 + 顶对齐。**关键**：Spacer 的宽度是 SwiftUI **layout-time 计算**
        // 的结果（panel.width - notchSize.width 后均分给两个 Spacer），**不被 .animation 拦截**。
        //
        // 之前用 `.position(x: geo.width/2, y: ...)` 或 ZStack(alignment: .top) 都失败：
        // SwiftUI 的 `.animation(_:value: embeddedActive)` 把 `.position.x` 跟 alignment 计算结果
        // 当作 animatable CGFloat，一起 spring 插值 → NotchShape size 跳变到 (260,64) 起点的同时
        // .position.x 还在 spring 中（130→210 半路），结果 NotchShape 中心在 panel 内不是水平居中,
        // 而是介于两个对齐位置之间 → 用户看到「向左跳一下」。
        //
        // Spacer 方案下，layout pass 每帧根据当前 NotchShape size 重新均分剩余宽度，
        // Spacer 宽度 = (panel.width - notchSize.width) / 2，由 layout 系统瞬时计算 → 严格对称扩张。
        let activeRadius: CGFloat = embeddedActive ? 28 : currentRadius

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                ZStack {
                    // ① NotchShape 背景：size 由 ZStack 的 .frame 决定，spring 插值
                    NotchShape(cornerRadius: activeRadius)
                        .fill(isInErrorState ? Color(red: 0.55, green: 0.32, blue: 0.05) : Color.black)
                        .shadow(color: embeddedActive ? .black.opacity(0.35) : .clear, radius: 18, y: 6)

                    // ② 内容层：跟 NotchShape 同 size + 同 clip
                    Group {
                        if embeddedActive, let vm = viewModel {
                            EmbeddedChatPanelView(
                                viewModel: vm,
                                notchHeight: notchHeight,
                                onExpandToFullWindow: {
                                    // 用户主动点"展开主聊天窗"图标：先收回 embedded，再让 AppDelegate 开 ChatWindow
                                    embeddedActive = false
                                    hoverLeaveTask?.cancel()
                                    setEmbeddedExpanded(false)
                                    expandToFullChatWindow()
                                }
                            )
                            .transition(.opacity)
                        } else {
                            idleAndHoverContent
                                .transition(.opacity)
                        }
                    }
                    .clipShape(NotchShape(cornerRadius: activeRadius))
                }
                .frame(width: notchVisualSize.width, height: notchVisualSize.height)
                // 🔑 .contentShape(NotchShape) 限制 hit-test 到视觉路径内 —— panel 现在永远 420 宽,
                // idle 时两侧 80pt 是透明区域，这里让透明区域不响应 hover/click（视觉=交互边界）。
                // 同时影响 NSHostingView.hitTest 返回值 → NSClickGestureRecognizer 也只在 NotchShape 区域触发
                .contentShape(NotchShape(cornerRadius: activeRadius))

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// idle / hover / 工具进度 / 通知 / 错误 等各种形态的胶囊**内容**（不含 NotchShape 背景，由父 pillBody 统一画）。
    /// 关键：不再用 `ZStack.frame(width: 280, height: 68)` 限制布局 —— 那会让 idle 圆点在 panel.w=280 时
    /// 在 X=18，panel.w=420（embedded 时 idle 内容 fade out 中）时跳到 X=88（ZStack 居中 70 + leading 18），
    /// 用户看到圆点"往左跳 70pt"。改成撑满后 idle 内容 leading 18 跟 embedded mode icon leading 14
    /// 只差 4pt → fade 切换几乎原地完成
    private var idleAndHoverContent: some View {
        VStack(spacing: 0) {
            pillContent
                .frame(maxWidth: .infinity)
                .frame(height: currentHeight)
                .scaleEffect(shutterScale)
                .overlay { shutterOverlay }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// h) 截屏快门白光叠层
    @ViewBuilder
    private var shutterOverlay: some View {
        if shutterFlash {
            NotchShape(cornerRadius: currentRadius)
                .fill(Color.white)
                .frame(width: currentWidth, height: currentHeight)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// 灵动岛胶囊主内容（按状态优先级分发到不同分支卡片）
    @ViewBuilder
    private var pillContent: some View {
        if isInErrorState && !isShowingNotification && currentToolKind == nil {
            errorStateCard
        } else if diffSummaryVisible {
            diffSummaryCard
        } else if isShowingNotification {
            notificationCard
        } else if let toolKind = currentToolKind {
            toolStateCard(toolKind)
        } else {
            ZStack {
                if isHovering {
                    hoverCard
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                } else {
                    idleStateRow
                        .transition(.opacity)
                }
            }
            .animation(AnimTok.snappy, value: isHovering)
        }
    }

    /// e) 错误态卡片：⚠️ 已断开 + 提示点击重试
    private var errorStateCard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("连接已断开")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("· 点击重试")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// c) diff 摘要卡片
    private var diffSummaryCard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                ModeSpriteView(mode: currentMode, isWorking: false, size: 18)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                Text("已修改 \(diffSummaryCount) 个文件")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// 通知态卡片（截图、错误等短暂提示）
    private var notificationCard: some View {
        let isError = notificationText.contains("⚠️") || notificationText.contains("失败") || notificationText.contains("权限")
        return VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "camera.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isError ? Color.yellow : Color.green)
                Text(notificationText.replacingOccurrences(of: "⚠️ ", with: ""))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !isError && notificationCount > 1 {
                    Text("·\(notificationCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    /// 工具调用卡片：[Clawd] [verb] [arg] · [M/N 步] · [Xs]
    private func toolStateCard(_ toolKind: ToolKind) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                ModeSpriteView(mode: currentMode, isWorking: true, size: 18)
                HStack(spacing: 5) {
                    Text(toolKind.verb)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if !currentToolArg.isEmpty {
                        Text(currentToolArg)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if stepStarted >= 2 {
                        Text("· 第 \(min(stepEnded + 1, stepStarted))/\(stepStarted) 步")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if elapsedSeconds >= 10 {
                        Text("· \(elapsedSeconds)s")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 12)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// hover 卡片（鼠标悬停时显示 mode + 状态点 + 模型名 + 上次 AI 回复预览 + 未读徽章）。
    /// 关键约束：currentHeight 必须保持 idle vs hover 两档（不能因为 preview 多让出空间），
    /// 否则 SwiftUI 反推 NSHostingView.updateAnimatedWindowSize → 嵌套 layout 必崩
    /// （CLAUDE.md 决策 #5 / #7 / issue #3 反复踩过）。preview 用 overlay 不参与 layout
    private var hoverCard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: status.color.opacity(0.55), radius: 3)
                // hover 时 sprite 放大到 22pt（idle 12pt 圆点 → hover 22pt 完整 sprite）
                ModeSpriteView(mode: currentMode, isWorking: spriteIsWorking, size: 22)
                Text(currentMode.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .tracking(0.3)
                if unreadConversationCount > 0 {
                    Text("·\(unreadConversationCount) 未读")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.20)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            // preview overlay —— 不参与 SwiftUI layout（关键！防嵌套 layout 崩），
            // 自带黑底胶囊作为视觉容器，offset 推到 hoverCard 下方约 24pt 位置
            if !latestAssistantPreview.isEmpty {
                Text(latestAssistantPreview)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.85))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: currentWidth - 20)
                    .offset(y: 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// 默认 idle 行：左耳极简圆点 + 右耳指示器（hover 才展开 sprite）
    private var idleStateRow: some View {
        HStack(spacing: 0) {
            IdleModeDot(tint: modeTint(currentMode))
                .padding(.leading, 18)
            Spacer()
            if backgroundStreamingCount > 0 {
                BackgroundStreamingBadge(
                    count: backgroundStreamingCount,
                    tint: modeTint(currentMode)
                )
                .padding(.trailing, 4)
                .transition(.scale.combined(with: .opacity))
            }
            RightEarIndicator(
                connectionStatus: status,
                taskStatus: taskStatus,
                voiceLevel: voiceLevel,
                glowTint: modeTint(currentMode)
            )
            .padding(.trailing, 14)
        }
        .animation(AnimTok.snappy, value: backgroundStreamingCount)
        .transition(.opacity)
    }
}

// MARK: - idle 极简圆点（左耳）

/// idle 形态时左耳的极简圆点 —— 12pt mode 主色 + 4s 周期呼吸（alpha 0.6→0.85→0.6）。
/// 比 14pt sprite 更克制，让"什么都没事"的视觉信号尽可能轻。
/// hover 时由 hoverCard 接管，露出 22pt 完整 mode sprite。
///
/// 5 分钟系统无活动时 → sleeping 态：圆点 dim + 缩小 + 飘 "z"（打哈欠）。
/// 状态来源 `IdleStateTracker`，通知名 `HermesPetUserIdleChanged`
struct IdleModeDot: View {
    let tint: Color
    @State private var breathe = false
    @State private var isSleeping = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 12, height: 12)
                .opacity(isSleeping
                         ? (breathe ? 0.40 : 0.25)
                         : (breathe ? 0.85 : 0.60))
                .shadow(color: tint.opacity(isSleeping ? 0.20 : 0.45), radius: 4)
                .scaleEffect(isSleeping ? 0.82 : 1.0)

            if isSleeping {
                FloatingSleepZ(tint: tint)
                    .offset(x: 10, y: -6)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(AnimTok.smooth, value: isSleeping)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
            // 进入 view 时立即同步一次状态（之前已经 idle 5min 的话直接显示 sleeping）
            isSleeping = IdleStateTracker.shared.isSleeping
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetUserIdleChanged"))) { note in
            isSleeping = (note.userInfo?["isSleeping"] as? Bool) ?? false
        }
    }
}

/// 飘 "z" 子动画 —— 上浮 + 淡出循环（每 2.4s 一个 z 从下往上飘）
struct FloatingSleepZ: View {
    let tint: Color
    @State private var phase: CGFloat = 0   // 0 → 1，控制位置与透明度

    var body: some View {
        Text("z")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(tint.opacity(0.7 - Double(phase) * 0.7))
            .offset(y: -CGFloat(phase) * 10)
            .onAppear {
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
    }
}

// MARK: - d) 后台对话计数角标（idle 右耳左侧）

/// 当前激活对话之外还有 N 个对话在后台流式时显示，例如 `·2`
struct BackgroundStreamingBadge: View {
    let count: Int
    let tint: Color

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 1.5) {
            // 极小的呼吸点 —— 强调"正在跑"
            Circle()
                .fill(tint)
                .frame(width: 4, height: 4)
                .opacity(pulse ? 1.0 : 0.5)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            Capsule()
                .fill(tint.opacity(0.25))
        )
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.5), lineWidth: 0.5)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - 右耳任务指示器（loading 圈 / 完成对勾 / idle 状态图标）

/// 灵动岛右耳的小图标 —— 根据任务状态切换：
/// - idle：连接状态图标（✓ / ✗ / ?）
/// - working：旋转的弧形圆环（loading spinner）
/// - success：Face ID 风格的画线对勾，绿色，淡入 + 描边动画
struct RightEarIndicator: View {
    let connectionStatus: DynamicIslandPillView.ConnectionStatusDisplay
    let taskStatus: DynamicIslandPillView.RightEarTaskStatus
    /// 录音中的实时电平（0~1），用于 listening 状态的 5 段音量条
    var voiceLevel: Float = 0
    /// 成功对勾完成时的光晕颜色（mode 主色）
    var glowTint: Color = .green

    var body: some View {
        ZStack {
            switch taskStatus {
            case .idle:
                Image(systemName: connectionStatus.iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(connectionStatus.color)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))

            case .working:
                LoadingSpinner()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))

            case .success:
                AnimatedCheckmark(glowTint: glowTint)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))

            case .listening:
                ListeningMic(level: CGFloat(voiceLevel))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// "按住说话"指示器 —— 5 段实时音量条 + 红色脉冲背景
/// 每段独立映射 level 的一段区间，从左到右依次"亮起"，模拟阶梯式音量表
struct ListeningMic: View {
    /// 当前麦克风电平 (0~1)，由 HermesPetVoiceLevel 通知驱动
    let level: CGFloat

    @State private var pulse = false

    private let barCount = 5
    private let barWidth: CGFloat = 1.6
    private let barSpacing: CGFloat = 1.2
    private let baseHeight: CGFloat = 2
    private let peakHeight: CGFloat = 10

    var body: some View {
        ZStack {
            // 红色脉冲背景圈（保留"录音中"标识感）
            Circle()
                .fill(Color.red.opacity(0.30))
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.20 : 0.85)
                .opacity(pulse ? 0 : 0.7)
            // 5 段竖条 —— 每段独立映射 level 的一段区间
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: barWidth, height: barHeight(for: i))
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }

    /// 第 i 段（0-based）的高度：level 落在 [i/N, (i+1)/N] 区间时该段从 base 长到 peak
    private func barHeight(for index: Int) -> CGFloat {
        let segment = 1.0 / CGFloat(barCount)
        let lower = segment * CGFloat(index)
        // 该段对应的归一化能量（0~1），低于 lower 就是 base，高于 lower+segment 就是 peak
        let raw = (level - lower) / segment
        let clamped = max(0, min(1, raw))
        return baseHeight + (peakHeight - baseHeight) * clamped
    }
}

/// Claude.ai 风格的"思考中"加载动画 —— 三个白点波浪式脉冲。
/// 每个点错开 200ms 启动，0.9s 一个周期 fade+scale 呼吸。
/// 视觉上感觉是一组点从左到右"流过"，比单纯旋转更有 AI 思考的感觉。
struct LoadingSpinner: View {
    @State private var animating = false

    private let dotSize: CGFloat = 3.2
    private let dotSpacing: CGFloat = 2.5
    private let cycleDuration: Double = 0.9
    private let stagger: Double = 0.2     // 每个点之间相位错开 200ms

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(animating ? 1.0 : 0.3)
                    .scaleEffect(animating ? 1.0 : 0.55)
                    .animation(
                        .easeInOut(duration: cycleDuration / 2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * stagger),
                        value: animating
                    )
            }
        }
        .onAppear {
            // 第一帧设 false → 下一帧设 true，触发首帧的 transition
            animating = true
        }
    }
}

/// Face ID 风格画线对勾 —— success 状态用
/// 多层动画依次发生：
/// 1) 0~0.42s：路径从 0% 描边到 100%（easeOut 手写笔触感）
/// 2) 0.42s+：白色 shimmer 沿路径扫过一遍（25% 长度的高光段移动）
/// 3) 0.42s+：mode 主色光晕环从中心扩散并淡出（戏剧感）
struct AnimatedCheckmark: View {
    var glowTint: Color = .green

    @State private var progress: CGFloat = 0
    @State private var shimmerStart: CGFloat = -0.3
    @State private var glowScale: CGFloat = 0.5
    @State private var glowOpacity: Double = 0

    private static let strokeStyle = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)

    var body: some View {
        ZStack {
            // 3) mode 主色光晕环 —— 描边完成后扩散
            Circle()
                .stroke(glowTint, lineWidth: 1.5)
                .scaleEffect(glowScale)
                .opacity(glowOpacity)
                .frame(width: 14, height: 14)
                .blur(radius: 0.6)

            // 1) 对勾基础描边（绿色 —— 任务成功通用色）
            CheckmarkShape()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: Self.strokeStyle)

            // 2) Shimmer —— 25% 长度的高光段沿路径移动
            CheckmarkShape()
                .trim(from: max(0, shimmerStart), to: min(1, shimmerStart + 0.25))
                .stroke(Color.white.opacity(0.9), style: Self.strokeStyle)
                .blendMode(.plusLighter)
        }
        .frame(width: 12, height: 10)
        .onAppear {
            // 描边动画 —— easeOut 模拟手写笔触
            withAnimation(.easeOut(duration: 0.42)) {
                progress = 1.0
            }
            // 描边完成后触发 shimmer + glow
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 420_000_000)
                // Shimmer 扫过
                withAnimation(.easeOut(duration: 0.55)) {
                    shimmerStart = 1.0
                }
                // 同时 mode 主色光晕环扩散 + 淡出
                glowOpacity = 0.75
                withAnimation(.easeOut(duration: 0.7)) {
                    glowScale = 2.0
                    glowOpacity = 0
                }
            }
        }
    }
}

/// 对勾的 Path：左下 → 拐点 → 右上的两段折线
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 起点：左侧偏中
        path.move(to: CGPoint(x: rect.minX,                  y: rect.midY))
        // 拐点：底部偏左 1/3
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        // 终点：右上
        path.addLine(to: CGPoint(x: rect.maxX,                y: rect.minY))
        return path
    }
}

/// 上直角、下圆角的形状。圆角参与动画，方便 hover 时圆角变化。
struct NotchShape: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - r, y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height)
        )
        path.addLine(to: CGPoint(x: r, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height - r),
            control: CGPoint(x: 0, y: rect.height)
        )
        path.closeSubpath()
        return path
    }
}
