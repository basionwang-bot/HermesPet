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
    /// 窗口尺寸 —— Clawd 像素是 11:10 接近正方形，高 30 时宽 33。
    /// height=50 保证 padding 10pt 上下，刚好容纳 jumping=-10pt 不被 NSHostingView 截顶
    private static let windowSize = NSSize(width: 48, height: 50)
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

    private init() {}

    /// AppDelegate 启动时调一次。后续完全靠通知驱动状态切换
    func start(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        self.lastMode = viewModel.agentMode
        state.visual = petVisual(for: viewModel.agentMode)
        registerNotifications()
        evaluateState()
    }

    /// 根据当前 AgentMode 选择宠物种类。claudeCode → clawd / directAPI → cloud；
    /// 其他 mode 桌宠不出现（shouldShow 已拦），此处 fallback 到 clawd 即可
    private func petVisual(for mode: AgentMode) -> PetVisualKind {
        mode == .directAPI ? .cloud : .clawd
    }

    // MARK: - Notification 监听
    private func registerNotifications() {
        let nc = NotificationCenter.default

        // idle 状态变化（IdleStateTracker tick）
        nc.addObserver(forName: .init("HermesPetUserIdleChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateState() }
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
                        let home = NSPoint(x: self.notchCenterX(on: screen) - Self.windowSize.width / 2,
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
    }

    // MARK: - 触发条件评估

    /// 当前条件是否允许 Clawd 漫步
    ///
    /// 普通模式（freeRoam=OFF）：mode=Claude + 漫步开关 + 3min idle + 无 streaming
    /// 自由活动模式（freeRoam=ON）：mode=Claude + 漫步开关 + 无 streaming（跳过 idle 前置）
    private func shouldShow() -> Bool {
        guard let vm = viewModel else { return false }
        guard vm.clawdWalkEnabled else { return false }
        guard vm.agentMode == .claudeCode || vm.agentMode == .directAPI else { return false }
        // 戴眼镜动画期间强制保持显示 —— 用户能看完整个"掏眼镜→戴上→保持→摘下"流程，
        // 之后再按常规规则判定是否回家（vision 切换后通常 streaming 仍在跑会回家）
        if let pending = glassesPendingUntil, pending > Date() { return true }
        // streaming 时永远不出来（不管哪种模式），避免抢灵动岛进度的注意力
        if vm.conversations.contains(where: { $0.isStreaming }) { return false }
        // directAPI 在线 AI 模式：宠物直接到桌面，不等 idle（云朵小精灵主动陪伴）
        if vm.agentMode == .directAPI { return true }
        // 自由活动模式：放行
        if vm.clawdFreeRoamEnabled { return true }
        // 普通模式：必须 idle
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

    /// 漫步 y：菜单栏下方 4pt 处。visibleFrame.maxY 已扣掉菜单栏，正好用
    private func walkBaseY(on screen: NSScreen) -> CGFloat {
        let h = Self.windowSize.height
        return screen.visibleFrame.maxY - 4 - h
    }

    // MARK: - 显示 / 隐藏

    private func showAndStartWalking() {
        guard let screen = targetScreen() else { return }
        if window == nil { createWindow() }
        guard let win = window else { return }

        let startCenterX = notchCenterX(on: screen)
        walkY = walkBaseY(on: screen)
        positionX = startCenterX - Self.windowSize.width / 2
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
        let islandTopY = screen.frame.maxY - Self.windowSize.height
        win.setFrame(
            NSRect(x: positionX, y: islandTopY, width: Self.windowSize.width, height: Self.windowSize.height),
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
                NSRect(x: positionX, y: walkY, width: Self.windowSize.width, height: Self.windowSize.height),
                display: true
            )
        })

        isShown = true
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

        guard let win = window, let screen = targetScreen() else {
            window?.orderOut(nil)
            return
        }

        // 退场：滑回灵动岛位置 + fade out
        let islandCenterX = notchCenterX(on: screen)
        let backX = islandCenterX - Self.windowSize.width / 2
        let islandTopY = screen.frame.maxY - Self.windowSize.height

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
            win.animator().setFrame(
                NSRect(x: backX, y: islandTopY, width: Self.windowSize.width, height: Self.windowSize.height),
                display: true
            )
        }, completionHandler: { [weak win] in
            Task { @MainActor in win?.orderOut(nil) }
        })
    }

    // MARK: - NSWindow 创建

    private func createWindow() {
        let w = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
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
        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
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
        let clawdCx = positionX + Self.windowSize.width / 2
        let clawdCy = walkY + Self.windowSize.height / 2
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
            let rightBound = visible.maxX - Self.windowSize.width - Self.edgeMargin
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
        let rightBound = visible.maxX - Self.windowSize.width - Self.edgeMargin
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
                && abs(icon.position.x - (self.positionX + Self.windowSize.width / 2)) > 80
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
            let home = NSPoint(x: notchCenterX(on: screen) - Self.windowSize.width / 2,
                               y: walkBaseY(on: screen))
            patrol = .returning(target: home)
            patrolWatchdogAt = now.addingTimeInterval(Self.patrolWatchdog)
        }

        switch patrol {
        case .goingTo(let target, let icon):
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
                let home = NSPoint(x: notchCenterX(on: screen) - Self.windowSize.width / 2,
                                   y: walkBaseY(on: screen))
                patrol = .returning(target: home)
                state.pose = .rest
                state.bubbleVisible = false   // 嗅完气泡也收起，干净
                bubbleHideAt = nil
                patrolWatchdogAt = now.addingTimeInterval(Self.patrolWatchdog)
            }

        case .returning(let target):
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
        let h = Self.windowSize.height
        let w = Self.windowSize.width
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

    /// 拼给 Hermes 的 prompt —— 严格要求短回复
    private func sniffPrompt(for icon: DesktopIcon) -> String {
        let kind = icon.isFolder ? "文件夹" : "文件"
        return """
        你是桌面宠物 Clawd 🦞，正在用户桌面闲逛，发现了一个\(kind)。
        请用**不超过 10 个汉字**的一句话，用轻松、好奇、可爱的口吻评论它的名字。
        不要加引号、不要 emoji、不要解释、不要省略号。
        \(kind)名: \(icon.name)
        """
    }

    /// 本地兜底文案 —— Hermes 没配 / 网络挂 / 限流时用
    private func localFallbackQuote(for icon: DesktopIcon) -> String {
        let folderQuotes = ["翻翻这个~", "里面装啥?", "嗯…文件夹", "看着挺鼓", "藏宝盒?"]
        let fileQuotes   = ["这名字有意思", "什么文件呢?", "嗅嗅~", "瞄一眼", "看着挺新"]
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
        let centerX = positionX + Self.windowSize.width / 2
        let centerY = walkY + Self.windowSize.height / 2
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
                        x: self.notchCenterX(on: screen) - Self.windowSize.width / 2,
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
        let cx = positionX + Self.windowSize.width / 2
        let bx = cx - Self.bubbleSize.width / 2
        let by = walkY + Self.windowSize.height + 2
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
}

/// 桌面漫步支持的两种像素宠物视觉。
enum PetVisualKind {
    case clawd
    case cloud
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

    /// Clawd 像素高度（窗口 44pt，留 7pt 上下 padding 容纳 jumping）
    private let clawdHeight: CGFloat = 30

    var body: some View {
        ZStack {
            // 按当前宠物种类切渲染。两种 sprite 应用同一套 scale/offset/animation modifier，
            // 保证 walk/jump/drag/facing 等手势行为视觉一致。
            Group {
                switch state.visual {
                case .clawd:
                    // 把 state.isWalking 传给 ClawdView，让它内部播放官方走路动画
                    // （4 腿对角交替、身体 bob、手臂上下摆 —— 这些是 SVG 原版 keyframe，
                    // 不再用 SwiftUI 外层 bobOffset 重复模拟）
                    ClawdView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking)
                case .cloud:
                    CloudPetView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking,
                                 glassesProgress: glassesProgress)
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
        .onDisappear { glassesHideTask?.cancel() }
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
