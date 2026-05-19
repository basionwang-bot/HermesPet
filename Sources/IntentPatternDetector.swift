import Foundation

/// 用户意图模式识别器（v1.3 Phase 2 —— 纯本地规则，零 AI 调用）。
///
/// 每次 `UserIntentRecorder` 落库一条新意图后调 `evaluate`：
///
/// 1. **重复屏幕检测** —— 同 `screen_hash` 在 1 小时内 ≥ 3 次（Wave B5 起仅归档不弹卡片）
///
/// 冷却规则：
/// - 自然冷却：同 pattern_id 1 小时内最多触发 1 次
/// - 拒绝冷却：用户点过"不用了" → 24 小时内不再触发
///
/// 命中后通过 `onDetected` closure 通知外部（IntentNotificationManager）。
/// **不依赖任何 UI**，纯计算逻辑，便于测试。
///
/// **砍掉的 detector**：
/// - `checkErrorOnScreen`（OCR 含 error/failed/cannot/not found 子串就弹"看到报错了"卡片）
///   假阳性极高（终端 / GitHub PR / git log / 文档里这些词太常见），且没有 hasCodeLikeContext
///   上下文校验，跟 IntentInstantFeedback.screenKeyword 小气泡（有代码语境校验）严重重复。
///   报错信号现在只走两条高置信通道：
///   - copiedError：用户主动 Cmd+C 复制了报错文本
///   - screenKeyword：OCR 命中 + 代码语境校验（hasCodeLikeContext 验证含引号/扩展名/camelCase/snake_case）
@MainActor
final class IntentPatternDetector {
    static let shared = IntentPatternDetector()

    /// 重复检测窗口（分钟）
    private static let repeatedWindowMinutes = 60
    /// 重复检测阈值：同 hash 出现次数 ≥ 此值才算"重复"
    private static let repeatedThreshold = 3

    private weak var store: ActivityStore?

    /// 冷却字典：pattern_id → 解除冷却的时间点
    /// 自然冷却 1h（每个 pattern 1 小时只触发 1 次），拒绝冷却 24h
    private var cooldowns: [String: Date] = [:]

    /// 外部订阅：命中后回调
    /// AppDelegate 启动时连线到 IntentNotificationManager.handle
    var onDetected: ((DetectedPattern) -> Void)?

    private init() {}

    func attach(store: ActivityStore) {
        self.store = store
    }

    // MARK: - 评估

    /// UserIntentRecorder 每次成功落库后调
    func evaluate(latestIntent: UserIntent) {
        // 黑名单的不评估（OCR 是空，模式识别没意义）
        guard !latestIntent.isBlacklisted else { return }

        checkRepeatedScreen(intent: latestIntent)
    }

    // MARK: - Detector 1: 重复屏幕

    private func checkRepeatedScreen(intent: UserIntent) {
        guard let hash = intent.screenHash else { return }
        guard let store else { return }

        // 查窗口内同 hash 出现次数（含本次）
        let recent = store.recentUserIntents(
            withinMinutes: Self.repeatedWindowMinutes,
            limit: 200
        )
        let sameHashCount = recent.filter { $0.screenHash == hash }.count
        guard sameHashCount >= Self.repeatedThreshold else { return }

        let patternID = "repeated_screen:\(hash)"
        guard !inCooldown(patternID) else { return }
        markCooldown(patternID, hours: 1)

        // Wave B5：repeated_screen 是"事后归纳"型 pattern —— 攒 3 次才发现意味着延后至少几分钟
        //         实时弹卡片会显得"AI 反应迟钝"。改成只 NSLog 归档（Wave F morning briefing
        //         拉这个日志 + AI 总结），实时反馈交给 Wave B1/B2/B3 的"当下感知"detector
        NSLog("[Pattern] repeated_screen 已归档（不实时弹）: \(patternID) · count=\(sameHashCount)")
    }

    // 注：原 Detector 2「报错命中」(checkErrorOnScreen) 已砍掉。
    // OCR 关键词子串匹配假阳性太高（终端 / GitHub PR / git log 里 cannot/failed/error 太常见），
    // 且没有 hasCodeLikeContext 上下文校验。报错信号已经在 IntentInstantFeedback 走更高置信的通道：
    // copiedError（用户主动复制） + screenKeyword（OCR + 代码语境校验）

    // MARK: - 冷却管理

    private func inCooldown(_ patternID: String) -> Bool {
        guard let until = cooldowns[patternID] else { return false }
        return Date() < until
    }

    private func markCooldown(_ patternID: String, hours: Double) {
        cooldowns[patternID] = Date().addingTimeInterval(hours * 3600)
    }

    /// 用户点了"不用了"：加 24h 拒绝冷却（覆盖原来的自然冷却）
    func markRejected(_ patternID: String) {
        cooldowns[patternID] = Date().addingTimeInterval(24 * 3600)
    }

    // MARK: - 文案生成（纯模板，未来 Phase 3 可换 AI）

    private func subtitleForApp(_ intent: UserIntent) -> String {
        let app = intent.appName ?? "某个 app"
        if let title = intent.windowTitle, !title.isEmpty {
            return "\(app) · \(title)"
        }
        return app
    }

    /// 重复劳动的聊天预填 prompt —— 把 OCR 摘要给 AI 当上下文
    private func makeRepeatedPrompt(intent: UserIntent, count: Int) -> String {
        let app = intent.appName ?? "某个 app"
        let title = intent.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let ocrSnippet = (intent.ocrText ?? "").prefix(300)
        return """
        我注意到你在过去一小时里反复回到这个屏幕 \(count) 次：
        - 应用：\(app)
        - 窗口：\(title)

        当前屏幕内容片段：
        \(ocrSnippet)…

        有什么我能帮你的吗？是不是这件事可以自动化或者优化？
        """
    }

}

// MARK: - 模型

/// 被识别出的"用户值得被打扰一下"的瞬间
struct DetectedPattern {
    enum Kind {
        case repeatedScreen
        // errorOnScreen 已废弃 —— 假阳性太高，详见类注释
    }

    let kind: Kind
    /// 冷却用的唯一 ID（包含 hash / appID / 关键词）
    let patternID: String
    /// 卡片顶部一行短文字
    let title: String
    /// 卡片副标题（通常是 app 名 + 窗口标题）
    let subtitle: String
    /// 用户点"看看吧"后聊天窗自动预填的 prompt
    let promptDraft: String
    /// 触发这次的原始意图记录（用来反查 OCR 全文 / 标 followedUp）
    let intent: UserIntent

    /// 卡片上小图标
    var iconName: String {
        switch kind {
        case .repeatedScreen: return "arrow.triangle.2.circlepath"
        }
    }
}
