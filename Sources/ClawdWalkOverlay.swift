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
    private var hostingView: NSHostingController<ClawdWalkView>?
    private let state = ClawdWalkState()

    // 头顶气泡的独立窗口（不放在 Clawd 窗口里是因为 Clawd 窗口很小，气泡放外面更灵活定位）
    private var bubbleWindow: NSWindow?
    private static let bubbleSize = NSSize(width: 160, height: 28)

    // MARK: - Walk params
    /// 基础窗口尺寸 —— 高 50pt 保证上下 padding 10pt（容纳 jumping=-10pt 不被截顶）。
    /// 宽 68pt（比 sprite 45pt 宽一截）是给"魔法搭建"等表演留两侧道具空间：悬浮锤子 / 披风
    /// 要摆在 Clawd 身体两侧才不重叠。**只动宽度安全**——walkY 只依赖 height，宽度变化由
    /// windowSize computed 自动传导到所有几何（撞墙/居中/patrol）。代价：可点击的透明窗口横向
    /// 略大一点（桌宠本身没变大）。
    private static let baseWindowSize = NSSize(width: 68, height: 50)

    /// 偷玩电脑态的"大场景"窗口尺寸（桌子+椅子+显示器+背面 Clawd 都要塞进去）。
    /// 仅这个长表演期间临时把桌宠窗口 setFrame 到这么大，从菜单栏下方往桌面方向展开；结束复原。
    /// 桌宠窗口本来就会 setFrame（漫步/改档位），不受灵动岛"禁 setFrame"约束（决策 #1 只管灵动岛）。
    private static let gamingWindowSize = NSSize(width: 98, height: 108)
    private var gamingWinSize: NSSize {
        NSSize(width: Self.gamingWindowSize.width * sizeScale,
               height: Self.gamingWindowSize.height * sizeScale)
    }

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
    /// 休息态 walkTimer 降频（6fps 够检测"该醒了吗" + 鼠标贴近惊醒）
    private static let tickIntervalRest: TimeInterval = 1.0/6.0
    /// 自由漫步累积活跃多久就"累了"想休息（随机区间，避免节奏机械）
    private static let restAfterActiveRange: ClosedRange<TimeInterval> = 30...55   // 走这么久才"累"想歇，大部分时间在动
    /// 一次休息时长（随机区间）
    /// 一次休息（睡觉）时长 —— 拉长，鼠标不靠近就睡久点（用户要"睡觉这个动画能长期播放"）。
    /// 鼠标贴近 / hover / 拖动随时把它弄醒（见 tick 休息态分支），所以长睡不影响逗它。
    private static let restDurationRange: ClosedRange<TimeInterval> = 50...140
    private static let pauseEveryMin: TimeInterval = 4.0
    private static let pauseEveryMax: TimeInterval = 8.0
    private static let pauseDurMin: TimeInterval = 1.4
    private static let pauseDurMax: TimeInterval = 2.8
    /// 鼠标距离阈值 —— 进入 chasing 后用 exit 阈值，避免边缘抖动反复切换
    private static let chaseEnterDist: CGFloat = 180
    private static let chaseExitDist: CGFloat = 240
    /// 始终在场模式（自由活动 / 在线 AI / fomo）：用户连续这么久没碰电脑 → 趴下深睡。
    /// 无限睡到鼠标"移动着靠近"才醒（见 tick 1.4 / 休息态分支）。
    private static let idleSleepThreshold: TimeInterval = 180
    /// 睡着时：检测到任何输入在这么短时间内 → 睁一只眼"偷瞄"（远处打字/动鼠标）
    private static let peekWindow: TimeInterval = 2.5

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
    /// 桌宠"当前所在屏"的 displayID —— tick 每帧读 targetScreen() 必须稳定，不能跟着鼠标实时变
    /// （否则鼠标刚跨屏、relocate 还没跑就会有 1 帧 positionX 错位）。跨屏跟随只在收到信号时受控更新。
    private var petScreenID: CGDirectDisplayID?
    private var nextPauseAt: Date?
    private var pauseEndsAt: Date?

    // 疲劳/休息状态机（TODO Step 7 省电）
    /// 自由漫步累积活跃时长，达到 restThreshold → 进入休息
    private var walkAccum: TimeInterval = 0
    /// 当前这轮疲劳阈值（每次醒来重新随机）
    private var restThreshold: TimeInterval = .random(in: 18...32)
    /// != nil 表示正在休息，值为休息结束时间
    private var restingUntil: Date?

    private var lastBackgroundStreamingCount: Int = 0
    private var lastMode: AgentMode = .hermes
    private var isHovering = false

    // 鼠标活跃度追踪 —— 只有用户"晃动"光标时才追逐；光标静止时桌宠照常漫步/表演。
    // 否则用户一凑近看，光标静止在附近也会触发追逐，把所有表演都挤掉（用户反馈"看不到表演"）。
    private var lastMouseLoc: NSPoint? = nil
    private var lastMouseMovedAt: Date? = nil
    /// 光标静止超过这个时长就算"不活跃" —— 不再追逐，让位给随机表演
    private static let mouseActiveWindow: TimeInterval = 1.2
    /// 判定"移动了"的最小位移（避免微小抖动算移动）
    private static let mouseMoveThreshold: CGFloat = 3.0

    // 系统级空闲检测 —— 用 CGEventSource 看用户多久没碰鼠标/键盘了（跟 IdleStateTracker 同源）。
    // 用于：① 始终在场模式 3min 没操作 → 趴下深睡；② 睡着时远处有输入 → 睁一只眼偷瞄。
    /// 最近一次鼠标/键盘输入到现在的秒数；节流 0.5s 在 tick 里探一次（省 CGEventSource 调用）
    private var userIdleSeconds: TimeInterval = 0
    private var lastIdleProbeAt: Date? = nil
    private static let idleProbeInterval: TimeInterval = 0.5

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

    /// 表演用的临时动画 Task（目前只有"开心蹦"靠它连续 toggle isJumping）。
    /// 表演结束 / 桌宠隐藏时取消。
    private var performanceTask: Task<Void, Never>? = nil

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
    /// - directAPI → monster（红色小怪兽，跟灵动岛 MonsterIslandSprite 一致）
    /// - hermes → horse（金黄小马）
    /// - codex → terminal（mini Terminal.app 窗口）
    private func petVisual(for mode: AgentMode) -> PetVisualKind {
        switch mode {
        case .directAPI:  return .monster
        case .qwenCode:   return .bear     // QwenCode = 布尔熊（见 BearSprite.swift）
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

        // 聊天窗拖拽进行中 —— 临时冻结桌宠，把主线程让给拖拽追踪（避免拖文件卡顿）。
        nc.addObserver(forName: .init("HermesPetDragInProgress"), object: nil, queue: .main) { [weak self] note in
            let active = (note.userInfo?["active"] as? Bool) ?? false
            Task { @MainActor in self?.setDragPaused(active) }
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
        // 静止/钉住开关变化 —— 开启时清掉所有"会自己挪位置"的临时态并钉在当前位置
        nc.addObserver(forName: .init("HermesPetPinnedSettingChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handlePinnedSettingChanged() }
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

        // Clawd 是像素图，额外切 pose 让眼睛看一下（其他 sprite 没有 pose，靠 rotation 表达）。
        // 正在表演（activity != .idle，如搭建时 pose 也是 .rest）时不抢 pose，免得打断表演。
        if state.visual == .clawd, state.pose == .rest, state.activity == .idle {
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

    /// 屏幕变化 / 跟随当前屏 / 插拔屏 统一入口：把桌宠对齐到"期望屏"。
    /// 期望屏 = 全局选屏逻辑（follow → 鼠标所在屏；pinned → 指定屏；屏被拔 → 兜底带刘海屏）。
    /// - 期望屏 ≠ 当前缓存屏 → **跨屏搬移**：取消巡视/传送门临时态，落到新屏靠近鼠标的水平位置继续走。
    /// - 期望屏 == 当前屏（仅分辨率/排列变化）→ 只把 positionX clamp 回屏内。
    private func handleScreenParamsChanged() {
        guard isShown, let win = window else { return }
        guard let desired = HermesIslandGeometry.targetScreen() else { return }
        let movedToNewScreen = (desired.displayID != petScreenID)
        petScreenID = desired.displayID

        walkY = walkBaseY(on: desired)
        let visible = desired.visibleFrame
        let leftBound  = visible.minX + Self.edgeMargin
        let rightBound = visible.maxX - windowSize.width - Self.edgeMargin

        if movedToNewScreen {
            // 清掉会"自己控制位置"的临时态，免得跟这次搬移打架
            if isTeleporting {
                isTeleporting = false
                portalWindow?.orderOut(nil)
                win.alphaValue = 1
            }
            if patrol != nil {
                patrol = nil
                patrolWatchdogAt = nil
            }
            state.isChasing = false   // 旧屏的追逐方向作废，新屏下个 tick 重判
            // 落到新屏靠近鼠标的水平位置（"出现在你过去的那块屏"）
            let mouseX = NSEvent.mouseLocation.x
            positionX = max(leftBound, min(rightBound, mouseX - windowSize.width / 2))
        } else {
            positionX = max(leftBound, min(rightBound, positionX))
        }
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
        // 6 个 mode 都允许桌面漫步（含 QwenCode = 青色眼镜怪兽）
        guard vm.agentMode == .claudeCode || vm.agentMode == .directAPI ||
              vm.agentMode == .openclaw || vm.agentMode == .hermes ||
              vm.agentMode == .codex || vm.agentMode == .qwenCode else { return false }
        // 戴眼镜动画期间强制保持显示 —— 用户能看完整个"掏眼镜→戴上→保持→摘下"流程，
        // 之后再按常规规则判定是否回家（vision 切换后通常 streaming 仍在跑会回家）
        if let pending = glassesPendingUntil, pending > Date() { return true }
        // 钉住模式：固定常驻 —— 桌宠停在用户放置处，不受 idle / streaming 影响
        // （静止的桌宠不抢注意力，消失反而破坏"固定摆件"的一致性）
        if isPinnedMode { return true }
        // streaming 时永远不出来（不管哪种模式），避免抢灵动岛进度的注意力
        if vm.conversations.contains(where: { $0.isStreaming }) { return false }
        // HTTP API 类 mode + QwenCode：宠物直接到桌面，不等 idle（主动陪伴系）
        if vm.agentMode == .directAPI || vm.agentMode == .openclaw || vm.agentMode == .qwenCode { return true }
        // 自由活动模式：放行
        if vm.clawdFreeRoamEnabled { return true }
        // 普通模式（Claude / Hermes / Codex）：必须 idle 3min 才出来
        return IdleStateTracker.shared.isSleeping
    }

    /// 是否"始终在场"的模式（自由活动 / 在线 AI / fomo）。
    /// 这些模式不靠 idle 出场（一直在桌面），所以睡觉绑定"用户 3min 没操作"（tick 1.4），
    /// 平时一直逛不自己打盹；普通模式本来就只在 idle 时出场，仍保留旧的漫步疲劳小憩。
    private var isAlwaysShownMode: Bool {
        guard let vm = viewModel else { return false }
        if vm.agentMode == .directAPI || vm.agentMode == .openclaw || vm.agentMode == .qwenCode { return true }
        return vm.clawdFreeRoamEnabled
    }

    /// 用户是否开了"桌宠固定不动"（静止/钉住模式）
    private var isPinnedMode: Bool { viewModel?.petPinnedEnabled ?? false }

    // 钉住位置持久化（UserDefaults）—— 记住用户上次把桌宠放在哪（仅同屏恢复）
    private static let pinnedXKey = "petPinnedPosX"
    private static let pinnedYKey = "petPinnedPosY"
    private static let pinnedScreenKey = "petPinnedScreenID"

    /// 记录当前桌宠位置为"钉住点"（窗口左下角 NSScreen 坐标 + 所在屏 displayID）
    private func savePinnedPosition(on screen: NSScreen) {
        let d = UserDefaults.standard
        d.set(Double(positionX), forKey: Self.pinnedXKey)
        d.set(Double(walkY), forKey: Self.pinnedYKey)
        d.set(Int(screen.displayID ?? 0), forKey: Self.pinnedScreenKey)
    }

    /// 读回钉住点（仅当落在当前屏才有效；越界自动 clamp 进可见区）。无记录 / 跨屏 → nil
    private func loadPinnedPosition(on screen: NSScreen) -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.pinnedXKey) != nil else { return nil }
        guard d.integer(forKey: Self.pinnedScreenKey) == Int(screen.displayID ?? 0) else { return nil }
        let vis = screen.visibleFrame
        let x = max(vis.minX, min(vis.maxX - windowSize.width, CGFloat(d.double(forKey: Self.pinnedXKey))))
        let y = max(vis.minY, min(vis.maxY - windowSize.height, CGFloat(d.double(forKey: Self.pinnedYKey))))
        return NSPoint(x: x, y: y)
    }

    /// 用户在设置里切换"桌宠固定不动"开关
    private func handlePinnedSettingChanged() {
        if isPinnedMode {
            // 进入钉住：取消所有会"自己挪位置"的临时态，钉在当前位置
            sniffAITask?.cancel(); sniffAITask = nil
            patrol = nil
            patrolWatchdogAt = nil
            nextPatrolAt = nil
            state.isChasing = false
            pauseEndsAt = nil
            restingUntil = nil
            state.lowPower = false
            state.activity = .idle
            state.pose = .rest
            if isTeleporting {
                isTeleporting = false
                portalState.openness = 0
                portalWindow?.orderOut(nil)
                window?.alphaValue = 1
            }
            if isShown, let screen = targetScreen() { savePinnedPosition(on: screen) }
        }
        evaluateState()
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

    /// 桌宠"当前所在屏"。用缓存的 `petScreenID` 锁住，保证 tick 每帧拿到稳定的屏。
    /// 缓存为空（首次）/ 该屏已被拔掉 → 用全局选屏逻辑（`HermesIslandGeometry.targetScreen()`：
    /// follow 跟随鼠标 / pinned 固定屏）兜底并回填缓存。跨屏搬移走 `handleScreenParamsChanged()`。
    private func targetScreen() -> NSScreen? {
        if let id = petScreenID,
           let s = NSScreen.screens.first(where: { $0.displayID == id }) {
            return s
        }
        let s = HermesIslandGeometry.targetScreen()
        petScreenID = s?.displayID
        return s
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
        // 钉住模式：恢复上次用户放置的位置（仅同屏；无记录则用默认刘海中心）
        if isPinnedMode, let saved = loadPinnedPosition(on: screen) {
            positionX = saved.x
            walkY = saved.y
        }
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
        state.lowPower = false
        restingUntil = nil
        walkAccum = 0
        restThreshold = Double.random(in: Self.restAfterActiveRange)
        startWalkTimer()
        // 出场表演：Clawd 一出来就先抛会儿球当"登场仪式"
        scheduleEntrancePerformance()
    }

    /// Clawd 出场后来一段抛球当登场表演（约 4s），给个"我来啦"的招呼。
    private func scheduleEntrancePerformance() {
        guard state.visual == .clawd else { return }
        performanceTask?.cancel()
        performanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)   // 等出场滑入动画跑完 + 一拍
            guard isShown, state.visual == .clawd,
                  !state.isBeingDragged, patrol == nil,
                  restingUntil == nil, !isTeleporting else { return }
            state.isChasing = false
            state.pose = .armsUp
            state.activity = .juggling
            pauseEndsAt = Date().addingTimeInterval(4.0)
            nextPauseAt = nil
        }
    }

    private func stopAndHide() {
        isShown = false
        walkTimer?.invalidate()
        walkTimer = nil
        lastTickAt = nil
        pauseEndsAt = nil
        state.isChasing = false
        // 退场清理表演态 + 休息态（下次 show 重新计时）
        performanceTask?.cancel(); performanceTask = nil
        state.activity = .idle
        state.isJumping = false
        restingUntil = nil
        state.lowPower = false
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
        }, completionHandler: { [weak self, weak win, weak state] in
            Task { @MainActor in
                win?.orderOut(nil)
                // orderOut 完成后才关 sprite 动画 —— 不然飞回灵动岛途中桌宠会瞬间僵硬
                state?.spriteAnimated = false
                // 忘掉所在屏 —— 下次出场重新按当前选择 / 鼠标位置定屏（用户期间可能换了屏）
                self?.petScreenID = nil
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

        // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
        // host 是 container 的子视图（上面还压着 FileDropView），controller 由 walkHosting 持有
        let host = NSHostingController(rootView: ClawdWalkView(
            state: state,
            onSingleTap: { [weak self] in self?.handleSingleTap() },
            onDoubleTap: { [weak self] in self?.handleDoubleTap() },
            onHoverChange: { [weak self] hovering in self?.handleHoverChange(hovering) },
            onDragStarted: { [weak self] in self?.handleClawdDragStarted() },
            onDragChanged: { [weak self] t in self?.handleClawdDragChanged(translation: t) },
            onDragEnded: { [weak self] t in self?.handleClawdDragEnded(translation: t) }
        ))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)

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
        // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
        // （Canvas + TimelineView 30fps 重绘 + withAnimation 改 openness，历史上 v1.2.7 跑 4.5h 必崩）
        let host = NSHostingController(rootView: TeleportPortalView(state: portalState))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        w.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
        w.setContentSize(Self.portalWindowSize)
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
        case .qwenCode:   return .teal
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

        // 决策 #1/#6 升级：裸 NSHostingView 即便 sizingOptions=[] 在 macOS 26 仍会经
        // updateAnimatedWindowSize 反推 setFrame（2026-06-11 00:09 崩溃实锤）；只有
        // NSHostingController + sizingOptions=[] 真正禁掉反推（照语音陪聊/迷你岛范本）
        let host = NSHostingController(rootView: ClawdWalkBubbleView(state: state))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        w.contentViewController = host
        host.view.autoresizingMask = [.width, .height]   // 防御：铺满全窗（autoresizingMask 收口）
        w.setContentSize(Self.bubbleSize)
        bubbleWindow = w
    }

    // MARK: - 漫步主循环

    private func startWalkTimer(interval: TimeInterval = ClawdWalkController.tickInterval) {
        walkTimer?.invalidate()
        lastTickAt = Date()
        walkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 拖拽进行中临时冻结桌宠 —— 同时停 sprite TimelineView（`state.dragPaused`）和位移 tick（`walkTimer`），
    /// 把主线程整段让给拖拽追踪，松手后按当前是否在休息态选回正确的节奏恢复。
    /// 只在拖文件那一小段生效，不改平时走路手感。
    private var dragFrozen = false
    func setDragPaused(_ paused: Bool) {
        guard isShown else { return }
        if paused {
            guard !dragFrozen else { return }
            dragFrozen = true
            state.dragPaused = true
            walkTimer?.invalidate()
            walkTimer = nil
        } else {
            guard dragFrozen else { return }
            dragFrozen = false
            state.dragPaused = false
            lastTickAt = Date()   // 重置时间戳，避免恢复后 dt 累积一大跳让桌宠"瞬移"
            startWalkTimer(interval: restingUntil != nil ? Self.tickIntervalRest : Self.tickInterval)
        }
    }

    /// 进入休息态：冒一句"累了"，趴下不动，sprite 降到 12fps + walkTimer 降到 6fps 省电。
    /// - indefinite=false：普通"跑累了"的小憩，睡 50~140s 自动醒（普通模式 / 旧节奏）。
    /// - indefinite=true：用户 3min 没操作的"深睡"，无限睡到鼠标移动着靠近才醒（始终在场模式）。
    ///   （实现上把 restingUntil 设成一天后，等价无限睡；只靠 disturbed 弄醒，见休息态分支。）
    private func enterRest(now: Date, indefinite: Bool = false) {
        restingUntil = indefinite
            ? now.addingTimeInterval(86_400)
            : now.addingTimeInterval(Double.random(in: Self.restDurationRange))
        walkAccum = 0
        state.isWalking = false
        state.isChasing = false
        state.pose = .rest
        state.activity = .sleeping       // 趴下休息 = 睡觉态（闭眼 + 头顶 Zzz）
        state.peeking = false            // 刚趴下先闭眼酣睡，远处有输入再睁眼偷瞄
        state.lowPower = true
        performanceTask?.cancel(); performanceTask = nil
        pauseEndsAt = nil
        nextPauseAt = nil
        // 深睡（用户已走开）就别冒"累了"气泡了——没人看，纯噪音；小憩才报一句
        if !indefinite {
            showBubble(text: pickQuote(from: ClawdQuotes.tired), duration: 2.6)
        }
        startWalkTimer(interval: Self.tickIntervalRest)
    }

    /// 退出休息态：恢复 30fps + 正常漫步节奏。`announce` 时冒一句"睡饱啦"。
    private func wakeUp(now: Date, announce: Bool) {
        restingUntil = nil
        walkAccum = 0
        // 清零空闲秒数 + 强制下个 tick 重新探一次 —— 否则刚被鼠标弄醒、空闲探测还停在旧的 ≥180s
        // 值（0.5s 节流），1.4 分支会立刻又把它送回深睡，造成"刚醒又睡"抽搐。
        userIdleSeconds = 0
        lastIdleProbeAt = nil
        restThreshold = Double.random(in: Self.restAfterActiveRange)
        state.lowPower = false
        state.peeking = false
        state.pose = .rest
        state.activity = .idle           // 醒来回到默认态
        nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
        startWalkTimer(interval: Self.tickInterval)
        if announce {
            showBubble(text: pickQuote(from: ClawdQuotes.refreshed), duration: 2.0)
        }
    }

    /// 漫步途中到了"该停下来表演一会儿"的时机 —— 加权随机挑一个小动作。
    /// 大部分时候还是简单张望 / 伸懒腰（节奏自然、不浮夸），其余概率来个带道具的小表演。
    /// 表演靠设 `state.activity` + `pauseEndsAt`（表演时长）驱动：表演期间 tick 会在暂停分支
    /// 提前 return 不移动，时间到了在同一分支收尾回 .idle。仅 Clawd 螃蟹有道具（试水）。
    private func beginIdlePerformance(now: Date) {
        // 带道具的表演暂时只 Clawd 螃蟹演（按用户要求先专注 Clawd）；其它宠物只张望/伸懒腰
        guard state.visual == .clawd else {
            state.pose = Int.random(in: 0..<3) == 0 ? .armsUp
                       : (Bool.random() ? .lookLeft : .lookRight)
            state.activity = .idle
            pauseEndsAt = now.addingTimeInterval(Double.random(in: Self.pauseDurMin...Self.pauseDurMax))
            return
        }
        // 注：偷玩电脑（.gaming）暂时下架（用户觉得场景不够好看），代码留着，先不触发。
        switch Int.random(in: 0..<12) {
        case 0, 1:      // 张望（看左 / 看右）
            state.pose = Bool.random() ? .lookLeft : .lookRight
            state.activity = .idle
            pauseEndsAt = now.addingTimeInterval(Double.random(in: Self.pauseDurMin...Self.pauseDurMax))
        case 2:         // 伸懒腰
            state.pose = .armsUp
            state.activity = .idle
            pauseEndsAt = now.addingTimeInterval(Double.random(in: Self.pauseDurMin...Self.pauseDurMax))
        case 3, 4:      // 抛球（举手 + 头顶彩球）
            state.pose = .armsUp
            state.activity = .juggling
            pauseEndsAt = now.addingTimeInterval(Double.random(in: 3.0...4.2))
        case 5, 6:      // 搭建（小魔法师遥控锤子）
            state.pose = .rest
            state.activity = .building
            pauseEndsAt = now.addingTimeInterval(Double.random(in: 3.0...4.0))
        case 7:         // 开心蹦 + 星星
            state.pose = .armsUp
            state.activity = .happy
            pauseEndsAt = now.addingTimeInterval(2.2)
            startHappyHops()
        case 8, 9:      // 听音乐（蹦跳 + 耳机 + 彩灯 + 音符）
            state.activity = .music
            pauseEndsAt = now.addingTimeInterval(Double.random(in: 3.0...4.0))
            startMusicBob()
        default:        // 扫地（左右扫 + 灰尘）
            state.pose = .rest
            state.activity = .sweeping
            pauseEndsAt = now.addingTimeInterval(Double.random(in: 3.2...4.2))
        }
    }

    /// 开心态的连续小跳 —— toggle `isJumping`（带 spring）跳 3 下。
    /// 跟 tick 不冲突：表演期间 tick 在暂停分支提前 return，不会动 isJumping。
    private func startHappyHops() {
        performanceTask?.cancel()
        performanceTask = Task { @MainActor in
            for _ in 0..<3 {
                state.isJumping = true
                try? await Task.sleep(nanoseconds: 230_000_000)
                if Task.isCancelled { return }
                state.isJumping = false
                try? await Task.sleep(nanoseconds: 230_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    /// 听音乐态的"蹦着摇摆" —— 每拍：跳起 + 举手，落地 + 放手，跟着旋律打拍子。
    /// **不转眼珠**（之前 lookLeft/lookRight 快速切换让眼神乱跳，看着奇怪）：armsUp 和 rest
    /// 的眼睛都在正中，所以整支舞眼神都平静，只有身体在蹦、手臂在抬。
    /// 耳机画在 sprite 本体里会跟着一起蹦。表演结束 tick 收尾时取消并复位。
    private func startMusicBob() {
        performanceTask?.cancel()
        performanceTask = Task { @MainActor in
            while !Task.isCancelled {
                // 落拍：跳起 + 举手
                state.isJumping = true
                state.pose = .armsUp
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { state.isJumping = false; state.pose = .rest; return }
                // 抬拍：落地 + 放手
                state.isJumping = false
                state.pose = .rest
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    /// 进入偷玩电脑大场景：把桌宠窗口临时放大（从当前窗口顶往下展开），容纳桌子/椅子/显示器。
    /// 期间正面 sprite 由 `.opacity` 隐藏（activity==.gaming），场景由 activityProps 的 GamingDeskView 呈现。
    private func enterGamingScene() {
        guard let win = window, let screen = targetScreen() else { return }
        let cx = positionX + windowSize.width / 2
        let topY = walkY + windowSize.height          // 当前窗口顶（贴菜单栏下方）
        let gs = gamingWinSize
        let visible = screen.visibleFrame
        let gx = max(visible.minX + 4, min(visible.maxX - gs.width - 4, cx - gs.width / 2))
        let gy = max(visible.minY + 4, topY - gs.height)   // 从顶往下展开，别越过屏幕底
        win.setFrame(NSRect(x: gx, y: gy, width: gs.width, height: gs.height), display: true, animate: false)
    }

    /// 退出偷玩电脑大场景：把桌宠窗口复原回正常漫步尺寸与位置。
    private func endGamingScene() {
        guard let win = window else { return }
        win.setFrame(NSRect(x: positionX, y: walkY, width: windowSize.width, height: windowSize.height),
                     display: true, animate: false)
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

        // —— -0.5) 静止/钉住模式 —— 停在原地只做微动作，不漫步/追逐/巡视/回家/传送
        if isPinnedMode {
            tickPinned(now: now, win: win, screen: screen)
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
        if let next = nextPatrolAt, now >= next, isHovering == false, pauseEndsAt == nil, restingUntil == nil {
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

        // 鼠标活跃度：光标位移超过阈值就刷新"最近移动时间"
        if let last = lastMouseLoc {
            if hypot(mouseLoc.x - last.x, mouseLoc.y - last.y) > Self.mouseMoveThreshold {
                lastMouseMovedAt = now
                lastMouseLoc = mouseLoc
            }
        } else {
            lastMouseLoc = mouseLoc
            lastMouseMovedAt = now
        }
        let mouseActive = lastMouseMovedAt.map { now.timeIntervalSince($0) < Self.mouseActiveWindow } ?? false

        // 系统级空闲秒数（鼠标 + 键盘最近一次输入）—— 节流 0.5s 探一次，省 CGEventSource 调用
        if lastIdleProbeAt == nil || now.timeIntervalSince(lastIdleProbeAt!) >= Self.idleProbeInterval {
            let mIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            let kIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            userIdleSeconds = min(mIdle, kIdle)
            lastIdleProbeAt = now
        }

        // —— 1.4) 始终在场模式：用户连续 3min 没碰电脑 → 趴下深睡（无限睡，鼠标靠近才醒）——
        // 平时（用户在操作）一直漫步表演不打盹；只有真走开 3min 才睡。普通模式不在此触发
        // （它本来就只在 idle 时出场，否则会"一出场就睡"），仍走下面的漫步疲劳小憩。
        if isAlwaysShownMode, restingUntil == nil, !state.isBeingDragged, !state.isEating,
           patrol == nil, userIdleSeconds >= Self.idleSleepThreshold {
            enterRest(now: now, indefinite: true)
            syncBubbleWindow()
            return
        }

        // —— 1.5) 休息态：趴着省电；睡够 / 被 hover / 被拖动 / 鼠标移动着贴近 → 醒来 ——
        if restingUntil != nil {
            // "靠近"必须是移动着凑过来（mouseActive）才算；光标静止停在附近不算 —— 否则用户
            // 把鼠标搁在桌宠旁边就走开，会"刚睡就被自己旁边的静止光标弄醒"反复抽搐。
            let disturbed = isHovering || state.isBeingDragged || state.isEating
                          || (dist < Self.chaseEnterDist && mouseActive)
            if let until = restingUntil, now < until, !disturbed {
                // 继续睡：远处有输入（打字/动鼠标）→ 睁一只眼偷瞄；全静止 → 闭眼酣睡
                let peek = userIdleSeconds < Self.peekWindow
                if state.peeking != peek { state.peeking = peek }
                state.isWalking = false
                syncBubbleWindow()
                return
            }
            // 到点自然醒报一句；被打扰惊醒则安静起身（不打断用户操作）
            wakeUp(now: now, announce: !disturbed)
        }

        if !isHovering, pauseEndsAt == nil {
            // 只有"光标在动"时才追逐 —— 静止光标不触发，让桌宠安心表演（用户能看到表演）
            if !state.isChasing && dist < Self.chaseEnterDist && mouseActive {
                state.isChasing = true
                // 进入追逐时取消 pause 排程；50% 概率冒一句招呼
                nextPauseAt = nil
                if Bool.random() {
                    showBubble(text: pickQuote(from: ClawdQuotes.greetings), duration: 1.8)
                }
            } else if state.isChasing && (dist > Self.chaseExitDist || !mouseActive) {
                // 跑远了、或光标静止下来 → 退出追逐，恢复漫步/表演节奏
                state.isChasing = false
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            }
        }

        // —— 1.8) 偷玩电脑（长表演）：鼠标靠近 / hover → "被发现了"赶紧收摊，复原窗口回漫步 ——
        if state.activity == .gaming {
            let busted = isHovering || dist < Self.chaseEnterDist
            if busted {
                endGamingScene()
                pauseEndsAt = nil
                state.activity = .idle
                state.pose = .rest
                performanceTask?.cancel(); performanceTask = nil
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
                // 不 return —— 让本 tick 继续按常规逻辑（多半会进 chasing 朝鼠标跑）
            } else {
                // 没被发现 → 继续玩，保持大场景不动
                state.isWalking = false
                syncBubbleWindow()
                return
            }
        }

        // —— 2) 暂停态 / 表演态（仅非 chasing 时生效）——
        if !state.isChasing, let until = pauseEndsAt {
            if now >= until {
                // 表演 / 暂停结束 → 收尾回默认态，排下次
                pauseEndsAt = nil
                state.pose = .rest
                state.activity = .idle
                state.isJumping = false   // 听音乐/开心蹦可能停在跳起态，复位
                performanceTask?.cancel(); performanceTask = nil
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            } else {
                state.isWalking = false
                syncBubbleWindow()
                return
            }
        } else if !state.isChasing, !isHovering, let next = nextPauseAt, now >= next {
            // 到点了 → 随机挑一个小表演（张望 / 伸懒腰 / 抛球 / 搭建 / 开心蹦）
            beginIdlePerformance(now: now)
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
        // 疲劳累积小憩：仅"普通模式"（只在 idle 时出场）保留旧节奏 —— 漫步够久就"累了"趴下省电。
        // 始终在场模式（自由活动 / 在线 AI / fomo）改成"只在用户 3min 没操作时深睡"（见 1.4），
        // 平时一直逛不自己打盹（用户偏好：平时只逛不睡，空闲才睡）。
        if !isAlwaysShownMode {
            walkAccum += dt
            if walkAccum >= restThreshold {
                enterRest(now: now)
                return
            }
        }
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

    /// 静止/钉住模式 tick —— 桌宠停在用户放置处，只保留呼吸·眨眼·偶尔张望伸懒腰等微动作。
    /// 不漫步、不追鼠标、不巡视、不回家、不传送、不疲劳深睡；位置只由用户拖动改变。
    private func tickPinned(now: Date, win: NSWindow, screen: NSScreen) {
        state.isWalking = false
        state.isChasing = false

        // 气泡自动隐藏（保留偶尔冒一句的趣味）
        if let hide = bubbleHideAt, now >= hide {
            state.bubbleVisible = false
            bubbleHideAt = nil
            nextBubbleAt = now.addingTimeInterval(randomBubbleInterval())
        }

        // hover：停下（眼睛已在 sprite 内部跟随鼠标），不额外动作
        if isHovering {
            syncBubbleWindow()
            return
        }

        // 暂停/表演态：进行中保持；到点收尾排下一次。这些表演（张望/伸懒腰/抛球/搭建等）都在原地。
        if let until = pauseEndsAt {
            if now >= until {
                pauseEndsAt = nil
                state.pose = .rest
                state.activity = .idle
                state.isJumping = false
                performanceTask?.cancel(); performanceTask = nil
                nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            } else {
                syncBubbleWindow()
                return
            }
        } else if let next = nextPauseAt, now >= next {
            beginIdlePerformance(now: now)
            syncBubbleWindow()
            return
        } else if nextPauseAt == nil {
            // 刚进入钉住 / 刚收尾还没排程 → 排一次，让微动作循环不断
            nextPauseAt = now.addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
        }

        // 偶尔冒一句气泡（按时段挑台词）
        if let next = nextBubbleAt, now >= next, !state.bubbleVisible {
            showBubble(text: pickQuote(from: ClawdQuotes.contextualBucket()), duration: 2.4)
        }

        state.pose = .rest
        syncBubbleWindow()
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
        let persona: String
        switch state.visual {
        case .clawd:    persona = "Clawd 🦞"
        case .monster:  persona = "小怪兽 👾"
        case .cloud:    persona = "云朵小精灵 ☁️"
        case .fox:      persona = "九尾狐 fomo 🦊"
        case .horse:    persona = "金黄小马 🐴"
        case .terminal: persona = "终端小精灵 💻"
        case .bear:     persona = "小青怪 👓"
        }
        // Phase 5-3：桌宠短评跟随界面语言（中文限 10 字、英文限 ~8 词）
        switch LocaleManager.currentLanguage() {
        case .zh:
            let kind = icon.isFolder ? "文件夹" : "文件"
            return """
            你是桌面宠物 \(persona)，正在用户桌面闲逛，发现了一个\(kind)。
            请用**不超过 10 个汉字**的一句话，用轻松、好奇、可爱的口吻评论它的名字。
            不要加引号、不要 emoji、不要解释、不要省略号。
            \(kind)名: \(icon.name)
            """
        case .en:
            let kind = icon.isFolder ? "folder" : "file"
            return """
            You are the desktop pet \(persona), wandering on the user's desktop, and you spotted a \(kind).
            In **no more than 8 English words**, comment on its name in a light, curious, playful tone.
            No quotes, no emoji, no explanation, no ellipsis.
            \(kind) name: \(icon.name)
            """
        }
    }

    /// 本地兜底文案 —— Hermes 没配 / 网络挂 / 限流时用。
    /// 按当前桌宠形象给不同口吻：Clawd 用嗅嗅 / 螃蟹腔，小马用哒哒 / 嗅嗅，云朵用飘飘 / 看看
    private func localFallbackQuote(for icon: DesktopIcon) -> String {
        // 每个池一个 key，多句用 `|` 分隔（见 L10nPet），读出后 split 再随机选一句
        let folderKey: String
        let fileKey: String
        switch state.visual {
        case .clawd:
            folderKey = "pet.sniff.clawd.folder"
            fileKey   = "pet.sniff.clawd.file"
        case .monster:
            folderKey = "pet.sniff.monster.folder"
            fileKey   = "pet.sniff.monster.file"
        case .cloud:
            folderKey = "pet.sniff.cloud.folder"
            fileKey   = "pet.sniff.cloud.file"
        case .fox:
            folderKey = "pet.sniff.fox.folder"
            fileKey   = "pet.sniff.fox.file"
        case .horse:
            folderKey = "pet.sniff.horse.folder"
            fileKey   = "pet.sniff.horse.file"
        case .terminal:
            folderKey = "pet.sniff.terminal.folder"
            fileKey   = "pet.sniff.terminal.file"
        case .bear:
            folderKey = "pet.sniff.bear.folder"
            fileKey   = "pet.sniff.bear.file"
        }
        let pool = L(icon.isFolder ? folderKey : fileKey).split(separator: "|").map(String.init)
        return pool.randomElement() ?? L("pet.sniff.default")
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

        // 钉住模式：松手即停在原地（记住位置），不嗅文件、不走回菜单栏
        if isPinnedMode {
            if let screen = targetScreen() { savePinnedPosition(on: screen) }
            state.pose = .rest
            state.activity = .idle
            state.isWalking = false
            nextPauseAt = Date().addingTimeInterval(Double.random(in: Self.pauseEveryMin...Self.pauseEveryMax))
            Haptic.tap(.alignment)
            return
        }

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
        let pick = (filtered.randomElement() ?? pool.first) ?? L("pet.bubble.fallback")
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
                showBubble(text: L("pet.bubble.feedMe"), duration: 30)   // 由 exit / drop 提前结束
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
        showBubble(text: L("pet.bubble.chewing", shortName), duration: 2.0)

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
        state.lowPower = false
        restingUntil = nil
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
    /// 当前活动场景 —— 桌宠随机表演的小动作（睡觉 / 抛球 / 搭建 / 开心）。
    /// 由 ClawdWalkController 的表演调度设置；ClawdWalkView 据此叠对应道具层。
    var activity: ClawdActivity = .idle
    /// 睡着时"睁一只眼偷瞄" —— 用户在远处操作电脑（打字/动鼠标但没凑近）时置 true。
    /// 只在 activity == .sleeping 时影响渲染（ClawdView）。鼠标真靠近会直接醒（见 tick）。
    var peeking: Bool = false
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

    /// 低功耗休息态 —— 桌宠"跑累了趴下休息"时置 true，sprite 渲染降到 12fps（呼吸/眨眼仍流畅）省 CPU。
    /// 由 ClawdWalkController 的疲劳状态机驱动（TODO Step 7 节能）。
    var lowPower: Bool = false

    /// 拖拽进行中临时冻结 —— 用户往聊天窗拖文件时置 true，彻底停 sprite TimelineView，
    /// 把主线程让给拖拽追踪，避免桌宠走动的每帧重渲染跟拖拽抢资源导致卡顿。松手后由 Controller 恢复。
    var dragPaused: Bool = false

    /// Wave A1 实时存在感：每次 UserIntentRecorder 落库一条意图就 +1，
    /// ClawdWalkView 监听数值变化触发"瞥一眼"动画（rotation 摆头 + 白色 flash）。
    /// 用 Int 而非 Bool / Date 是为了让 .onChange 准确捕获每次触发（同值不触发）
    var glancePulse: Int = 0
}

/// 桌面漫步支持的像素宠物视觉。
/// - clawd: 橙色螃蟹（Claude Code mode）
/// - monster: 红色小怪兽（在线 AI / directAPI mode，HermesPet Core 吉祥物，跟灵动岛 MonsterIslandSprite 一致）
/// - cloud: indigo 云朵（已弃用为 directAPI 形象，保留枚举值兼容旧逻辑；自动戴眼镜切 vision）
/// - horse: 金黄小马（Hermes Gateway mode，飞马 Pegasus 形象）
/// - terminal: 终端窗口（Codex mode，macOS 风格 Terminal.app + 小腿）
enum PetVisualKind {
    case clawd
    case monster
    case cloud
    case fox        // OpenClaw mode 的 fomo 九尾狐
    case horse
    case terminal
    case bear       // QwenCode 的布尔熊（见 BearSprite.swift）
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

/// Clawd 心情台词 —— 按情境分组，让出现时机有上下文。
/// 每个池一句一句用 `|` 存在翻译表里（key 见 L10nPet），读出后 split。
@MainActor
fileprivate enum ClawdQuotes {
    /// 把一个台词池 key 读出来并按 `|` 拆成数组
    private static func pool(_ key: String) -> [String] {
        L(key).split(separator: "|").map(String.init)
    }

    /// 普通漫步时随机冒
    static var idle: [String] { pool("pet.quote.idle") }
    /// 早上 6-10 点
    static var morning: [String] { pool("pet.quote.morning") }
    /// 深夜 22-2 点
    static var lateNight: [String] { pool("pet.quote.lateNight") }
    /// 鼠标靠近时的招呼
    static var greetings: [String] { pool("pet.quote.greetings") }
    /// 撞到屏幕边缘
    static var bumps: [String] { pool("pet.quote.bumps") }
    /// 跑累了进入休息态时冒
    static var tired: [String] { pool("pet.quote.tired") }
    /// 休息够了起身时冒
    static var refreshed: [String] { pool("pet.quote.refreshed") }

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
        case .monster:  return paletteStore.palette(for: .directAPI)
        case .cloud:    return paletteStore.palette(for: .directAPI)
        case .fox:      return paletteStore.palette(for: .openclaw)
        case .horse:    return paletteStore.palette(for: .hermes)
        case .terminal: return paletteStore.palette(for: .codex)
        case .bear:     return paletteStore.palette(for: .qwenCode)
        }
    }

    var body: some View {
        ZStack {
            // 按当前宠物种类切渲染。两种 sprite 应用同一套 scale/offset/animation modifier，
            // 保证 walk/jump/drag/facing 等手势行为视觉一致。
            Group {
                let palette = currentPalette
                // 桌宠隐藏时（orderOut 后 spriteAnimated=false），sprite 切静态帧，
                // sprite 内部 TimelineView 不再空转。
                // 休息态（lowPower）同样彻底停 TimelineView —— 关键：.animation schedule 会持续
                // 驱动屏幕刷新周期（即便降帧也不停 step），连带每个周期触发所有窗口（含不可见的
                // 聊天窗 fullSizeContentView）重算 drag margins + 遍历焦点树，烧满 CPU。只有完全
                // 去掉 TimelineView（画静态帧）才能让 display cycle 真正停下来。桌宠"睡着"本就静止。
                // 偷玩电脑态正面 sprite 被隐藏（opacity 0），同时停掉它的 TimelineView 省电
                // （长表演不能让隐藏的 sprite 30fps 空转；贪吃蛇/身体晃各有自己的低频驱动）
                let anim = state.spriteAnimated && !state.lowPower && !state.dragPaused
                          && state.activity != .gaming
                switch state.visual {
                case .clawd:
                    // 把 state.isWalking 传给 ClawdView，让它内部播放官方走路动画
                    // （4 腿对角交替、身体 bob、手臂上下摆 —— 这些是 SVG 原版 keyframe，
                    // 不再用 SwiftUI 外层 bobOffset 重复模拟）
                    ClawdView(pose: state.pose, height: clawdHeight, isWalking: state.isWalking,
                              palette: palette, animated: anim,
                              activity: state.activity, peeking: state.peeking)
                case .monster:
                    // 在线 AI 的红色小怪兽 —— 跟灵动岛 MonsterIslandSprite 同款像素渲染。
                    // 怪兽无走路腿部动画，漫步靠 NSWindow 横移 + 自带呼吸/眨眼/朝向(pose) 表达生命感。
                    MonsterPixelView(pose: state.pose, height: clawdHeight,
                                     isWorking: state.isWalking, palette: palette, animated: anim)
                case .bear:
                    // QwenCode 的青色戴眼镜小怪兽 —— 在线 AI 红怪兽变体
                    MonsterPixelView(pose: state.pose, height: clawdHeight,
                                     isWorking: state.isWalking, palette: palette, animated: anim, wearsGlasses: true)
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
            // 休息态把 sprite 帧率从 30fps 降到 12fps（呼吸/眨眼仍流畅）省 CPU；走动/被逗时恢复 30fps
            .environment(\.spriteFrameInterval, state.lowPower ? 1.0/12.0 : 1.0/30.0)
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
            // 偷玩电脑态：正面 sprite 隐藏，改由 activityProps 里的桌前背面场景呈现
            .opacity(state.activity == .gaming ? 0 : 1)
            .contentShape(Rectangle())   // 透明 padding 不接收点击
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 魔法师披风 —— 放 .background（在 Clawd 身后），搭建态时从肩部垂下、向两侧飘。
        .background { activityBackdrop }
        // 活动道具层 —— 桌宠随机表演时叠的小道具（Zzz / 彩球 / 锤子 / 星星 / 巫师帽）。
        // 放在 scaleEffect(镜像) 之外，朝左时道具不跟着翻转；都 allowsHitTesting(false) 不抢点击。
        .overlay { activityProps }
        .animation(.easeInOut(duration: 0.35), value: state.activity)
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
        .help(L("pet.walk.help"))
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

    /// 活动道具层 —— 按 state.activity 叠对应的小道具。各道具自带动画、各自定位。
    /// 暂时只 Clawd 螃蟹渲染（按用户要求先专注 Clawd）；其它宠物 activity 恒 .idle，天然全空。
    @ViewBuilder
    private var activityProps: some View {
        if state.visual == .clawd {
            switch state.activity {
            case .sleeping:
                // 睡觉：头顶右上飘 Zzz
                SleepingZzzView(color: currentPalette.primary, baseHeight: clawdHeight)
                    .offset(x: clawdHeight * 0.32, y: -clawdHeight * 0.34)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            case .juggling:
                // 抛接：头顶上方 3 颗彩球抛接
                JugglingBallsView(baseHeight: clawdHeight)
                    .offset(y: -clawdHeight * 0.30)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            case .building:
                // 搭建：Clawd 举魔法棒"遥控"悬浮锤子敲方块 + 彩色魔法粒子（小魔法师）
                MagicBuildView(baseHeight: clawdHeight, facingRight: state.facingRight)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            case .happy:
                // 开心：周身冒星星（蹦跶由 controller 驱动 isJumping）
                HappySparklesView(baseHeight: clawdHeight)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            case .music:
                // 听音乐：顶部彩色光束打下来（蹦迪感）+ 周身飘彩色音符
                ZStack {
                    StageLightsView(baseHeight: clawdHeight)
                    MusicNotesView(baseHeight: clawdHeight)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            case .sweeping:
                // 扫地：拿扫帚左右扫 + 灰尘
                BroomSweepView(baseHeight: clawdHeight, facingRight: state.facingRight)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            case .gaming:
                // 偷玩电脑：变出整张桌子，背对着坐在椅子上玩贪吃蛇（窗口已临时放大）
                GamingDeskView(baseHeight: clawdHeight, bodyColor: currentPalette.primary)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            case .idle:
                EmptyView()
            }
        }
    }

    /// 活动背景层（在 Clawd 身后）—— 目前只有搭建态的魔法师披风。
    @ViewBuilder
    private var activityBackdrop: some View {
        if state.visual == .clawd, state.activity == .building {
            WizardCapeView(baseHeight: clawdHeight)
                .allowsHitTesting(false)
                .transition(.opacity)
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

/// 睡觉态头顶的 "Zzz" —— 三个由小到大、向右上方飘的 Z，错峰呼吸式淡入淡出。
///
/// **省电要点**：桌宠"睡着"（lowPower）时主体 sprite 是静态帧（TimelineView 已停，见
/// chat_window_idle_cpu 决策）。这层 Zzz 用 SwiftUI `withAnimation(.repeatForever)` 的
/// **Core Animation 隐式动画**驱动 —— 在渲染服务进程插值，不会每帧重跑 SwiftUI body、
/// 也不复活 Canvas 的逐帧重绘，主线程几乎零开销。view 随 lowPower 出现/消失，
/// 动画也随 onAppear / 视图销毁自动启停。
struct SleepingZzzView: View {
    /// Z 的颜色（用宠物主色，跟身体协调）
    var color: Color
    /// 基准尺寸 = clawdHeight，三个 Z 按比例缩放（桌宠放大档位时 Zzz 同步变大）
    var baseHeight: CGFloat

    /// 三个 Z 的当前透明度，由 onAppear 里的 repeatForever 动画错峰拉到 1.0 再回落
    @State private var opacities: [Double] = [0.12, 0.12, 0.12]

    var body: some View {
        // bottomLeading 锚点：最小的 Z 在左下（贴近头顶），往右上方越来越大
        ZStack(alignment: .bottomLeading) {
            zChar(0, size: baseHeight * 0.20, dx: 0,                  dy: 0)
            zChar(1, size: baseHeight * 0.26, dx: baseHeight * 0.17,  dy: -baseHeight * 0.13)
            zChar(2, size: baseHeight * 0.32, dx: baseHeight * 0.40,  dy: -baseHeight * 0.28)
        }
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        .onAppear { startBreathing() }
    }

    private func zChar(_ i: Int, size: CGFloat, dx: CGFloat, dy: CGFloat) -> some View {
        Text("Z")
            .font(.system(size: size, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .opacity(opacities[i])
            .offset(x: dx, y: dy)
    }

    /// 三个 Z 错峰呼吸：每个 0.85s 一来回，依次延迟 0.28s 启动 → 像"Z…z…z…"逐个亮
    private func startBreathing() {
        for i in 0..<3 {
            withAnimation(
                .easeInOut(duration: 0.85)
                    .repeatForever(autoreverses: true)
                    .delay(Double(i) * 0.28)
            ) {
                opacities[i] = 1.0
            }
        }
    }
}

/// 抛接态：头顶上方 3 颗彩球做"左手抛到右手"的连续抛接。
///
/// 用 `TimelineView(.animation)` 按时间算每颗球的抛物线位置（x 用 cos 在两手之间来回，
/// y 用 |sin| 起落），三颗球相位各差 1/3 周期 → 永远有球在空中，看着像在杂耍。
/// 只在 .juggling 表演的几秒内存在（view 随 activity 出现/销毁），桌宠漫步本就 30fps，
/// 这几秒多一个 TimelineView 不增显著负担；睡眠等静止态不会触发。
struct JugglingBallsView: View {
    var baseHeight: CGFloat

    /// 三颗球的颜色 —— 暖红 / 明黄 / 天蓝，明快好认
    private let ballColors: [Color] = [
        Color(red: 0.95, green: 0.43, blue: 0.40),
        Color(red: 0.98, green: 0.78, blue: 0.32),
        Color(red: 0.40, green: 0.70, blue: 0.95),
    ]

    var body: some View {
        let d = baseHeight * 0.17          // 球直径
        let spread = baseHeight * 0.46     // 两手水平间距
        let peak = baseHeight * 0.52       // 抛物线最高
        let period = 0.95                  // 一颗球一来回的秒数

        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = ((t / period) + Double(i) / 3.0)
                        .truncatingRemainder(dividingBy: 1.0)
                    let x = -spread / 2 * CGFloat(cos(2 * .pi * p))
                    let y = peak * CGFloat(abs(sin(2 * .pi * p)))
                    Circle()
                        .fill(ballColors[i])
                        .frame(width: d, height: d)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .offset(x: x, y: -y)   // y 向上为负
                }
            }
            .frame(width: spread + d, height: peak + d, alignment: .bottom)
        }
    }
}

/// 搭建态（魔法师版）：Clawd 举着魔法棒，"遥控"一把悬浮的锤子去敲方块，
/// 棒尖与锤子周围迸发不断变色的彩色魔法粒子。
///
/// 为什么这么设计：螃蟹胳膊是固定像素、没法真"握住"工具（上一版直接拿锤子被吐槽没实感）。
/// 改成"举法棒遥控悬浮工具"后，锤子本就该飘在半空，不必贴合手部，反而自然、可爱、有梗。
/// - 敲击：~7fps Task 切 `struck`，悬浮锤子一下下压向方块 + 迸火花。
/// - 彩色特效：对魔法元素套 `repeatForever` 的 `.hueRotation(spin)`，颜色不停流转（CA 驱动，省）。
/// - facingRight：整套工作台镜像到桌宠面朝那侧。
struct MagicBuildView: View {
    var baseHeight: CGFloat
    var facingRight: Bool

    @State private var struck = false
    @State private var spin: Double = 0
    @State private var wiggle: Double = 0
    @State private var tapTask: Task<Void, Never>?

    /// 魔法基色（紫）—— 经 hueRotation 流转成彩虹各色
    private let magicBase = Color(red: 0.66, green: 0.45, blue: 1.0)

    var body: some View {
        let H = baseHeight
        let s: CGFloat = facingRight ? 1 : -1
        let workX = s * H * 0.85      // 工作台推到 Clawd 身体侧外，不跟它重叠
        ZStack {
            // 巫师帽（戴头顶）
            wizardHat(H: H)

            // 被敲的方块（木色）
            RoundedRectangle(cornerRadius: H * 0.03, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.80, green: 0.62, blue: 0.40),
                                              Color(red: 0.55, green: 0.40, blue: 0.24)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: H * 0.34, height: H * 0.15)
                .offset(x: workX, y: H * 0.30)

            // 悬浮锤子（被遥控，更大）—— 彩色光晕 + 敲下压向方块
            hammerShape(H: H)
                .shadow(color: magicBase.opacity(0.95), radius: H * 0.09)
                .hueRotation(.degrees(spin))
                .offset(x: workX, y: struck ? H * 0.10 : -H * 0.07)

            // 敲击火花
            Image(systemName: "sparkle")
                .font(.system(size: H * 0.22, weight: .bold))
                .foregroundStyle(magicBase)
                .hueRotation(.degrees(spin))
                .opacity(struck ? 1 : 0)
                .offset(x: workX, y: H * 0.16)

            // 魔法粒子：棒尖 → 锤子 一路飘几颗，颜色错峰流转
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: H * (0.08 + 0.014 * CGFloat(i)), weight: .bold))
                    .foregroundStyle(magicBase)
                    .hueRotation(.degrees(spin + Double(i) * 50))
                    .opacity(0.9)
                    .offset(x: s * H * (0.58 + 0.07 * CGFloat(i)),
                            y: -H * 0.10 + H * 0.04 * CGFloat(i))
            }

            // 魔法棒（桌宠举着、向外伸，更大）
            wandShape(H: H, s: s)
        }
        .frame(width: H, height: H)
        .onAppear { start(s: s) }
        .onDisappear { tapTask?.cancel(); tapTask = nil }
    }

    /// 巫师帽：圆锥帽身 + 宽帽檐 + 帽尖星星，戴在头顶
    private func wizardHat(H: CGFloat) -> some View {
        ZStack {
            // 帽檐（椭圆）
            Ellipse()
                .fill(Color(red: 0.34, green: 0.22, blue: 0.55))
                .frame(width: H * 0.62, height: H * 0.14)
                .offset(y: H * 0.18)
            // 帽身（圆锥）
            Triangle()
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.40, blue: 0.85),
                                              Color(red: 0.34, green: 0.22, blue: 0.58)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: H * 0.46, height: H * 0.44)
            // 帽尖星星（流光）
            Image(systemName: "star.fill")
                .font(.system(size: H * 0.13, weight: .bold))
                .foregroundStyle(magicBase)
                .hueRotation(.degrees(spin))
                .offset(y: -H * 0.20)
        }
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        .offset(y: -H * 0.66)   // 戴到头顶上方（帽檐正好落在头顶线）
    }

    private func hammerShape(H: CGFloat) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: H * 0.025, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: H * 0.32, height: H * 0.14)
            RoundedRectangle(cornerRadius: H * 0.02, style: .continuous)
                .fill(Color(red: 0.62, green: 0.45, blue: 0.28))
                .frame(width: H * 0.07, height: H * 0.24)
        }
    }

    private func wandShape(H: CGFloat, s: CGFloat) -> some View {
        ZStack {
            // 棒身（更长更粗）
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: H * 0.055, height: H * 0.42)
            // 棒尖星星（更大、流光）
            Image(systemName: "sparkles")
                .font(.system(size: H * 0.24, weight: .bold))
                .foregroundStyle(magicBase)
                .hueRotation(.degrees(spin))
                .offset(y: -H * 0.24)
        }
        .rotationEffect(.degrees(Double(s) * -42))            // 斜举向外
        .rotationEffect(.degrees(wiggle), anchor: .bottom)    // 轻轻挥
        .offset(x: s * H * 0.42, y: H * 0.02)                 // 举在身体侧前方
    }

    private func start(s: CGFloat) {
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            spin = 360
        }
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            wiggle = Double(s) * 10
        }
        tapTask?.cancel()
        tapTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.10)) { struck = true }
                try? await Task.sleep(nanoseconds: 130_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.18)) { struck = false }
                try? await Task.sleep(nanoseconds: 340_000_000)
                if Task.isCancelled { return }
            }
        }
    }
}

/// 等腰三角形（帽身用）
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 魔法师披风形状：窄肩 → 宽下摆，下摆带波浪
struct CapeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        let topHalf = w * 0.16
        p.move(to: CGPoint(x: w / 2 - topHalf, y: 0))
        p.addLine(to: CGPoint(x: w / 2 + topHalf, y: 0))
        p.addLine(to: CGPoint(x: w, y: h))                                   // 右侧外扩到底
        p.addQuadCurve(to: CGPoint(x: w * 0.66, y: h * 0.90),                // 波浪下摆
                       control: CGPoint(x: w * 0.84, y: h))
        p.addQuadCurve(to: CGPoint(x: w * 0.34, y: h * 0.90),
                       control: CGPoint(x: w * 0.50, y: h * 0.82))
        p.addQuadCurve(to: CGPoint(x: 0, y: h),
                       control: CGPoint(x: w * 0.16, y: h))
        p.closeSubpath()                                                     // 左侧收回窄肩
        return p
    }
}

/// 魔法师披风 —— 在 Clawd 身后，从肩部垂下、向两侧外扩，轻轻摆动。
/// 大部分被身体挡住，只露出两侧 + 下摆，配合巫师帽点出"魔法师"。
struct WizardCapeView: View {
    var baseHeight: CGFloat
    @State private var sway = false

    var body: some View {
        let H = baseHeight
        CapeShape()
            .fill(LinearGradient(colors: [Color(red: 0.46, green: 0.33, blue: 0.78),
                                          Color(red: 0.26, green: 0.16, blue: 0.46)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: H * 1.9, height: H * 0.66)
            .offset(y: H * 0.14)
            .rotationEffect(.degrees(sway ? 2.5 : -2.5), anchor: .top)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    sway = true
                }
            }
    }
}

/// 开心态：桌宠周身错峰冒出几颗 `sparkle` 星星（缩放 + 透明度脉动）。
/// 蹦跶动作由 ClawdWalkController 驱动 `state.isJumping` 完成，这里只负责星星。
struct HappySparklesView: View {
    var baseHeight: CGFloat
    @State private var on = false

    /// 星星相对桌宠中心的位置（×baseHeight）
    private let spots: [(CGFloat, CGFloat)] = [
        (-0.52, -0.30), (0.52, -0.22), (0.0, -0.58), (-0.40, 0.22), (0.44, 0.18),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<spots.count, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: baseHeight * 0.22, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.86, blue: 0.42))
                    .scaleEffect(on ? 1.0 : 0.25)
                    .opacity(on ? 1.0 : 0.15)
                    .offset(x: spots[i].0 * baseHeight, y: spots[i].1 * baseHeight)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.11),
                        value: on
                    )
            }
        }
        .onAppear { on = true }
    }
}

