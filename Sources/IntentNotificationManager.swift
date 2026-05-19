import AppKit

/// 意图反向唤醒调度器（v1.3 Phase 2）
///
/// 把 IntentPatternDetector 的"发现 pattern"事件路由到合适的 UI 形态：
///   - Phase 2：只用 IntentSuggestionWindowController（灵动岛下方卡片）
///   - Phase 3 计划：桌宠 visible 时优先桌宠冒泡，关着时 fallback 灵动岛卡片
///
/// 同时处理用户反馈：
///   - 用户点"看看吧" → 把 promptDraft 写入聊天窗输入框 + 打开聊天 + 标记 followedUp
///   - 用户点"知道了" / 8s 自动消失 → detector.markRejected (24h 冷却)
///   - 灵动岛卡片已经处理了"hover 暂停 dismiss"逻辑
///
/// 启动时机：AppDelegate launch 序列里，UserIntentRecorder.start 之后立即 attach。
@MainActor
final class IntentNotificationManager {
    static let shared = IntentNotificationManager()

    private weak var viewModel: ChatViewModel?
    private weak var store: ActivityStore?
    private var didStart = false

    private init() {}

    /// 启动调度：连线 detector → SuggestionWindow + 监听用户反馈通知
    func start(viewModel: ChatViewModel, store: ActivityStore) {
        guard !didStart else { return }
        didStart = true
        self.viewModel = viewModel
        self.store = store

        // 1) 连线 detector → 弹卡片
        IntentPatternDetector.shared.onDetected = { [weak self] pattern in
            MainActor.assumeIsolated {
                self?.presentSuggestion(pattern)
            }
        }

        // 2) 用户点"看看吧"
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetIntentSuggestionAccepted"),
            object: nil, queue: .main
        ) { [weak self] note in
            // Swift 6 isolation：先提取基本类型（Sendable）再 hop，避免传 note.userInfo 整体
            let promptDraft = (note.userInfo?["promptDraft"] as? String) ?? ""
            let intentID = (note.userInfo?["intentID"] as? Int) ?? 0
            MainActor.assumeIsolated {
                self?.handleAccepted(promptDraft: promptDraft, intentID: intentID)
            }
        }

        // 3) 用户点"知道了" / 8s 超时 / × 关
        NotificationCenter.default.addObserver(
            forName: .init("HermesPetIntentSuggestionDismissed"),
            object: nil, queue: .main
        ) { [weak self] note in
            let patternID = (note.userInfo?["patternID"] as? String) ?? ""
            MainActor.assumeIsolated {
                self?.handleDismissed(patternID: patternID)
            }
        }
    }

    // MARK: - 路由

    private func presentSuggestion(_ pattern: DetectedPattern) {
        guard let vm = viewModel else { return }
        // 当前激活的 mode → 决定卡片上 sprite
        let mode = vm.agentMode
        // 灵动岛 hover / permission / response summary 在显示时让位 —— 简单策略：
        //   PermissionWindowController.isShowing? → 不弹（让位关键操作）
        //   ResponseSummary 显示中 → 不弹（让位用户已经在读的回复）
        // Phase 2 简化：只检查 ResponseSummary，permission 自然冷却 1h 不太可能同时触发
        if ResponseSummaryWindowController.shared?.isShowing == true { return }

        IntentSuggestionWindowController.shared?.show(pattern: pattern, currentMode: mode)
    }

    // MARK: - 用户反馈处理

    private func handleAccepted(promptDraft: String, intentID: Int) {
        guard !promptDraft.isEmpty, let vm = viewModel else { return }

        // 标记这条 intent 已被 follow up（防止以后基于同一条再次提示）
        if intentID != 0 {
            store?.markIntentFollowedUp(intentID)
        }

        // 把 promptDraft 写入当前对话的输入框（不直接发送，让用户编辑）
        // —— 跟 ChoiceCard 点击 → 填入输入框 的 UX 一致（决策 #17）
        vm.inputText = promptDraft

        // 打开聊天窗 + 把光标移到末尾
        NotificationCenter.default.post(name: .init("HermesPetOpenChatRequested"), object: nil)
        // 等一帧让聊天窗显示完，再抢回输入框焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            NotificationCenter.default.post(name: .init("HermesPetFocusInputField"), object: nil)
        }
    }

    private func handleDismissed(patternID: String) {
        guard !patternID.isEmpty else { return }
        // 用户主动拒绝（含 8s 超时）→ 加 24h 冷却
        IntentPatternDetector.shared.markRejected(patternID)
    }
}
