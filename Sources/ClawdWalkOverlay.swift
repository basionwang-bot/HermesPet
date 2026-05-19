import AppKit
import SwiftUI

/// Clawd 桌面漫步 🐾 —— Claude 模式下的"桌面伴侣"彩蛋。
///
/// 触发条件（全部满足才出来）：
///   1. 当前 mode == Claude Code
///   2. 用户已 idle 3min（`IdleStateTracker.isSleeping == true`）
///   3. 设置里开了"Clawd 桌面漫步"（`clawdWalkEnabled`）
///   4. 没有任何对话在 streaming（不打扰用户等结果）
///
/// 触发后：
///   - 从灵动岛左耳位置 fade+slide 出来
///   - 沿菜单栏正下方水平往返漫步，速度 ~28 pt/s
///   - 每 4~8s 随机暂停 1.5~3s，表演 lookLeft / lookRight / armsUp（伸懒腰）
///   - 鼠标 hover → 暂停 + 看着鼠标方向
///   - 单击 → 打开聊天窗口
///   - 双击 → 切换到 Claude 模式（如果已在 Claude 则等同单击）
///
/// 退出（任一不满足）：
///   - 跳回灵动岛位置 + fade out（350ms）
///
/// 实现要点：
///   - 用 NSPanel `.nonactivatingPanel`，level 同灵动岛 statusBar
///   - 窗口尺寸 = sprite 实际渲染区，避免大块透明区误吞点击
///   - 单 Timer @ 30fps 驱动位移；pose / 表情 走 ClawdView 已有的 4 种姿势
@MainActor
final class ClawdWalkController {
    static let shared = ClawdWalkController()

    private weak var viewModel: ChatViewModel?
    private var window: NSWindow?
    private var hostingView: NSHostingView<ClawdWalkView>?
    private let state = ClawdWalkState()

    // 头顶气泡的独立窗口（不放在 Clawd 窗口里是因为 Clawd 窗口很小，气泡放外面更灵活定位）
    private var bubbleWindow: NSWindow?
    private static let bubbleSize = NSSize(width: 160, height: 28)

    // MARK: - Walk params
    /// 基础窗口尺寸 —— Clawd 像素是 11:10 接近正方形，基础高 50pt 保证 padding 10pt 上下
    /// 容纳 jumping=-10pt 不被 NSHostingView 截顶
    private static let baseWindowSize = NSSize(width: 48, height: 50)

    /// 当前 scale（读 AppStorage，监听变化通过 PetWalkSizeScale.didChangeNotification）
    private var sizeScale: CGFloat {
        let raw = UserDefaults.standard.double(forKey: PetWalkSizeScale.storageKey)
        return raw < 0.1 ? 1.0 : CGFloat(raw)
    }

    /// 当前实际窗口尺寸 = 基础 × scale。所有几何计算（撞墙 / 拖动 / patrol 站位）都读这个
    private var windowSize: NSSize {
        NSSize(
            width: Self.baseWindowSize.width * sizeScale,
            height: Self.baseWindowSize.height * sizeScale
        )
    }
    private static let walkSpeed: CGFloat = 28           // pt/s，慢悠悠
    private static let chaseSpeedMul: CGFloat = 1.6      // 鼠标靠近时小跑加速倍率
    private static let patrolSpeed: CGFloat = 60         // 巡视时下到桌面 / 回菜单栏速度
    private static let edgeMargin: CGFloat = 18          // 屏幕左右 18pt 内反弹
    private static let tickInterval: TimeInterval = 1.0/30.0
    private static let pauseEveryMin: TimeInterval = 4.0
    private static let pauseEveryMax: TimeInterval = 8.0
    private static let pauseDurMin: TimeInterval = 1.4
    private static let pauseDurMax: TimeInterval = 2.8
    /// 鼠标距离阈值 —— 进入 chasing 后用 exit 阈值，避免边缘抖动反复切换
    private static let chaseEnterDist: CGFloat = 180
    private static let chaseExitDist: CGFloat = 240

    // MARK: - Desktop patrol params（"遇见桌面图标 → 嗅一下 → AI 短评"）
    /// 巡视间隔 —— 第一次出场后 15~30s 就来一次，之后每次结束后 45~90s 再来
    /// （之前 30~60 + 90~180 用户反馈太稀疏；现在大约每分钟一次有节奏感但不烦）
    private static let patrolFirstDelayRange: ClosedRange<TimeInterval> = 15...30
    private static let patrolIntervalRange: ClosedRange<TimeInterval> = 45...90
    /// 走向图标时算"到达"的距离阈值（NSScreen 单位）
    private static let patrolArriveDist: CGFloat = 6
    /// 嗅停留时长（够 Hermes 返回 + 气泡读 1 句）
    private static let sniffDurationRange: ClosedRange<TimeInterval> = 4.5...6.0
    /// 站到图标侧边的偏移 —— 避免 Clawd 主体盖住图标的命中区
    private static let iconSideOffset: CGFloat = 36
    /// 巡视到一半 Finder 卡死时的兜底超时（超过 → 直接回菜单栏）
    private static let patrolWatchdog: TimeInterval = 20

    // MARK: - 状态
    private var walkTimer: Timer?
    private var lastTickAt: Date?
    private var isShown = false
    private var positionX: CGFloat = 0
    private var direction: CGFloat = 1                   // +1 右 / -1 左
    private var walkY: CGFloat = 0
    private var nextPauseAt: Date?
    private var pauseEndsAt: Date?
    private var lastBackgroundStreamingCount: Int = 0
    private var lastMode: AgentMode = .hermes
    private var isHovering = false

    // 冒泡状态
    private var nextBubbleAt: Date?
    private var bubbleHideAt: Date?
    private var lastBubbleQuote: String = ""

    // MARK: - 桌面巡视状态
    /// 巡视生命周期 —— nil = 不在巡视，普通漫步
    private enum PatrolPhase {
        /// 正在走向图标 target；targetPos 是 Clawd 窗口左下角的目标坐标
        case goingTo(target: NSPoint, icon: DesktopIcon)
        /// 已到达图标，停下嗅；until 是这一阶段结束时间
        case sniffing(icon: DesktopIcon, until: Date)
        /// 嗅完往菜单栏方向走（targetPos 同上）
        case returning(target: NSPoint)
    }
    private var patrol: PatrolPhase? = nil
    /// 下次启动巡视的时间。每次出场 / 巡视结束时重排
    private var nextPatrolAt: Date? = nil
    /// 当前巡视的看门狗（Finder 卡死 / 路径异常时强制回菜单栏）
    private var patrolWatchdogAt: Date? = nil
    /// 飞行中的 AI 调用 Task，stop 时取消避免桌面巡视关掉后还在跑
    private var sniffAITask: Task<Void, Never>? = nil

    /// 戴眼镜动画完整结束的截止时间。在此之前 shouldShow 强制返回 true，
    /// 确保用户能看完戴眼镜全过程而不被 streaming 立即回家打断
    private var glassesPendingUntil: Date? = nil
    private var glassesEvalTask: Task<Void, Never>? = nil

    // MARK: - Wave A1 实时存在感
    /// 上次触发 glance 的时间，1s 内只触发一次（防止用户连按回车桌宠抽搐）
    private var lastGlanceAt: Date? = nil

    // MARK: - 灵动岛避让 + 传送门
    /// 灵动岛物理水平占用范围两侧再各 buffer 30pt 形成"避让带" —— 桌宠普通漫步不进，必须穿越时走传送门
    private static let notchAvoidBuffer: CGFloat = 30
    /// 传送门动画总耗时：开门 0.2s + 移动 0.0s（瞬移） + 收门 0.2s + 桌宠淡入淡出 0.4s = 0.6s 左右
    private static let teleportTotalDuration: TimeInterval = 0.6
    /// 传送门冷却：完成一次后 3s 内禁止再次触发，避免鼠标在两侧乱晃时反复闪
    private static let teleportCooldown: TimeInterval = 3.0
    /// 当前是否正在传送中（tick 期间应跳过所有自动位移逻辑）
    private var isTeleporting: Bool = false
    /// 上次传送结束时间，加 teleportCooldown 算冷却到期点
    private var lastTeleportEndedAt: Date? = nil
    /// 传送门 SwiftUI state（openness 0~1 驱动门展开/收回）
    private let portalState = TeleportPortalState()
    /// 传送门 NSPanel（独立窗口，跟桌宠 NSWindow 平级 z-order）
    private var portalWindow: NSWindow?
    /// 传送门窗口尺寸 —— 比桌宠略大，让外圈光晕能溢出
    private static let portalWindowSize = NSSize(width: 80, height: 80)

    private init() {}

    /// AppDelegate 启动时调一次。后续完全靠通知驱动状态切换
    func start(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        self.lastMode = viewModel.agentMode
        state.visual = petVisual(for: viewModel.agentMode)
        registerNotifications()
        evaluateState()
    }

    /// 根据当前 AgentMode 选择宠物种类。
    /// - claudeCode → clawd（橙色螃蟹）
    /// - directAPI → cloud（indigo 云朵）
    /// - hermes → horse（金黄小马）
    /// - codex → terminal（mini Terminal.app 窗口）
    private func petVisual(for mode: AgentMode) -> PetVisualKind {
        switch mode {
        case .directAPI:  return .cloud
        case .openclaw:   return .fox     // PR-B: fomo 九尾狐
        case .hermes:     return .horse
        case .codex:      return .terminal
        case .claudeCode: return .clawd
        }
    }

