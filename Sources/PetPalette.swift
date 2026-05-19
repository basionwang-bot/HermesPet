import SwiftUI
import AppKit

/// 4 种桌宠的调色板 —— 让用户为每个 mode 单独自定义"主色"。
///
/// 设计：用户只调主色一种，其他派生色（顶高光、底阴影）由主色自动 HSB lighten/darken 派生，
/// 这样既能给桌宠换色，又不要求用户对每个色板都手工调一遍。
///
/// 派生规则：
/// - `derivedTop`：主色 +12% brightness（左上光源高光）
/// - `derivedBottom`：主色 -15% brightness（底部阴影 / 体积感）
///
/// 各 sprite 的其他色（鬃毛 / 翅膀 / 蹄子 / 屏幕黑 / 火焰 / LED 等）保持默认不参与调色，
/// 避免用户改完后失去 sprite 的视觉辨识度。
struct PetPalette: Codable, Equatable {
    /// 主色（16 进制 hex，无 # 前缀，如 "DE886D"）
    /// `private(set)` —— 外部要改主色必须新建 PetPalette 实例，让 init 一次性算好派生色。
    /// 之前是 `var`，外部直接改 hex 不会刷新 cached primary/derivedTop/derivedBottom
    private(set) var primaryHex: String

    /// 主色 SwiftUI Color（init 时一次性算好，避免每帧 sprite Canvas draw 时重新 parse hex）
    let primary: Color
    /// 顶部高光（主色 +12% brightness）—— init 时算好缓存
    let derivedTop: Color
    /// 底部阴影（主色 -15% brightness）—— init 时算好缓存
    let derivedBottom: Color

    init(primaryHex: String) {
        self.primaryHex = primaryHex
        // 性能优化：一次性把派生色算好存为 stored property。
        // 60fps Canvas draw 时每帧调几十次 palette.primary / .derivedTop / .derivedBottom，
        // 之前是 computed property → 每次 NSColor() + getHue/setHue 重算，CPU 大头之一。
        let base = Color(hex: primaryHex) ?? Self.fallbackColor
        self.primary = base
        self.derivedTop = base.lightened(by: 0.12)
        self.derivedBottom = base.darkened(by: 0.15)
    }

    // MARK: - Codable —— 只 encode/decode primaryHex，派生色 init 里重算

    enum CodingKeys: String, CodingKey { case primaryHex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try c.decode(String.self, forKey: .primaryHex)
        self.init(primaryHex: hex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(primaryHex, forKey: .primaryHex)
    }

    // MARK: - Equatable —— 只比 primaryHex（派生色一定等价）

    static func == (lhs: PetPalette, rhs: PetPalette) -> Bool {
        lhs.primaryHex == rhs.primaryHex
    }

    // —— 各 mode 默认 palette ——

    /// Claude Code · Clawd 螃蟹默认 Anthropic 橙 #DE886D
    static let clawdDefault    = PetPalette(primaryHex: "DE886D")
    /// 在线 AI · 云朵默认 indigo #7367D9
    static let cloudDefault    = PetPalette(primaryHex: "7367D9")
    /// OpenClaw · fomo 九尾狐默认月光银白 #B4C5E8（参考图主体色调）
    static let fomoDefault     = PetPalette(primaryHex: "B4C5E8")
    /// Hermes · 金黄小马默认 #E8C97A
    static let horseDefault    = PetPalette(primaryHex: "E8C97A")
    /// Codex · 喷射机器人默认深空蓝 #1C2A3A
    static let terminalDefault = PetPalette(primaryHex: "1C2A3A")

    private static let fallbackColor = Color.gray
}

// MARK: - PetPaletteStore

/// 全局调色板存储 —— UserDefaults JSON 持久化
///
/// 用 @Observable + @MainActor 让 SwiftUI 视图自动观察。设置页的 ColorPicker
/// 改色 → updatePalette → 所有读取此 store 的 sprite view 自动重渲染。
@MainActor
@Observable
final class PetPaletteStore {
    static let shared = PetPaletteStore()

    var claudePalette: PetPalette
    var directAPIPalette: PetPalette
    var fomoPalette: PetPalette
    var hermesPalette: PetPalette
    var codexPalette: PetPalette

    private init() {
        // 同步 load 一次，没有就用默认
        let stored: Stored? = {
            guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }()
        self.claudePalette    = stored?.claude    ?? .clawdDefault
        self.directAPIPalette = stored?.directAPI ?? .cloudDefault
        self.fomoPalette      = stored?.fomo      ?? .fomoDefault
        self.hermesPalette    = stored?.hermes    ?? .horseDefault
        self.codexPalette     = stored?.codex     ?? .terminalDefault
    }

    /// 取某个 mode 对应的调色板
    func palette(for mode: AgentMode) -> PetPalette {
        switch mode {
        case .claudeCode: return claudePalette
        case .directAPI:  return directAPIPalette
        case .openclaw:   return fomoPalette
        case .hermes:     return hermesPalette
        case .codex:      return codexPalette
        }
    }

