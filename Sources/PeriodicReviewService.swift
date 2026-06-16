import Foundation

/// 周期性「总结回顾」服务（v1.3 跨天记忆第二层）。
///
/// 跟第一层 `MorningBriefingService`（每天的昨日回顾）的区别是**时间尺度**：
///   - 第一层看"昨天"，每天一次；
///   - 这一层看"这一阵子"，攒一段时间做一次大回顾。
///
/// 触发两种：
///   1. **周报**：距上次周期回顾 ≥ 7 天的那次首次启动（不依赖用户周日开 app，更稳）
///   2. **里程碑**：认识满 30 / 100 / 365 天（带纪念感）
///
/// 这次回顾必须同时给到两样价值（见 [[memory-feature-two-level-value]]）：
///   - **情感陪伴**：让用户感到这段时间一直被陪着、被懂、被关心（豆包式）；
///   - **工作提效**：基于活动规律帮他看清时间花在哪、有没有反复卡住，并给能减负的小建议——
///     这是我们观察用户的"价值意义所在"。
///
/// 数据全部来自本地 `daily_journal`（第一层每天写的归档），不再重新查原始数据、不上报。
@MainActor
final class PeriodicReviewService {
    static let shared = PeriodicReviewService()

    private let lastWeeklyDateKey = "periodicReviewLastWeeklyDate"   // yyyy-MM-dd
    private let firstDayKey = "companionFirstDay"                    // yyyy-MM-dd（第一次见面那天）
    private let firedMilestonesKey = "companionFiredMilestones"     // [Int]，已庆祝过的里程碑

    /// 里程碑天数（认识满 N 天）
    private static let milestones = [30, 100, 365]
    /// 周报间隔天数
    private static let weeklyIntervalDays = 7
    /// 周报 / 手动至少要攒够几天日报才有意义
    private static let minJournalDaysForWeekly = 3

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private var isGenerating = false

    private init() {}

    // MARK: - 触发入口