    // MARK: - Notification 监听
    private func registerNotifications() {
        let nc = NotificationCenter.default

        // idle 状态变化（IdleStateTracker tick）
        nc.addObserver(forName: .init("HermesPetUserIdleChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateState() }
        }

        // 桌宠大小档位变化 —— 已显示中需要 setFrame 调整窗口 + walkY 重新计算
        nc.addObserver(forName: PetWalkSizeScale.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSizeScaleChanged() }
        }

        // 设置开关变化（漫步总开关 / 自由活动开关）
        nc.addObserver(forName: .init("HermesPetClawdWalkSettingChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateState() }
        }
        nc.addObserver(forName: .init("HermesPetClawdFreeRoamSettingChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateState() }
        }
        // 桌面巡视开关 —— 开启 → 立刻排首次巡视；关闭 → 若已在巡视则强制提前返回
        nc.addObserver(forName: .init("HermesPetClawdPatrolSettingChanged"), object: nil, queue: .main) { [weak self] note in
            // 在 task-isolated 闭包外先抓 enabled，避免 note 跨 actor 边界引发 SendingRisksDataRace
            let enabled = (note.userInfo?["enabled"] as? Bool) ?? false
            Task { @MainActor in
                guard let self = self, self.isShown else { return }
                if enabled {
                    // 刚开 → 强制刷新桌面快照（避免用本地老缓存）+ 立刻排一次
                    DesktopIconReader.shared.invalidate()
                    self.scheduleNextPatrolIfEnabled(firstTime: true)
                } else {
                    // 关闭：清下次排程 + 中断进行中的巡视（取消 AI、立即返回菜单栏）
                    self.nextPatrolAt = nil
                    self.sniffAITask?.cancel()
                    self.sniffAITask = nil
                    if self.patrol != nil, let screen = self.targetScreen() {
                        let home = NSPoint(x: self.notchCenterX(on: screen) - self.windowSize.width / 2,
                                           y: self.walkBaseY(on: screen))
                        self.patrol = .returning(target: home)
                        self.state.bubbleVisible = false
                        self.bubbleHideAt = nil
                    }
                }
            }
        }

        // CloudPet 戴眼镜通知 —— vision 自动切换时触发。
        // 总动画时长 = 戴上 1.4s + 保持 duration + 摘下 0.6s，整个期间云朵必须留在桌面
        nc.addObserver(forName: .init("HermesPetCloudPetWearGlasses"), object: nil, queue: .main) { [weak self] note in
            let duration = (note.userInfo?["duration"] as? Double) ?? 6.0
            let totalSec = 1.4 + duration + 0.6
            Task { @MainActor in
                guard let self = self else { return }
                self.glassesPendingUntil = Date().addingTimeInterval(totalSec)
                // 立刻 evaluate：把刚回家的云朵叫回来（或保持现状）
                self.evaluateState()
                // 动画结束时再 evaluate 一次：若那时 streaming 仍在跑会自然回家
                self.glassesEvalTask?.cancel()
                self.glassesEvalTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(totalSec * 1_000_000_000))
                    if Task.isCancelled { return }
                    self.glassesPendingUntil = nil
                    self.evaluateState()
                }
            }
        }

        // Mode 变化（切到非 Claude → 立刻收起）
        nc.addObserver(forName: .init("HermesPetModeChanged"), object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?["mode"] as? String) ?? ""
            let mode = AgentMode(rawValue: raw) ?? .hermes
            Task { @MainActor in
                guard let self = self else { return }
                self.lastMode = mode
                self.state.visual = self.petVisual(for: mode)
                self.evaluateState()
            }
        }

        // 后台 streaming 总数变化（任务进行中 → 收起，不打扰）
        nc.addObserver(forName: .init("HermesPetBackgroundStreamingChanged"), object: nil, queue: .main) { [weak self] note in
            let cnt = (note.userInfo?["count"] as? Int) ?? 0
            Task { @MainActor in
                self?.lastBackgroundStreamingCount = cnt
                self?.evaluateState()
            }
        }