/// 听音乐态：桌宠周身飘几枚彩色音符，各自轻轻上浮 + 脉动 + 颜色流转。
/// 摇头晃脑由 ClawdWalkController 驱动 pose，这里只负责音符。
struct MusicNotesView: View {
    var baseHeight: CGFloat
    @State private var on = false
    @State private var spin: Double = 0

    /// 每枚音符：(x, y 基准位置 ×H, 符号名)。摆在身体两侧与上方，避开正中
    private let notes: [(CGFloat, CGFloat, String)] = [
        (-0.62, -0.22, "music.note"),
        (0.60, -0.16, "music.note"),
        (-0.42, -0.46, "music.note.list"),
        (0.46, -0.42, "music.note"),
        (0.05, -0.58, "music.note"),
    ]

    var body: some View {
        let H = baseHeight
        ZStack {
            ForEach(0..<notes.count, id: \.self) { i in
                Image(systemName: notes[i].2)
                    .font(.system(size: H * (0.16 + 0.02 * CGFloat(i % 3)), weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.50, blue: 1.0))
                    .hueRotation(.degrees(spin + Double(i) * 60))
                    .opacity(on ? 1.0 : 0.2)
                    .offset(x: notes[i].0 * H,
                            y: notes[i].1 * H + (on ? -H * 0.06 : H * 0.02))   // 轻轻上浮
                    .animation(.easeInOut(duration: 0.7)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.18), value: on)
            }
        }
        .onAppear {
            on = true
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                spin = 360
            }
        }
    }
}

