import AppKit

/// 用户意图反馈"预算管理器"（Wave B4）
///
/// 所有"当下感知层"反馈（B1 copied_error / B2 window_title / B3 screen_keyword）
/// 在发出前必须先调 `canEmitFeedback(triggerAt:)`，集中决定该不该出现。
///
/// 抑制规则（任一条命中就静默）：
/// 1. **quietMode** —— 用户在设置里关了桌宠动效，意味着"我现在专注，别打扰我"
/// 2. **新鲜度门槛 60s** —— 事件触发距今 > 60s 就过期，不发（Wave B 的核心反延后准则）
/// 3. **打字静默 10s** —— 最近 10s 内有按键 = 用户正在输入，不打断思路
/// 4. **每天上限 + 每分钟上限** —— 防"AI 一直在哔哔哔"轰炸（v1.3「不刻意」护栏：默认安静）
/// 5. **关键 UI 显示中** —— PermissionWindow / ResponseSummary / IntentSuggestion 任一显示
///    就让位（它们都已经在表达 AI 意图，再加一层会乱）
///
/// 设计原则：宁可少发，不可烦人 —— 信任感的根基比"展现智能"重要。
/// 意图数据的主要去处是「日报归档」当安静的记忆底料，主动气泡只是点缀，所以默认压得很低。
@MainActor
final class IntentFeedbackBudget {
    static let shared = IntentFeedbackBudget()

    /// 触发-反馈新鲜度门槛：事件发生超过这个秒数就放弃反馈
    /// （核心反"延后笨"原则 —— 5min 前的事现在说就是马后炮）
    static let freshnessSeconds: TimeInterval = 60

    /// 最近按键 < 此秒数就视为"用户在打字"，不打扰
    static let typingQuietSeconds: TimeInterval = 10

    /// 滑动窗口 60s 内最多发几次反馈 —— 读用户偏好。
    /// 用 AppStorage key `intentFeedbackPerMinute` 配置，默认 1（安静）。
    /// 设置面板把它呈现为 安静(1) / 适中(2) / 频繁(4) 三档
    static var maxPerMinute: Int {
        let raw = UserDefaults.standard.integer(forKey: "intentFeedbackPerMinute")
        return raw <= 0 ? 1 : raw   // 0 = 未设置 → 默认 1（安静）
    }

    /// 一整天最多发几次主动气泡 —— "不刻意"硬护栏。
    /// 防止零零碎碎冒一整天显得刻意；意图数据主要沉淀进日报归档，不靠实时气泡刷存在感。
    /// in-memory 计数（重启清零），作为软护栏足够。
    static let maxPerDay = 5

    private var recentFeedbackAt: [Date] = []
    private var lastKeyDownAt: Date? = nil

    private init() {}

    /// UserIntentRecorder.handleKeyEvent 任意按键都调一下，用于"打字静默"判断
    func noteKeyEvent() {
        lastKeyDownAt = Date()
    }

    /// 是否允许发出一次"当下感知"反馈
    /// - Parameter triggerAt: 触发事件发生的时间戳（落库时间 / 复制时间等）
    /// - Returns: true 才能发，发完调用方负责调 `recordEmitted()` 记账
    func canEmitFeedback(triggerAt: Date) -> Bool {
        // 1. quietMode 总开关
        if UserDefaults.standard.bool(forKey: "quietMode") { return false }

        // 2. 新鲜度门槛
        if Date().timeIntervalSince(triggerAt) > Self.freshnessSeconds { return false }

        // 3. 打字静默
        if let last = lastKeyDownAt, Date().timeIntervalSince(last) < Self.typingQuietSeconds {
            return false
        }

        // 4. 频率上限（"不刻意"双重护栏）：先按 24h 修剪，再判每天上限 + 每分钟上限。
        //    recentFeedbackAt 保留最近 24h 的发送记录（in-memory，重启清零，作为软护栏够用）。
        let dayCutoff = Date().addingTimeInterval(-86400)
        recentFeedbackAt = recentFeedbackAt.filter { $0 > dayCutoff }
        // 4a. 每天上限 —— 防一整天零零碎碎冒太多显得刻意
        if recentFeedbackAt.count >= Self.maxPerDay { return false }
        // 4b. 每分钟上限（读用户偏好，默认安静 1 次）
        let minuteCutoff = Date().addingTimeInterval(-60)
        if recentFeedbackAt.filter({ $0 > minuteCutoff }).count >= Self.maxPerMinute { return false }

        // 5. 关键 UI 让位
        if PermissionWindowController.shared?.isShowing == true { return false }
        if ResponseSummaryWindowController.shared?.isShowing == true { return false }
        if IntentSuggestionWindowController.shared?.isShowing == true { return false }

        return true
    }

    /// 反馈发出后调用，记账到滑动窗口
    func recordEmitted() {
        recentFeedbackAt.append(Date())
    }

    /// 调试用：当前窗口已发反馈次数
    var emittedInLastMinute: Int {
        let cutoff = Date().addingTimeInterval(-60)
        return recentFeedbackAt.filter { $0 > cutoff }.count
    }
}