        // 任务开始/结束（兜底 —— 上面 BackgroundStreaming 已基本能覆盖，但 active 对话的 streaming 也应中止 Clawd）
        nc.addObserver(forName: .init("HermesPetTaskStarted"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateState() }
        }
        nc.addObserver(forName: .init("HermesPetTaskFinished"), object: nil, queue: .main) { [weak self] _ in
            // 任务结束后稍等一拍再决策（让 streaming flag 落定）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.evaluateState()
            }
        }

        // 屏幕参数变化（外接屏插拔 / 缩放变化 / 主屏切换）→ 桌宠也得跟新屏走
        // 重新算 walkY + clamp positionX 到新屏的 visible range
        nc.addObserver(forName: .init("HermesPetScreenParamsChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleScreenParamsChanged() }
        }

        // Wave A1 实时存在感：UserIntentRecorder 每次落库一条意图就广播这个通知。
        // 桌宠收到后做 0.4s 的"瞥一眼"动画（rotation 摆头 + 白色 flash），1s 内去重。
        nc.addObserver(forName: .init("HermesPetIntentRecorded"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleIntentRecorded() }
        }
    }

    /// Wave A1：UserIntentRecorder 落库后调，触发桌宠"瞥一眼"
    /// - 桌宠没显示 / 正在被拖动 / 正在吃文件时跳过（忙时不打扰）
    /// - quietMode 开启时跳过（尊重用户的安静偏好）
    /// - 1s 内多次触发只动一次（连按回车防抽搐）
    private func handleIntentRecorded() {
        guard isShown else { return }
        guard !state.isBeingDragged, !state.isEating else { return }
        let quiet = UserDefaults.standard.bool(forKey: "quietMode")
        guard !quiet else { return }
        if let last = lastGlanceAt, Date().timeIntervalSince(last) < 1.0 { return }
        lastGlanceAt = Date()

        // 通知 SwiftUI View 做 rotation + flash 动画
        state.glancePulse &+= 1

        // Clawd 是像素图，额外切 pose 让眼睛看一下（其他 sprite 没有 pose，靠 rotation 表达）
        if state.visual == .clawd, state.pose == .rest {
            let lookRight = Bool.random()
            setPoseLookingAt(worldRight: lookRight)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                // 仅当 pose 还是 look 系列时才回 rest，避免覆盖中途用户 hover / 任务态切换
                if state.pose == .lookLeft || state.pose == .lookRight {
                    state.pose = .rest
                }
            }
        }
    }

    /// 屏幕参数变化处理：把桌宠重新摆到新屏的合法位置（walkY 重算 + positionX clamp 到屏内）
    private func handleScreenParamsChanged() {
        guard isShown, let win = window, let screen = targetScreen() else { return }
        walkY = walkBaseY(on: screen)
        let visible = screen.visibleFrame
        let leftBound  = visible.minX + Self.edgeMargin
        let rightBound = visible.maxX - windowSize.width - Self.edgeMargin
        positionX = max(leftBound, min(rightBound, positionX))
        win.setFrameOrigin(NSPoint(x: positionX, y: walkY))
        // 气泡跟着 Clawd 位置同步
        syncBubbleWindow()
    }

    // MARK: - 触发条件评估

    /// 当前条件是否允许 Clawd 漫步
    ///
    /// 普通模式（freeRoam=OFF）：mode=Claude + 漫步开关 + 3min idle + 无 streaming
    /// 自由活动模式（freeRoam=ON）：mode=Claude + 漫步开关 + 无 streaming（跳过 idle 前置）
    private func shouldShow() -> Bool {
        guard let vm = viewModel else { return false }
        guard vm.clawdWalkEnabled else { return false }
        // 5 个 mode 都允许桌面漫步（.openclaw 加在内，对应 fomo 九尾狐 PR-B）
        guard vm.agentMode == .claudeCode || vm.agentMode == .directAPI ||
              vm.agentMode == .openclaw || vm.agentMode == .hermes ||
              vm.agentMode == .codex else { return false }
        // 戴眼镜动画期间强制保持显示 —— 用户能看完整个"掏眼镜→戴上→保持→摘下"流程，
        // 之后再按常规规则判定是否回家（vision 切换后通常 streaming 仍在跑会回家）
        if let pending = glassesPendingUntil, pending > Date() { return true }
        // streaming 时永远不出来（不管哪种模式），避免抢灵动岛进度的注意力
        if vm.conversations.contains(where: { $0.isStreaming }) { return false }
        // HTTP API 类 mode：宠物直接到桌面，不等 idle（云朵 / fomo 都属于主动陪伴系）
        if vm.agentMode == .directAPI || vm.agentMode == .openclaw { return true }
        // 自由活动模式：放行
        if vm.clawdFreeRoamEnabled { return true }
        // 普通模式（Claude / Hermes / Codex）：必须 idle 3min 才出来
        return IdleStateTracker.shared.isSleeping
    }

    private func evaluateState() {
        let want = shouldShow()
        if want && !isShown {
            showAndStartWalking()
        } else if !want && isShown {
            stopAndHide()
        }
    }

    /// 用户在设置里改了桌宠大小档位 —— 已显示中调整窗口尺寸 + 重新算 walkY 让桌宠贴菜单栏
    /// 桌宠不在屏幕上时无需任何操作（下次出场时 windowSize computed 自动用新 scale）
    private func handleSizeScaleChanged() {
        guard isShown, let win = window, let screen = targetScreen() else { return }
        let newSize = windowSize
        walkY = walkBaseY(on: screen)
        // 重新 clamp positionX 避免新窗口宽溢出
        let visible = screen.visibleFrame
        let leftBound  = visible.minX + Self.edgeMargin
        let rightBound = visible.maxX - newSize.width - Self.edgeMargin
        positionX = max(leftBound, min(rightBound, positionX))
        win.setFrame(
            NSRect(x: positionX, y: walkY, width: newSize.width, height: newSize.height),
            display: true, animate: false
        )
        // 气泡窗口跟新位置同步
        syncBubbleWindow()
    }

    // MARK: - 屏幕几何

    /// 选 notch 屏，没有就 main
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// 灵动岛中心 x（用 auxiliary 反推；非 notch 屏取 screen 中线）
    private func notchCenterX(on screen: NSScreen) -> CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return (l.maxX + r.minX) / 2
        }
        return screen.frame.midX
    }

    /// 灵动岛"避让带" —— 桌宠普通漫步不能进、chasing/patrol 跨越要触发传送门。
    /// notch 模式：物理刘海宽度两侧各 +30pt
    /// floating 模式：悬浮胶囊矩形两侧各 +30pt
    private func notchAvoidZone(on screen: NSScreen) -> ClosedRange<CGFloat>? {
        return HermesIslandGeometry.avoidZoneX(on: screen)
    }

    /// 判断桌宠窗口（左下角 = positionX，宽 = windowSize.width）是否跟避让带相交。
    /// 用桌宠中心 x 判断更直观 —— 桌宠中心进入 zone = 算作"接触"
    private func clawdCenterInAvoidZone(positionX: CGFloat, on screen: NSScreen) -> Bool {
        guard let zone = notchAvoidZone(on: screen) else { return false }
        let cx = positionX + windowSize.width / 2
        return zone.contains(cx)
    }

    /// 漫步 y：按 displayMode 走在菜单栏下方（notch）或悬浮胶囊下方（floating），保证桌宠不遮灵动岛
    private func walkBaseY(on screen: NSScreen) -> CGFloat {
        HermesIslandGeometry.clawdWalkBaseY(on: screen, clawdHeight: windowSize.height)
    }

    // MARK: - 显示 / 隐藏

    private func showAndStartWalking() {
        guard let screen = targetScreen() else { return }
        if window == nil { createWindow() }
        guard let win = window else { return }

        let startCenterX = notchCenterX(on: screen)
        walkY = walkBaseY(on: screen)
        positionX = startCenterX - windowSize.width / 2
        direction = Bool.random() ? 1 : -1
        nextPauseAt = Date().addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
        pauseEndsAt = nil
        // 首次冒泡时机：出场后 25-60s 第一次冒，之后用 randomBubbleInterval()
        nextBubbleAt = Date().addingTimeInterval(Double.random(in: 25...60))
        bubbleHideAt = nil
        state.isChasing = false
        if bubbleWindow == nil { createBubbleWindow() }
        // 巡视：如果设置开了，调度首次桌面巡视
        patrol = nil
        patrolWatchdogAt = nil
        scheduleNextPatrolIfEnabled(firstTime: true)

        // 入场：从灵动岛位置（y=屏幕顶部）滑到漫步 y + fade in
        let islandTopY = screen.frame.maxY - windowSize.height
        win.setFrame(
            NSRect(x: positionX, y: islandTopY, width: windowSize.width, height: windowSize.height),
            display: false
        )
        win.alphaValue = 0
        state.facingRight = (direction > 0)
        state.pose = .rest
        win.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1.0
            win.animator().setFrame(
                NSRect(x: positionX, y: walkY, width: windowSize.width, height: windowSize.height),
                display: true
            )
        })

        isShown = true
        state.spriteAnimated = true   // 桌宠显示 → sprite 内部 TimelineView 启动
        startWalkTimer()
    }

    private func stopAndHide() {
        isShown = false
        walkTimer?.invalidate()
        walkTimer = nil
        lastTickAt = nil
        pauseEndsAt = nil
        state.isChasing = false
        // 气泡立即收起 + 窗口跟着 Clawd 一起退
        state.bubbleVisible = false
        state.bubbleText = ""
        bubbleWindow?.orderOut(nil)
        nextBubbleAt = nil
        bubbleHideAt = nil
        // 巡视相关：取消飞行中的 AI 请求 + 清状态
        patrol = nil
        nextPatrolAt = nil
        patrolWatchdogAt = nil
        sniffAITask?.cancel()
        sniffAITask = nil
        state.isBeingDragged = false
        // 传送门：取消进行中的传送 + 立即收门，避免桌宠隐藏后门还浮着
        isTeleporting = false
        portalState.openness = 0
        portalWindow?.orderOut(nil)

        guard let win = window, let screen = targetScreen() else {
            window?.orderOut(nil)
            return
        }

        // 退场：滑回灵动岛位置 + fade out
        let islandCenterX = notchCenterX(on: screen)
        let backX = islandCenterX - windowSize.width / 2
        let islandTopY = screen.frame.maxY - windowSize.height

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
            win.animator().setFrame(
                NSRect(x: backX, y: islandTopY, width: windowSize.width, height: windowSize.height),
                display: true
            )
        }, completionHandler: { [weak win, weak state] in
            Task { @MainActor in
                win?.orderOut(nil)
                // orderOut 完成后才关 sprite 动画 —— 不然飞回灵动岛途中桌宠会瞬间僵硬
                state?.spriteAnimated = false
            }
        })
    }

    // MARK: - NSWindow 创建

    private func createWindow() {
        let w = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.dynamicIsland   // 跟灵动岛同级，永远在最前
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovableByWindowBackground = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = false                // 要接收点击和 hover

        // 容器 NSView：底层 SwiftUI hosting view（Clawd 视觉）+ 上层 FileDropView（接受拖放）
        // FileDropView 用 hitTest=nil 让点击事件穿透下去，但 dragging 事件正常拦截
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: ClawdWalkView(
            state: state,
            onSingleTap: { [weak self] in self?.handleSingleTap() },
            onDoubleTap: { [weak self] in self?.handleDoubleTap() },
            onHoverChange: { [weak self] hovering in self?.handleHoverChange(hovering) },
            onDragStarted: { [weak self] in self?.handleClawdDragStarted() },
            onDragChanged: { [weak self] t in self?.handleClawdDragChanged(translation: t) },
            onDragEnded: { [weak self] t in self?.handleClawdDragEnded(translation: t) }
        ))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        // 决策 #6：禁止 SwiftUI 反推 NSWindow setFrame，避免嵌套 layout cycle 崩溃
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        container.addSubview(host)

        let dropView = FileDropView(frame: container.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onFileDropped = { [weak self] url in
            Task { @MainActor in self?.handleFileDropped(url) }
        }
        dropView.onDragStateChanged = { [weak self] entering in
            Task { @MainActor in self?.handleDragStateChanged(entering: entering) }
        }
        container.addSubview(dropView)

        w.contentView = container
        self.window = w
        self.hostingView = host
    }

    /// 传送门独立窗口 —— 跟桌宠 NSWindow 平级，spawn 时在桌宠当前位置打开门、瞬移后在 target 位置打开门。
    /// 不接收点击（穿透到桌面），永远在桌宠上层略偏，让门视觉包住桌宠
    private func createPortalWindow() {
        let w = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.portalWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.dynamicIsland
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TeleportPortalView(state: portalState))
        host.frame = NSRect(origin: .zero, size: Self.portalWindowSize)
        host.autoresizingMask = [.width, .height]
        // 决策 #6：禁止 SwiftUI 反推 NSWindow setFrame —— Canvas + TimelineView 30fps 重绘 +
        // withAnimation 改 openness 驱动 scaleEffect/opacity，没这道防线 ~ 长时间运行后必崩
        // (用户 v1.2.7 跑 4.5 小时后崩溃 SIGTRAP @ NSView updateConstraintsForSubtreeIfNeeded)
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        w.contentView = host
        portalWindow = w
    }

    /// 传送门每 tick 跟桌宠中心对齐 —— 传送中桌宠移动时门也跟着滑过去
    private func syncPortalWindow() {
        guard let portal = portalWindow, isTeleporting else { return }
        let cx = positionX + windowSize.width / 2
        let cy = walkY + windowSize.height / 2
        portal.setFrameOrigin(NSPoint(
            x: cx - Self.portalWindowSize.width / 2,
            y: cy - Self.portalWindowSize.height / 2
        ))
    }

    /// 当前 mode 主色 —— 传送门 tint 跟着桌宠
    private func currentModeTintColor() -> Color {
        switch lastMode {
        case .hermes:     return .green
        case .directAPI:  return .indigo
        case .openclaw:   return Color(red: 0.706, green: 0.773, blue: 0.910)
        case .claudeCode: return .orange
        case .codex:      return .cyan
        }
    }

    /// 尝试触发传送门 —— 把桌宠从当前位置嗖一下传到 targetPositionX（NSWindow 左下角 x）。
    /// 触发条件全部满足才会启动：(1) 冷却到期 (2) 当前不在传送中 (3) avoidZone 存在
    /// 动画时序：
    ///   t=0.00 → 开门 + 桌宠 fade out（持续 0.18s）
    ///   t=0.20 → positionX 设到 targetPositionX，window 和 portal 同时 setFrameOrigin 瞬移
    ///   t=0.20~0.40 → 桌宠 fade in
    ///   t=0.40 → 收门动画启动
    ///   t=0.60 → 收门完成，portal orderOut，isTeleporting = false，记 lastTeleportEndedAt 进冷却
    @discardableResult
    private func tryTeleport(toX targetPositionX: CGFloat, on screen: NSScreen) -> Bool {
        if isTeleporting { return false }
        if let last = lastTeleportEndedAt,
           Date().timeIntervalSince(last) < Self.teleportCooldown {
            return false
        }
        guard let win = window else { return false }
        if portalWindow == nil { createPortalWindow() }
        guard let portal = portalWindow else { return false }

        isTeleporting = true
        // 桌宠停掉 chasing / patrol 临时状态，免得动画结束后跟自身位移冲突
        state.isWalking = false
        state.pose = .rest

        // 入门位置 = 桌宠当前中心
        let cx0 = positionX + windowSize.width / 2
        let cy0 = walkY + windowSize.height / 2
        portal.setFrameOrigin(NSPoint(
            x: cx0 - Self.portalWindowSize.width / 2,
            y: cy0 - Self.portalWindowSize.height / 2
        ))
        portalState.tintColor = currentModeTintColor()
        portalState.openness = 0
        portal.alphaValue = 1
        portal.orderFront(nil)

        // 阶段 1：开门 0.2s（withAnimation 内部已带 spring，0.32s 完成弹出）+ 桌宠 fade out 0.18s
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
            portalState.openness = 1.0
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
        }

        // 阶段 2 (t=0.20)：瞬移
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self = self, self.isTeleporting else { return }
            self.positionX = targetPositionX
            self.walkY = self.walkBaseY(on: screen)  // 确保 walkY 是菜单栏下（patrol 可能下到桌面中央）
            let cx1 = self.positionX + self.windowSize.width / 2
            let cy1 = self.walkY + self.windowSize.height / 2
            self.window?.setFrameOrigin(NSPoint(x: self.positionX, y: self.walkY))
            self.portalWindow?.setFrameOrigin(NSPoint(
                x: cx1 - Self.portalWindowSize.width / 2,
                y: cy1 - Self.portalWindowSize.height / 2
            ))

            // 桌宠淡入 0.20s
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window?.animator().alphaValue = 1
            }

            // 阶段 3 (t=0.40)：收门
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self = self, self.isTeleporting else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.74)) {
                    self.portalState.openness = 0
                }

                // 阶段 4 (t=0.60)：清理
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                    guard let self = self else { return }
                    self.portalWindow?.orderOut(nil)
                    self.isTeleporting = false
                    self.lastTeleportEndedAt = Date()
                }
            }
        }

        return true
    }

    /// patrol 进 .goingTo / .returning 第一帧时检查：target 是否在 zone 另一侧？
    /// 是 → 触发传送门跨过（成功返回 true，advancePatrol 应跳过本帧 moveToward）
    @discardableResult
    private func tryTeleportAcrossZoneForPatrol(targetWindowOrigin: NSPoint, on screen: NSScreen) -> Bool {
        guard let zone = notchAvoidZone(on: screen) else { return false }
        let clawdCx = positionX + windowSize.width / 2
        let targetCx = targetWindowOrigin.x + windowSize.width / 2
        let clawdLeft = clawdCx < zone.lowerBound
        let clawdRight = clawdCx > zone.upperBound
        let targetLeft = targetCx < zone.lowerBound
        let targetRight = targetCx > zone.upperBound
        guard (clawdLeft && targetRight) || (clawdRight && targetLeft) else {
            return false
        }
        // 直接传送到目标位置（patrol 的 target 已经是 window origin）
        return tryTeleport(toX: targetWindowOrigin.x, on: screen)
    }

    /// Clawd 头顶气泡的独立窗口 —— 透明、不接收点击，每 tick 跟随 Clawd 中心 x 对齐
    private func createBubbleWindow() {
        let w = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.bubbleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        w.level = HermesWindowLevel.dynamicIsland
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true          // 气泡不抢点击
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: ClawdWalkBubbleView(state: state))
        host.frame = NSRect(origin: .zero, size: Self.bubbleSize)
        host.autoresizingMask = [.width, .height]
        // 决策 #6：禁止 SwiftUI 反推 NSWindow setFrame
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        w.contentView = host
        bubbleWindow = w
    }

    // MARK: - 漫步主循环

    private func startWalkTimer() {
        walkTimer?.invalidate()
        lastTickAt = Date()
        walkTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isShown, let win = window, let screen = targetScreen() else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTickAt ?? now)
        lastTickAt = now

        // —— -2) 正在传送 —— 所有自动位移让位，位置由 startTeleport / completeTeleport 直接控制
        if isTeleporting {
            syncPortalWindow()
            syncBubbleWindow()
            return
        }

        // —— -1) 用户正在拖动 Clawd —— 一切自动逻辑让位，位置完全由 handleClawdDragChanged 控制
        if state.isBeingDragged {
            syncBubbleWindow()
            return
        }

        // —— 0) 气泡自动隐藏 ——
        if let hide = bubbleHideAt, now >= hide {
            state.bubbleVisible = false
            bubbleHideAt = nil
            // 显示完后立即定下一次冒泡时机
            nextBubbleAt = now.addingTimeInterval(randomBubbleInterval())
        }

        // —— 0.5) 桌面巡视：触发 / 推进 ——
        // patrol 进行中时跳过普通漫步逻辑（chase / pause / 撞墙），专注完成巡视
        if patrol != nil {
            advancePatrol(now: now, dt: dt, win: win, screen: screen)
            syncBubbleWindow()
            return
        }
        // patrol 未启动 + 到点 + 条件满足 → 开新一次（异步抓桌面图标）
        if let next = nextPatrolAt, now >= next, isHovering == false, pauseEndsAt == nil {
            nextPatrolAt = nil   // 防止并发触发
            startPatrol(screen: screen)
            // 不 return —— 让本 tick 继续走常规逻辑直到 patrol 真正切到 goingTo（异步几百 ms 后）
        }

        // —— 1) 鼠标距离 + chasing 状态切换 ——
        let mouseLoc = NSEvent.mouseLocation
        let clawdCx = positionX + windowSize.width / 2
        let clawdCy = walkY + windowSize.height / 2
        let dx = mouseLoc.x - clawdCx
        let dy = mouseLoc.y - clawdCy
        let dist = sqrt(dx * dx + dy * dy)

        if !isHovering, pauseEndsAt == nil {
            if !state.isChasing && dist < Self.chaseEnterDist {
                state.isChasing = true
                // 进入追逐时取消 pause 排程；50% 概率冒一句招呼
                nextPauseAt = nil
                if Bool.random() {
                    showBubble(text: pickQuote(from: ClawdQuotes.greetings), duration: 1.8)
                }
            } else if state.isChasing && dist > Self.chaseExitDist {
                state.isChasing = false
                // 恢复普通漫步节奏
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            }
        }

        // —— 2) 暂停态（仅非 chasing 时生效）——
        if !state.isChasing, let until = pauseEndsAt {
            if now >= until {
                pauseEndsAt = nil
                state.pose = .rest
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            } else {
                state.isWalking = false
                syncBubbleWindow()
                return
            }
        } else if !state.isChasing, !isHovering, let next = nextPauseAt, now >= next {
            pauseEndsAt = now.addingTimeInterval(Double.random(in: Self.pauseDurMin...Self.pauseDurMax))
            let roll = Int.random(in: 0..<4)
            switch roll {
            case 0:  state.pose = .lookLeft
            case 1:  state.pose = .lookRight
            default: state.pose = .armsUp   // 伸懒腰最常见，比较萌
            }
            state.isWalking = false
            syncBubbleWindow()
            return
        }

        // —— 3) hover：停 + 转头看鼠标方向 ——
        if isHovering {
            state.isWalking = false
            syncBubbleWindow()
            return
        }

        // —— 4) chasing：朝鼠标方向小跑，眼睛锁定鼠标 ——
        //
        // 视觉抖动修复：
        //   1) 鼠标距离 < 32pt 时进入"停留态" —— 站住不动 + 看着鼠标方向
        //      facing 完全不更新，避免反复翻转
        //   2) 移动态下 facing/direction 切换加滞回：|dx| 必须 > 12pt 才允许翻转
        //   3) pose 切换也加滞回：|dx| 必须 > 6pt 才允许换边
        //   4) 撞墙不再反向（普通漫步才反向），保持 chasing 方向避免远离鼠标
        if state.isChasing {
            let chaseStopDist: CGFloat = 32
            let facingHysteresis: CGFloat = 12
            let poseHysteresis: CGFloat = 6

            // 1) 停留态：鼠标很近就站住 + 看着鼠标方向（不再翻转身体）
            if dist < chaseStopDist {
                if abs(dx) > poseHysteresis {
                    setPoseLookingAt(worldRight: dx > 0)
                }
                state.isWalking = false
                syncBubbleWindow()
                return
            }

            // 1.5) 灵动岛避让 —— 鼠标在 zone 内 → 走到 zone 边停下不进；
            //      桌宠跟鼠标分布在 zone 两侧 → 触发传送门跨过。
            //      （avoid zone 仅 notch 屏存在；非 notch 屏 zone=nil 跳过整段）
            if let zone = notchAvoidZone(on: screen) {
                let clawdCx = positionX + windowSize.width / 2
                let mouseX = mouseLoc.x
                let mouseInZone = zone.contains(mouseX)
                let clawdLeftOfZone  = clawdCx < zone.lowerBound
                let clawdRightOfZone = clawdCx > zone.upperBound

                if mouseInZone {
                    // 鼠标停在灵动岛附近 —— 桌宠走到 zone 边外 6pt 处停下看着鼠标，不进 zone
                    let stopCx: CGFloat = clawdLeftOfZone ? (zone.lowerBound - 6)
                                        : clawdRightOfZone ? (zone.upperBound + 6)
                                        : clawdCx   // 已经在 zone 内（罕见，刚 spawn 时），原地不动
                    let stopX = stopCx - windowSize.width / 2
                    if abs(positionX - stopX) < 3 {
                        if abs(dx) > poseHysteresis {
                            setPoseLookingAt(worldRight: dx > 0)
                        }
                        state.isWalking = false
                        syncBubbleWindow()
                        return
                    }
                    // 朝 stopX 走，不越过
                    let wantDir: CGFloat = (stopX - positionX) >= 0 ? 1 : -1
                    direction = wantDir
                    state.facingRight = (wantDir > 0)
                    if abs(dx) > poseHysteresis {
                        setPoseLookingAt(worldRight: dx > 0)
                    }
                    let stepX = Self.walkSpeed * Self.chaseSpeedMul * direction * CGFloat(dt)
                    positionX += stepX
                    if (direction > 0 && positionX > stopX) || (direction < 0 && positionX < stopX) {
                        positionX = stopX
                    }
                    win.setFrameOrigin(NSPoint(x: positionX, y: walkY))
                    state.isWalking = true
                    syncBubbleWindow()
                    return
                }

                // 鼠标在 zone 另一侧 → 传送门跨过
                let mouseLeftOfZone  = mouseX < zone.lowerBound
                let mouseRightOfZone = mouseX > zone.upperBound
                if (clawdLeftOfZone && mouseRightOfZone) || (clawdRightOfZone && mouseLeftOfZone) {
                    // 跳到 zone 另一侧外 24pt 处刚好走出避让带
                    let targetCx: CGFloat = clawdLeftOfZone ? (zone.upperBound + 24)
                                                            : (zone.lowerBound - 24)
                    let targetX = targetCx - windowSize.width / 2
                    if tryTeleport(toX: targetX, on: screen) {
                        return
                    }
                    // 冷却中 → fallthrough 走 chasing 但下一帧 mouseInZone 判定会卡在 zone 边
                }
            }

            // 2) 移动态：facing/direction 切换必须 |dx| 跨过阈值才允许，避免抖动
            let wantDir: CGFloat = (dx >= 0) ? 1 : -1
            let shouldFlip = (state.facingRight  && dx < -facingHysteresis) ||
                             (!state.facingRight && dx >  facingHysteresis)
            if shouldFlip {
                direction = wantDir
                state.facingRight = (wantDir > 0)
            }
            // 3) pose 滞回更松（眼神跟着鼠标更敏感些）
            //    setPoseLookingAt 内会读取已更新过的 state.facingRight，
            //    所以即使刚翻完身，眼神方向也是对的
            if abs(dx) > poseHysteresis {
                setPoseLookingAt(worldRight: dx > 0)
            }

            let delta = Self.walkSpeed * Self.chaseSpeedMul * direction * CGFloat(dt)
            positionX += delta
            // 4) chasing 撞墙：只 clamp 位置，不反向（普通漫步才反向）
            let visible = screen.visibleFrame
            let leftBound  = visible.minX + Self.edgeMargin
            let rightBound = visible.maxX - windowSize.width - Self.edgeMargin
            positionX = max(leftBound, min(rightBound, positionX))

            win.setFrameOrigin(NSPoint(x: positionX, y: walkY))
            // chasing 时也是"在走路"，让官方走路动画播放
            state.isWalking = true
            syncBubbleWindow()
            return
        }

        // —— 5) 正常漫步 ——
        state.pose = .rest
        state.isWalking = true
        let delta = Self.walkSpeed * direction * CGFloat(dt)
        positionX += delta

        let visible = screen.visibleFrame
        let leftBound  = visible.minX + Self.edgeMargin
        let rightBound = visible.maxX - windowSize.width - Self.edgeMargin
        if positionX < leftBound {
            positionX = leftBound
            direction = 1
            state.facingRight = true
            maybeBumpQuote()
        } else if positionX > rightBound {
            positionX = rightBound
            direction = -1
            state.facingRight = false
            maybeBumpQuote()
        }

        // 灵动岛 zone：普通漫步走到边界 → 优先尝试触发传送门嗖到另一侧继续走；
        // 冷却中（3s 内）回退到软墙反向，避免桌宠卡在 zone 边死磕
        if let zone = notchAvoidZone(on: screen) {
            let cx = positionX + windowSize.width / 2
            if direction > 0 && cx >= zone.lowerBound && cx < zone.upperBound {
                // 朝右走撞到 zone 左边 → 传送到 zone 右边外 24pt 继续朝右
                let targetCx = zone.upperBound + 24
                let targetX = targetCx - windowSize.width / 2
                if tryTeleport(toX: targetX, on: screen) {
                    return
                }
                // 冷却中 → 反向走
                positionX = zone.lowerBound - windowSize.width / 2
                direction = -1
                state.facingRight = false
            } else if direction < 0 && cx <= zone.upperBound && cx > zone.lowerBound {
                // 朝左走撞到 zone 右边 → 传送到 zone 左边外 24pt 继续朝左
                let targetCx = zone.lowerBound - 24
                let targetX = targetCx - windowSize.width / 2
                if tryTeleport(toX: targetX, on: screen) {
                    return
                }
                positionX = zone.upperBound - windowSize.width / 2
                direction = 1
                state.facingRight = true
            }
        }

        win.setFrameOrigin(NSPoint(x: positionX, y: walkY))

        // —— 6) 普通漫步时随机冒泡 ——
        if state.bubbleVisible == false, let nb = nextBubbleAt, now >= nb {
            showBubble(text: pickQuote(from: ClawdQuotes.contextualBucket()), duration: 2.4)
        }

        syncBubbleWindow()
    }

    // MARK: - 桌面巡视：调度 + 推进

    /// 安排下次巡视时间 —— 设置关闭时不排
    private func scheduleNextPatrolIfEnabled(firstTime: Bool) {
        guard let vm = viewModel, vm.clawdDesktopPatrolEnabled else {
            nextPatrolAt = nil
            return
        }
        let range = firstTime ? Self.patrolFirstDelayRange : Self.patrolIntervalRange
        nextPatrolAt = Date().addingTimeInterval(Double.random(in: range))
    }

    /// 触发一次桌面巡视：异步抓桌面图标快照，挑一个能"走得到"的目标，切到 goingTo 阶段
    private func startPatrol(screen: NSScreen) {
        Task { @MainActor in
            let icons = await DesktopIconReader.shared.snapshot()
            // 仍要再次确认 controller 还在线（用户切走 mode / 时间过得久）
            guard self.isShown, self.patrol == nil else { return }
            guard !icons.isEmpty else {
                // 没图标 / 没权限 —— 静默放弃，重排下一次
                self.scheduleNextPatrolIfEnabled(firstTime: false)
                return
            }
            // 只挑桌面**可视区**内的图标（visibleFrame 已扣掉菜单栏）
            let visible = screen.visibleFrame
            let candidates = icons.filter { icon in
                visible.contains(icon.position)
                // 离 Clawd 当前位置太近的不挑（≤ 80pt，无趣）
                && abs(icon.position.x - (self.positionX + windowSize.width / 2)) > 80
            }
            guard let pick = candidates.randomElement() ?? icons.randomElement() else {
                self.scheduleNextPatrolIfEnabled(firstTime: false)
                return
            }
            let target = self.targetWindowOriginNextTo(icon: pick, screen: screen)
            self.patrol = .goingTo(target: target, icon: pick)
            self.patrolWatchdogAt = Date().addingTimeInterval(Self.patrolWatchdog)
            // 普通漫步的"暂停"和 chasing 都让位给巡视
            self.pauseEndsAt = nil
            self.nextPauseAt = nil
            self.state.isChasing = false
        }
    }

    /// 推进巡视状态机
    private func advancePatrol(now: Date, dt: TimeInterval, win: NSWindow, screen: NSScreen) {
        // 看门狗：超时 → 强制回菜单栏（防 Finder 卡死 / AI 长挂）
        if let wd = patrolWatchdogAt, now >= wd {
            sniffAITask?.cancel()
            sniffAITask = nil
            let home = NSPoint(x: notchCenterX(on: screen) - windowSize.width / 2,
                               y: walkBaseY(on: screen))
            patrol = .returning(target: home)
            patrolWatchdogAt = now.addingTimeInterval(Self.patrolWatchdog)
        }

        switch patrol {
        case .goingTo(let target, let icon):
            // 跨灵动岛 → 走传送门一步到位（成功后下一帧 isTeleporting=true 拦 tick）
            if tryTeleportAcrossZoneForPatrol(targetWindowOrigin: target, on: screen) {
                return
            }
            if moveToward(target: target, dt: dt, win: win) {
                // 到了 → 切到 sniffing，触发 AI 短评
                let duration = Double.random(in: Self.sniffDurationRange)
                patrol = .sniffing(icon: icon, until: now.addingTimeInterval(duration))
                state.isWalking = false
                state.pose = .armsUp   // 站直伸手 = 嗅 / 凑近看
                requestSniffQuote(for: icon)
            }

        case .sniffing(let icon, let until):
            state.isWalking = false
            // 嗅期间偶尔摆头看图标方向（poseHysteresis 同 chasing 那套，但单次）
            if Int.random(in: 0..<60) == 0 {
                state.pose = (state.pose == .armsUp) ? .lookRight : .armsUp
            }
            _ = icon
            if now >= until {
                // 嗅完，回菜单栏
                let home = NSPoint(x: notchCenterX(on: screen) - windowSize.width / 2,
                                   y: walkBaseY(on: screen))
                patrol = .returning(target: home)
                state.pose = .rest
                state.bubbleVisible = false   // 嗅完气泡也收起，干净
                bubbleHideAt = nil
                patrolWatchdogAt = now.addingTimeInterval(Self.patrolWatchdog)
            }

        case .returning(let target):
            // 返回菜单栏路径如果穿越灵动岛 → 也走传送门
            if tryTeleportAcrossZoneForPatrol(targetWindowOrigin: target, on: screen) {
                return
            }
            if moveToward(target: target, dt: dt, win: win) {
                // 回到菜单栏 —— 结束巡视，恢复普通漫步
                patrol = nil
                patrolWatchdogAt = nil
                state.pose = .rest
                state.isWalking = false
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
                scheduleNextPatrolIfEnabled(firstTime: false)
            }

        case .none:
            break
        }
    }

    /// 朝 target 移动一帧。到达（距离 < patrolArriveDist）→ 返回 true，调用方切下一阶段
    private func moveToward(target: NSPoint, dt: TimeInterval, win: NSWindow) -> Bool {
        let curX = positionX
        let curY = walkY
        let dx = target.x - curX
        let dy = target.y - curY
        let dist = sqrt(dx * dx + dy * dy)
        if dist < Self.patrolArriveDist {
            positionX = target.x
            walkY = target.y
            win.setFrameOrigin(NSPoint(x: positionX, y: walkY))
            return true
        }
        let step = Self.patrolSpeed * CGFloat(dt)
        let nx = curX + dx / dist * step
        let ny = curY + dy / dist * step
        positionX = nx
        walkY = ny
        win.setFrameOrigin(NSPoint(x: positionX, y: walkY))
        // 朝向 + 走路动画
        state.facingRight = (dx >= 0)
        state.isWalking = true
        return false
    }

    /// 算 Clawd 站到图标侧边时窗口左下角应当的位置（NSScreen 坐标）。
    /// 优先站右侧；右侧出屏 → 站左侧
    private func targetWindowOriginNextTo(icon: DesktopIcon, screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let h = windowSize.height
        let w = windowSize.width
        // 假设 icon.position 是图标 top-left 的 NSScreen 坐标
        // 视觉中心 ≈ icon.position 偏下 32pt 左右（图标 + 标签）
        let iconCenterY = icon.position.y - 32
        let clawdY = max(visible.minY + 4, iconCenterY - h / 2)

        // 默认站右侧
        var clawdX = icon.position.x + Self.iconSideOffset
        if clawdX + w > visible.maxX - 4 {
            // 右侧出屏 → 改站左侧
            clawdX = icon.position.x - Self.iconSideOffset - w
        }
        // 再裁一次（图标在屏幕最左侧时 fallback）
        clawdX = min(max(clawdX, visible.minX + 4), visible.maxX - w - 4)
        return NSPoint(x: clawdX, y: clawdY)
    }

    /// 触发一次 AI 短评（异步走 Hermes）—— 失败/无 key 用本地兜底
    private func requestSniffQuote(for icon: DesktopIcon) {
        // 先用本地兜底立刻显示一句，AI 回来再覆盖（避免气泡空着）
        showBubble(text: localFallbackQuote(for: icon), duration: 5.5)
        guard let vm = viewModel else { return }

        sniffAITask?.cancel()
        let prompt = sniffPrompt(for: icon)
        sniffAITask = Task { @MainActor [weak self] in
            var collected = ""
            do {
                // 强制走 Hermes（用户明确要求轻量），不写 ActivityStore（不污染早报数据）
                let stream = vm.streamOneShotAsk(
                    prompt: prompt,
                    modeOverride: .hermes,
                    recordToActivity: false
                )
                for try await chunk in stream {
                    try Task.checkCancellation()
                    collected += chunk
                    // 多数模型一次性吐 1~3 段，不流式显示，攒齐再展示
                }
            } catch {
                return   // 失败保留本地兜底文案
            }
            let trimmed = collected
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            // 限长：≤14 字（防止模型啰嗦溢出气泡）
            guard let self = self, self.isShown else { return }
            // 必须仍处于 sniffing 才覆盖气泡（用户中途切走 / 巡视已结束 → 不再 showBubble）
            if case .sniffing(let cur, _) = self.patrol, cur.name == icon.name, !trimmed.isEmpty {
                let final = trimmed.count > 14 ? String(trimmed.prefix(14)) : trimmed
                self.showBubble(text: final, duration: 4.5)
            }
        }
    }

    /// 拼给 Hermes 的 prompt —— 严格要求短回复。
    /// 角色名 / 表情符号根据当前桌宠形象切换，让 AI 短评的口吻跟视觉一致
    private func sniffPrompt(for icon: DesktopIcon) -> String {
        let kind = icon.isFolder ? "文件夹" : "文件"
        let persona: String
        switch state.visual {
        case .clawd:    persona = "Clawd 🦞"
        case .cloud:    persona = "云朵小精灵 ☁️"
        case .fox:      persona = "九尾狐 fomo 🦊"
        case .horse:    persona = "金黄小马 🐴"
        case .terminal: persona = "终端小精灵 💻"
        }
        return """
        你是桌面宠物 \(persona)，正在用户桌面闲逛，发现了一个\(kind)。
        请用**不超过 10 个汉字**的一句话，用轻松、好奇、可爱的口吻评论它的名字。
        不要加引号、不要 emoji、不要解释、不要省略号。
        \(kind)名: \(icon.name)
        """
    }

    /// 本地兜底文案 —— Hermes 没配 / 网络挂 / 限流时用。
    /// 按当前桌宠形象给不同口吻：Clawd 用嗅嗅 / 螃蟹腔，小马用哒哒 / 嗅嗅，云朵用飘飘 / 看看
    private func localFallbackQuote(for icon: DesktopIcon) -> String {
        let folderQuotes: [String]
        let fileQuotes: [String]
        switch state.visual {
        case .clawd:
            folderQuotes = ["翻翻这个~", "里面装啥?", "嗯…文件夹", "看着挺鼓", "藏宝盒?"]
            fileQuotes   = ["这名字有意思", "什么文件呢?", "嗅嗅~", "瞄一眼", "看着挺新"]
        case .cloud:
            folderQuotes = ["飘过看看~", "里面有啥?", "云遮着了", "好奇好奇", "藏着什么?"]
            fileQuotes   = ["飘着瞧瞧~", "新东西?", "嗯～", "看看名字", "挺有意思"]
        case .fox:
            folderQuotes = ["嗯…有点东西", "里面藏什么", "嗅嗅~", "月光照过", "九尾扫过~"]
            fileQuotes   = ["这名字…", "好奇好奇", "嗯～看看", "瞄一眼", "新的耶"]
        case .horse:
            folderQuotes = ["哒哒~ 这个", "里面装啥?", "嗅一嗅~", "挺有趣", "进去看看?"]
            fileQuotes   = ["哒哒哒~", "新东西!", "嗅嗅看", "瞄一眼", "听过这名"]
        case .terminal:
            folderQuotes = ["ls 一下?", "cd 进去看", "scan 中…", "$ stat .", "目录树呢"]
            fileQuotes   = ["cat 试试?", "$ file .", "扫描中…", "新文件!", "看看 metadata"]
        }
        let pool = icon.isFolder ? folderQuotes : fileQuotes
        return pool.randomElement() ?? "嗅嗅~"
    }

    // MARK: - 用户拖动 Clawd（Clawd → 文件 方向）
    //
    // 跟"文件 → Clawd"（吃文件送 AI 深度处理，见 handleFileDropped）行为完全不同：
    // 用户用鼠标拽起 Clawd 移到桌面图标上 → 松手时如果落在图标附近 → 嗅一下（armsUp + AI 短评气泡），
    // 嗅完自动回菜单栏。未命中图标 → 直接走回菜单栏

    /// 拖动起点的 NSScreen 坐标缓存（窗口左下角 origin）
    private var dragStartOriginX: CGFloat = 0
    private var dragStartOriginY: CGFloat = 0
    /// 拖动期间是否已经锁定过朝向。
    /// 设计：首次明确移动方向 → 锁定 facingRight，整个拖动期间不再翻转。
    /// 之前用 translation.width 累计判断会让"往右拖一下回拖"反复镜像抖动，视觉很乱
    private var dragFacingLocked = false

    private func handleClawdDragStarted() {
        guard isShown else { return }
        dragStartOriginX = positionX
        dragStartOriginY = walkY
        dragFacingLocked = false
        state.isBeingDragged = true
        state.isWalking = false
        state.pose = .armsUp           // 被拎起来 → 举手姿势
        // 自动 Patrol / 暂停 / chasing / 气泡 全部让位
        sniffAITask?.cancel()
        sniffAITask = nil
        patrol = nil
        patrolWatchdogAt = nil
        pauseEndsAt = nil
        nextPauseAt = nil
        state.isChasing = false
        state.bubbleVisible = false
        bubbleHideAt = nil
        Haptic.tap(.alignment)
    }

    private func handleClawdDragChanged(translation: CGSize) {
        guard state.isBeingDragged, let win = window else { return }
        // SwiftUI translation y 向下为正；NSScreen y 向上为正，所以减去 height
        let nx = dragStartOriginX + translation.width
        let ny = dragStartOriginY - translation.height
        positionX = nx
        walkY = ny
        win.setFrameOrigin(NSPoint(x: nx, y: ny))
        // 朝向：首次明确移动方向（|dx| > 8pt）→ 锁定，整个拖动期间不再翻转。
        // 这样消除"拖动期间镜像反复翻转 / sprite 看起来跟鼠标方向反"的视觉抖动
        if !dragFacingLocked, abs(translation.width) > 8 {
            state.facingRight = translation.width > 0
            dragFacingLocked = true
        }
    }

    private func handleClawdDragEnded(translation: CGSize) {
        guard state.isBeingDragged else { return }
        state.isBeingDragged = false

        // 松手位置：Clawd 中心 NSScreen 坐标
        let centerX = positionX + windowSize.width / 2
        let centerY = walkY + windowSize.height / 2
        let clawdCenter = NSPoint(x: centerX, y: centerY)

        // 异步抓桌面图标（命中缓存 → 立即；缓存过期 → ~200ms osascript）
        Task { @MainActor [weak self] in
            guard let self = self, self.isShown, !self.state.isBeingDragged else { return }
            let icons = await DesktopIconReader.shared.snapshot()
            // 二次确认：用户可能又开始新一轮拖动 / Clawd 已下线
            guard self.isShown, !self.state.isBeingDragged else { return }

            // 命中阈值：60pt 内算"扔到了图标上"
            let matchDist: CGFloat = 60
            let matchDistSq = matchDist * matchDist
            var best: DesktopIcon? = nil
            var bestDistSq: CGFloat = .greatestFiniteMagnitude
            for icon in icons {
                let dx = icon.position.x - clawdCenter.x
                let dy = icon.position.y - clawdCenter.y
                let d2 = dx * dx + dy * dy
                if d2 < bestDistSq {
                    bestDistSq = d2
                    best = icon
                }
            }

            if let hit = best, bestDistSq < matchDistSq {
                // 命中 → 直接进 sniffing（复用 patrol 状态机的嗅 + 自动 returning 流程）
                let duration = Double.random(in: Self.sniffDurationRange)
                self.patrol = .sniffing(icon: hit, until: Date().addingTimeInterval(duration))
                self.patrolWatchdogAt = Date().addingTimeInterval(Self.patrolWatchdog)
                self.state.pose = .armsUp
                self.state.isWalking = false
                self.requestSniffQuote(for: hit)
                Haptic.tap(.levelChange)
            } else {
                // 未命中 → 走回菜单栏（用 patrol .returning 复用走过去的位移逻辑）
                if let screen = self.targetScreen() {
                    let home = NSPoint(
                        x: self.notchCenterX(on: screen) - windowSize.width / 2,
                        y: self.walkBaseY(on: screen)
                    )
                    self.patrol = .returning(target: home)
                    self.patrolWatchdogAt = Date().addingTimeInterval(Self.patrolWatchdog)
                }
                self.state.pose = .rest
            }
        }
    }

    // MARK: - 气泡

    private func showBubble(text: String, duration: TimeInterval) {
        guard !text.isEmpty else { return }
        state.bubbleText = text
        state.bubbleVisible = true
        bubbleWindow?.orderFront(nil)
        bubbleHideAt = Date().addingTimeInterval(duration)
    }

    // MARK: - Wave B 外部接口（IntentInstantFeedback 调用）

    /// 桌宠当前是否在屏幕上展示（IntentInstantFeedback 路由用：visible 走气泡，hidden 走灵动岛）
    var isPresentingVisible: Bool { isShown }

    /// 给桌宠头顶冒一句"当下感知"短气泡（B 阶段反馈通道）。
    /// 文字应该已经过 IntentCopyWriter 截断到 12 字以内
    func showIntentBubble(text: String, duration: TimeInterval = 2.5) {
        guard isShown else { return }
        showBubble(text: text, duration: duration)
    }

    /// 撞墙时 30% 概率冒一句"哎呀"
    private func maybeBumpQuote() {
        guard state.bubbleVisible == false else { return }
        guard Int.random(in: 0..<10) < 3 else { return }
        showBubble(text: pickQuote(from: ClawdQuotes.bumps), duration: 1.4)
    }

    /// 随机间隔（45-110s）—— 加一点抖动避免出现节律感
    private func randomBubbleInterval() -> TimeInterval {
        Double.random(in: 45...110)
    }

    /// 避免连续冒同一句话；同时随机选时段相关的
    private func pickQuote(from pool: [String]) -> String {
        let filtered = pool.filter { $0 != lastBubbleQuote }
        let pick = (filtered.randomElement() ?? pool.first) ?? "👀"
        lastBubbleQuote = pick
        return pick
    }

    /// 把气泡窗口对齐到 Clawd 中线上方 4pt
    private func syncBubbleWindow() {
        guard let bw = bubbleWindow else { return }
        let cx = positionX + windowSize.width / 2
        let bx = cx - Self.bubbleSize.width / 2
        let by = walkY + windowSize.height + 2
        bw.setFrameOrigin(NSPoint(x: bx, y: by))
    }

    // MARK: - 点击 / hover

    private func handleSingleTap() {
        triggerJump()
        // jump 动画跑完一拍再开聊天，戳到的反馈更明确
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
        }
    }

    private func handleDoubleTap() {
        // 双击 = 单击：开聊天。
        // 不做跨 mode 切换 —— 桌宠出现时本来就在对应 mode（Claude 出 Clawd / directAPI 出云朵），
        // 双击强切到 Claude 反而让在线 AI 用户莫名跳模式（用户 2026-05-16 反馈禁掉）
        triggerJump()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
        }
    }

    /// 被戳一下的反馈：state.isJumping=true 触发 SwiftUI spring 跳起 ~10pt，
    /// 280ms 后归位（spring 动画自带回弹）
    private func triggerJump() {
        state.isJumping = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            state.isJumping = false
        }
    }

    // MARK: - 吃文件 🍞

    /// 文件拖到 Clawd 上面（未松手）时：站住 + 抬头看 + 冒"嗯?"气泡
    private func handleDragStateChanged(entering: Bool) {
        guard isShown else { return }
        if entering {
            // 拖入：暂停游走，兴奋举手（armsUp 在所有 facing 下视觉对称），冒一句"嗯?"
            pauseEndsAt = Date().addingTimeInterval(60)   // 长效暂停直到 drop 或离开
            state.isWalking = false
            state.pose = .armsUp
            if !state.bubbleVisible {
                showBubble(text: "嗯？给我吃的？", duration: 30)   // 由 exit / drop 提前结束
            }
        } else {
            // 拖出：恢复漫步
            pauseEndsAt = nil
            nextPauseAt = Date().addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            state.bubbleVisible = false
            bubbleHideAt = nil
        }
    }

    /// 收到 drop —— 把文件投喂给 Clawd → AI 立即处理。
    /// 流程：嚼嚼气泡 → 鼓胀 → 摆头 → 缩小消失 → 附件加入 ChatViewModel → 自动发送 + 打开聊天窗
    private func handleFileDropped(_ url: URL) {
        guard let vm = viewModel, !state.isEating else { return }
        state.isEating = true

        let fileName = url.lastPathComponent
        let shortName = (fileName.count <= 14) ? fileName : (String(fileName.prefix(12)) + "…")

        // 类型识别：图片走 pendingImages，其余统一走 documentPath（Claude 模式必须）
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic", "heif"]
        let isImage = imageExts.contains(url.pathExtension.lowercased())
        if isImage, let data = try? Data(contentsOf: url) {
            vm.addPendingImage(data)
        } else {
            vm.attachDocumentPath(url)
        }

        // 嚼嚼气泡（覆盖之前的"嗯?"）
        showBubble(text: "嚼嚼… \(shortName)", duration: 2.0)

        Task { @MainActor in
            // 1) 鼓胀 200ms（"咕嘟"一口吃下）
            state.eatScale = 1.18
            try? await Task.sleep(nanoseconds: 200_000_000)
            // 2) 回到正常 150ms
            state.eatScale = 1.0
            try? await Task.sleep(nanoseconds: 150_000_000)
            // 3) 嚼嚼期：左右摆头 3 次（750ms）
            for _ in 0..<3 {
                state.pose = .lookLeft
                try? await Task.sleep(nanoseconds: 125_000_000)
                state.pose = .lookRight
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
            state.pose = .rest

            // 5) 注入默认 prompt —— **图片 vs 文件不同 prompt**
            //   - 图片：让模型直接描述图（之前误用文件版 prompt 会让模型去 Read 工具找文件，找不到报"找不到"）
            //   - 文件：让模型按路径 Read
            if vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if isImage {
                    vm.inputText = "这张图里是什么？请帮我看看"
                } else {
                    vm.inputText = "请帮我看看这个文件「\(fileName)」是什么 / 主要内容是什么"
                }
            }

            // 6) 收尾策略 —— **图片 + directAPI** 走特殊路径：
            //   不缩 0 消失也不 hideImmediately，让云朵留在桌面戴眼镜（vision 切换）。
            //   sendMessage 内会 post wear glasses 通知设 glassesPendingUntil，
            //   evaluateState 看到 pending 会强制保持显示，戴完后自然回家
            let shouldStayForGlasses = isImage && vm.agentMode == .directAPI
            if !shouldStayForGlasses {
                // 缩到 0 消失（450ms）
                state.eatScale = 0
                try? await Task.sleep(nanoseconds: 450_000_000)
            }

            vm.sendMessage()
            NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)

            if shouldStayForGlasses {
                // 留在桌面 → reset eating 状态，让戴眼镜动画接管
                state.isEating = false
                state.eatScale = 1.0
                state.pose = .rest
            } else {
                // 文件 / Claude 模式：保持原行为，立刻消失
                hideImmediately()
            }
        }
    }

    /// 让 Clawd 视觉上看向**世界坐标**的某一侧 —— 自动处理 facing 镜像。
    ///
    /// 关键认识：pose 的 lookLeft/lookRight 是 **sprite 局部坐标**（不镜像态下的方向）。
    /// 当 facingRight=false 时整个 sprite 走 scaleEffect(x:-1) 镜像 →
    /// pose=lookRight 镜像后视觉变成"看左"。
    /// 所以要让眼睛看向世界坐标的鼠标方向，pose 选择必须根据当前 facing 反向。
    private func setPoseLookingAt(worldRight: Bool) {
        if state.facingRight {
            state.pose = worldRight ? .lookRight : .lookLeft
        } else {
            // sprite 镜像态：pose 方向跟视觉方向相反
            state.pose = worldRight ? .lookLeft : .lookRight
        }
    }

    /// 紧急下线（吃完文件 / 异常情况）—— 跳过 fade-out 飞回岛动画，直接 orderOut
    private func hideImmediately() {
        isShown = false
        walkTimer?.invalidate()
        walkTimer = nil
        lastTickAt = nil
        pauseEndsAt = nil
        state.isChasing = false
        state.isEating = false
        state.eatScale = 1.0
        state.pose = .rest
        state.bubbleVisible = false
        state.bubbleText = ""
        state.spriteAnimated = false   // 隐藏 = 关 sprite 内部 TimelineView
        nextBubbleAt = nil
        bubbleHideAt = nil
        patrol = nil
        nextPatrolAt = nil
        patrolWatchdogAt = nil
        sniffAITask?.cancel()
        sniffAITask = nil
        state.isBeingDragged = false
        bubbleWindow?.orderOut(nil)
        window?.orderOut(nil)
    }

    private func handleHoverChange(_ hovering: Bool) {
        isHovering = hovering
        guard hovering else {
            state.pose = .rest
            return
        }
        // hover 时根据鼠标在窗口的相对位置让眼睛看向鼠标（自动处理 facing 镜像）
        guard let win = window else { return }
        let mouseLoc = NSEvent.mouseLocation
        let frame = win.frame
        let relX = mouseLoc.x - frame.midX
        setPoseLookingAt(worldRight: relX >= 0)
    }
}