/// 听音乐态的舞台彩灯 —— 几道不同颜色的光束从顶部斜射下来，打在跳舞的 Clawd 身上。
/// 光束颜色不停流转（hueRotation）、左右摆动（像摇头灯）、随拍闪烁；用 plusLighter 叠加混色，
/// 越叠越亮，像蹦迪现场。光束顶端（光源）在窗口上方被裁掉，正好像"灯装在上面照下来"。
struct StageLightsView: View {
    var baseHeight: CGFloat
    @State private var spin: Double = 0
    @State private var sway: Double = 0
    @State private var flicker = false

    private let beamColors: [Color] = [
        Color(red: 1.0, green: 0.30, blue: 0.45),   // 红
        Color(red: 1.0, green: 0.85, blue: 0.30),   // 黄
        Color(red: 0.35, green: 0.90, blue: 0.55),  // 绿
        Color(red: 0.40, green: 0.60, blue: 1.0),   // 蓝
    ]
    private let baseAngles: [Double] = [-27, -10, 10, 27]

    var body: some View {
        let H = baseHeight
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Triangle()
                    .fill(LinearGradient(colors: [beamColors[i].opacity(0.55),
                                                  beamColors[i].opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: H * 0.55, height: H * 1.45)
                    .hueRotation(.degrees(spin + Double(i) * 28))
                    .blendMode(.plusLighter)
                    .opacity(flicker ? 0.95 : 0.5)
                    .rotationEffect(.degrees(baseAngles[i] + (i % 2 == 0 ? sway : -sway)),
                                    anchor: .top)
                    .offset(y: -H * 0.62)   // 光源顶端推到窗口上方（裁掉）→ 从上方照下来
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) { spin = 360 }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sway = 11 }
            withAnimation(.easeInOut(duration: 0.38).repeatForever(autoreverses: true)) { flicker = true }
        }
    }
}

