import AppKit
import SwiftUI

/// 顶到屏幕**物理最顶**（盖住刘海两侧菜单栏空白）的承载窗口。
///
/// - override `constrainFrameRect` 原样返回 —— 否则 macOS 26 默认会把窗口约束回 `screen.visibleFrame`
///   （菜单栏下方），顶不到屏幕顶就跟刘海黑区之间隔着一条菜单栏、没法连成一片（照搬 `EmbeddableIslandPanel`）。
/// - 用 NSPanel + `canBecomeKey=true` + `becomesKeyOnlyIfNeeded`：应用启动器有搜索框，需要能接键盘输入；
///   nonactivating panel 让它**不抢 app 焦点/不激活**，但点搜索框时按需成为 key 接收文字。
final class TopMergedStatsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// 承载「系统信息完整仪表盘」的独立 NSWindow，紧贴灵动岛下方展开。
///
/// **为什么独立窗口**：灵动岛 NSWindow 一旦 setFrame 改尺寸，macOS 26 上 NSHostingView 会触发
/// invalidateSafeAreaInsets → 嵌套 setNeedsUpdate → NSException 必崩（决策 #1）。所以
/// hover 想"完整展示"系统信息（远超灵动岛那 ~180×42pt 可用区）只能走独立窗口，
/// 范式几乎照搬 PermissionWindowController（决策 #16）：黑色 NotchShape 背景延续灵动岛凹槽，
/// 视觉上像"灵动岛长出一张仪表盘"，代码上两窗口完全独立、互不 setFrame。
///
/// **触发**：监听灵动岛 hover 通知（HermesPetIslandHoverChanged）显示；鼠标从灵动岛滑到面板时，
/// 面板自身的 hover（HermesPetSystemStatsPanelHover）接力，避免"一离开灵动岛就消失"的空档。
/// 仅在「灵动岛系统信息」开关开 + 没有 permission/question 卡占用同一空间时才弹。
@MainActor
final class SystemStatsPanelController {
    static var shared: SystemStatsPanelController?

    private let window: NSWindow
    private let state = SystemStatsPanelState()

    /// 面板宽度 = 灵动岛**真实 NSWindow 宽度**（刘海核心宽 + idleExtraWidth=80），跟灵动岛「耳朵」左右沿严格对齐。
    /// 用户要求「整体放大、一体」：面板撑到这个全宽，纯黑顶部直角紧贴刘海下沿 → 黑色跟刘海连成一片，
    /// 看着像「刘海整体放大成一块宽面板」（照搬 PermissionWindowController 的无缝范式，不再是窄水滴下的独立卡）。
    /// computed 每次实时从屏幕读（照搬 PermissionWindowController 的教训：存字段会错过首发通知）。
    /// 面板宽度（按面板**实际所在屏**算，不再固定读刘海屏）：
    /// = 该屏灵动岛窗口宽（刘海宽 / 悬浮回退 180，+ idleExtraWidth 80）+ **48 外扩**
    /// → 比灵动岛/悬浮胶囊每侧多盖 24pt，确保胶囊本体 + 光晕被完全盖住（用户：胶囊比较大，要盖更大）。
    private func cardWidth(on screen: NSScreen) -> CGFloat {
        let notchW: CGFloat
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea,
           let r = screen.auxiliaryTopRightArea {
            notchW = r.minX - l.maxX
        } else {
            notchW = 180   // 跟 DynamicIslandController floating 回退一致
        }
        return notchW + 80 + 48
    }
    private let cardHeight: CGFloat = 138

    // hover 接力状态：灵动岛在 hover 或面板自身在 hover，都算"应显示"
    private var islandHovering = false
    private var panelHovering = false
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    /// 「粘住」期间（应用/乐园等可交互大功能区）点面板外的全局点击监听 → 点空白处关闭
    private var clickOutsideMonitor: Any?

    /// 悬停多久才弹（黄金分割 0.618s）—— 避免鼠标一扫过灵动岛就弹、太敏感
    private let showDelay: TimeInterval = 0.618

    init() {
        let win = TopMergedStatsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: cardHeight),
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
        win.isFloatingPanel = true
        win.becomesKeyOnlyIfNeeded = true   // 平时不抢 key，点搜索框时按需成为 key
        win.hidesOnDeactivate = false
        self.window = win

