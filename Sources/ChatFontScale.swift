import SwiftUI

/// 聊天正文字号缩放因子（Chrome 风格 ⌘+ / ⌘- / ⌘0 控制）。
///
/// 缩放只影响**消息正文**：气泡内文本、Markdown 渲染、代码块、表格、ChoiceCard。
/// 不缩放：输入栏、对话胶囊、灵动岛、菜单栏、设置面板。
///
/// 状态：UserDefaults 持久化（key = `chatFontScale`），默认 1.0。
/// 跨进程访问：`@AppStorage("chatFontScale")` 在 ChatView / SettingsView 都能用。
enum ChatFontScale {
    /// AppStorage key
    static let storageKey = "chatFontScale"

    /// 缩放档位：60% / 70% / 85% / 100% / 115% / 130% / 150% / 170% / 200% / 250%
    /// 两头都拉宽 —— 能缩得更小（一屏塞更多字）也能放得更大（演示/远看/老花），覆盖写作长文需求
    static let presets: [Double] = [0.6, 0.7, 0.85, 1.0, 1.15, 1.30, 1.50, 1.70, 2.0, 2.5]

    static let `default`: Double = 1.0

    /// 缩放变化时广播 —— ChatView 用来弹 toast 显示当前档位
    static let didChangeNotification = Notification.Name("HermesPetChatFontScaleChanged")

    /// 找到当前 scale 最接近的预设档位 index（容差 0.02 以内）；找不到返回 -1
    static func currentIndex(for scale: Double) -> Int {
        for (i, p) in presets.enumerated() where abs(p - scale) < 0.02 {
            return i
        }
        return -1
    }

    /// 升一档（已经在最大档 → 不动）。返回新档位 scale
    static func cycleUp(from current: Double) -> Double {
        let idx = currentIndex(for: current)
        if idx < 0 {
            // 当前 scale 不在预设档位（用户手动改过），找比它大的最小档
            return presets.first(where: { $0 > current }) ?? presets.last ?? `default`
        }
        return presets[min(idx + 1, presets.count - 1)]
    }

    /// 降一档（已经在最小档 → 不动）
    static func cycleDown(from current: Double) -> Double {
        let idx = currentIndex(for: current)
        if idx < 0 {
            return presets.last(where: { $0 < current }) ?? presets.first ?? `default`
        }
        return presets[max(idx - 1, 0)]
    }

    /// 当前档位的显示文本（toast 用："字号 115%"）
    static func displayLabel(for scale: Double) -> String {
        "字号 \(Int(scale * 100))%"
    }

    /// 给一个基础字号 size，按 scale 缩放后的实际值
    static func scaled(_ size: CGFloat, by scale: Double) -> CGFloat {
        size * CGFloat(scale)
    }
}

// MARK: - Environment

/// 把字号 scale 通过 Environment 传给消息渲染层 —— 比 @AppStorage 在每个 view 重复读更轻量，
/// 也避免 SettingsView 改字号后 ChatView 多余 rerender。
/// ChatView 在最外层 `.environment(\.chatFontScale, scale)` 注入。
private struct ChatFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = ChatFontScale.default
}

extension EnvironmentValues {
    var chatFontScale: Double {
        get { self[ChatFontScaleKey.self] }
        set { self[ChatFontScaleKey.self] = newValue }
    }
}
