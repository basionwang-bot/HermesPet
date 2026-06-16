import AppKit

/// 用户在设置里的"显示模式"选项。
/// - `auto`：按当前激活屏判，有刘海 → notch、无刘海 → floating
/// - `notch`：强制刘海模式（NSWindow 顶部贴菜单栏顶 + NotchShape 顶部直角左右下凹）
/// - `floating`：强制悬浮胶囊（NSWindow 顶部贴菜单栏下方 8pt + 完整 Capsule + mode 主色外发光）
/// - `mini`：**第三形态**。不显示大灵动岛，改在菜单栏上常驻一颗极小的迷你胶囊（Clawd 头像 + 连接状态点），
///   有后台任务时旁边并排多出任务胶囊。占地最小，专治"菜单栏 / 刘海太占空间"。
///   由独立的 `MiniIslandController` 渲染（大灵动岛 `DynamicIslandController` 在此模式下根本不创建）。
///
/// 切换后会弹 alert 提示重启生效（决策 #1：NSWindow 永远不能运行期 setFrame）
enum DisplayMode: String, Codable {
    case auto
    case notch
    case floating
    case mini

    static let storageKey = "HermesPetDisplayMode"

    /// 是否第三形态（迷你胶囊）—— AppDelegate 据此决定创建大灵动岛还是迷你控制器
    static var isMini: Bool { current == .mini }

    /// 用户设置的原始选项（含 `.auto`）
    static var current: DisplayMode {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? "auto"
        return DisplayMode(rawValue: raw) ?? .auto
    }

    static func save(_ value: DisplayMode) {
        UserDefaults.standard.set(value.rawValue, forKey: storageKey)
    }
}

/// 「灵动岛显示在哪块屏」设置。用户在设置里直接选：
/// - `.follow`（默认）：跟随鼠标当前所在屏，切到另一块屏会整体搬过去。
/// - `.pinned(displayID)`：固定显示在用户指定的那块屏（哪怕鼠标在别的屏）。
///
/// 存储用一个字符串：`"follow"` 或 displayID 的十进制字符串（方便直接绑 `@AppStorage` + Picker tag）。
enum IslandScreenChoice {
    case follow
    case pinned(CGDirectDisplayID)

    static let storageKey = "HermesPetIslandScreenChoice"
    static let followRaw = "follow"
    /// 切换通知 —— DynamicIslandController 收到后立即重摆位（无需重启）
    static let changedNotification = Notification.Name("HermesPetIslandScreenChoiceChanged")

    /// 从 UserDefaults 读当前选择（默认 follow）。
    static var current: IslandScreenChoice {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? followRaw
        if raw == followRaw { return .follow }
        if let id = UInt32(raw) { return .pinned(id) }
        return .follow   // 脏数据兜底
    }

    var isFollow: Bool {
        if case .follow = self { return true }
        return false
    }
}

/// 解析后的实际显示形态（去 `auto`，只剩 `notch` / `floating` 二选一）。
/// `notch` 模式下灵动岛紧贴菜单栏顶 + NotchShape；`floating` 模式下悬浮在菜单栏下方 + 完整 Capsule + glow。
enum EffectiveDisplayMode {
    case notch
    case floating
}

/// 几何 helper 单一权威源 —— DynamicIslandController / Permission / ResponseSummary / ClawdWalk
/// 都从这里读 "灵动岛在哪 / 卡片紧贴在哪 / 桌宠避让带"，避免散落多处计算导致漂移。
enum HermesIslandGeometry {

    /// 灵动岛"卡片紧贴底部 y" 余量 —— 方案 A 后 floating / notch 都贴屏幕顶，留 0 跟刘海一致
    static let floatingGap: CGFloat = 0

    /// 解析 `DisplayMode.current`：auto 时按屏幕是否有刘海决定，否则用用户选的
    static func effective(on screen: NSScreen) -> EffectiveDisplayMode {
        switch DisplayMode.current {
        case .notch:    return .notch
        case .floating: return .floating
        // mini 模式不渲染大灵动岛，但权限卡 / Clawd 等仍可能读 effective 定位 —— 按屏幕物理刘海兜底
        case .auto, .mini: return screen.safeAreaInsets.top > 0 ? .notch : .floating
        }
    }

