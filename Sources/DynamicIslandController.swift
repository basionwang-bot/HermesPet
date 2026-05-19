import AppKit
import SwiftUI

/// 灵动岛专用 NSPanel 子类。
///
/// override `constrainFrameRect` 返回原 frameRect —— macOS 26 默认会把 panel 约束到
/// `screen.visibleFrame`（避开 menu bar），即使 `level = .statusBar` 也被约束。
/// 我们要 panel 顶贴**物理屏顶**（盖住刘海两侧），所以原样返回。
///
/// 阶段 1 暂不 override `canBecomeKey` —— idle 状态没有键盘输入需求；阶段 2 做 permission
/// UI 需要 NSTextView 接收输入时再开（届时配合 `isFloatingPanel + becomesKeyOnlyIfNeeded`）。
final class EmbeddableIslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// 与刘海融合的桌宠胶囊。
/// 默认（idle）：刘海两侧探出来一段，像 iPhone 灵动岛常驻态显示信息。
/// 悬停（hover）：横向收紧到刘海宽度、纵向也变短，像一个紧凑的可点击按钮。
@MainActor
final class DynamicIslandController {
    private(set) var pillWindow: NSWindow
    /// 用 NSHostingController 而非 NSHostingView。
    /// 两者的 `sizingOptions = []` 语义不同：NSHostingView 在 macOS 26 上**仍不能**完全阻止
    /// `updateAnimatedWindowSize` 在 CA Transaction commit 期间反推 NSWindow.setFrame
    /// (这是 v1.2.4 必须把 permission UI 放独立窗口的原因)。NSHostingController 能真正禁掉
    /// 那条路径，让 panel.setFrame 安全可用 —— 为阶段 2 让灵动岛真正长大变形铺路。
    private let hostingController: NSHostingController<DynamicIslandPillView>

    private weak var statusItem: NSStatusItem?
    /// 点击灵动岛胶囊时回调（由 AppDelegate 注册）
    var onTapped: (() -> Void)?

    /// NSEvent 鼠标监听器（local + global）—— NSWindow.ignoresMouseEvents=true 后 SwiftUI 内部
    /// 收不到任何鼠标事件，hover/click 完全由这俩 monitor 在屏幕坐标系自检 hit area 触发
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    /// controller 端持有的 hover 状态 —— hit area state machine 的 single source of truth。
    /// false 时用 idle hit area 检测进入；true 时用 hover hit area 检测维持/离开
    private var isMouseHovering: Bool = false
    /// positionWindow 算完几何后缓存到这里，computeHitRectInScreen 用它算 hit 区屏幕坐标
    private var cachedNotchHeight: CGFloat = 32

    // MARK: - 形态参数（要改观感就调这四个）

    /// 默认（idle）状态：露在刘海下方的高度（极少，让耳朵"融入"刘海高度）
    private let idleDrop: CGFloat = 4
    /// 默认（idle）状态：横向比刘海多出多少（两侧各加一半 = 每个"耳朵"的宽度）
    private let idleExtraWidth: CGFloat = 80

    /// 悬停（hover）状态：向下展开的高度
    /// 36 → 42pt：让黑色多出 6pt 给文字呼吸空间，避免内容被摄像头/刘海视觉区压住
    private let hoverDrop: CGFloat = 42
    /// 悬停（hover）状态：横向比刘海多出多少。
    /// **水滴动画**：idle 时两侧耳朵全宽（80）跟刘海融为一体；hover 时收窄到 4，
    /// 整体宽度几乎等同于 MacBook 硬件刘海宽度（auxiliaryTopArea 反推得到的真实像素），
    /// 视觉上像一滴墨从刘海正下方润下来，两侧耳朵随高度展开同步回缩
    private let hoverExtraWidth: CGFloat = 4