    /// 修改 + 持久化 + 广播刷新
    func updatePalette(for mode: AgentMode, _ palette: PetPalette) {
        switch mode {
        case .claudeCode: claudePalette    = palette
        case .directAPI:  directAPIPalette = palette
        case .openclaw:   fomoPalette      = palette
        case .hermes:     hermesPalette    = palette
        case .codex:      codexPalette     = palette
        }
        save()
    }

    /// 改主色 —— 新建 PetPalette 让 init 重算派生色（primaryHex 是 private(set)）
    func updatePrimary(for mode: AgentMode, color: Color) {
        let p = PetPalette(primaryHex: color.hexString)
        updatePalette(for: mode, p)
    }

    /// 重置某个 mode 到默认
    func resetToDefault(for mode: AgentMode) {
        switch mode {
        case .claudeCode: claudePalette    = .clawdDefault
        case .directAPI:  directAPIPalette = .cloudDefault
        case .openclaw:   fomoPalette      = .fomoDefault
        case .hermes:     hermesPalette    = .horseDefault
        case .codex:      codexPalette     = .terminalDefault
        }
        save()
    }

    // —— 持久化 ——

    private struct Stored: Codable {
        var claude: PetPalette
        var directAPI: PetPalette
        /// fomo palette —— PR-B 新增，老版本 JSON 缺这个字段时 decode 走 decodeIfPresent fallback
        var fomo: PetPalette?
        var hermes: PetPalette
        var codex: PetPalette
    }

    private static let storageKey = "petPalettes.v1"

    private func save() {
        let s = Stored(
            claude: claudePalette,
            directAPI: directAPIPalette,
            fomo: fomoPalette,
            hermes: hermesPalette,
            codex: codexPalette
        )
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Color hex / HSB 派生

extension Color {
    /// 从 16 进制 hex 字符串创建 Color（支持 "#RRGGBB" 或 "RRGGBB"）
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        }
        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >>  8) / 255
        let b = Double( rgb & 0x0000FF)        / 255
        self.init(red: r, green: g, blue: b)
    }

    /// 取 Color 的 hex 字符串（无 # 前缀，大写，如 "DE886D"）
    /// ColorPicker 修改 Color 后用这个转回 hex 存到 palette
    var hexString: String {
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return "808080" }
        let r = Int(round(rgb.redComponent   * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent  * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// 调亮（HSB 空间 brightness +amount，clamp 到 [0,1]）
    func lightened(by amount: Double) -> Color {
        adjustBrightness(by: amount)
    }

    /// 调暗
    func darkened(by amount: Double) -> Color {
        adjustBrightness(by: -amount)
    }

    private func adjustBrightness(by delta: Double) -> Color {
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newB = max(0, min(1, b + CGFloat(delta)))
        return Color(
            hue: Double(h),
            saturation: Double(s),
            brightness: Double(newB),
            opacity: Double(a)
        )
    }
}

// MARK: - PetWalkSizeScale

/// 桌面漫步桌宠缩放因子。
///
/// **只影响桌面漫步 sprite**（ClawdWalkController 的窗口大小 + 内部 sprite 高度），
/// 不影响灵动岛 sprite（受刘海物理高度约束，加 scale 反而不协调）。
///
/// 状态：UserDefaults 持久化（key = `petWalkSizeScale`），默认 1.0。
/// 访问：`@AppStorage("petWalkSizeScale")` 在 ClawdWalkOverlay / SettingsView 都能用。
enum PetWalkSizeScale {
    static let storageKey = "petWalkSizeScale"

    /// 五档缩放：70% / 85% / 100% / 120% / 150%
    /// 设计：跟 ChatFontScale 同款 5 档风格，档差 ~15-30% 让差异肉眼可见
    static let presets: [Double] = [0.7, 0.85, 1.0, 1.2, 1.5]

    static let `default`: Double = 1.0

    /// 缩放变化时广播 —— ClawdWalkController 监听后 setFrame 已显示的桌宠窗口
    static let didChangeNotification = Notification.Name("HermesPetWalkSizeScaleChanged")

    /// 找到当前 scale 最接近的预设档位 index（容差 0.02）；找不到返回 -1
    static func currentIndex(for scale: Double) -> Int {
        for (i, p) in presets.enumerated() where abs(p - scale) < 0.02 {
            return i
        }
        return -1
    }

    /// 档位的显示标签（segmented Picker 用）
    static func label(for scale: Double) -> String {
        switch scale {
        case 0.7:  return "迷你"
        case 0.85: return "小"
        case 1.0:  return "默认"
        case 1.2:  return "大"
        case 1.5:  return "特大"
        default:   return "\(Int(scale * 100))%"
        }
    }

    /// 把基础尺寸按 scale 缩放
    static func scaled(_ base: CGFloat, by scale: Double) -> CGFloat {
        base * CGFloat(scale)
    }
}
