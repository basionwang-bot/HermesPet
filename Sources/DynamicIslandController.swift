import AppKit
import SwiftUI

/// 与刘海融合的桌宠胶囊。
/// 默认（idle）：刘海两侧探出来一段，像 iPhone 灵动岛常驻态显示信息。
/// 悬停（hover）：横向收紧到刘海宽度、纵向也变短，像一个紧凑的可点击按钮。
@MainActor
final class DynamicIslandController {
    private(set) var pillWindow: NSWindow
    private let hostingView: NSHostingView<DynamicIslandPillView>
    private var visibilityObserver: NSObjectProtocol?

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
    /// 悬停（hover）状态：横向比刘海多出多少。
    /// **水滴动画**：idle 时两侧耳朵全宽（80）跟刘海融为一体；hover 时收窄到 4，
    /// 整体宽度几乎等同于 MacBook 硬件刘海宽度（auxiliaryTopArea 反推得到的真实像素），
    /// 视觉上像一滴墨从刘海正下方润下来，两侧耳朵随高度展开同步回缩
    private let hoverExtraWidth: CGFloat = 4

    init() {
        // window 始终是 idle 尺寸（也就是最大尺寸），命中区域 = 整个 window
        // 这样 hover 后形状收缩，鼠标若仍在 idle 范围内，hover 状态依然保持，不抖
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.level = HermesWindowLevel.dynamicIsland   // 最高层，见 WindowLevels.swift
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        self.pillWindow = window

        let hosting = NSHostingView(rootView: DynamicIslandPillView())
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 70)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        self.hostingView = hosting

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleChat))
        hosting.addGestureRecognizer(click)
        hosting.wantsLayer = true

        visibilityObserver = NotificationCenter.default.addObserver(
            forName: .init("HermesPetDynamicIslandVisibilityChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let enabled = (note.userInfo?["enabled"] as? Bool) ?? true
            enabled ? self?.show() : self?.hide()
        }

        positionWindow()
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

        // window 用 hover 最大尺寸，避免 hover 膨胀超出窗口边界产生残影
        let windowWidth  = actualNotchWidth  + idleExtraWidth
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
                "hoverExtraWidth": hoverExtraWidth
            ]
        )
    }

    // MARK: - Actions

    @objc private func toggleChat() {
        onTapped?()
    }
}

// MARK: - SwiftUI Pill View

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

    var body: some View {
        pillBodyWithStateObservers
            .onHover { hovering in
            // **水滴动画**：width 80→4 + height 32→64 + radius 14→22 三轴同步驱动。
            // 用 interpolatingSpring（mass=1.0, stiffness=180, damping=22）让水流感更连贯：
            //  · stiffness 180 比标准 spring 软，水滴下流不"砸"
            //  · damping 22 让收尾平滑无回弹
            //  · mass 1.0 给形变一点"惯性"，模拟液体黏滞性
            // 比之前的 spring(response:0.38, dampingFraction:0.82) 更像液体而非弹簧
            withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 180, damping: 22, initialVelocity: 0)) {
                isHovering = hovering
            }
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
        .onAppear {
            let hasKey = !(UserDefaults.standard.string(forKey: "apiKey") ?? "").isEmpty
            status = hasKey ? .connected : .unknown
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

    /// 胶囊本体 + 截屏闪光叠加 —— 抽出来让 SwiftUI 编译器在 body 里只面对 modifier 链
    private var pillBody: some View {
        VStack(spacing: 0) {
            ZStack {
                NotchShape(cornerRadius: currentRadius)
                    .fill(isInErrorState ? Color(red: 0.55, green: 0.32, blue: 0.05) : Color.black)
                pillContent
            }
            .frame(width: currentWidth, height: currentHeight)
            .scaleEffect(shutterScale)
            .overlay { shutterOverlay }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // hover 命中区严格限制到"硬件刘海几何区"，传**死高度**而非 inset
        // （SwiftUI 给 path(in:) 的 rect 是外层 maxFrame=windowHeight 64pt，
        //  之前用 inset 算出 56pt 命中区，鼠标贴近菜单栏就会误触发 —— 已修正）
        // idle:  hitHeight = notchHeight - 4 = 24pt（命中区严格在刘海可见 28pt 内，
        //        还要鼠标深入 4pt 才触发，杜绝菜单栏下沿误触）
        //        horizontalInset = idleExtraWidth/2 = 40pt（两侧耳朵延伸区不响应）
        // hover: hitHeight = windowHeight 64pt（覆盖完整水滴），horizontalInset = 0
        //        —— 鼠标在扩展区停留不会立刻丢 hover
        .contentShape(
            IslandHitShape(
                hitHeight: isExpanded ? (notchHeight + hoverDrop) : max(0, notchHeight - 4),
                horizontalInset: isExpanded ? 0 : idleExtraWidth / 2
            )
        )
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

    /// 工具调用卡片：[Clawd] [verb] [arg] · [M/N 步] · [Xs] + 底部进度条
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

    /// hover 卡片（鼠标悬停时显示 mode + 状态点 + 模型名）
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
            }
            .frame(maxHeight: .infinity)
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