/// 偷玩电脑大场景（v2，黑色家具版）：一把**大黑色办公椅背对我们**，Clawd 只有脑袋从椅背上方探出来
/// （看不到脸 = 背对），上方是显示器（亮屏跑贪吃蛇），后面一张黑桌子。一眼就是"有人背对着坐着玩电脑"。
/// 去掉了之前的橙色身体/手臂/键盘（那让人误以为正面抱手机）。整套画在临时放大的窗口里。
struct GamingDeskView: View {
    var baseHeight: CGFloat
    var bodyColor: Color            // Clawd 主色（探出的脑袋）
    @State private var bob = false   // 玩游戏时脑袋轻晃

    private let furnitureTop = Color(white: 0.17)
    private let furnitureBot = Color(white: 0.08)

    var body: some View {
        let H = baseHeight
        let screenW = H * 1.25
        let screenH = screenW * 6.0 / 9.0
        ZStack {
            // —— 显示器（最后方，屏幕朝我们）——
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: H * 0.05, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.05)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: screenW + H * 0.11, height: screenH + H * 0.11)
                    SnakeGameView(screenWidth: screenW)
                        .frame(width: screenW, height: screenH)
                        .clipShape(RoundedRectangle(cornerRadius: H * 0.02, style: .continuous))
                    RoundedRectangle(cornerRadius: H * 0.02, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: screenW, height: screenH)
                }
                .shadow(color: Color(red: 0.3, green: 1.0, blue: 0.5).opacity(0.35), radius: H * 0.06)
                Rectangle().fill(Color(white: 0.12)).frame(width: H * 0.09, height: H * 0.2)
            }
            .offset(y: -H * 1.32)

            // —— 黑桌子（紧凑梯形俯视：键盘 + 鼠标）——
            ZStack {
                Trapezoid()
                    .fill(LinearGradient(colors: [Color(white: 0.20), furnitureBot],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: H * 2.8, height: H * 0.92)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                // 键盘（深灰，键帽点阵）
                ZStack {
                    RoundedRectangle(cornerRadius: H * 0.03, style: .continuous)
                        .fill(Color(white: 0.26))
                        .frame(width: H * 1.05, height: H * 0.4)
                    VStack(spacing: H * 0.04) {
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: H * 0.04) {
                                ForEach(0..<6, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 0.5)
                                        .fill(Color(white: 0.5)).frame(width: H * 0.11, height: H * 0.07)
                                }
                            }
                        }
                    }
                }
                .offset(x: -H * 0.18, y: H * 0.16)
                // 鼠标（往中间收，别让右手伸太远）
                Ellipse().fill(Color(white: 0.55))
                    .frame(width: H * 0.2, height: H * 0.3)
                    .offset(x: H * 0.46, y: H * 0.16)
            }
            .offset(y: -H * 0.42)

            // —— Clawd 橙色身体 + 双臂 + 双手（整块画在 Canvas 里，保证手臂跟身体相连）——
            //    左手搭键盘、右手够鼠标；手臂根部被身体盖住 → 像从身体伸出去。都带深色描边。
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + x * H, y: cy + y * H) }
                let body = GraphicsContext.Shading.color(bodyColor)
                let edge = GraphicsContext.Shading.color(.black.opacity(0.3))
                let lw: CGFloat = max(0.6, H * 0.028)
                let armW = H * 0.24   // 加粗：不要细长像触手
                let leftHand = P(-0.18, -0.22), rightHand = P(0.44, -0.2)
                let leftSh = P(-0.17, 0.14), rightSh = P(0.17, 0.14)
                // 手臂（先描边后主色），先画 → 根部被身体盖住
                for (sh, hd) in [(leftSh, leftHand), (rightSh, rightHand)] {
                    var pa = Path(); pa.move(to: sh); pa.addLine(to: hd)
                    ctx.stroke(pa, with: edge, style: StrokeStyle(lineWidth: armW + lw * 2, lineCap: .round))
                    ctx.stroke(pa, with: body, style: StrokeStyle(lineWidth: armW, lineCap: .round))
                }
                // 双手（圆爪，比手臂略大 + 描边）
                for hd in [leftHand, rightHand] {
                    let r = H * 0.16
                    let rc = CGRect(x: hd.x - r, y: hd.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rc), with: body)
                    ctx.stroke(Path(ellipseIn: rc), with: edge, lineWidth: lw)
                }
                // 身体 + 平头（圆角矩形，最后画盖住手臂根部）
                let bw = H * 0.8, bh = H * 0.85
                let bc = P(0, 0.3)
                let brect = CGRect(x: bc.x - bw / 2, y: bc.y - bh / 2, width: bw, height: bh)
                let bpath = Path(roundedRect: brect, cornerRadius: H * 0.16, style: .continuous)
                ctx.fill(bpath, with: body)
                ctx.stroke(bpath, with: edge, lineWidth: lw)
            }
            .frame(width: H * 3, height: H * 2.6)
            .offset(x: bob ? H * 0.02 : -H * 0.02)

            // —— 黑椅背（背对我们，缩小到比 Clawd 略大）——
            RoundedRectangle(cornerRadius: H * 0.34, style: .continuous)
                .fill(LinearGradient(colors: [furnitureTop, furnitureBot], startPoint: .top, endPoint: .bottom))
                .frame(width: H * 1.2, height: H * 1.2)
                .overlay(
                    Capsule().fill(Color.black.opacity(0.35)).frame(width: H * 0.09, height: H * 0.8)
                )
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(y: H * 0.72)

            // —— 椅子底座（小）——
            VStack(spacing: 0) {
                Rectangle().fill(Color(white: 0.12)).frame(width: H * 0.1, height: H * 0.22)
                Trapezoid().fill(LinearGradient(colors: [furnitureTop, furnitureBot],
                                                startPoint: .top, endPoint: .bottom))
                    .frame(width: H * 0.7, height: H * 0.12)
            }
            .offset(y: H * 1.35)
        }
        .scaleEffect(0.85)   // 整体再缩一档
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }

}

