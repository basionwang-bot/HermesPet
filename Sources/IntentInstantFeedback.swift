import AppKit

/// 用户对"AI 出场"主通道的偏好。AppStorage key `intentChannelPreference`，默认 `auto`。
/// 三档：
/// - **auto**（默认）：桌宠 visible 走桌宠头顶气泡，hidden 走灵动岛 transient label
/// - **pet**：强制走桌宠 —— 桌宠 hidden 时降级到灵动岛（不至于完全无反馈）
/// - **island**：强制走灵动岛 —— 永远不走桌宠（用户更喜欢"通知中心"式信号）
enum IntentChannelPreference: String, CaseIterable {
    case auto, pet, island

    static func current() -> IntentChannelPreference {
        let raw = UserDefaults.standard.string(forKey: "intentChannelPreference") ?? "auto"
        return IntentChannelPreference(rawValue: raw) ?? .auto
    }

    /// 设置面板展示用
    var displayName: String {
        switch self {
        case .auto:   return "自动"
        case .pet:    return "桌宠优先"
        case .island: return "灵动岛优先"
        }
    }
}

/// "当下感知"反馈路由（Wave B 核心，Wave C 加入双通道偏好）
///
/// 给 detector 一个简单 emit 入口，内部决定：
/// 1. **总开关守护** —— UserIntent 功能关掉时直接 bail（避免老数据残留触发）
/// 2. **抑制判断** —— 调 IntentFeedbackBudget.canEmitFeedback 决定能不能发
/// 3. **通道选择** —— 按 IntentChannelPreference + 桌宠可见性二维路由
/// 4. **文案打磨** —— Wave D 会把"带具体名词 + 桌宠人设"逻辑加进来
///
/// 设计原则：detector 只关心"发现了什么"，路由 / 抑制 / 通道选择都收敛在这里。
@MainActor
final class IntentInstantFeedback {
    static let shared = IntentInstantFeedback()

    private init() {}

    /// 长度天花板（Wave D4）
    /// 桌宠气泡 12 字 / 灵动岛标签 8 字
    private static let petBubbleLimit: Int = 12
    private static let islandLabelLimit: Int = 8

    /// 发出一次"当下感知"反馈（Wave D 接口：交给 IntentCopyWriter 决定文案）。
    /// - Parameters:
    ///   - kind: 反馈类型（copiedError / windowTitleDebug / screenKeyword 等）
    ///   - nounSource: 用于挖"具体名词"的原始文本（剪贴板内容 / 窗口标题 / OCR 片段）
    ///   - triggerAt: 触发事件发生时间（用于 60s 新鲜度门槛）
    ///   - durationSec: 反馈持续秒数，默认 2.5s
    func emit(kind: IntentSignalKind, nounSource: String?, triggerAt: Date, durationSec: TimeInterval = 2.5) {
        // 0. 总开关守护（Wave C 边界）—— 功能关闭时不发任何反馈
        guard UserDefaults.standard.bool(forKey: "userIntentEnabled") else { return }

        // 1. 抑制判断
        guard IntentFeedbackBudget.shared.canEmitFeedback(triggerAt: triggerAt) else {
            NSLog("[IntentFeedback] 被抑制 (\(kind))")
            return
        }

        // 2. 读当前 mode + 让 IntentCopyWriter 组合人设化文案
        let modeRaw = UserDefaults.standard.string(forKey: "agentMode") ?? "directAPI"
        let mode = AgentMode(rawValue: modeRaw) ?? .directAPI
        guard let rawText = IntentCopyWriter.compose(kind: kind, mode: mode, nounSource: nounSource) else {
            NSLog("[IntentFeedback] 无名词不发 (\(kind))")
            return
        }

        // 3. 通道选择：按用户偏好 + 桌宠可见性二维路由
        let pref = IntentChannelPreference.current()
        let petVisible = ClawdWalkController.shared.isPresentingVisible
        let usePet: Bool
        switch pref {
        case .auto:   usePet = petVisible
        case .pet:    usePet = petVisible   // hidden 时降级到灵动岛
        case .island: usePet = false
        }

        // 4. 按通道截断到对应长度天花板
        let limit = usePet ? Self.petBubbleLimit : Self.islandLabelLimit
        let safeText = IntentCopyWriter.truncate(rawText, to: limit)

        if usePet {
            ClawdWalkController.shared.showIntentBubble(text: safeText, duration: durationSec)
        } else {
            NotificationCenter.default.post(
                name: .init("HermesPetIslandTransientLabel"),
                object: nil,
                userInfo: [
                    "text": safeText,
                    "duration": durationSec
                ]
            )
        }

        // 5. 记账
        IntentFeedbackBudget.shared.recordEmitted()
        NSLog("[IntentFeedback] 已发 (\(usePet ? "pet" : "island")) \(kind): \(safeText)")
    }
}