// MARK: - Observable state

@Observable
@MainActor
final class ClawdWalkState {
    var pose: ClawdPose = .rest
    /// 朝向：默认朝右；走左时 facingRight=false，sprite 用 scaleX(-1) 镜像
    var facingRight: Bool = true
    /// 被点击时短暂跳起（spring 弹回），表达"嘿，戳到我啦"
    var isJumping: Bool = false
    /// 头顶气泡当前文字
    var bubbleText: String = ""
    /// 气泡是否显示
    var bubbleVisible: Bool = false
    /// 鼠标追逐态 —— Clawd 朝鼠标方向小跑（速度 1.5x，眼睛锁定鼠标）
    var isChasing: Bool = false
    /// 正在"吃"拖入的文件 —— 鼓胀 → 嚼嚼 → 缩小消失整个流程
    var isEating: Bool = false
    /// 吃东西时身体缩放：1.0 → 1.15（鼓胀）→ 1.0 → 0（缩小消失）。
    /// 普通态保持 1.0
    var eatScale: CGFloat = 1.0
    /// 是否正在走路 —— 让 ClawdView 内部播放官方走路动画（腿对角交替、身体 bob、手臂摆）
    var isWalking: Bool = false
    /// 用户正在用鼠标拖动 Clawd —— 用于视觉反馈（轻微放大 + 优先级最高的 armsUp pose），
    /// 也让 ClawdWalkController.tick 跳过自动位移，避免手势 / tick 双写打架
    var isBeingDragged: Bool = false