        // ⭐ #143/#144/#145 崩溃根治：面板每次 hover 灵动岛即弹、切 tab/铺满工作台会 setFrame 改尺寸，
        // 裸 NSHostingView 在 macOS 26.5.1 显示周期反推几何 → NSException 崩。改 NSHostingController
        // + sizingOptions=[]，让既有的 setFrame 真正安全（决策 #6 范式）。
        let host = NSHostingController(rootView: SystemStatsPanelRoot(state: state))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }   // 决策 #6：禁反向 setFrame
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor   // 清空 hosting 背景，杜绝四角黑底
        win.contentViewController = host
        // ⭐ v1.4.5 回归修复：转 contentViewController 后必须把 hosting view 的 autoresizingMask 补回
        // [.width,.height]（照灵动岛 line 106 已验证范式）。否则 AppKit 默认用约束把内容钉到窗口的
        // contentLayoutGuide / safe-area —— 本窗顶贴物理屏顶压住刘海，safe-area 顶 inset≈刘海高，
        // 内容就被又往下顶一截（用户报「展开的卡片不太对 / 工作台内容偏移」）。铺满全窗压过刘海才对。
        host.view.autoresizingMask = [.width, .height]
        win.setContentSize(NSSize(width: 280, height: cardHeight))

        Self.shared = self
        positionUnderIsland()

        let nc = NotificationCenter.default
        // 屏幕几何变化 → 重新定位
        nc.addObserver(forName: .init("HermesPetGeometry"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionUnderIsland() }
        }
        // 灵动岛 hover 进出
        nc.addObserver(forName: .init("HermesPetIslandHoverChanged"), object: nil, queue: .main) { [weak self] note in
            let hovering = (note.userInfo?["hovering"] as? Bool) ?? false
            MainActor.assumeIsolated {
                self?.islandHovering = hovering
                self?.evaluate()
            }
        }
        // 面板自身 hover 进出（鼠标从灵动岛滑下来落到面板上）
        nc.addObserver(forName: .init("HermesPetSystemStatsPanelHover"), object: nil, queue: .main) { [weak self] note in
            let hovering = (note.userInfo?["hovering"] as? Bool) ?? false
            MainActor.assumeIsolated {
                self?.panelHovering = hovering
                self?.evaluate()
            }
        }
        // 点了 📌 钉住 → 立即收起 hover 面板（交给常驻卡片）
        nc.addObserver(forName: .init("HermesPetSystemStatsForceHide"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.islandHovering = false
                self?.panelHovering = false
                self?.scheduleHide()
            }
        }
    }

    /// 当前是否启用「应用启动器」标签（islandHubApps，默认开）。
    private var appsEnabled: Bool {
        let ud = UserDefaults.standard
        return ud.object(forKey: "islandHubApps") == nil || ud.bool(forKey: "islandHubApps")
    }

    /// 是否允许弹面板：开关开 + 没有 permission/question 卡占用刘海下方同一块地。
    /// ⚠️ 已钉出常驻系统卡片时**仍要能弹**——面板里还有「应用启动器」等标签要用（早期一刀切掉
    /// 整个面板导致钉了系统卡就再也打不开应用启动器）。只有当应用启动器也关了、面板真没别的可看才不弹。
    private var gateOK: Bool {
        let ud = UserDefaults.standard
        let enabled = ud.object(forKey: "systemStatsEnabled") == nil || ud.bool(forKey: "systemStatsEnabled")
        guard enabled else { return false }
        if PermissionWindowController.shared?.isShowing == true { return false }
        if SystemStatsPinController.shared.isPinned, !appsEnabled { return false }
        return true
    }

    private func evaluate() {
        // 粘住期间（应用/乐园可交互区）不随 hover 收起，交给 × / 点外部 dismiss()
        if state.sticky {
            hideWork?.cancel(); hideWork = nil
            return
        }
        if (islandHovering || panelHovering) && gateOK {
            scheduleShow()
        } else {
            showWork?.cancel(); showWork = nil   // 还没弹就离开了 → 取消待弹
            scheduleHide()
        }
    }

    /// 悬停 0.618s 后才弹（不第一时间弹，太敏感）。期间鼠标离开 → evaluate 会取消这个 work。
    private func scheduleShow() {
        hideWork?.cancel(); hideWork = nil
        guard !state.visible, showWork == nil else { return }   // 已显示 / 已在倒计时就不重排
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.showWork = nil
            guard (self.islandHovering || self.panelHovering), self.gateOK else { return }   // 0.618s 后仍在 hover 才弹
            self.show()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    private func show() {
        hideWork?.cancel(); hideWork = nil
        guard !state.visible else { return }
        SystemMonitor.shared.start()
        // 每次新弹默认从「系统区·紧凑」开始（不粘住、随 hover 收起）；
        // 但若系统区已钉在桌面常驻 → 直接开「应用启动器」（可交互/粘住），避免跟常驻卡片重复显示系统区。
        let toApps = SystemStatsPinController.shared.isPinned && appsEnabled
        state.section = toApps ? .apps : .system
        state.sticky = toApps
        positionUnderIsland()   // 按 state.section 定尺寸（apps 又宽又高）
        window.orderFront(nil)
        window.alphaValue = 1
        postPanelOpen(true)   // 告诉灵动岛：面板开了，保持 idle 紧凑别再 hover 变大
        if toApps {           // 复刻 switchSection(.apps) 的可交互装配（瞬切尺寸、不走 animator，无形变崩溃风险）
            AppLauncherStore.shared.loadIfNeeded()
            window.makeKey()
            installClickOutsideMonitor()
        }
        // 入场：顶端锚定遮罩往下展开（StatsRevealTransition），高 damping 不回弹、不漏顶边
        withAnimation(.spring(response: 0.5, dampingFraction: 0.95, blendDuration: 0.2)) {
            state.visible = true
        }
    }

    /// 广播控制中心面板开/关 —— 灵动岛据此决定要不要因 hover 而展开（开着时保持 idle 紧凑）
    private func postPanelOpen(_ open: Bool) {
        NotificationCenter.default.post(
            name: .init("HermesPetStatsPanelOpen"), object: nil, userInfo: ["open": open]
        )
    }

    // MARK: - 分区切换 + 形变

    /// 切换功能分区：把窗口**瞬切**到该分区大小（又宽又高），再切内容（动感交给 SwiftUI 内容动画）。
    /// 非系统区（应用/乐园）切过去后「粘住」——可交互、不随鼠标离开消失。
    func switchSection(_ section: IslandPanelSection) {
        guard state.section != section else { return }
        guard let screen = HermesIslandGeometry.targetScreen() else { return }
        let sticky = (section != .system)
        // 先瞬切窗口尺寸（display:false，安全通道），再换内容 —— 避免窗口 resize 和 SwiftUI 内容切换
        // 撞在同一个 CA transaction 里触发约束更新崩溃（决策 #1/#6）。
        applyFrame(for: section, on: screen, animated: false)
        withAnimation(.easeInOut(duration: 0.28)) {
            state.section = section
            state.sticky = sticky
        }
        if section == .apps {
            AppLauncherStore.shared.loadIfNeeded()
            window.makeKey()   // 让搜索框能接键盘
        }
        if sticky { installClickOutsideMonitor() } else { removeClickOutsideMonitor() }
    }

    /// 从菜单直接「展开成全屏工作台」：无视 hover gate，把面板切到 `.workspace` 全屏分区并粘住。
    /// 全屏几乎无「外部」可点 → **不装 clickOutside**，靠工作台自身的「收回」按钮调 `dismiss()`。
    /// 尺寸瞬切（applyFrame `display:false`，不走 animator）守决策 #1/#6；窗口本体绝不联动灵动岛 setFrame。
    func presentWorkspace() {
        guard let screen = HermesIslandGeometry.targetScreen() else { return }
        showWork?.cancel(); showWork = nil
        hideWork?.cancel(); hideWork = nil
        removeClickOutsideMonitor()
        state.section = .workspace
        state.sticky = true                 // 粘住：hover 进出不收（evaluate 内 sticky 直接 return）
        applyFrame(for: .workspace, on: screen, animated: false)
        window.orderFront(nil)
        window.alphaValue = 1
        window.makeKey()
        postPanelOpen(true)
        if !state.visible {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.95, blendDuration: 0.2)) {
                state.visible = true
            }
        }
    }

    /// 切换工作台尺寸档（铺满 / 中等）后重新定位窗口（瞬切 setFrame(display:false)，守决策 #1/#6）。
    func relayoutWorkspace() {
        guard state.section == .workspace, let screen = HermesIslandGeometry.targetScreen() else { return }
        applyFrame(for: .workspace, on: screen, animated: false)
    }

    /// 关闭面板（× / 点外部 / 打开了某个 app 之后）——直接渐隐，复位回系统区。
    func dismiss() {
        removeClickOutsideMonitor()
        islandHovering = false
        panelHovering = false
        state.sticky = false
        postPanelOpen(false)   // 灵动岛恢复正常 hover 展开
        withAnimation(.easeOut(duration: 0.26)) { state.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self = self else { return }
            if !self.state.visible {
                self.window.alphaValue = 0
                self.window.orderOut(nil)
                self.state.section = .system   // 复位，下次 hover 从紧凑开始
                self.positionUnderIsland()
            }
        }
    }

    /// 各分区内容区的尺寸（不含顶部让位区 topZone）。应用/乐园「又宽又高」，但左右留 80pt 给菜单栏角落图标。
    private func contentSize(for section: IslandPanelSection, on screen: NSScreen) -> CGSize {
        let baseW = cardWidth(on: screen)   // 系统区/兜底宽（已含盖住胶囊的外扩）
        switch section {
        case .system:
            return CGSize(width: baseW, height: 134)
        case .apps:
            let maxW = max(baseW, screen.frame.width - 160)
            return CGSize(width: min(560, maxW), height: 384)
        case .tokens:
            // 计费卡：跟系统区同宽（窄、贴齐灵动岛），高一点容下消耗条 + 趋势 + 省钱明细。
            return CGSize(width: baseW, height: 322)
        case .pets:
            let maxW = max(baseW, screen.frame.width - 160)
            return CGSize(width: min(460, maxW), height: 372)
        case .workspace:
            // 「中等」档（「铺满」档在 applyFrame 里特判占满整屏，不走这）：顶贴刘海、左右留边、底不到底。
            return CGSize(width: min(1280, screen.frame.width - 220),
                          height: max(560, screen.frame.height * 0.72))
        }
    }

    /// 顶部「让位区」高度：面板要顶满屏幕物理顶，这段黑色留给灵动岛自己的内容。
    /// 面板开着时灵动岛被 `HermesPetStatsPanelOpen` 通知**钉在 idle 紧凑态**（不随 hover 变大），
    /// 所以恒定只让出 idle 那一点 → 不空不挤、位置一致（用户：缩上去后顶部空着不协调）。
    /// - 刘海屏：面板**只在展开时显示**，此刻灵动岛被强制切到「标准耳朵态」(下露 panelOpenDrop=11)，
    ///   底 ≈ coreH + 11，让 coreH + 16（给桌宠/右耳留位，与 PillView 的 panelOpenDrop 配套，改那边记得改这里）；
    /// - 无刘海（悬浮胶囊）：胶囊 = 上边距4 + 高20 = 24，让固定 30（与 floatingTopMargin/floatingIdleHeight 配套）。
    private func topZone(coreH: CGFloat, isNotch: Bool) -> CGFloat {
        isNotch ? coreH + 16 : 30
    }

    /// 按分区把窗口摆到「顶满屏幕物理顶、内容下移到让位区下方」的位置，宽高取 contentSize。
    private func applyFrame(for section: IslandPanelSection, on screen: NSScreen, animated: Bool) {
        let centerX = HermesIslandGeometry.islandCenterX(on: screen)
        let coreH = HermesIslandGeometry.islandCoreHeight(on: screen)
        let zone = topZone(coreH: coreH, isNotch: screen.safeAreaInsets.top > 0)
        state.topInset = zone
        // 工作台「铺满」档：直接占满整个物理屏（到边、到底、盖 Dock）；topInset 让内容避开刘海。
        if section == .workspace, WorkbenchThemeStore.shared.size == .large {
            window.setFrame(screen.frame, display: false)
            return
        }
        let size = contentSize(for: section, on: screen)
        let total = size.height + zone
        let x = centerX - size.width / 2
        let y = screen.frame.maxY - total
        let rect = NSRect(x: x, y: y, width: size.width, height: total)
        // ⚠️ 绝不能用 `window.animator().setFrame(…, display: true)`（AppKit 动画通道）——它在
        // CA Transaction commit 期间驱动 NSHostingView 约束更新 → 嵌套 updateConstraintsForSubtree →
        // NSException 必崩（决策 #1/#6 同款签名，点标签形变时**已实测崩**：crash 2026-06-06 02:11）。
        // 一律**瞬切** setFrame(display:false)（PermissionWindow 同款安全通道）；形变的"动感"交给 SwiftUI
        // 内容动画（switchSection 里的 withAnimation + StatsRevealTransition），窗口本身不走动画通道。
        _ = animated
        window.setFrame(rect, display: false)
    }

    // MARK: - 点外部关闭（仅粘住期间）

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.state.sticky else { return }
                if NSApp.modalWindow != nil { return }   // 系统选图框等模态窗开着时别误关面板
                if !self.window.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
    }

    /// 离开后延时收起（给鼠标从灵动岛滑到面板留 0.35s 空档，避免一离岛就消失）。
    /// **退场=直接渐隐**（removal 用 .opacity 淡出，不"卷回灵动岛"）—— 用户：收回去时鼠标再碰又被拉下来太敏感。
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.islandHovering || self.panelHovering || self.state.sticky { return }   // 移回来了 / 粘住中
            self.postPanelOpen(false)   // 面板要收了 → 灵动岛恢复正常 hover 展开
            withAnimation(.easeOut(duration: 0.28)) {
                self.state.visible = false                            // 触发 .opacity 退场 = 渐隐
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self else { return }
                if !self.state.visible {
                    self.window.alphaValue = 0
                    self.window.orderOut(nil)
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 把面板顶到屏幕**物理最顶**，黑色填满灵动岛两侧顶部空白 → 跟顶部黑区连成一整块
    /// （用户要求：要跟"电脑黑框"融合，而不是停在下沿、中间隔着一条壁纸）。
    ///
    /// 刘海屏 / 无刘海屏（悬浮胶囊）**统一处理**：窗口顶 = 屏幕物理顶；总高 = 灵动岛核心高 + 内容高；
    /// 内容靠 `topInset`(=灵动岛核心高) 下移到灵动岛下方可见区，顶部那条核心高的黑色补在灵动岛左右
    /// → 刘海屏跟物理刘海黑融为一体、无刘海屏跟悬浮胶囊连成一块（不再上面空着）。
    /// 面板上方有灵动岛窗口（同层、本面板后 orderFront 在其上），两块纯黑重叠无缝。
    /// 面板宽=刘海+80 居中，菜单栏图标在屏幕两侧、不被这中间窄面板遮。
    private func positionUnderIsland() {
        guard let screen = HermesIslandGeometry.targetScreen() else { return }
        applyFrame(for: state.section, on: screen, animated: false)
    }
}

// MARK: - SwiftUI 状态 + Root

@MainActor
@Observable
final class SystemStatsPanelState {
    var visible = false
    /// 内容区顶部内缩量（=刘海高）：面板顶满屏幕物理顶后，内容靠它下移到刘海下方可见区
    var topInset: CGFloat = 37
    /// 当前功能分区（系统 / 应用 / 乐园）
    var section: IslandPanelSection = .system
    /// 是否「粘住」（应用/乐园等大功能区点开后不随鼠标离开消失，靠 × / 点外部关闭）
    var sticky = false
}

/// 系统面板专用入场/退场：**只做顶部锚定的遮罩展开**（从屏幕顶往下"卷出来"），
/// 不做 PermissionCardTransition 那种整体上移 offset。
///
/// 为什么不用 offset：本面板顶满屏幕物理顶，任何整体位移（尤其 spring 回弹那一下）都会
/// 让面板顶边离开屏幕顶 → 把胶囊/壁纸边缘漏出来（用户反馈的"下弹会漏边"）。
/// 遮罩顶端恒贴屏幕顶、高度从 0 长到满 → 顶部全程被黑色盖死，干净无漏边。
struct StatsRevealTransition: ViewModifier {
    /// 0 = 收起（高度 0）/ 1 = 完全展开
    let progress: CGFloat
    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            Rectangle().scaleEffect(x: 1, y: max(0.0001, progress), anchor: .top)
        }
    }
}

/// 面板顶层：visible 时显示仪表盘（顶部锚定遮罩展开，不漏顶边）。
/// 整层 onHover 把鼠标进出广播出去，供 controller 做 hover 接力。
struct SystemStatsPanelRoot: View {
    @Bindable var state: SystemStatsPanelState

    var body: some View {
        ZStack {
            if state.visible {
                IslandHubView(state: state, topInset: state.topInset)
                    .transition(.asymmetric(
                        // 入场：顶端锚定遮罩往下展开；退场：直接渐隐（不卷回去）
                        insertion: .modifier(
                            active: StatsRevealTransition(progress: 0),
                            identity: StatsRevealTransition(progress: 1)
                        ),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            NotificationCenter.default.post(
                name: .init("HermesPetSystemStatsPanelHover"),
                object: nil,
                userInfo: ["hovering": hovering]
            )
        }
    }
}
