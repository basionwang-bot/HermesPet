import SwiftUI

/// 工作台视觉主题系统（可扩展 / 未来可远程下发的雏形）。
///
/// 核心设计 = **双层 token**（2026-06-13 方向讨论定）：
/// - ① 静态基底层：配色 / 质感 / 圆角 —— 决定"长什么样"，可整套替换；
/// - ② 激活态层：干活时的辉光 / 呼吸强度 —— 决定"动起来什么感觉"。
///
/// 一个主题 = 给这两层填不同的值：
///   剑黑科技 = 深底 + 强辉光；原生极简 = 浅玻璃 + 弱辉光。
///
/// 工作台任何 UI 都读 `theme.xxx`、**不写死颜色** → 换主题 = 换一个实例，界面整套变。
/// `WorkbenchTheme.all` 是内置预设；将来可像 `ProviderPreset` / `presets.json` 一样
/// 合并远程 `themes.json`（push 不发版即上新主题），甚至做主题市场。
struct WorkbenchTheme: Identifiable, Hashable {
    let id: String
    let name: String       // 显示名（主题切换器）
    let symbol: String     // SF Symbol 图标

    enum Base { case dark, light }
    let base: Base

    // ① 静态基底层 —— 三级明度台阶（治"发灰"：用实色层级，不靠半透明乱叠）
    let backgroundTop: Color     // 大底渐变上
    let backgroundBottom: Color  // 大底渐变下
    let surface1: Color          // 栏 / 侧边面板（比大底提一档）
    let surface2: Color          // 卡片（比 surface1 再提一档，浮起感）
    let panelStroke: Color       // 卡片 / 面板 1px 描边
    let hairline: Color          // 极细分隔线（专业克制的"干净分隔"）
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color      // 第三级文字（次要标签 / 占位）
    let accent: Color            // 主色（按钮 / 高亮 / 辉光色）
    let cornerRadius: CGFloat
    let cardShadow: Color        // 卡片极轻阴影（浅色可见 / 深色近无、靠明度台阶区分）
    let cardShadowRadius: CGFloat

    // ② 激活态层（干活可视化）----------------------------------------------
    let glowEnabled: Bool      // 卡片亮起辉光开关
    let glowStrength: Double    // 0~1，辉光 / 阴影强度
    let breatheEnabled: Bool    // 呼吸脉动开关

    /// 兼容旧代码：原 panelFill 现映射到 surface1（栏背景）
    var panelFill: Color { surface1 }

    /// 让窗口控件 / Divider 跟随主题明暗
    var colorScheme: ColorScheme { base == .dark ? .dark : .light }
}

extension WorkbenchTheme {
    /// 剑黑科技（= 方向讨论里的 A）：深色毛玻璃底 + 主色强辉光，
    /// 跟刘海 / 舰队剧场 / 语音陪聊一脉相承，"把可视化做爆"。
    static let swordBlack = WorkbenchTheme(
        id: "sword-black",
        name: "剑黑科技",
        symbol: "bolt.fill",
        base: .dark,
        backgroundTop: Color(red: 0.10, green: 0.10, blue: 0.13),
        backgroundBottom: Color(red: 0.066, green: 0.066, blue: 0.088),
        surface1: Color(red: 0.13, green: 0.13, blue: 0.16),
        surface2: Color(red: 0.17, green: 0.17, blue: 0.21),
        panelStroke: Color.white.opacity(0.09),
        hairline: Color.white.opacity(0.055),
        textPrimary: Color.white.opacity(0.93),
        textSecondary: Color.white.opacity(0.56),
        textTertiary: Color.white.opacity(0.34),
        accent: Color(red: 0.56, green: 0.50, blue: 1.0),
        cornerRadius: 12,
        cardShadow: Color.black.opacity(0.22),
        cardShadowRadius: 5,
        glowEnabled: true,
        glowStrength: 0.9,
        breatheEnabled: true
    )

    /// 原生极简（= 方向讨论里的 B）：浅色玻璃 + 大留白 + 克制，像原生 macOS 应用。
    static let nativeMinimal = WorkbenchTheme(
        id: "native-minimal",
        name: "原生极简",
        symbol: "circle",
        base: .light,
        backgroundTop: Color(red: 0.96, green: 0.96, blue: 0.975),
        backgroundBottom: Color(red: 0.93, green: 0.93, blue: 0.945),
        surface1: Color.white,
        surface2: Color.white,
        panelStroke: Color.black.opacity(0.07),
        hairline: Color.black.opacity(0.05),
        textPrimary: Color.black.opacity(0.88),
        textSecondary: Color.black.opacity(0.5),
        textTertiary: Color.black.opacity(0.32),
        accent: Color(red: 0.0, green: 0.48, blue: 1.0),
        cornerRadius: 12,
        cardShadow: Color.black.opacity(0.07),
        cardShadowRadius: 9,
        glowEnabled: false,
        glowStrength: 0.2,
        breatheEnabled: false
    )

    /// 内置预设（未来 + 远程 themes.json 合并 / 覆盖）。
    static let all: [WorkbenchTheme] = [.swordBlack, .nativeMinimal]
}

/// 工作台尺寸档（仅刘海全屏 `.workspace` 模式）。
enum WorkbenchSize: String, CaseIterable, Sendable {
    case large    // 铺满整个物理屏（到边、到底、盖 Dock）
    case medium   // 居中大窗：顶贴刘海、左右留边、底不到底
    var label: String { self == .large ? "铺满" : "中等" }
    var symbol: String { self == .large ? "rectangle.inset.filled" : "rectangle.center.inset.filled" }
}

/// 当前选中主题 + 尺寸档的单例（@Observable → 切换时所有读它的 View 自动重渲，
/// 不用 `.id()` 重建、不用 `.environment` 注入；范式同 `PetPaletteStore` / `LocaleManager`）。
@MainActor
@Observable
final class WorkbenchThemeStore {
    static let shared = WorkbenchThemeStore()
    private let key = "workbenchThemeID.v1"
    private let sizeKey = "workbenchSize.v1"

    var current: WorkbenchTheme
    var size: WorkbenchSize

    private init() {
        let savedID = UserDefaults.standard.string(forKey: key)
        current = WorkbenchTheme.all.first { $0.id == savedID } ?? .swordBlack
        size = WorkbenchSize(rawValue: UserDefaults.standard.string(forKey: sizeKey) ?? "") ?? .large
    }

    func select(_ theme: WorkbenchTheme) {
        guard theme.id != current.id else { return }
        current = theme
        UserDefaults.standard.set(theme.id, forKey: key)
    }

    func selectSize(_ s: WorkbenchSize) {
        guard s != size else { return }
        size = s
        UserDefaults.standard.set(s.rawValue, forKey: sizeKey)
    }
}