    init() {
        // window 始终是 idle 尺寸（也就是最大尺寸），命中区域 = 整个 window
        // 这样 hover 后形状收缩，鼠标若仍在 idle 范围内，hover 状态依然保持，不抖
        let panel = EmbeddableIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = HermesWindowLevel.dynamicIsland   // 最高层，见 WindowLevels.swift
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // ⚠️ NSWindow 完全不接事件 —— 鼠标穿透到 menubar 不再"占据"任何事件响应空间。
        // hover/click 的 hit-test 完全搬到 controller 端用 NSEvent globalMonitor 自检（见下面
        // localEventMonitor / globalEventMonitor），跟 SwiftUI .onContinuousHover/.onTapGesture
        // 这套"NSWindow contentView 必须接事件才能触发"路线相比，根本上避免 NSWindow 物理 280×74pt
        // 遮挡菜单栏其他区域可点击范围
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        self.pillWindow = panel

        // 用 NSHostingController：sizingOptions = [] 能真正禁用 SwiftUI 反推 setFrame。
        // 跟历史 NSHostingView 实现的关键差别 —— 后者即便 sizingOptions=[] 在 macOS 26 上
        // 仍会通过 updateAnimatedWindowSize 在 CA transaction commit 期间反推 NSWindow.setFrame
        // → 嵌套 layout → SIGABRT。这是 v1.2.4 PermissionWindowController 必须用独立窗口的根因。
        // 改用 NSHostingController 后 panel.setFrame 安全可用，阶段 2 可以让灵动岛真正长大。
        let hosting = NSHostingController(rootView: DynamicIslandPillView())
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        panel.contentViewController = hosting
        self.hostingController = hosting

        // hostingController.view 是 NSHostingView 实例（私有类型），但 NSView 接口足够挂 gesture
        let hostingNSView = hosting.view
        hostingNSView.autoresizingMask = [.width, .height]
        hostingNSView.wantsLayer = true

        positionWindow()

        // NSEvent monitor 必须在所有 stored property 赋值完之后才能在 closure 里安全 capture self。
        // 屏幕坐标系监听鼠标位置：本 app 内事件走 localMonitor，其他 app（menubar 等）事件走 globalMonitor。
        // closure 在 nonisolated 上下文，跳 main 调 handleMouseEvent（@MainActor）
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            let type = event.type
            DispatchQueue.main.async { self?.handleMouseEvent(type: type) }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            let type = event.type
            DispatchQueue.main.async { self?.handleMouseEvent(type: type) }
        }

