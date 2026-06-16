import Foundation

/// 跨模式「共享记忆」（v1.3 Phase 4a）。
///
/// 一份**所有 mode（5 个 AI）共享、用户可编辑、结构化限长**的本地用户记忆。
/// 类比 Claude Code 给用户维护的 memory，但关键升级是 **跨 5 个 AI 共享** ——
/// 用户不管换哪个 AI，都读这同一份记忆 → "切 AI 也接着懂你"。
///
/// 三条主线：
///   - **读（零 AI 成本）**：`injectionText()`，各 mode 在对话开头注入一次（4b/4c 接）。
///   - **写（一天一次，搭早报便车）**：`updateMemory(...)` 修订式更新 —— 喂「当前记忆 + 新材料」，
///     让 AI 合并 / 纠正 / 删过时 / 压回限长。**只记具体、可行动、非显而易见的点。**
///   - **用户可编辑**：设置里能看 / 改 / 清空。手写的内容会被下次更新当"当前记忆"保留合并，不会被冲掉。
///
/// 隐私：本地文件，可编辑、可清、可总开关关。注入 = 发给所选后端 AI（4b 起），需向用户明示。
/// 只有不可变状态（两个 let 常量）→ 整个类是 Sendable，读写方法天然 nonisolated，
/// 各 mode 的 client 在后台 streaming 线程能直接取 `shared` 注入。只有用到 viewModel 的
/// `updateMemory` 标 `@MainActor`。
final class UserMemoryStore: Sendable {
    static let shared = UserMemoryStore()

    /// 记忆全文硬性上限（字符数）——逼它只留精华 + 注入便宜。AI prompt 里要求 ≤1500 字，这里再留点裕量兜底。
    /// B 阶段从 1500 扩到 4000：空闲实时更新后记忆更细，需要更大容量。
    static let maxChars = 4000