/// 贪吃蛇网格点
private struct SnakeCell: Equatable {
    var x: Int
    var y: Int
}

/// 屏幕里自动跑的贪吃蛇 —— 贪心朝豆子走、吃到变长、豆子换位、撞墙/自身就转向。
/// 用 `Timer.publish` + `.onReceive`（主线程定时器）每 0.16s 推进一格并刷新 Canvas，
/// 比 Task 更稳地触发视图重绘（之前 Task 驱动有时不重绘 → 画面像卡住）。
struct SnakeGameView: View {
    var screenWidth: CGFloat

    private static let cols = 9
    private static let rows = 6

    @State private var snake: [SnakeCell] = [SnakeCell(x: 3, y: 3), SnakeCell(x: 2, y: 3), SnakeCell(x: 1, y: 3)]
    @State private var food = SnakeCell(x: 6, y: 2)
    @State private var dir = SnakeCell(x: 1, y: 0)

    private let tick = Timer.publish(every: 0.16, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let cw = size.width / CGFloat(Self.cols)
            let ch = size.height / CGFloat(Self.rows)
            // 屏幕底（深绿黑）
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.05, green: 0.11, blue: 0.07)))
            // 豆子（红）
            let fr = CGRect(x: CGFloat(food.x) * cw + cw * 0.18, y: CGFloat(food.y) * ch + ch * 0.18,
                            width: cw * 0.64, height: ch * 0.64)
            ctx.fill(Path(ellipseIn: fr), with: .color(Color(red: 1.0, green: 0.42, blue: 0.42)))
            // 蛇身（头亮、身体稍暗）
            for (i, c) in snake.enumerated() {
                let r = CGRect(x: CGFloat(c.x) * cw + 0.5, y: CGFloat(c.y) * ch + 0.5,
                               width: cw - 1, height: ch - 1)
                let col = i == 0 ? Color(red: 0.55, green: 1.0, blue: 0.55)
                                 : Color(red: 0.30, green: 0.82, blue: 0.42)
                ctx.fill(Path(roundedRect: r, cornerRadius: max(0.5, cw * 0.18)), with: .color(col))
            }
        }
        .frame(width: screenWidth, height: screenWidth * CGFloat(Self.rows) / CGFloat(Self.cols))
        .onReceive(tick) { _ in step() }
    }

    private func valid(_ c: SnakeCell) -> Bool {
        c.x >= 0 && c.x < Self.cols && c.y >= 0 && c.y < Self.rows && !snake.dropLast().contains(c)
    }

    private func step() {
        guard let head = snake.first else { return }
        let dx = food.x - head.x, dy = food.y - head.y
        // 贪心：朝豆子方向（优先差距大的轴）
        var nd = dir
        if dx != 0 && (abs(dx) >= abs(dy) || dy == 0) {
            nd = SnakeCell(x: dx > 0 ? 1 : -1, y: 0)
        } else if dy != 0 {
            nd = SnakeCell(x: 0, y: dy > 0 ? 1 : -1)
        }
        // 不允许 180° 掉头
        if nd.x == -dir.x && nd.y == -dir.y { nd = dir }
        var nh = SnakeCell(x: head.x + nd.x, y: head.y + nd.y)
        // 撞墙 / 撞自己 → 依次试着转向；都不行就这帧不动（不要把蛇头插到非法格跑出屏幕）
        if !valid(nh) {
            var ok = false
            for cand in [SnakeCell(x: -nd.y, y: nd.x), SnakeCell(x: nd.y, y: -nd.x),
                         SnakeCell(x: -nd.x, y: -nd.y)] {
                let c = SnakeCell(x: head.x + cand.x, y: head.y + cand.y)
                if valid(c) { nd = cand; nh = c; ok = true; break }
            }
            if !ok { return }
        }
        dir = nd
        snake.insert(nh, at: 0)
        let ate = (nh == food)
        if ate { placeFood() }
        // 控长：蛇最长 5 节，绝不会填满网格把自己困死（之前会走进死角→蛇头跑出格子像卡住）
        if !ate || snake.count > 5 { snake.removeLast() }
    }

    private func placeFood() {
        for _ in 0..<20 {
            let c = SnakeCell(x: Int.random(in: 0..<Self.cols), y: Int.random(in: 0..<Self.rows))
            if !snake.contains(c) { food = c; return }
        }
    }
}