        // 屏幕参数变化（外接屏插拔 / HiDPI 缩放变化 / 屏幕排列变化 / 主屏切换）→ 灵动岛重摆位
        // 这是 SwiftUI 子模块（PermissionWindow / ResponseSummary / ClawdWalk）跟着灵动岛走的唯一信号源
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParamsChanged() }
        }
    }

    /// 屏幕参数变化处理：重新算 NSWindow frame + 广播给所有依赖灵动岛位置的子模块
    private func handleScreenParamsChanged() {
        positionWindow()
        // 给 PermissionWindowController / ResponseSummaryWindowController / ClawdWalkController 等
        // 一个统一信号 —— 它们各自重算自己的几何（用 HermesIslandGeometry helper）
        NotificationCenter.default.post(
            name: .init("HermesPetScreenParamsChanged"),
            object: nil
        )
    }

    // DynamicIslandController 是 AppDelegate 持有的单例，app 生命周期内不释放 → 不写 deinit
    // 清理 NSEvent monitor（Swift 6 nonisolated deinit 也访问不了 @MainActor 属性）

    // MARK: - NSEvent 屏幕坐标 hit-test

    /// 全局鼠标移动 / 点击都走这里。判断鼠标在 hit area 屏幕矩形内 → 更新 hover 状态 / 触发 click
    private func handleMouseEvent(type: NSEvent.EventType) {
        let mouseLoc = NSEvent.mouseLocation   // 屏幕坐标
        let hitRect = computeHitRectInScreen(forHovered: isMouseHovering)
        let inside = hitRect.contains(mouseLoc)

        switch type {
        case .mouseMoved:
            if inside != isMouseHovering {
                isMouseHovering = inside
                NotificationCenter.default.post(
                    name: .init("HermesPetIslandHoverChanged"),
                    object: nil,
                    userInfo: ["hovering": inside]
                )
            }
        case .leftMouseDown:
            // click 用**当前 hover 状态**对应的 hit area —— 跟视觉一致：
            // - idle 状态（水滴扁形态）：必须严格在刘海正下方小矩形内才 click
            // - hover 状态（水滴展开）：水滴本身 + 8pt buffer 都能 click
            // 之前一律用 hover hit area 判断会导致：idle 状态下用户在水滴下方视觉空白区点击
            // 也能弹出聊天窗（用户感受"没碰到灵动岛"）
            let clickRect = computeHitRectInScreen(forHovered: isMouseHovering)
            if clickRect.contains(mouseLoc) {
                onTapped?()
            }
        default:
            break
        }
    }

    /// 算 hit area 在屏幕坐标系的矩形。NSWindow contentView 内 (inset, 0, w - 2*inset, hitHeight)
    /// 顶端贴 NSWindow 顶 = 屏幕顶；转屏幕坐标 y 向上时顶端 y = window.maxY，底端 y = window.maxY - hitHeight
    private func computeHitRectInScreen(forHovered hovered: Bool) -> NSRect {
        let f = pillWindow.frame
        let hitHeight: CGFloat = hovered
            ? (cachedNotchHeight + hoverDrop)
            : max(0, cachedNotchHeight - 4)
        let inset: CGFloat = hovered
            ? max(0, (idleExtraWidth - hoverExtraWidth) / 2 - 8)
            : max(0, idleExtraWidth / 2 - 10)

        return NSRect(
            x: f.minX + inset,
            y: f.maxY - hitHeight,
            width: max(0, f.width - 2 * inset),
            height: hitHeight
        )
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

    private func positionWindow(animated: Bool = false) {
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
        // 显示模式：notch 用真实刘海高，floating 固定 28pt 让悬浮胶囊有标准尺寸
        let effectiveMode = HermesIslandGeometry.effective(on: screen)
        let actualNotchHeight: CGFloat = {
            switch effectiveMode {
            case .notch:    return hasNotch ? safeArea.top : 28
            case .floating: return 28
            }
        }()
        // 缓存给 computeHitRectInScreen 用（NSEvent monitor 自检 hit area 时算屏幕坐标）
        self.cachedNotchHeight = actualNotchHeight

        // 灵动岛 NSWindow 永远保持常规尺寸 —— **绝对不能改 frame**。
        // 任何 frame 变化（即便瞬切）都会触发 NSHostingView.invalidateSafeAreaInsets →
        // 嵌套 setNeedsUpdate → NSException 必崩。Permission UI 大卡片用独立 PermissionWindow 显示
        let windowWidth: CGFloat = actualNotchWidth  + idleExtraWidth
        let windowHeight: CGFloat = actualNotchHeight + hoverDrop

        // 水平：用「刘海真实中心」对齐（floating 模式没有物理刘海时用屏幕中线）
        let notchCenterX: CGFloat = {
            if let l = notchLeftX, let r = notchRightX {
                return (l + r) / 2
            }
            return screenFrame.midX
        }()
        let x = notchCenterX - windowWidth / 2
        // 纵向：方案 A —— notch / floating 都紧贴屏幕顶。
        // floating 模式胶囊正好覆盖菜单栏中央 28pt 区域，模拟刘海屏的灵动岛视觉。
        // NSWindow.ignoresMouseEvents=true，菜单栏中央被胶囊遮的图标仍可点击（事件穿透）
        let y = screenFrame.maxY - windowHeight

        pillWindow.setFrame(
            NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
            display: true
        )

        NotificationCenter.default.post(
            name: .init("HermesPetGeometry"),
            object: nil,
            userInfo: [
                "notchWidth": actualNotchWidth,
                "notchHeight": actualNotchHeight,
                "idleDrop": idleDrop,
                "idleExtraWidth": idleExtraWidth,
                "hoverDrop": hoverDrop,
                "hoverExtraWidth": hoverExtraWidth,
                "notchCenterX": notchCenterX,
                "windowBottomY": y,
                "isFloating": effectiveMode == .floating
            ]
        )
    }

    // MARK: - Actions

    @objc private func toggleChat() {
        onTapped?()
    }
}

// MARK: - SwiftUI Pill View

/// permission 卡片 transition 用的 modifier —— 同时驱动 scale + opacity + blur 三轴变化。
/// 让卡片像液体从灵动岛"凝聚长出"，配合 spring withAnimation 形成 FaceID 级动画
struct PermissionTransitionModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: UnitPoint(x: 0.5, y: 0.05))
            .opacity(opacity)
            .blur(radius: blur)
    }
}

struct DynamicIslandPillView: View {
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
    /// 卡片内容顶部额外 padding —— 在 notchHeight 之上再往下移文字，远离摄像头/刘海视觉区。
    /// 之前文字紧贴刘海下沿，物理摄像头镜头位置会切到第一行字。
    private let contentTopPad: CGFloat = 4
    /// floating（无刘海）显示模式：胶囊 4 角全圆 + mode 主色外发光 glow，
    /// 不再画顶部直角 NotchShape。由 DynamicIslandController.positionWindow 广播 HermesPetGeometry
    /// 携带 isFloating 字段驱动
    @State private var isFloating: Bool = false


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