    /// AppDelegate 启动时调 —— 自动判断该不该做周期回顾。
    /// 延迟 6s（晚于早报的 3s），避免同一次启动里早报 + 周期回顾两份卡片撞一起。
    func generateIfNeeded(viewModel: ChatViewModel) {
        ensureFirstDay()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await self.runAuto(viewModel: viewModel)
        }
    }

    /// 用户手动「立即生成总结回顾」—— 不管周期，直接做一份阶段性回顾
    func generateNow(viewModel: ChatViewModel) {
        ensureFirstDay()
        Task { @MainActor in
            await self.generate(viewModel: viewModel, kind: .manual, isManual: true)
        }
    }

    // MARK: - 自动判断

    private func runAuto(viewModel: ChatViewModel) async {
        // 里程碑优先级高于周报
        if let milestone = pendingMilestone() {
            await generate(viewModel: viewModel, kind: .milestone(days: milestone), isManual: false)
            markMilestoneFired(milestone)
            // 里程碑也顺手刷新周报日期，避免同周再弹一次周报
            UserDefaults.standard.set(Self.dateFormatter.string(from: Date()), forKey: lastWeeklyDateKey)
            return
        }
        if weeklyDue() {
            await generate(viewModel: viewModel, kind: .weekly, isManual: false)
            UserDefaults.standard.set(Self.dateFormatter.string(from: Date()), forKey: lastWeeklyDateKey)
        }
    }

    /// 距上次周期回顾是否够 7 天了（从没做过 → true，数据量门槛在 generate 里再判）
    private func weeklyDue() -> Bool {
        guard let s = UserDefaults.standard.string(forKey: lastWeeklyDateKey),
              let last = Self.dateFormatter.date(from: s) else { return true }
        let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
        return days >= Self.weeklyIntervalDays
    }

    /// 当前该庆祝哪个里程碑（已到天数 + 还没庆祝过的里程碑里取最大）
    private func pendingMilestone() -> Int? {
        let fired = Set(UserDefaults.standard.array(forKey: firedMilestonesKey) as? [Int] ?? [])
        let days = companionDays
        return Self.milestones.filter { days >= $0 && !fired.contains($0) }.max()
    }

    private func markMilestoneFired(_ m: Int) {
        var fired = UserDefaults.standard.array(forKey: firedMilestonesKey) as? [Int] ?? []
        if !fired.contains(m) { fired.append(m) }
        UserDefaults.standard.set(fired, forKey: firedMilestonesKey)
    }

    // MARK: - 认识天数

    private func ensureFirstDay() {
        if UserDefaults.standard.string(forKey: firstDayKey) == nil {
            UserDefaults.standard.set(Self.dateFormatter.string(from: Date()), forKey: firstDayKey)
        }
    }

    /// 认识满多少天（从第一次见面那天算起）
    private var companionDays: Int {
        guard let s = UserDefaults.standard.string(forKey: firstDayKey),
              let d = Self.dateFormatter.date(from: s) else { return 0 }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: d),
                                  to: cal.startOfDay(for: Date())).day ?? 0
    }

    // MARK: - 回顾类型

    private enum ReviewKind {
        case weekly
        case milestone(days: Int)
        case manual
    }

    // MARK: - 主流程

    private func generate(viewModel: ChatViewModel, kind: ReviewKind, isManual: Bool) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        let store = ActivityRecorder.shared.queryStore
        let lookback: Int
        switch kind {
        case .weekly:    lookback = 7
        case .manual:    lookback = 14
        case .milestone: lookback = 30
        }
        let journals = store.recentDailyJournals(limit: lookback)

        // 数据量门槛：周报/手动至少几天才有料；里程碑放宽到 1 天（重点是纪念感）
        let minDays: Int
        if case .milestone = kind { minDays = 1 } else { minDays = Self.minJournalDaysForWeekly }
        guard journals.count >= minDays else {
            if isManual {
                viewModel.errorMessage = "日报攒得还不够（目前 \(journals.count) 天）。再用几天让我多了解你一点，就能给你做总结回顾啦。"
            }
            return
        }

        let prompt = buildPrompt(kind: kind, journals: journals)
        let backend = viewModel.morningBriefingBackend
        // 即时反馈：灵动岛立刻进入"工作中"脉冲 + 暖暖的横幅文字（复用早报那套，见 islandFeedbackStart）
        let startText: String
        if case .milestone = kind { startText = "🎉 正在回顾我们这一路…" } else { startText = "🌱 正在整理这阵子…" }
        MorningBriefingService.islandFeedbackStart(text: startText)
        var result = ""
        do {
            for try await chunk in viewModel.streamOneShotAsk(
                prompt: prompt,
                modeOverride: backend,
                recordToActivity: false
            ) {
                result += chunk
            }
        } catch {
            print("[PeriodicReview] 生成失败: \(error.localizedDescription)")
            MorningBriefingService.islandFeedbackFinish(success: false)
            if isManual {
                viewModel.errorMessage = "总结回顾生成失败：\(error.localizedDescription)"
            }
            return
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            MorningBriefingService.islandFeedbackFinish(success: false)
            if isManual {
                viewModel.errorMessage = "回顾 AI 没返回内容，请检查 \(backend.label) 后端是否正常"
            }
            return
        }

        MorningBriefingService.islandFeedbackFinish(success: true)
        let (title, seed) = titleAndSeed(for: kind)
        viewModel.createBriefingConversation(content: trimmed, title: title, seedUserText: seed)
    }

    private func titleAndSeed(for kind: ReviewKind) -> (String, String) {
        switch kind {
        case .milestone(let days):
            return ("🎉 我们认识 \(days) 天啦", "我们认识 \(days) 天啦，陪我聊聊吧")
        case .weekly, .manual:
            return ("🌱 这阵子的回顾", "陪我回顾一下这阵子吧")
        }
    }

    // MARK: - Prompt 构造

    /// 解码第一层写进 daily_journal.structured_json 的结构化原料
    private struct DayDigest: Decodable {
        let date: String
        let topApps: [String]
        let focus: [String]
        let documents: [String]
        let questionCount: Int
    }

    private func buildPrompt(kind: ReviewKind, journals: [DailyJournalEntry]) -> String {
        var lines: [String] = []
        lines.append("# 角色")
        lines.append("你是用户桌面上一只可爱的小宠物，也是最懂他、最关心他的伙伴。现在陪他做一次更长时间跨度、用心的回顾——像一个一直在他身边的人，认认真真帮他把这阵子梳理一遍、好好讲给他听。")
        lines.append("")
        lines.append("## 这次回顾必须同时给到两样价值（缺一不可）")
        lines.append("1. **情感陪伴**：让他感到这段时间你一直在身边、真的懂他、心疼他的辛苦。温暖、有人味，像个贴心的小家伙，但别肉麻别油腻。")
        lines.append("2. **工作提效**：基于这段时间的活动规律，帮他看清自己把时间花在哪、有没有反复卡住或一直没收尾的事，并温柔地给 1-3 条能真正减轻他负担的小建议。这是你一直陪着他、观察他的意义所在——让他看到你在实实在在帮他、让他更轻松。")
        lines.append("")

        switch kind {
        case .milestone(let days):
            lines.append("## 场景")
            lines.append("今天是你们认识满 **\(days) 天**的日子，带一点温暖的纪念感开场，好好回顾这一路走来。")
        case .weekly, .manual:
            lines.append("## 场景")
            lines.append("一次用心的阶段性回顾（这段时间大约 \(journals.count) 天）。")
        }
        lines.append("")

        // 篇幅：用户主动选「简洁」就别强塞长文；其余风格写得充实、有细节、有起伏。
        let lengthInstruction: String
        if BriefingStyle.current() == .concise {
            lengthInstruction = "篇幅紧凑但有料，约 500-800 字，挑最重要的几件事说透、说具体。"
        } else {
            lengthInstruction = "篇幅要充实，约 900-1500 字，分成几个自然段落或带小标题，把这段时间好好讲清楚、讲得动人——这是一份用心的总结，不是三言两语的便签。"
        }

        lines.append("## 口吻 / 格式（很重要）")
        lines.append("- \(BriefingStyle.current().toneInstruction)")
        lines.append("- 第二人称「你」，用 markdown，可以适当用小标题 / 分段让层次清楚，像一封用心写的信、或一份温柔又有条理的总结。")
        lines.append("- \(lengthInstruction)")
        lines.append("- **一定要具体、有细节、有画面感**：多引用真实发生过的事——大概哪几天在忙什么、碰过哪些文档、反复纠结或关注过什么。别只说「你很努力」这种空话，要让他感到「你是真的记得、真的一直在看着」。")
        lines.append("- 但别写成冷冰冰的数据报告、也别逐日流水账：把这些细节**提炼成规律和故事感**，串成有温度、有起伏的叙述。")
        lines.append("- 提到反复卡住 / 一直没收尾的事时，用很软的语气，本质是帮 TA、不武断断定、不打击。")
        lines.append("- \(LocaleManager.aiReplyLanguageInstruction())")  // Phase 5-3：回顾用界面语言生成
        lines.append("")
        lines.append("## 可以这样组织（灵活参考，自然为主，别死板套模板）")
        lines.append("1. 暖暖的开场，点出这段时间整体的感觉 / 主基调")
        lines.append("2. **这段时间的几条主线**——你主要在忙的事，每条都讲得具体些（大概哪些天、围绕什么、用了什么工具、碰过什么文档、纠结过什么）")
        lines.append("3. **我眼里的你**——这段时间的投入、有没有高光时刻、辛苦在哪、状态的起伏")
        lines.append("4. 如果有看起来反复卡住或一直没收尾的事，用很软的语气提一句")
        lines.append("5. **给你的 1-3 条贴心建议**——要具体、能落地、真能帮他减负")
        lines.append("6. 一句温暖收尾，带一点对接下来的小期待")
        lines.append("")
        lines.append("## 这段时间的素材（按天，越靠前越近；请从中消化提炼，别原样照搬）")
        lines.append("")

        // 每天给两样：结构化要点（骨架）+ 当天那份回顾正文（细节金矿，原来一直没喂给 AI）。
        // 天数多时每天的正文少给点，避免 prompt 过长。
        let bodyMax = journals.count > 12 ? 300 : 450
        for j in journals {
            var dayBlock: [String] = []
            if let data = j.structuredJSON?.data(using: .utf8),
               let d = try? JSONDecoder().decode(DayDigest.self, from: data) {
                var seg = "要点："
                if !d.topApps.isEmpty { seg += "用了 \(d.topApps.prefix(5).joined(separator: "、"))；" }
                if !d.focus.isEmpty { seg += "关注 \(d.focus.prefix(5).joined(separator: "、"))；" }
                if !d.documents.isEmpty {
                    let names = d.documents.prefix(5).map { ($0 as NSString).lastPathComponent }
                    seg += "碰过 \(names.joined(separator: "、"))；"
                }
                seg += "聊了 \(d.questionCount) 个话题"
                dayBlock.append(seg)
            }
            let body = Self.cleanJournalBody(j.summaryMarkdown, maxChars: bodyMax)
            if !body.isEmpty { dayBlock.append("那天的回顾：\(body)") }
            guard !dayBlock.isEmpty else { continue }
            lines.append("### \(j.date)")
            lines.append(contentsOf: dayBlock)
            lines.append("")
        }

        lines.append("---")
        lines.append("直接输出回顾正文，不要解释任务、不要复述上面的素材清单，把它们消化成你自己的话讲给他听。")
        return lines.joined(separator: "\n")
    }

    /// 清理当天回顾正文：去掉末尾自动附加的 ```docs 文档卡围栏，压成一段，再截断到上限。
    private static func cleanJournalBody(_ markdown: String, maxChars: Int) -> String {
        var body = markdown
        if let range = body.range(of: "```docs") {
            body = String(body[..<range.lowerBound])
        }
        body = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > maxChars {
            body = String(body.prefix(maxChars)) + "…"
        }
        return body
    }
}
