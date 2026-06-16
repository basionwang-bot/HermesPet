import Foundation

/// 一张技能卡 —— AgentForge「上学带回的装备」与 opencode `SKILL.md` 的统一中间表示。
///
/// 桥接两种格式：
/// - **AgentForge 格式**（`agent-forge/agent-school/skills/技能名.md`）：`# 技能:名字` + `**什么时候用**`
///   + 步骤/验证/注意。面向人读，是用户在 AgentForge 仓库里看到的「上学实物成果」。
/// - **opencode 格式**（`<工作目录>/.opencode/skills/<name>/SKILL.md`）：YAML frontmatter（`name`/`description`）
///   + 正文。opencode 原生 `skill` 工具靠 `description` 决定何时**按需加载**（不污染上下文）。
///
/// 同一张卡两头通用 —— 用户在 AgentForge 写/毕业的技能，转一下就给工作台的在线 AI 用。
struct SkillCard: Identifiable, Sendable, Hashable, Codable {
    enum Origin: String, Sendable, Codable { case bundled, agentForge }

    let id: String          // ASCII slug，做 opencode skill 目录名（机读标识）
    let displayName: String // 一句话技能名（UI 显示，可中文）
    let summary: String     // 「什么时候用」→ opencode description（单行，决定何时加载）
    let source: String?     // 来自哪门课 / 哪次实战
    let body: String        // 完整 markdown 正文（步骤/验证/注意）
    let origin: Origin

    var isGraduated: Bool { origin == .agentForge }

    /// 生成 opencode 能加载的 `SKILL.md` 文本（自带 frontmatter，body 不应再含 frontmatter）。
    var skillMarkdown: String {
        let desc = summary
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        name: \(id)
        description: \(desc)
        ---
        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}

/// 一门课（AgentForge `agent-school/课程地图.md` 表格里的一行）。
struct Course: Identifiable, Sendable, Hashable {
    let id: String        // 课程编号，如 "Z02" / "T01" / "01"
    let name: String      // 课程名
    let summary: String   // 「任务方向」一句话
    let done: Bool        // 状态列是否 ✅（已开课）
}

/// 一个学院（课程地图里的一个 `## emoji 名称 · 简介` 分组）。
struct Academy: Identifiable, Sendable, Hashable {
    let id: String        // = title（每学院唯一）
    let title: String     // 含 emoji，如 "🎨 设计学院"
    let tagline: String   // "· " 后的一句话简介（去掉「(N 门)」）
    let courses: [Course]
}

/// 技能库：内置精选 + 从用户 agent-forge 仓库读到的真实毕业技能卡。
///
/// 全是 `static` 纯函数（非 MainActor）—— 既给 `OpenCodeConfigGenerator`（后台写 SKILL.md）用，
/// 也给 `SkillLibraryStore`（主线程 UI）用。读 UserDefaults / 文件系统都线程安全。
enum SkillLibrary {