    /// 灵动岛 + 所有附属卡片（权限 / 总结 / 意图）共用的"该出现在哪块屏"权威逻辑。
    /// - 跟随开启：用**鼠标物理所在屏**（`NSEvent.mouseLocation` 命中哪块屏的 frame）。
    ///   比 `NSScreen.main`（= 键盘焦点窗口所在屏）更贴合用户直觉——灵动岛没有键盘焦点，
    ///   `NSScreen.main` 在多屏下经常指不到用户正看的那块。
    /// - 跟随关闭 / 找不到鼠标所在屏：钉在带刘海的内置屏，没刘海再退到 main / 第一块。
    /// 让灵动岛本体与附属卡片走同一套选屏，避免"岛在 A 屏、权限卡弹 B 屏"的错位。
    static func targetScreen() -> NSScreen? {
        switch IslandScreenChoice.current {
        case .follow:
            let loc = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(loc) }) {
                return s
            }
        case .pinned(let id):
            if let s = NSScreen.screens.first(where: { $0.displayID == id }) {
                return s   // 用户固定的那块屏还在
            }
            // 固定的屏被拔了 → 落到下面的兜底（灵动岛不会消失，回到带刘海内置屏）
        }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// 灵动岛物理水平中心 x（用 auxiliary 反推；非 notch 屏取 screen 中线）
    static func islandCenterX(on screen: NSScreen) -> CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return (l.maxX + r.minX) / 2
        }
        return screen.frame.midX
    }

    /// 灵动岛核心宽度（物理刘海宽度；无刘海屏退到固定 200pt）
    static func islandCoreWidth(on screen: NSScreen) -> CGFloat {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return r.minX - l.maxX
        }
        return 200
    }

    /// 灵动岛核心高度（刘海模式 = safeArea.top；floating 模式固定 28pt）
    static func islandCoreHeight(on screen: NSScreen) -> CGFloat {
        switch effective(on: screen) {
        case .notch:    return max(screen.safeAreaInsets.top, 28)
        case .floating: return 28
        }
    }

    /// 灵动岛"底部 y" —— 卡片紧贴这条线展开（PermissionWindow / ResponseSummary 用）。
    /// 方案 A：notch / floating 都贴屏幕顶（floating 模式胶囊覆盖菜单栏中央，模拟刘海屏视觉）
    static func islandBottomY(on screen: NSScreen) -> CGFloat {
        return screen.frame.maxY - islandCoreHeight(on: screen)
    }

    /// 卡片紧贴灵动岛底部时多留多少 gap（floating 模式视觉上更喘息）
    static func cardTopGapBelowIsland(on screen: NSScreen) -> CGFloat {
        switch effective(on: screen) {
        case .notch:    return 0   // 跟凹槽无缝衔接
        case .floating: return 10  // 跟悬浮胶囊错开一点呼吸感
        }
    }

    /// 桌宠"避让带" —— 普通漫步软墙 + chasing/patrol 跨越触发传送门。
    /// - notch 模式：物理刘海两侧各 +30pt
    /// - floating 模式：悬浮胶囊矩形两侧各 +30pt（胶囊本体宽 = islandCoreWidth + 80pt buffer）
    static func avoidZoneX(on screen: NSScreen) -> ClosedRange<CGFloat>? {
        let core = islandCoreWidth(on: screen)
        switch effective(on: screen) {
        case .notch:
            guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else {
                return nil   // 非刘海屏没物理刘海可读
            }
            return (l.maxX - 30)...(r.minX + 30)
        case .floating:
            // 悬浮胶囊本体宽度 = core + 80pt (idleExtraWidth)，对称分布在 centerX 两侧
            let cx = islandCenterX(on: screen)
            let halfWidth = (core + 80) / 2
            return (cx - halfWidth - 30)...(cx + halfWidth + 30)
        }
    }

    /// 桌宠 walkY —— 沿菜单栏下方哪条线走。
    /// floating 模式下需要走在悬浮胶囊"下方"留 8pt gap，避免穿胶囊
    static func clawdWalkBaseY(on screen: NSScreen, clawdHeight: CGFloat) -> CGFloat {
        switch effective(on: screen) {
        case .notch:
            // visibleFrame.maxY 已扣掉菜单栏，紧贴菜单栏下方 4pt
            return screen.visibleFrame.maxY - 4 - clawdHeight
        case .floating:
            // 走在悬浮胶囊下方 8pt（避开胶囊 + glow）
            return islandBottomY(on: screen) - 8 - clawdHeight
        }
    }
}

extension NSScreen {
    /// CoreGraphics 显示 ID —— 用来判断鼠标当前在哪块屏 / 灵动岛是否需要换屏。
    /// 比直接比较 NSScreen 实例稳：NSScreen 对象在屏幕参数变化后可能被重建。
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
