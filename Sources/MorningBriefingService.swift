import Foundation

/// 每日早报服务 —— 在每天首次启动时自动生成一份"今日早报"。
///
/// 流程：
///   1. 检查 lastBriefingDate < today（同一天不重复生成）
///   2. 拉昨天的 activity_sessions / app_usage_stats / user_questions
///   3. 喂给用户在设置里选定的 `morningBriefingBackend` AI（默认 Hermes）
///   4. AI 返回 markdown briefing → ChatViewModel 自动开一个"📰 今日早报"对话
///
/// 为什么 backend 用户必须显式选：早报包含活动汇总 + 你跟 AI 的问题主题，
/// 数据敏感，让用户有意识地决定哪家服务商能看到这些。
@MainActor
final class MorningBriefingService {
    static let shared = MorningBriefingService()

    private let lastBriefingDateKey = "morningBriefingLastDate"
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    /// 是否在跑（避免重入 / 用户连点）
    private var isGenerating = false

    private init() {}

    // MARK: - 触发入口

    /// AppDelegate 启动时调用 —— 同一天只跑一次
    func generateIfNeeded(viewModel: ChatViewModel) {
        let today = Self.dateFormatter.string(from: Date())
        let last = UserDefaults.standard.string(forKey: lastBriefingDateKey) ?? ""
        if last == today {
            return  // 今天已经生成过
        }
        // 启动后等 3s 再触发，让 ActivityRecorder 把当天 stats 先聚合一下，
        // 也让用户看到 app 启动时不会有突兀弹窗
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self.generateInternal(viewModel: viewModel, isManual: false)
        }
    }

    /// 用户在菜单栏 / 灵动岛点击"立即生成今日早报"调用 —— 不管 lastBriefingDate
    func generateNow(viewModel: ChatViewModel) {
        Task { @MainActor in
            await self.generateInternal(viewModel: viewModel, isManual: true)
        }
    }

    // MARK: - 主流程

    private func generateInternal(viewModel: ChatViewModel, isManual: Bool) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        // 1. 收数据 —— 优先昨天（每天早晨打开看的是回顾）；
        // 如果昨天为空（比如刚装、或周末没用），回退到今天 to-date 的数据
        var data = collectData(forYesterday: true)
        if data.isEmpty {
            data = collectData(forYesterday: false)
        }
        if data.isEmpty {
            if isManual {
                viewModel.errorMessage = "还没有任何活动数据。让 ActivityRecorder 跑一会儿（用一会儿电脑）再来生成早报。"
            }
            return
        }

        // 2. 构造 prompt
        let prompt = buildPrompt(data: data)

        // 3. 调用 AI（用用户选定的 morningBriefingBackend，不写入 user_questions）。
        // 即时反馈：点完不能干等到窗口才弹 —— 灵动岛立刻进入"工作中"脉冲 + 一条暖暖的横幅文字。
        let backend = viewModel.morningBriefingBackend
        Self.islandFeedbackStart(text: "🌅 正在为你回顾昨天…")
        var briefing = ""
        do {
            for try await chunk in viewModel.streamOneShotAsk(
                prompt: prompt,
                modeOverride: backend,
                recordToActivity: false
            ) {
                briefing += chunk
            }
        } catch {
            print("[MorningBriefing] 生成失败: \(error.localizedDescription)")
            Self.islandFeedbackFinish(success: false)
            if isManual {
                viewModel.errorMessage = "早报生成失败：\(error.localizedDescription)"
            }
            return
        }

        let trimmed = briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.islandFeedbackFinish(success: false)
            if isManual {
                viewModel.errorMessage = "早报 AI 没返回内容，请检查 \(backend.label) 后端是否正常"
            }
            return
        }

        // 4. 在正文末尾附上可点击的文档卡（真实存在的路径，正文本身不含路径，统一在这里加）
        var finalContent = trimmed
        if !data.documents.isEmpty {
            finalContent += "\n\n```docs\n" + data.documents.joined(separator: "\n") + "\n```"
        }

        // 5. 写入日报归档（给第二层「周期总分析」+ 设置「成长轨迹」面板用）。
        //    date 用「被回顾的那一天」做主键 —— 这样 daily_journal 一天一行，是一条活动轨迹时间线。
        let journalDate = Self.dateFormatter.string(from: data.yesterdayDate)
        ActivityRecorder.shared.queryStore.upsertDailyJournal(
            date: journalDate,
            summaryMarkdown: finalContent,
            structuredJSON: Self.buildDigestJSON(data: data),
            backend: backend.rawValue
        )

        // 6. 灵动岛：回顾生成完成 → 对勾，然后窗口滑出（让"做完了 → 窗口出现"连成一气）
        Self.islandFeedbackFinish(success: true)

        // 7. 创建回顾对话
        viewModel.createBriefingConversation(content: finalContent)

        // 8. 标记今天已生成
        UserDefaults.standard.set(Self.dateFormatter.string(from: Date()), forKey: lastBriefingDateKey)

        // 9. 顺手更新「共享记忆」（搭早报便车，一天一次）。窗口已经弹出来了，这步在后台静默跑、不挡用户。
        //    喂 trimmed（不含 ```docs 围栏的纯回顾正文）+ 最近问 AI 的话题，让 AI 修订式更新那份跨模式记忆。
        await UserMemoryStore.shared.updateMemory(
            viewModel: viewModel,
            recap: trimmed,
            questionContents: data.yesterdayQuestions.map { $0.content }
        )
    }

    // MARK: - 灵动岛即时反馈（复用现有通知机制，不新增灵动岛状态）

    /// 生成开始：灵动岛进入持续"工作中"脉冲 + 一条暖暖的横幅文字。
    /// 复用 PillView 已有的 HermesPetTaskStarted（持续态）+ HermesPetScreenshotAdded（文字横幅通道）。
    static func islandFeedbackStart(text: String) {
        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)
        NotificationCenter.default.post(
            name: .init("HermesPetScreenshotAdded"),
            object: nil,
            userInfo: ["text": text]
        )
    }

    /// 生成结束：成功 → 对勾后回 idle；失败 → 静默回 idle。
    static func islandFeedbackFinish(success: Bool) {
        NotificationCenter.default.post(
            name: .init("HermesPetTaskFinished"),
            object: nil,
            userInfo: ["success": success]
        )
    }

    // MARK: - 数据收集

    /// - forYesterday: true=拉昨天（早晨自动模式），false=拉今天到目前为止（manual fallback）
    private func collectData(forYesterday: Bool) -> BriefingData {
        let store = ActivityRecorder.shared.queryStore
        let targetDate = forYesterday
            ? (Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            : Date()
        let dayStart = Calendar.current.startOfDay(for: targetDate)
        let dayEnd = dayStart.addingTimeInterval(86400)

        // 先聚合一遍当天 stats（确保最新）
        store.aggregateDailyStats(for: targetDate)
        let stats = store.dailyStats(for: targetDate)

        // 拿当天的用户问题
        let allRecent = store.recentUserQuestions(withinMinutes: 48 * 60, limit: 200)
        let dayQuestions = allRecent.filter {
            $0.timestamp >= dayStart && $0.timestamp < dayEnd
        }

        // 最近 7 天最常用 app
        let topApps = store.topApps(days: 7, limit: 5)

        // 当天的意图采样（仅在用户开了「意图感知」时才有数据）→ 提炼两样：
        //   1. focus 摘要："app · 窗口标题"，让 AI 知道你昨天在屏幕上关注什么
        //   2. 碰过的文档：真实文件路径，给昨日回顾甩出可 ⌘+点击打开的链接
        // recentUserIntents(limit:) 是最新在前，所以下面拿到的也是「最近碰的在前」
        let dayIntents = store.recentUserIntents(limit: 1000).filter {
            $0.timestamp >= dayStart && $0.timestamp < dayEnd && !$0.isBlacklisted
        }

        var seenFocus = Set<String>()
        var focusSummaries: [String] = []
        for intent in dayIntents {
            guard let app = intent.appName, !app.isEmpty else { continue }
            let title = intent.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = (title?.isEmpty == false) ? "\(app) · \(title!)" : app
            if seenFocus.insert(line).inserted { focusSummaries.append(line) }
            if focusSummaries.count >= 12 { break }
        }

        var seenDoc = Set<String>()
        var documents: [String] = []
        for intent in dayIntents {
            guard let p = intent.documentPath, !p.isEmpty, !seenDoc.contains(p) else { continue }
            seenDoc.insert(p)
            // 只留还存在的文件，避免甩出点了打不开的死链接
            if FileManager.default.fileExists(atPath: p) {
                documents.append(p)
            }
            if documents.count >= 6 { break }
        }

        return BriefingData(
            yesterdayDate: targetDate,
            yesterdayStats: stats,
            yesterdayQuestions: dayQuestions,
            topAppsLast7Days: topApps,
            focusSummaries: focusSummaries,
            documents: documents
        )
    }

    // MARK: - Prompt 构造

    private func buildPrompt(data: BriefingData) -> String {
        var lines: [String] = []
        lines.append("# 角色")
        lines.append("你是用户桌面上一只可爱的小宠物，也是最懂他的伙伴。现在基于他昨天的电脑活动，跟他温温地聊一聊「昨天过得怎么样」，并自然地把今天接上。")
        lines.append("")
        lines.append("## 口吻（最重要）")
        lines.append("- \(BriefingStyle.current().toneInstruction)")
        lines.append("- **绝不要像系统在报数据，更不要像监工。** 不管什么口吻，都要真正找出对 TA 有用的点。")
        lines.append("- 第二人称「你」。**不要只盯工作**：他昨天忙到很晚、在某件事上耗了很久、或者今天可以松口气……这些关心都可以聊。")
        lines.append("- markdown 格式，篇幅适中（约 250-450 字，简洁风格可更短）。别长篇大论、别把下面的数据原样复述出来。")
        lines.append("")
        lines.append("## 结构（灵活参考，不必死板套用）")
        lines.append("1. 一句暖暖的问候")
        lines.append("2. 昨天你大概在忙些什么 —— 综合活动和你关注的主题，提炼成「我懂你」的话，别照搬窗口标题或原话")
        lines.append("3. 如果有看起来还没收尾的事，**用很软的语气**提一句（例：「那篇 xxx 好像还没写完？要不要接着弄」）。**绝对不要武断断定他『没做完』**，只是温柔地问一句。")
        lines.append("4. 基于昨天，温柔地建议今天可以做的 1-2 件小事；或者就鼓励他轻松一点")
        lines.append("5. 一句暖心收尾")
        lines.append("")
        lines.append("## 你昨天观察到的数据 (\(Self.dateFormatter.string(from: data.yesterdayDate)))")
        lines.append("")

        // App 使用情况
        if !data.yesterdayStats.isEmpty {
            lines.append("### 用了哪些 App（Top \(min(5, data.yesterdayStats.count))）")
            for s in data.yesterdayStats.prefix(5) {
                let h = s.totalSeconds / 3600
                let m = (s.totalSeconds % 3600) / 60
                let timeStr = h > 0 ? "\(h)h\(m)m" : "\(m)m"
                lines.append("- \(s.appName)：\(timeStr)，\(s.sessionCount) 次会话")
            }
            lines.append("")
        }

        // 屏幕上关注的内容（来自意图感知）
        if !data.focusSummaries.isEmpty {
            lines.append("### 在屏幕上具体关注的（app · 窗口）")
            for f in data.focusSummaries {
                lines.append("- \(f.prefix(80))")
            }
            lines.append("")
        }

        // 碰过的文档（只给文件名，路径由客户端处理成可点击卡片）
        if !data.documents.isEmpty {
            lines.append("### 昨天碰过的文档")
            for p in data.documents {
                lines.append("- \((p as NSString).lastPathComponent)")
            }
            lines.append("")
        }

        // 用户跟 AI 的对话
        let qCount = data.yesterdayQuestions.count
        if qCount > 0 {
            lines.append("### 跟你聊过的话题（用来推断他在关注什么，别照搬原话）")
            for q in data.yesterdayQuestions.prefix(15) {
                let preview = q.content.prefix(120).replacingOccurrences(of: "\n", with: " ")
                lines.append("- \(preview)")
            }
            lines.append("")
        }

        // 最近 7 天常用 app（作为对比）
        if !data.topAppsLast7Days.isEmpty {
            lines.append("### 最近 7 天最常用（仅作对比，未必要提）")
            for s in data.topAppsLast7Days {
                let h = s.totalSeconds / 3600
                lines.append("- \(s.appName)：累计约 \(h)h")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("注意：")
        lines.append("- 文档我会在末尾自动用卡片列出来给他点击，**你正文里自然提到文档名就好，不要输出任何文件路径**。")
        lines.append("- 直接输出回顾正文，不要解释任务、不要复述上面的数据清单。")
        lines.append("- \(LocaleManager.aiReplyLanguageInstruction())")  // Phase 5-3：回顾用界面语言生成
        return lines.joined(separator: "\n")
    }

    /// 把这次回顾的结构化原料编码成 JSON，写进 daily_journal.structured_json，
    /// 给第二层「周期总分析」当原料（不用再重新查一遍历史数据）。
    private static func buildDigestJSON(data: BriefingData) -> String? {
        struct Digest: Codable {
            let date: String
            let topApps: [String]
            let focus: [String]
            let documents: [String]
            let questionCount: Int
        }
        let topApps = data.yesterdayStats.prefix(5).map { s -> String in
            let h = s.totalSeconds / 3600
            let m = (s.totalSeconds % 3600) / 60
            let t = h > 0 ? "\(h)h\(m)m" : "\(m)m"
            return "\(s.appName) \(t)"
        }
        let digest = Digest(
            date: Self.dateFormatter.string(from: data.yesterdayDate),
            topApps: Array(topApps),
            focus: data.focusSummaries,
            documents: data.documents,
            questionCount: data.yesterdayQuestions.count
        )
        guard let json = try? JSONEncoder().encode(digest),
              let str = String(data: json, encoding: .utf8) else { return nil }
        return str
    }
}

/// 早报需要的全部数据快照
struct BriefingData {
    let yesterdayDate: Date
    let yesterdayStats: [AppDailyStat]
    let yesterdayQuestions: [UserQuestion]
    let topAppsLast7Days: [AppDailyStat]
    /// 来自意图感知：「app · 窗口标题」摘要（用户开了意图感知才有）
    let focusSummaries: [String]
    /// 来自意图感知：昨天碰过、且当前仍存在的文档真实路径（甩成可点击卡片）
    let documents: [String]

    var isEmpty: Bool {
        yesterdayStats.isEmpty && yesterdayQuestions.isEmpty && focusSummaries.isEmpty
    }
}