    /// 当前要渲染哪一种像素宠物。Controller 根据 agentMode 设置：
    /// claudeCode → .clawd（橙色螃蟹）；directAPI → .cloud（indigo 云朵）
    var visual: PetVisualKind = .clawd

    /// sprite TimelineView 是否启用 —— 桌宠在屏幕外 / orderOut 后仍占 SwiftUI 子树，
    /// 不关掉的话 ClawdView/HorseView/CloudPetView/TerminalView 内部 60fps TimelineView
    /// 会一直跑空转（v1.2.9 CPU 高负载主因之一：sample 抓到隐藏 NSWindow 的 sprite 还在 draw）。
    /// Controller 在 show 时置 true，stopAndHide 完成 orderOut 后置 false。
    var spriteAnimated: Bool = false

    /// Wave A1 实时存在感：每次 UserIntentRecorder 落库一条意图就 +1，
    /// ClawdWalkView 监听数值变化触发"瞥一眼"动画（rotation 摆头 + 白色 flash）。
    /// 用 Int 而非 Bool / Date 是为了让 .onChange 准确捕获每次触发（同值不触发）
    var glancePulse: Int = 0
}

/// 桌面漫步支持的像素宠物视觉。
/// - clawd: 橙色螃蟹（Claude Code mode）
/// - cloud: indigo 云朵（在线 AI / directAPI mode，自动戴眼镜切 vision）
/// - horse: 金黄小马（Hermes Gateway mode，飞马 Pegasus 形象）
/// - terminal: 终端窗口（Codex mode，macOS 风格 Terminal.app + 小腿）
enum PetVisualKind {
    case clawd
    case cloud
    case fox        // OpenClaw mode 的 fomo 九尾狐
    case horse
    case terminal
}