    /// AgentForge 仓库根目录（用户的 agent-forge 克隆）。可被 UserDefaults `agentForgePath` 覆盖。
    static var repoDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "agentForgePath"),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("agent-forge")
    }

    /// AgentForge 技能卡仓库目录。默认 = repoDir/agent-school/skills；可被 `agentForgeSkillsPath` 单独覆盖。
    static var graduatedSkillsDir: URL {
        if let custom = UserDefaults.standard.string(forKey: "agentForgeSkillsPath"),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return repoDir.appendingPathComponent("agent-school/skills")
    }

    /// AgentForge 仓库是否克隆到本地（决定工作台「去上学」能不能用）。
    static var repoExists: Bool { FileManager.default.fileExists(atPath: repoDir.path) }

    /// 公开课程库（普通用户一键克隆 / 点链接查看的引导目标）。
    static let repoCloneURL = "https://github.com/basionwang-bot/AgentForge.git"
    static var repoWebURL: URL { URL(string: "https://github.com/basionwang-bot/AgentForge")! }

    /// 把 AgentForge 课程库 clone 到 repoDir。成功返回 nil，失败返回人类可读错误。
    /// 阻塞调用（git 子进程）→ 务必放后台线程。
    static func cloneRepo() -> String? {
        let fm = FileManager.default
        let dest = repoDir.path
        if fm.fileExists(atPath: dest) {
            let items = (try? fm.contentsOfDirectory(atPath: dest)) ?? []
            if !items.isEmpty { return "目标目录已存在且非空：\(dest)\n请先清空，或在设置里改 agentForgePath。" }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "clone", "--depth", "1", repoCloneURL, dest]
        proc.environment = CLIProcessEnvironment.make(executablePath: "/usr/bin/git")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return "无法启动 git：\(error.localizedDescription)\n请确认本机已装 git（首次会提示安装 Xcode 命令行工具）。"
        }
        // 先读管道再 wait，避免输出量大时管道写满阻塞子进程（经典死锁）
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return nil }
        let tail = out.split(separator: "\n").suffix(3).joined(separator: " ")
        return "克隆失败（git 退出码 \(proc.terminationStatus)）：\(tail.isEmpty ? "未知错误" : tail)"
    }

    /// 「去上学」指令模板：让 agent 在 agent-forge 仓库里真实上一门课、沉淀一张技能卡。
    /// 经 `runWorkbenchCommand` 包装（前面会拼「你的工作目录是 …」），故这里说「见上方工作目录」。
    static let enrollPrompt = """
    你现在在 AgentForge「AI 养成所」仓库里（具体路径见上方工作目录）。请完成一次**真实的上学**：

    1. 先读 `agent-school/` 下的入学说明（`enroll.md` / `enroll.en.md` / `README.md` / `课程地图.md` 之类），搞懂上学流程和有哪些课。
    2. 看看 `agent-school/skills/` 里我已经学过哪些技能（已有的 `.md` 文件），**挑一门我还没学过的入门课**。
    3. 按课程要求**真实执行**毕业任务——真跑命令、真产出证据，不能只是嘴上说说。
    4. 在 `agent-school/skills/` 目录里**新建一张技能卡** `技能名.md`，严格按 `agent-school/skills/README.md` 的模板写：`# 技能:名字` + `**什么时候用**` + `**来自**` + `## 步骤` + `## 验证` + `## 注意`。
    5. 完成后用一两句话告诉我：你这趟学会了什么、技能卡叫什么名字。

    直接开始，不要反问要不要做。
    """

    /// 全部技能卡 = 内置精选 + agent-forge 真实毕业卡（毕业卡按 id 覆盖同名内置：用户真学的优先）。
    static func loadAll() -> [SkillCard] {
        var result = bundled
        for card in loadGraduated() {
            if let i = result.firstIndex(where: { $0.id == card.id }) { result[i] = card }
            else { result.append(card) }
        }
        return result
    }

    /// 读 agent-forge 技能库目录下所有 `.md`（排除 README），解析成 SkillCard。目录不存在/空 → 返回 []。
    static func loadGraduated() -> [SkillCard] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: graduatedSkillsDir, includingPropertiesForKeys: nil) else { return [] }
        let mdFiles = files
            .filter { $0.pathExtension.lowercased() == "md"
                && $0.lastPathComponent.lowercased() != "readme.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return mdFiles.enumerated().compactMap { idx, url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parseAgentForgeCard(
                markdown: text,
                fileName: url.deletingPathExtension().lastPathComponent,
                index: idx)
        }
    }

    /// 宽容解析 AgentForge 风格技能卡（标题/字段缺失都有兜底，绝不抛错）。
    static func parseAgentForgeCard(markdown: String, fileName: String, index: Int) -> SkillCard? {
        let lines = markdown.components(separatedBy: .newlines)

        // 标题：# 技能:xxx / # 技能：xxx / 普通 # xxx → displayName
        var displayName = fileName
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("# ") else { continue }
            var title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            for prefix in ["技能：", "技能:", "Skill：", "Skill:", "skill:"] {
                if title.hasPrefix(prefix) {
                    title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            if !title.isEmpty { displayName = title }
            break
        }

        // 「什么时候用」→ summary；「来自」→ source
        var summary = ""
        var source: String?
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if summary.isEmpty, let v = extractField(t, keys: ["什么时候用", "何时使用", "When to use", "when"]) { summary = v }
            if source == nil, let v = extractField(t, keys: ["来自", "From", "source"]) { source = v }
        }
        if summary.isEmpty { summary = "处理与「\(displayName)」相关的任务时使用。" }

        let slug = slug(displayName, fallbackIndex: index)
        return SkillCard(id: slug, displayName: displayName, summary: summary,
                         source: source, body: markdown, origin: .agentForge)
    }

    /// 从 `- **key**：value` / `**key**:value` / `key: value` 这类行里抽字段值。
    private static func extractField(_ line: String, keys: [String]) -> String? {
        var s = line
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        s = s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        for key in keys {
            for sep in ["：", ":"] {
                let prefix = key + sep
                if s.hasPrefix(prefix) {
                    let v = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    return v.isEmpty ? nil : v
                }
            }
        }
        return nil
    }

    /// 生成 opencode skill 目录名用的 ASCII slug。全中文 → 兜底 `af-skill-N`（目录名唯一即可，
    /// opencode 真正靠 description 中文触发词匹配，name 只是标识）。
    static func slug(_ input: String, fallbackIndex: Int) -> String {
        var out = ""
        var lastDash = true   // 开头不允许 -
        for ch in input.lowercased().unicodeScalars {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.unicodeScalars.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out = String(out.dropLast()) }
        return out.isEmpty ? "af-skill-\(fallbackIndex + 1)" : out
    }

    // MARK: - AI 学校：课程地图解析（陈列在工作台「学校」栏）

    static var courseMapFile: URL { repoDir.appendingPathComponent("agent-school/课程地图.md") }
    static var coursesDir: URL { repoDir.appendingPathComponent("agent-school/courses") }

    /// 解析 `课程地图.md` → 按学院分组的课程目录。文件不存在/解析空 → []。
    static func loadCourses() -> [Academy] {
        guard let text = try? String(contentsOf: courseMapFile, encoding: .utf8) else { return [] }
        var academies: [Academy] = []
        var curTitle: String?
        var curTagline = ""
        var curCourses: [Course] = []
        func flush() {
            if let t = curTitle, !curCourses.isEmpty {
                academies.append(Academy(id: t, title: t, tagline: curTagline, courses: curCourses))
            }
            curCourses = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let head = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                flush()
                guard head.contains("学院") else { curTitle = nil; continue }   // 「生产节奏」等非学院 → 停止收集
                let parts = head.components(separatedBy: " · ")
                curTitle = parts.first?.trimmingCharacters(in: .whitespaces) ?? head
                var tag = parts.count > 1 ? parts[1] : ""
                for paren in ["(", "（"] { if let r = tag.range(of: paren) { tag = String(tag[..<r.lowerBound]) } }
                curTagline = tag.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard curTitle != nil, line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cells.count >= 2, isCourseID(cells[0]) else { continue }   // 跳过表头/分隔行
            curCourses.append(Course(id: cells[0], name: cells[1],
                                     summary: cells.count > 2 ? cells[2] : "",
                                     done: (cells.last ?? "").contains("✅")))
        }
        flush()
        return academies
    }

    /// 课程编号形如 T01 / Z50 / J08 / 01 / 07（可选一个大写字母前缀 + 数字）。
    private static func isCourseID(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 4 else { return false }
        let scalars = Array(s.unicodeScalars)
        var i = 0
        if let f = scalars.first, f >= "A", f <= "Z" { i = 1 }
        guard i < scalars.count else { return false }
        for j in i..<scalars.count where !(scalars[j] >= "0" && scalars[j] <= "9") { return false }
        return true
    }

    /// 按编号找课程文件（`<id>-*.md` / `<id>.md`；基础学院 J01–J07 落到文件 01–07）。
    static func courseFileURL(id: String) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: coursesDir, includingPropertiesForKeys: nil) else { return nil }
        let md = files.filter { $0.pathExtension.lowercased() == "md" }
        if let hit = md.first(where: {
            $0.lastPathComponent.hasPrefix(id + "-") || $0.deletingPathExtension().lastPathComponent == id
        }) { return hit }
        if id.hasPrefix("J"), let n = Int(id.dropFirst()), (1...7).contains(n) {
            let num = String(format: "%02d", n)
            if let hit = md.first(where: { $0.lastPathComponent.hasPrefix(num + "-") }) { return hit }
        }
        return nil
    }

    /// 读课程正文（详情页用）。找不到文件 → nil。
    static func courseBody(id: String) -> String? {
        guard let url = courseFileURL(id: id) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 「去上这一门指定的课」指令（经 runWorkbenchCommand 会在前面拼上工作目录）。
    static func enrollPrompt(courseID: String, courseName: String) -> String {
        """
        你现在在 AgentForge「AI 养成所」仓库里（路径见上方工作目录）。请去上这一门指定的课：

        【课程】第 \(courseID) 课 · \(courseName)

        1. 打开 `agent-school/courses/` 目录，找到编号 \(courseID) 的课程文件（形如 `\(courseID)-*.md`），通读全文。
        2. 按课程里的毕业要求**真实执行**——真跑命令、真产出证据，不能只嘴上说。涉及装工具/联网/真实账号，先征得我同意。
        3. 学完在 `agent-school/skills/` 新建一张技能卡 `技能名.md`，严格按 `agent-school/skills/README.md` 模板写（`# 技能:名字` + `**什么时候用**` + `**来自**` + `## 步骤` + `## 验证` + `## 注意`）。
        4. 完成后用一两句话告诉我：学会了什么、技能卡叫什么。

        直接开始，别反问要不要做。
        """
    }

    // MARK: - 内置精选技能库（普通人 AI 工作台高频技能；等真毕业卡进来后被同名覆盖）

    static let bundled: [SkillCard] = [
        SkillCard(id: "tidy-files", displayName: "整理文件",
            summary: "整理或批量重命名本地文件夹里的文件（按内容/日期/类型）。当用户想「把这些图片按内容重命名」「整理这个下载文件夹」之类时使用。",
            source: "内置", body: """
            ## 我能做什么
            - 查看文件夹，读文件名/类型（必要时读内容）
            - 提一个清晰的命名/归类方案，确认后用 bash/文件工具执行
            - 始终告诉用户改了什么

            ## 步骤
            1. 列出目标文件夹，搞清楚里面有什么。
            2. 提方案（按日期/主题/类型），拿不准先问用户。
            3. 用 mv 重命名/移动，记录 旧名 → 新名。
            4. 汇报改动。

            ## 验证
            - 重新列文件夹：每个文件都在、没丢。

            ## 注意
            - 除非用户明确要求，绝不删文件，只重命名/移动。
            """, origin: .bundled),

        SkillCard(id: "web-research", displayName: "联网调研",
            summary: "从网页提取关键信息并附来源总结。当用户要「查一下」「研究某个话题」「从这个链接提取信息」之类时使用。",
            source: "内置", body: """
            ## 我能做什么
            - 用 webfetch 抓取网页
            - 只提取回答用户问题的内容
            - 每条结论旁标来源链接

            ## 步骤
            1. 明确要回答的具体问题。
            2. webfetch 每个相关 URL。
            3. 提取具体事实，忽略无关内容。
            4. 总结，每条标来源。

            ## 验证
            - 每条结论都能追溯到抓取的页面，不编造。

            ## 注意
            - 抓不到的页面如实说明，别猜内容。
            """, origin: .bundled),

        SkillCard(id: "social-copy", displayName: "社交文案",
            summary: "写即取即用的社交/营销文案（小红书/公众号/抖音等）。当用户想要一条帖子、文案、标题或带货文字时使用。",
            source: "内置", body: """
            ## 我能做什么
            - 贴合平台调性（小红书种草感 / 公众号信息量 / 抖音短勾人）
            - 产出成品文案，不是大纲
            - 标清给谁看、发哪个平台

            ## 步骤
            1. 不清楚就先问产品/受众/平台。
            2. 用该平台的口吻起草。
            3. 排成可直接复制的成品（合适处带 emoji / 话题标签）。

            ## 验证
            - 是成品帖子、不是 bullet 大纲。
            - 口吻贴合平台。

            ## 注意
            - 只产出草稿，绝不操作任何真实账号。
            """, origin: .bundled),

        SkillCard(id: "doc-polish", displayName: "文档润色",
            summary: "润色、改写、精简一段文字或一份文档（更通顺/更专业/更口语，按需要调）。当用户说「帮我改改这段」「润色一下」「写得更专业点」时使用。",
            source: "内置", body: """
            ## 我能做什么
            - 在保持原意的前提下改语气、改结构、删冗余
            - 按用户要的调性走（正式/口语/营销/学术）
            - 改完说清楚改了哪些地方、为什么

            ## 步骤
            1. 先确认目标读者和想要的调性。
            2. 通读原文，找出冗余、歧义、口气不对的地方。
            3. 重写，保留事实与原意，只改表达。
            4. 给出修改版 + 一句话说明主要改动。

            ## 验证
            - 事实/数字/专有名词没被改错。
            - 调性符合用户要求。

            ## 注意
            - 不替用户编造没有的事实或数据。
            """, origin: .bundled),

        SkillCard(id: "data-extract", displayName: "数据提取",
            summary: "把杂乱的文本/网页/文件里的信息提取成结构化表格（CSV/Markdown 表）。当用户说「整理成表格」「提取出来」「列个清单」时使用。",
            source: "内置", body: """
            ## 我能做什么
            - 从非结构化内容（聊天记录/网页/文档）里抽字段
            - 整理成对齐的 Markdown 表或 CSV
            - 缺失项标清楚，不硬编

            ## 步骤
            1. 跟用户确认要哪几列（字段）。
            2. 逐条抽取，缺的标「—」。
            3. 输出 Markdown 表；用户要文件就写成 .csv。
            4. 报告共多少条、有无异常。

            ## 验证
            - 行数与源数据条目对得上。
            - 每列含义一致、没串列。

            ## 注意
            - 拿不准的字段宁可留空也不瞎填。
            """, origin: .bundled),

        SkillCard(id: "slides-outline", displayName: "演示大纲",
            summary: "把一个主题或一堆资料整理成清晰的 PPT/演讲大纲（分页+每页要点）。当用户说「做个 PPT 大纲」「帮我理个演讲思路」时使用。",
            source: "内置", body: """
            ## 我能做什么
            - 把零散资料组织成有逻辑的分页结构
            - 每页给标题 + 3~5 个要点（不写满段落）
            - 标出哪页该放图/数据

            ## 步骤
            1. 确认演讲目标、时长、听众。
            2. 定主线（问题→方案→证据→行动 之类）。
            3. 拆成页，每页一个核心信息 + 要点。
            4. 输出大纲，建议每页配图/数据位置。

            ## 验证
            - 页与页之间逻辑连贯、不重复。
            - 单页信息量不过载。

            ## 注意
            - 只做大纲与要点，不替用户编造数据来源。
            """, origin: .bundled),
    ]
}

/// 技能库的主线程视图模型 —— 给工作台「技能墙」用。`refresh()` 重新扫描 agent-forge。
@MainActor
@Observable
final class SkillLibraryStore {
    static let shared = SkillLibraryStore()
    private(set) var cards: [SkillCard] = []
    private(set) var academies: [Academy] = []   // AI 学校课程目录（点开学校时懒加载）

    var graduatedCount: Int { cards.filter(\.isGraduated).count }
    var courseCount: Int { academies.reduce(0) { $0 + $1.courses.count } }

    private init() { refresh() }

    func refresh() { cards = SkillLibrary.loadAll() }

    /// 重新解析课程地图（读文件，故懒加载——学校视图首次出现时调）。
    func refreshCourses() { academies = SkillLibrary.loadCourses() }
}