    // MARK: - Wave A3 hover caption
    /// 当日意图采集总数 —— 用来判断 UserIntent 功能是否在工作（>0 才显示陪伴语）。
    /// 来源：UserIntentRecorder 每次落库后 broadcast，PillView.onAppear 主动查一次拿到初值
    @State private var todayIntentCount: Int = 0

    /// Wave C 边界：UserIntent 总开关，关掉时连陪伴语也不显示（避免旧数据残留误导）
    @AppStorage("userIntentEnabled") private var userIntentEnabled: Bool = false

    /// hover 时显示的陪伴语 —— 每次 isHovering 从 false→true 时随机换一句
    /// 池子按时段（早/午/下午/晚上/深夜）+ 通用混合，让"AI 在场"感更鲜活
    @State private var hoverCaption: String = "陪着你呢"

    // MARK: - Wave B 灵动岛 transient label（detector 命中后短临时反馈）
    /// 显示 2.5s 后自动消失的短文字（≤ 8 字），由 HermesPetIslandTransientLabel 通知触发
    @State private var transientLabelText: String = ""
    @State private var transientLabelVisible: Bool = false
    @State private var transientLabelTask: Task<Void, Never>? = nil

    // MARK: - o) 5 段音量条实时电平
    @State private var voiceLevel: Float = 0

    /// permission 卡片显示中 —— 灵动岛要冻结在 **idle 形态**（带耳朵的横条，width=280），
    /// 跟下方 PermissionWindow（280pt 宽）左右对齐，看起来是一体的 UI
    @State private var permissionActive: Bool = false

    /// 通知态 / hover / 工具调用中 / diff 摘要中 / 错误态 / Wave B 短反馈 → 都让胶囊"展开"成 hover 水滴形态。
    /// **注意 permissionActive 不进 isExpanded**：permission 卡片宽 280pt 跟 idle 形态等宽，
    /// 进 hover 反而收窄到 204pt 导致跟卡片错位
    ///
    /// **transientLabelVisible 必须进 isExpanded**（之前漏了，bug 修复）：
    /// 不撑开时 idleDrop 只有 4pt，文字塞不下 → 被刘海/摄像头视觉区遮住
    private var isExpanded: Bool {
        isHovering || isShowingNotification
            || currentToolKind != nil
            || diffSummaryVisible
            || isInErrorState
            || transientLabelVisible
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
        // permission 卡片显示中 → 底部直角，跟卡片顶部无缝衔接形成"灵动岛变形成大形态"
        if permissionActive { return 0 }
        return isExpanded ? 22 : 14
    }