// MARK: - File Drop View

/// 透明 NSView，注册接受文件 URL 拖放 —— 点击事件穿透到下方的 NSHostingView（hitTest=nil），
/// 仅在 dragging 流程中拦截事件
final class FileDropView: NSView {
    var onFileDropped: ((URL) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    /// 不接收鼠标事件，让 SwiftUI 的 onTapGesture / onHover 正常工作
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragStateChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragStateChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragStateChanged?(false)
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let first = urls.first else { return false }
        onFileDropped?(first)
        return true
    }
}

// MARK: - 台词池

/// Clawd 心情台词 —— 按情境分组，让出现时机有上下文
fileprivate enum ClawdQuotes {
    /// 普通漫步时随机冒
    static let idle = ["在散步~", "悠闲~", "👀", "看屏幕外", "今天怎么样?", "好像很闲?", "嗯哼~"]
    /// 早上 6-10 点
    static let morning = ["早安~", "新的一天 ☀️", "起这么早?", "咖啡了吗?"]
    /// 深夜 22-2 点
    static let lateNight = ["该睡啦~", "夜猫子 🌙", "再不睡眼睛会肿…", "明天还要早起呢"]
    /// 鼠标靠近时的招呼
    static let greetings = ["嗨~", "找我吗?", "诶?", "👋", "回来啦?", "在这呢"]
    /// 撞到屏幕边缘
    static let bumps = ["哎呀", "...", "走错了", "啊"]

    /// 按当前时段返回台词池（早上加 morning，深夜加 lateNight，其余只用 idle）
    static func contextualBucket() -> [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        if (6...10).contains(hour) { return morning + idle }
        if hour >= 22 || hour <= 2 { return lateNight + idle }
        return idle
    }
}