/// 扫地态：桌宠大幅度地左右挥扫帚 + 灰尘飞扬。扫帚绕握把端大角度来回摆、整体还左右平移，
/// 动作热烈；灰尘从扫帚头不断往上 + 向外飞散并淡出（飞扬感）。facingRight 镜像到面朝侧。
struct BroomSweepView: View {
    var baseHeight: CGFloat
    var facingRight: Bool
    @State private var sweep = false   // 扫帚大摆（autoreverses）
    @State private var flew = false    // 灰尘飞扬（autoreverses:false 循环）

    var body: some View {
        let H = baseHeight
        let s: CGFloat = facingRight ? 1 : -1
        ZStack {
            // 飞扬的灰尘 —— 从扫帚头往上 + 向外飞散，边飞边淡出，循环
            ForEach(0..<6, id: \.self) { i in
                let spread = CGFloat(i) - 2.5                  // -2.5…2.5 散开
                Ellipse()
                    .fill(Color(white: 0.72))
                    .frame(width: H * (0.12 - 0.01 * CGFloat(i % 3)),
                           height: H * (0.08 - 0.008 * CGFloat(i % 3)))
                    .opacity(flew ? 0.0 : 0.75)               // 飞起来后淡出
                    .scaleEffect(flew ? 1.4 : 0.5)
                    .offset(x: s * H * 0.58 + (flew ? s * H * 0.30 + spread * H * 0.06 : 0),
                            y: H * 0.38 + (flew ? -H * 0.40 : 0))   // 往上飞
                    .animation(.easeOut(duration: 0.7)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.11), value: flew)
            }

            // 扫帚（握把 + 扫帚头）—— 大角度绕握把端摆 + 整体随之平移，幅度大
            VStack(spacing: 0) {
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.72, green: 0.54, blue: 0.34),
                                                  Color(red: 0.52, green: 0.36, blue: 0.20)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: H * 0.055, height: H * 0.42)
                Trapezoid()
                    .fill(LinearGradient(colors: [Color(red: 0.94, green: 0.82, blue: 0.46),
                                                  Color(red: 0.78, green: 0.62, blue: 0.30)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: H * 0.26, height: H * 0.18)
            }
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            .rotationEffect(.degrees(sweep ? 32 : -32), anchor: .top)        // 大角度左右扫
            .offset(x: s * H * 0.46 + (sweep ? H * 0.10 : -H * 0.10), y: H * 0.08)  // 整体也平移
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                sweep = true
            }
            flew = true   // 触发灰尘飞扬循环（动画在每个 ForEach 元素上）
        }
    }
}

/// 上窄下宽梯形（扫帚头用）
struct Trapezoid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let topInset = r.width * 0.28
        p.move(to: CGPoint(x: r.minX + topInset, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - topInset, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
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
