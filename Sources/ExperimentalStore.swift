import Foundation
import Observation

/// 实验性功能开关（v1.6）。
///
/// 把尚不稳定 / 偏激进的创新功能放在这里，**默认全关**——用户不主动开，日常使用完全不涉及。
/// 设置里有独立的「实验性」分栏；以后新创新功能在这加一个开关即可。
@MainActor
@Observable
final class ExperimentalStore {
    static let shared = ExperimentalStore()

    private let takeoverKey = "experimental.screenTakeover"
    private let fleetKey = "experimental.fleetMode"

    /// 屏幕接管 / AI 操作软件（看窗口 → OCR/识图 → 模拟鼠标键盘操作，如自动盯微信回消息）。
    /// 关闭时：输入栏「+」分享窗口、菜单「接管窗口」等入口全部隐藏。
    var screenTakeoverEnabled: Bool {
        didSet { UserDefaults.standard.set(screenTakeoverEnabled, forKey: takeoverKey) }
    }

    /// 全量模式 / AI 公司舰队（一句话派活 → 满屏 agent 并发干活 → 质检 → 产出收进博物馆）。
    /// 关闭时：输入栏「+」菜单里的「🚀 全量模式」入口隐藏，日常使用完全不涉及。
    var fleetModeEnabled: Bool {
        didSet { UserDefaults.standard.set(fleetModeEnabled, forKey: fleetKey) }
    }

    private init() {
        screenTakeoverEnabled = UserDefaults.standard.bool(forKey: takeoverKey)   // 默认 false
        fleetModeEnabled = UserDefaults.standard.bool(forKey: fleetKey)           // 默认 false
    }
}