// MARK: - SwiftUI View

/// 桌面漫步 Clawd 的视图 —— 复用 ClawdView 的像素渲染
struct ClawdWalkView: View {
    @Bindable var state: ClawdWalkState
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onHoverChange: (Bool) -> Void
    /// 用户按住 Clawd 开始拖动（>= 4pt 偏移）
    var onDragStarted: () -> Void = {}
    /// 拖动中 —— translation 是相对手势起点的 SwiftUI 偏移（y 向下为正）
    var onDragChanged: (CGSize) -> Void = { _ in }
    /// 松手 —— translation 是最终累计偏移
    var onDragEnded: (CGSize) -> Void = { _ in }

    @State private var dragStarted = false
    /// 桌面漫步的 CloudPet 同步戴眼镜（跟灵动岛 CloudPetIslandSprite 同款动画）
    @State private var glassesProgress: Double = 0
    @State private var glassesHideTask: Task<Void, Never>?

    // MARK: - Wave A1 glance 动画
    /// 瞥一眼时短暂摆头的旋转角（0 → 6° → 0），由 state.glancePulse 变化触发
    @State private var glanceRotation: Double = 0
    /// 瞥一眼时身上闪一下的白色 alpha（0 → 0.28 → 0），用 plusLighter 混合给"灯一闪"的感觉
    @State private var glanceFlash: Double = 0
    @State private var glanceTask: Task<Void, Never>?