    private let enabledKey = "userMemoryEnabled"
    private let noticeShownKey = "userMemoryNoticeShown"

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet")
        return dir.appendingPathComponent("user-memory.md")
    }()

    private init() {}

    // MARK: - 总开关

    /// B 阶段改为**默认开**：键从没设过 → 视为开；用户显式关过（写过 false）→ 尊重为关。
    /// 只读 UserDefaults（线程安全）。
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    // MARK: - 首次低调告知（默认开，第一次用横幅告诉用户"我会记着你的偏好，可在设置关"）

    /// 还没给用户看过那条一次性提示（且功能确实开着）。
    var firstRunNoticePending: Bool {
        isEnabled && !UserDefaults.standard.bool(forKey: noticeShownKey)
    }

    func markNoticeShown() {
        UserDefaults.standard.set(true, forKey: noticeShownKey)
    }

    // MARK: - 读 / 写 / 清

    /// 读记忆全文（没有 / 读失败返回空串）。仅 FileManager 读，线程安全。
    func load() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// 保存记忆全文（自动建目录 + 截到硬上限）。用户手动编辑、AI 更新都走这里。
    func save(_ text: String) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > Self.maxChars {
            trimmed = String(trimmed.prefix(Self.maxChars))
        }
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var isEmpty: Bool {
        load().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 注入文本（供 4b/4c 各 mode 在对话开头注入）

    /// 给 AI 当背景的注入片段（空记忆 / 关闭时返回 nil，调用方跳过注入）。
    func injectionText() -> String? {
        guard isEnabled else { return nil }
        let mem = load().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mem.isEmpty else { return nil }
        return """
        # 关于这位用户（你的长期记忆，帮你更懂 TA；自然运用即可，不用刻意复述）
        \(mem)
        """
    }

    // MARK: - 修订式更新（搭早报便车，一天一次）

    /// 用「当前记忆 + 新材料」修订出一版新记忆并保存。失败静默（后台维护，不打扰用户）。
    /// @MainActor：用到 viewModel（ChatViewModel 是 @MainActor）。
    /// - Parameters:
    ///   - recap: 今天刚生成的那份回顾正文（已是当天的高浓缩摘要）
    ///   - questionContents: 用户最近问 AI 的话题（"把对话也加进来"）
    @MainActor
    func updateMemory(viewModel: ChatViewModel, recap: String, questionContents: [String]) async {
        guard isEnabled else { return }

        let current = load()
        let prompt = Self.buildUpdatePrompt(current: current, recap: recap, questions: questionContents)
        // 静默后台维护固定走「在线 AI」保底 —— 它零依赖（内置 opencode runtime + 免费模型）、永远在 enabled 集合，
        // 任何机器都能跑。不能赌用户配了 OpenClaw / 把 morningBriefingBackend 设成了重型 CLI。
        let backend: AgentMode = .directAPI

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
            print("[UserMemory] 更新失败（静默）: \(error.localizedDescription)")
            return
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        NSLog("[UserMemory] 已更新（\(trimmed.count) 字）")
    }

    /// B 阶段：空闲触发的近实时更新 —— 拿用户最近的对话片段当新材料修订记忆。
    /// 复用 updateMemory 的修订 prompt（recap 用一句占位，真正信号在「话题列表」）。
    /// 由 ChatViewModel 在用户空闲（3min）且期间聊过新内容时调用。
    @MainActor
    func updateFromRecentConversations(viewModel: ChatViewModel) async {
        guard isEnabled else { return }
        // 跨所有对话取最近的用户消息（最能反映 TA 在关注 / 在做什么），时间正序喂给 AI
        let sorted = viewModel.conversations
            .flatMap { $0.messages }
            .filter { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp > $1.timestamp }
        let recent = Array(sorted.prefix(20)).reversed().map { $0.content }
        guard !recent.isEmpty else { return }
        await updateMemory(
            viewModel: viewModel,
            recap: "（这是用户最近的对话片段，关注的话题见下方列表）",
            questionContents: Array(recent)
        )
    }

    // MARK: - 更新 prompt（质量关键：只记具体、可行动、非显而易见）

    private static func buildUpdatePrompt(current: String, recap: String, questions: [String]) -> String {
        var lines: [String] = []
        lines.append("# 任务")
        lines.append("你在维护一份「用户记忆」——它会被分享给这位用户接下来对话的**所有 AI**看，让它们都更懂 TA。")
        lines.append("现在根据新的材料，更新这份记忆。")
        lines.append("")
        lines.append("# 现有记忆")
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("（还是空的，这是第一次写）")
        } else {
            lines.append(current)
        }
        lines.append("")
        lines.append("# 新材料（最近发生的）")
        lines.append("## 今天的活动回顾")
        lines.append(recap)
        if !questions.isEmpty {
            lines.append("")
            lines.append("## 用户最近问 AI 的话题（推断 TA 在关注什么，别照搬原话）")
            for q in questions.prefix(20) {
                let preview = q.prefix(120).replacingOccurrences(of: "\n", with: " ")
                lines.append("- \(preview)")
            }
        }
        lines.append("")
        lines.append("# 更新规则（严格遵守）")
        lines.append("- 输出**完整的、更新后的记忆全文**（不是改动说明），我会直接保存覆盖。")
        lines.append("- ⚠️ **分清「用户本人」和「用户看的 / 测的 / 生成的东西」**：用户上传的图片、AI 识别出的图片内容、生成的图画、小说 / 游戏 / 动漫里的角色、样例文档、纯为测试 AI 能力而问的话（如「你是谁」「你了解我吗」「这是什么」「请分析这张图片」），统统**不是**关于用户的事实。**绝对不要**把图片 / 故事里的角色名，当成用户的名字、或用户对 AI 的称呼（反面例子：用户传了一张叫「银月」的角色图，**不等于**用户叫银月、也**不等于**用户管 AI 叫银月——这类一律不写）。")
        lines.append("- **拿不准就不记**：某条信息若没有「用户本人明确说出口」的直接依据（只是 TA 问过 / 看过 / 让你生成过），一律**不要**写进记忆。宁可漏记，也**绝不臆造**身份、技术栈、职业、生活细节。已有记忆里发现这类没依据的臆测，**主动删掉**。")
        lines.append("- 只记**具体、可行动、非显而易见**的点；泛泛而谈（如「用户喜欢编程」）一律删掉。")
        lines.append("- 把新信息**合并**进已有记忆；**纠正**过时/矛盾的；**删掉**不再相关的。保留用户手写进去的内容。")
        lines.append("- 保持精炼：**全文控制在 1500 字以内**。宁可少记、记准，别堆流水账。")
        lines.append("- 用第三人称「用户 / TA」写（这会被注入给别的 AI 当背景）。")
        lines.append("- \(LocaleManager.aiReplyLanguageInstruction())")  // Phase 5-3：记忆用界面语言写
        lines.append("- 固定用下面四个小节（某节暂时没内容就写「（暂无）」）：")
        lines.append("")
        lines.append("# 关于用户")
        lines.append("（角色、技术栈、长期在做的方向、稳定偏好）")
        lines.append("# 最近在忙")
        lines.append("（这几天的主线、关注的项目 / 主题）")
        lines.append("# 待续的事")
        lines.append("（没收尾的、说过想做但还没做的）")
        lines.append("# 怎么配合 TA 最好")
        lines.append("（回答方式偏好、反复采纳 / 拒绝的风格）")
        lines.append("")
        lines.append("直接输出更新后的记忆全文，不要任何解释或开场白。")
        return lines.joined(separator: "\n")
    }
}