    var body: some View {
        pillBodyWithStateObservers
        // ⚠️ .onHover 移到 pillBody 内部跟 .contentShape 同一层（见 pillBody 末尾）。
        // 原因：SwiftUI macOS 26 上 .onHover 不严格遵循 contentShape，会用 view layout frame
        // 整 280×74pt NSWindow 判断 → idle 时鼠标在 NotchShape 视觉区下方的透明区也触发 hover。
        // 把 .onHover 跟 contentShape 放同一 view 强制 SwiftUI 用 contentShape 当 hit-test 区域
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
        // C) 长任务情绪气泡 —— Clawd / CloudPet 都触发，按 mode 切换台词
        .onChange(of: elapsedSeconds) { _, secs in
            switch (currentMode, secs) {
            // Clawd（claudeCode）—— 严肃工程师人设
            case (.claudeCode, 30):  ClawdBubbleOverlayController.show("等等，快好了…")
            case (.claudeCode, 90):  ClawdBubbleOverlayController.show("emm，再花点时间")
            case (.claudeCode, 180): ClawdBubbleOverlayController.show("这个真的有点复杂…")
            // CloudPet（directAPI）—— 云端 / 飘逸人设
            case (.directAPI, 30):   ClawdBubbleOverlayController.show("云端有点慢呢…")
            case (.directAPI, 90):   ClawdBubbleOverlayController.show("这朵云有点大…")
            case (.directAPI, 180):  ClawdBubbleOverlayController.show("这片云遮了好久…")
            default: break
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
                // 失败 → 按 mode 冒不同人设气泡
                switch currentMode {
                case .claudeCode: ClawdBubbleOverlayController.show("糟糕 😵", duration: 2.2)
                case .directAPI:  ClawdBubbleOverlayController.show("云飘走了 😢", duration: 2.2)
                default: break   // Hermes / Codex 暂不冒
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
            if let v = note.userInfo?["isFloating"]      as? Bool    { isFloating = v }
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
        // Wave A3：UserIntentRecorder 落库时把 todayCount 更新到 hoverCard caption。
        // Wave A2 的 glanceShimmer 自发光效已砍 —— 每次切窗口都闪让人困惑，且"AI 在场"
        // 信号已经由桌宠 glance 动画（明确方向感）+ Wave B 短反馈卡片（有具体文案）覆盖
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetIntentRecorded"))) { note in
            if let c = note.userInfo?["todayCount"] as? Int {
                todayIntentCount = c
            }
        }
        // Wave B：detector 命中后短临时反馈
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetIslandTransientLabel"))) { note in
            let text = (note.userInfo?["text"] as? String) ?? ""
            let dur = (note.userInfo?["duration"] as? Double) ?? 2.5
            guard !text.isEmpty else { return }
            transientLabelTask?.cancel()
            transientLabelText = text
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                transientLabelVisible = true
            }
            transientLabelTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    transientLabelVisible = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionAsked"))) { _ in
            // 灵动岛底部从圆角变直角 → 跟 PermissionWindow 卡片衔接。柔和 spring 跟卡片同步
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86, blendDuration: 0.3)) {
                permissionActive = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionReplied"))) { _ in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.9, blendDuration: 0.25)) {
                permissionActive = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetPermissionDecisionMade"))) { _ in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.9, blendDuration: 0.25)) {
                permissionActive = false
            }
        }
        .onAppear {
            let hasKey = !(UserDefaults.standard.string(forKey: "apiKey") ?? "").isEmpty
            status = hasKey ? .connected : .unknown
            // Wave A3：从 ActivityStore 拉一次今日已观察总数（PillView 启动时只跑一次）
            // 后续每条新意图通过 HermesPetIntentRecorded 通知里的 todayCount 增量更新
            todayIntentCount = ActivityRecorder.shared.queryStore.todayIntentCount()
        }
    }

    /// 当前 mode 对应的强调色（跟聊天窗 headerTint 一致）
    private func modeTint(_ mode: AgentMode) -> Color {
        switch mode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    // MARK: - 各形态卡片（拆出来让 SwiftUI 编译器能 type-check 大 body）

    /// 胶囊本体 + 截屏闪光叠加 —— 抽出来让 SwiftUI 编译器在 body 里只面对 modifier 链
    private var pillBody: some View {
        VStack(spacing: 0) {
            ZStack {
                NotchShape(cornerRadius: currentRadius, isFloating: isFloating)
                    .fill(isInErrorState ? Color(red: 0.55, green: 0.32, blue: 0.05) : Color.black)
                    // floating 模式：贴边 1pt mode 主色细描边（不向外溢出）
                    .overlay {
                        if isFloating {
                            NotchShape(cornerRadius: currentRadius, isFloating: true)
                                .stroke(modeTint(currentMode).opacity(0.75), lineWidth: 1)
                        }
                    }
                pillContent
            }
            .frame(width: currentWidth, height: currentHeight)
            .scaleEffect(shutterScale)
            .overlay { shutterOverlay }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // hover 命中区严格贴住"实际渲染的形态"，否则鼠标在视觉上离开水滴后仍保持 hover 状态。
        // SwiftUI 给 path(in:) 的 rect 是外层 maxFrame = NSWindow 整个尺寸（典型 280×74pt），
        // 之前 hover 用 horizontalInset=0 → 整个 NSWindow 280pt 横向 + 68pt 纵向都 hit
        // → 鼠标在水滴正下方"延伸矩形区"（视觉上空白处）也保持 hover。
        //
        // idle:  hitHeight = notchHeight - 4 = ~28pt（严格在刘海可见区内，鼠标深入 4pt 才触发）
        //        horizontalInset = idleExtraWidth/2（两侧耳朵延伸区不响应，严格贴刘海正下方）
        // hover: hitHeight = notchHeight + hoverDrop（覆盖完整水滴高度）
        //        horizontalInset = (idleExtraWidth - hoverExtraWidth)/2 - 8pt buffer
        //        （横向贴水滴本身宽度 + 每侧 8pt 防抖 buffer，鼠标稍微出水滴边缘不立刻丢 hover）
        // ⚠️ NSWindow.ignoresMouseEvents=true 后 SwiftUI 内部所有 hover/tap gesture 全部收不到事件。
        // hover 状态完全由 DynamicIslandController 的 NSEvent monitor 在屏幕坐标系自检 hit area
        // 后通过 NotificationCenter 推过来。这里只是 receive + 用 spring 动画切 isHovering。
        // click 也是 controller 端 NSEvent .leftMouseDown 直接调 toggleChat，PillView 不参与
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetIslandHoverChanged"))) { note in
            // permission 卡片显示中：灵动岛冻结不响应 hover（permissionActive 已经把 isExpanded
            // 强制为 true，避免一离开卡片就 hover false 缩回）
            if permissionActive { return }
            let target = (note.userInfo?["hovering"] as? Bool) ?? false
            if isHovering != target {
                // 每次 hover 从 false → true 时换一句陪伴语（hover 期间稳定，离开再 hover 才再换）
                if target {
                    hoverCaption = Self.pickCompanionPhrase()
                }
                // **水滴动画**：width 80→4 + height 32→64 + radius 14→22 三轴同步驱动。
                // interpolatingSpring 让水流感更连贯（mass=1.0 给形变惯性 / stiffness 180 比标准
                // spring 软不"砸" / damping 22 收尾无回弹）
                withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 180, damping: 22, initialVelocity: 0)) {
                    isHovering = target
                }
            }
        }
    }

    /// Wave A3 polish：随机挑一句陪伴语。
    /// 70% 概率从通用池选（短而暖），30% 概率从当前时段池选（带时间感）。
    /// 写成 static 方便测试 + 不依赖 PillView 实例状态。
    static func pickCompanionPhrase() -> String {
        let general = [
            "陪着你呢", "嗯，在哒", "你忙你的", "在这儿",
            "我在", "嘿，在", "嗯哼～", "随你"
        ]
        let hour = Calendar.current.component(.hour, from: Date())
        let timed: [String]
        if (6...10).contains(hour) {
            timed = ["早呀～", "早安", "起这么早", "新一天～"]
        } else if (11...13).contains(hour) {
            timed = ["午饭了吗", "中午好", "歇会儿"]
        } else if (14...17).contains(hour) {
            timed = ["下午好", "继续吧", "在哒"]
        } else if (18...21).contains(hour) {
            timed = ["晚上好", "辛苦啦", "在呢"]
        } else {
            // 22:00 - 05:59 深夜
            timed = ["还在忙呢", "早点睡", "夜深啦", "注意休息"]
        }
        // 70/30 通用 vs 时段
        if Int.random(in: 0..<10) < 7 {
            return general.randomElement() ?? "陪着你呢"
        } else {
            return timed.randomElement() ?? "在哒"
        }
    }

    /// h) 截屏快门白光叠层
    @ViewBuilder
    private var shutterOverlay: some View {
        if shutterFlash {
            NotchShape(cornerRadius: currentRadius, isFloating: isFloating)
                .fill(Color.white)
                .frame(width: currentWidth, height: currentHeight)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // Wave A2 的 glanceShimmer（每次 UserIntent 落库灵动岛闪一下 mode 主色）已砍 ——
    // 自发光效跟用户切窗口/滚动节奏绑定，反复闪让人困惑且没传具体信息。"AI 在场"信号已经
    // 由桌宠 glance 动画（有明确方向感）+ Wave B 短反馈卡片（带文案）覆盖。

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
        } else if transientLabelVisible && !isHovering {
            // Wave B：detector 命中后的短临时反馈（≤ 8 字），让位 hover/工具/通知/错误态
            transientLabelCard
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
            Color.clear.frame(height: notchHeight + contentTopPad)
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
            Color.clear.frame(height: notchHeight + contentTopPad)
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
            Color.clear.frame(height: notchHeight + contentTopPad)
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

    /// Wave B：detector 命中后短临时反馈卡片（"看到 Foo 报错" 等）
    /// 用 sprite + 文字组合，比 notificationCard 更克制（无 icon、无副标）
    private var transientLabelCard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight + contentTopPad)
            HStack(spacing: 6) {
                ModeSpriteView(mode: currentMode, isWorking: false, size: 14)
                Text(transientLabelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxHeight: .infinity)
        }
        // 纯 opacity 过渡，避免决策 #6 几何 transform 风险
        .transition(.opacity)
    }

    /// 工具调用卡片：[Clawd] [verb] [arg] · [M/N 步] · [Xs] + 底部进度条
    private func toolStateCard(_ toolKind: ToolKind) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight + contentTopPad)
            HStack(spacing: 6) {
                ModeSpriteView(mode: currentMode, isWorking: true, size: 16)
                HStack(spacing: 4) {
                    Text(toolKind.verb)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !currentToolArg.isEmpty {
                        Text(currentToolArg)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if stepStarted >= 2 {
                        Text("· \(min(stepEnded + 1, stepStarted))/\(stepStarted)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if elapsedSeconds >= 10 {
                        Text("· \(elapsedSeconds)s")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .overlay(alignment: .bottom) {
            toolProgressBar
                .padding(.horizontal, 14)
                .padding(.bottom, 5)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// a) 工具卡底部迷你进度条 v3 —— Apple Music / Now Playing 风高级感设计：
    /// - **色彩调性**：底色用 mode 主色暗变体（同源），不引入中性白做轨道，避免三色撞色
    /// - **实色填充**：mode 主色 leading→trailing 渐变（暗→亮），暗示"还在生长"的方向感
    /// - **前导亮线**：填充末端叠 1.2pt 白色 capsule + blur 0.7，模拟"光头"在向前推进（类 Apple Music）
    /// - **玻璃感描边**：顶部 0.5pt 白色 0.4→0.05 渐变描边，让 capsule 像有反光的玻璃条而非平面色块
    /// - **进度算法**：TimelineView 30fps 合并步骤离散 + 时间软进度，displayRatio 连续变化永不卡住；
    ///   封顶 92% 留出 TaskFinished 时跳到 100% 的仪式感
    private var toolProgressBar: some View {
        let tint = modeTint(currentMode)
        // 步骤离散信号：已知步数则按精确比例
        let stepRatio: CGFloat = stepStarted > 0
            ? min(1, CGFloat(stepEnded) / CGFloat(stepStarted))
            : 0
        // 时间软进度的"预期总时长"：有步数信息按 4s/步估算（最低 8s 上限），无信息按 25s
        let expectedDuration: CGFloat = stepStarted > 0
            ? max(8, CGFloat(stepStarted) * 4)
            : 25
        let taskStart = taskStartTime

        return GeometryReader { geo in
            TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { ctx in
                // 精确 elapsed（不像 elapsedSeconds 是每秒跳一下的整数）
                let elapsed: CGFloat = {
                    guard let start = taskStart else { return 0 }
                    return CGFloat(ctx.date.timeIntervalSince(start))
                }()
                let timeRatio: CGFloat = min(0.92, elapsed / expectedDuration)
                // 三信号合并取最大：永远只前进不后退
                let displayRatio: CGFloat = max(0.06, stepRatio, timeRatio)
                let fillWidth = max(6, geo.size.width * displayRatio)

                ZStack(alignment: .leading) {
                    // 1) 底色轨道 —— mode 主色暗变体，跟整体色调同源
                    Capsule()
                        .fill(tint.opacity(0.18))

                    // 2) 实色填充 —— 深→亮渐变暗示生长方向
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.55), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)

                    // 3) 前导亮线 —— 填充末端的"光头"，1.2pt 白色 + 微 blur，类 Apple Music progress
                    RoundedRectangle(cornerRadius: 0.6, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 1.2, height: 3)
                        .blur(radius: 0.7)
                        .opacity(0.92)
                        .offset(x: max(0, fillWidth - 1.2))

                    // 4) 玻璃感顶部反光描边 —— 让 capsule 看起来有"厚度"而非贴纸
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.42),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
                .clipShape(Capsule())
                .shadow(color: tint.opacity(0.55), radius: 3, y: 0.5)
            }
        }
        .frame(height: 3)
    }

    /// hover 卡片（鼠标悬停时显示 mode + 状态点 + 模型名 + 陪伴语）
    private var hoverCard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight + contentTopPad)
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
                // Wave A3：陪伴语 caption —— 不暴露"今天观察 X 次"这种统计感（间谍感），
                // 改成简短陪伴感的短语，让用户感到"AI 在场"而非"AI 在数着"。
                // 每次 hover 进入时随机换一句（hover 期间稳定，离开再 hover 才换）。
                // Wave C 边界：必须 userIntentEnabled = true 且今天有过观察才显示
                if userIntentEnabled && todayIntentCount > 0 {
                    Text("· \(hoverCaption)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .id(hoverCaption)            // 文字变化时 transition 生效
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// 默认 idle 行：左耳极简圆点 + (floating 中间桌宠名 · 状态) + 右耳指示器
    private var idleStateRow: some View {
        HStack(spacing: 0) {
            IdleModeDot(tint: modeTint(currentMode))
                .padding(.leading, 18)

            // floating 模式：胶囊中间 ~200pt 黑色空白利用起来，显示桌宠名 + 状态
            // notch 模式中间被物理刘海遮住，保持极简不放文字
            if isFloating {
                HStack(spacing: 4) {
                    Text(idlePetName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(idleStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .id(idleStatusText)   // 文本变化时强制重建 → transition 生效
                        .transition(.opacity)
                }
                .padding(.leading, 8)
                .animation(.easeInOut(duration: 0.2), value: idleStatusText)
            }

            Spacer()
            // notch 模式保留独立 BackgroundStreamingBadge —— floating 已经用文字表达 N 条在跑
            if backgroundStreamingCount > 0 && !isFloating {
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

    /// 桌宠中文名 —— 跟 PetHeaderStrip / ResponseSummary 保持一致
    private var idlePetName: String {
        switch currentMode {
        case .claudeCode: return "Clawd"
        case .directAPI:  return "云朵"
        case .openclaw:   return "fomo"   // PR-B 上线龙虾 sprite 后正式启用
        case .hermes:     return "小马"
        case .codex:      return "coco"
        }
    }

    /// idle 时的状态文本：默认"在这呢"，后台 N 条对话流式 → "N 条对话在跑"
    private var idleStatusText: String {
        if backgroundStreamingCount > 0 {
            return "\(backgroundStreamingCount) 条对话在跑"
        }
        return "在这呢"
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
    /// 全局「桌宠动效」开关。quietMode=true 时圆点保持固定 opacity，不再 2s 周期呼吸
    @AppStorage("quietMode") private var quietMode: Bool = false

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
            // 进入 view 时立即同步一次状态（之前已经 idle 5min 的话直接显示 sleeping）
            isSleeping = IdleStateTracker.shared.isSleeping
            // quietMode=true 时不启动呼吸 —— breathe 保持 false，圆点固定中等亮度
            guard !quietMode else { return }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
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
    /// 全局「桌宠动效」开关。quietMode=true 时角标点保持固定 opacity
    @AppStorage("quietMode") private var quietMode: Bool = false

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
            guard !quietMode else { return }
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

/// 灵动岛 hover 命中区形状 —— 严格控制 onHover 触发的几何边界。
/// - `hitHeight`：从顶端往下多少 pt 是命中区（绝对值，不依赖 rect.height）
/// - `horizontalInset`：左右内缩 pt（每侧各缩 N pt，把两侧耳朵延伸区排除）
///
/// **为什么用绝对值不用 inset**：之前用 `bottomInset` 减 rect.height 算高度有 bug ——
/// SwiftUI 给 `path(in:)` 传的是外层 VStack 的 maxFrame（整个 NSWindow 64pt），
/// 不是内层 NotchShape 的当前高度。`rect.height - 8 = 56pt` 命中区远超刘海 28pt，
/// 导致鼠标在刘海下方任何位置都触发。改成传死高度后 idle 直接锁 24pt，跟动态 frame 解耦。
struct IslandHitShape: Shape {
    /// 命中区从顶端往下覆盖多少 pt（不超过 view 的 rect.height）
    var hitHeight: CGFloat
    /// 每侧横向内缩 pt
    var horizontalInset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(hitHeight, horizontalInset) }
        set {
            hitHeight = newValue.first
            horizontalInset = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let x = horizontalInset
        let w = max(0, rect.width - horizontalInset * 2)
        let h = min(rect.height, max(0, hitHeight))
        var p = Path()
        p.addRect(CGRect(x: x, y: 0, width: w, height: h))
        return p
    }
}

/// 灵动岛胶囊形状。
/// - `isFloating == false`（刘海模式）：顶部直角 + 左右下圆角，跟物理刘海无缝衔接
/// - `isFloating == true`（悬浮模式）：4 个角都圆，完整 Capsule，浮在菜单栏下方
struct NotchShape: Shape {
    var cornerRadius: CGFloat
    var isFloating: Bool = false

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        if isFloating {
            // 4 角都圆的胶囊
            return Path(roundedRect: rect, cornerRadius: r)
        }
        // 刘海风格：顶部直角，底部两个角圆
        var path = Path()
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