    /// 全局调色板存储 —— @Observable，用户改色后此 View 自动 invalidate 重渲染
    @State private var paletteStore = PetPaletteStore.shared

    /// 桌宠大小缩放档位（SettingsView 改了立刻生效）
    @AppStorage(PetWalkSizeScale.storageKey) private var sizeScale: Double = PetWalkSizeScale.default

    /// Clawd 像素高度 —— 基础 30pt × scale 档位
    private var clawdHeight: CGFloat { 30 * CGFloat(sizeScale) }

    /// 当前桌宠形象对应的调色板（state.visual → AgentMode → palette）
    private var currentPalette: PetPalette {
        switch state.visual {
        case .clawd:    return paletteStore.palette(for: .claudeCode)
        case .cloud:    return paletteStore.palette(for: .directAPI)
        case .fox:      return paletteStore.palette(for: .openclaw)
        case .horse:    return paletteStore.palette(for: .hermes)
        case .terminal: return paletteStore.palette(for: .codex)
        }
    }

    var body: some View {
        ZStack {
            // 按当前宠物种类切渲染。两种 sprite 应用同一套 scale/offset/animation modifier，
            // 保证 walk/jump/drag/facing 等手势行为视觉一致。
            Group {
                let palette = currentPalette
                // 桌宠隐藏时（orderOut 后 spriteAnimated=false），sprite 切静态帧，
                // sprite 内部 TimelineView 不再 60fps 空转
                let anim = state.spriteAnimated
                switch state.visual {
                case .clawd:
                    // 把 state.isWalking 传给 ClawdView，让它内部播放官方走路动画
                    // （4 腿对角交替、身体 bob、手臂上下摆 —— 这些是 SVG 原版 keyframe，
                    // 不再用 SwiftUI 外层 bobOffset 重复模拟）
                    ClawdView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking,
                              palette: palette, animated: anim)
                case .cloud:
                    CloudPetView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking,
                                 glassesProgress: glassesProgress, palette: palette, animated: anim)
                case .fox:
                    // OpenClaw mode 的 fomo 九尾狐桌宠（PR-B）
                    FomoView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking,
                             palette: palette, animated: anim)
                case .horse:
                    // 金黄小马 —— trot 步态 + 鬃毛尾巴飘动由 HorseView 内部自驱
                    HorseView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking,
                              palette: palette, animated: anim)
                case .terminal:
                    // 终端窗口 —— 光标闪烁 + 代码行抖动由 TerminalView 内部自驱
                    // isWorking 暂时跟 isWalking 联动（漫步态 = 在敲码氛围）
                    TerminalView(pose: state.pose, height: clawdHeight,
                                 isWalking: state.isWalking, isWorking: state.isWalking,
                                 palette: palette, animated: anim)
                }
            }
            // 朝向 + 吃东西时的整体缩放（鼓胀 / 缩小消失）合到一个 scaleEffect
            // 被拖动时整体放大 1.08，给"我被拎起来啦"的视觉反馈
            .scaleEffect(x: (state.facingRight ? 1 : -1) * state.eatScale * (state.isBeingDragged ? 1.08 : 1),
                         y: state.eatScale * (state.isBeingDragged ? 1.08 : 1),
                         anchor: .bottom)
            // jump 优先级最高 → 戳一下时整体跳起 -10pt
            .offset(y: state.isJumping ? -10 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: state.isJumping)
            .animation(.easeInOut(duration: 0.18), value: state.facingRight)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: state.eatScale)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: state.isBeingDragged)
            // Wave A1 glance：摆头 + 白色闪一下，由 state.glancePulse 触发
            .rotationEffect(.degrees(glanceRotation), anchor: .bottom)
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(glanceFlash))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())   // 透明 padding 不接收点击
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 注意 onTapGesture(count:) 顺序：先 count:2，再 count:1，SwiftUI 才会先尝试双击
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) { onSingleTap() }
        // 拖动手势 —— 跟 onTapGesture 共存：移动 < 4pt 仍判定为 tap，超过 4pt 才进入 drag。
        // 用 simultaneousGesture 让 hover/tap 仍能正常工作
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if !dragStarted {
                        dragStarted = true
                        onDragStarted()
                    }
                    onDragChanged(value.translation)
                }
                .onEnded { value in
                    if dragStarted {
                        onDragEnded(value.translation)
                    }
                    dragStarted = false
                }
        )
        .onHover { hovering in onHoverChange(hovering) }
        .help("Clawd 在散步 · 单击=打开聊天 · 双击=切到 Claude · 拖到桌面图标上=让它嗅一下")
        // 桌面 CloudPet 跟灵动岛 CloudPetIslandSprite 同步戴眼镜
        // 用 Task 手动每帧驱动 @State —— Canvas 是 immediate-mode 不接受 withAnimation 插值
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetCloudPetWearGlasses"))) { note in
            guard state.visual == .cloud else { return }
            let duration = (note.userInfo?["duration"] as? Double) ?? 6.0
            glassesHideTask?.cancel()
            glassesHideTask = Task { @MainActor in
                let onFrames = 84   // 1.4s 戴上
                for i in 1...onFrames {
                    if Task.isCancelled { return }
                    let t = Double(i) / Double(onFrames)
                    let c1 = 1.70158, c3 = c1 + 1, x = t - 1
                    glassesProgress = 1 + c3 * x * x * x + c1 * x * x
                    try? await Task.sleep(nanoseconds: 16_666_666)
                }
                glassesProgress = 1
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                if Task.isCancelled { return }
                let offFrames = 36   // 0.6s 摘下
                for i in 1...offFrames {
                    if Task.isCancelled { return }
                    let t = 1 - Double(i) / Double(offFrames)
                    glassesProgress = t * t
                    try? await Task.sleep(nanoseconds: 16_666_666)
                }
                glassesProgress = 0
            }
        }
        // Wave A1：当 controller 把 state.glancePulse +1 时触发 0.4s 摆头 + flash
        .onChange(of: state.glancePulse) { _, _ in
            triggerGlanceAnimation()
        }
        .onDisappear {
            glassesHideTask?.cancel()
            glanceTask?.cancel()
        }
    }

    /// Wave A1：桌宠"瞥一眼"动画 —— 摆头 6° + 身上一闪，总时长约 0.4s
    /// 用 spring 让回弹有弹性；flash 用 plusLighter 不抢眼但能感觉到"动了一下"
    private func triggerGlanceAnimation() {
        glanceTask?.cancel()
        // 起势：摆头 + flash 同时拉起
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            glanceRotation = 6
            glanceFlash = 0.28
        }
        glanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            // 回弹：摆头 + flash 一起回 0
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                glanceRotation = 0
                glanceFlash = 0
            }
        }
    }
}

/// 头顶气泡视图 —— 黑色 Capsule + 白字 + Clawd 橘色细描边。
/// 气泡贴近窗口底部出现，看起来悬浮在 Clawd 头顶上方
struct ClawdWalkBubbleView: View {
    @Bindable var state: ClawdWalkState

    /// Anthropic Clawd 品牌橘
    private static let clawdOrange = Color(red: 215.0/255, green: 119.0/255, blue: 87.0/255)

    var body: some View {
        ZStack(alignment: .bottom) {
            if state.bubbleVisible && !state.bubbleText.isEmpty {
                Text(state.bubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.82))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Self.clawdOrange.opacity(0.45), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
                    .padding(.bottom, 2)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state.bubbleVisible)
    }
}
