import SwiftUI
import AppKit

/// 「舰队工作流」第 1 期 —— 一支**有职位分工的「AI 公司」**把用户任务并行做完。
///
/// 心智模型(2026-06-03 与用户定):不是"派几个抽象子 Agent",而是
/// ① **各行各业的公司库**(`CompanyType`,软件/营销/内容/电商/咨询/通用…),派活前先定"这活归哪类公司";
/// ② 公司里有**有职位的员工**(`FleetRole`,各有职能 + 派最合适后端);
/// ③ 开工前先**反问**(`ClarifyQuestion`,带选项让用户确认),把目标逼清楚再动手;
/// ④ 真并行(HTTP 后端不限并发、子进程后端限并发),视觉上看得出在并行。
///
/// 守约束:决策 #5(@MainActor @Observable,状态全主线程写)、决策 #1(剧场是独立 NSWindow,不碰灵动岛 frame)、
/// sessionToken 防串(照 RunModel)。加 role 字段**不触发**决策 #18(不是新增 AgentMode,审计已确认)。

// MARK: - 后端并发特性(给 fan-out 调度用)

extension AgentMode {
    /// 是否本地重型子进程(spawn 进程):批量并发不稳、吃内存 → fan-out 时限并发。
    /// HTTP 类(hermes/directAPI/openclaw)= false,可放开并发。
    var isLocalHeavy: Bool {
        switch self {
        case .hermes, .directAPI, .openclaw: return false
        case .claudeCode, .codex, .qwenCode: return true
        }
    }
}

// MARK: - 职能角色(公司里的"工种",跨公司复用)

enum FleetRole: String, Codable, CaseIterable, Identifiable {
    case researcher, strategist, writer, engineer, designer, reviewer
    case analyst, marketer, planner, editor, ops

    var id: String { rawValue }

    var title: String {
        switch self {
        case .researcher: return "调研员"
        case .strategist: return "策划师"
        case .writer:     return "文案"
        case .engineer:   return "工程师"
        case .designer:   return "视觉/原型师"
        case .reviewer:   return "质检员"
        case .analyst:    return "分析师"
        case .marketer:   return "营销官"
        case .planner:    return "项目经理"
        case .editor:     return "主编"
        case .ops:        return "运营"
        }
    }

    /// 一句话职能
    var summary: String {
        switch self {
        case .researcher: return "搜集资料、查证事实、梳理背景，产出可信结论"
        case .strategist: return "把目标拆成方案、路线图与取舍建议，定整体打法"
        case .writer:     return "把内容写成给人看的稿子（文章/文档/营销文案）"
        case .engineer:   return "写/改代码、跑命令、操作本机文件，交付可运行产物"
        case .designer:   return "界面/原型/视觉实现（原生 UI、组件、版式）"
        case .reviewer:   return "审查其他角色的成果，挑错、查漏、把关质量"
        case .analyst:    return "数据对比、拆解指标、给出有依据的洞察"
        case .marketer:   return "增长/推广/投放与传播策略"
        case .planner:    return "统筹排期、拆里程碑、协调各角色"
        case .editor:     return "选题、内容结构与调性把控"
        case .ops:        return "选品、详情、活动等运营落地"
        }
    }

    /// 默认后端(优先 HTTP,只有真需要本地能力才用子进程)
    var defaultBackend: AgentMode {
        switch self {
        case .engineer: return .claudeCode   // 唯一真要读写本机文件/跑命令的角色 → 子进程
        case .strategist, .marketer, .ops: return .hermes   // 给 hermes 分担负载
        default: return .directAPI           // 最稳最通用(含视觉师:先出设计方向文字,由工程师落地)
        }
    }

    /// 流程阶段:**同阶段并发**,后阶段等前阶段产出再接力(0 最先 → 数字越大越后)。
    /// 这样"质检"不会和被检对象抢跑、"工程"能拿到前面的方案/设计当依据。
    var stage: Int {
        switch self {
        case .engineer: return 1     // 实现:基于前面的调研/策划/设计来落地
        case .reviewer: return 2     // 把关:审查所有人的成果,必须最后
        default:        return 0     // 调研/策划/设计/文案/分析/营销/项目/主编/运营:先一起并行
        }
    }

    /// 广度型角色:再派出多个子 agent **并行探索不同方向**——挖得更全 + 更快 + 单路失败不拖全局,
    /// 还制造"好多 agent 在为我干活"的爽感(大 agent 套小 agent 一层层铺开)。
    /// 大部分 stage-0 研究/创意/策划角色都分裂;只有产出"单一连贯成品"的 writer/designer 和
    /// 干本机活的 engineer / 最后把关的 reviewer 不分裂。只在 HTTP 后端递归(子进程不递归,避免进程爆炸)。
    var exploresInParallel: Bool {
        switch self {
        case .researcher, .analyst, .marketer, .strategist, .planner, .editor, .ops: return true
        case .writer, .designer, .engineer, .reviewer: return false
        }
    }

    var symbol: String {
        switch self {
        case .researcher: return "magnifyingglass"
        case .strategist: return "lightbulb.fill"
        case .writer:     return "pencil.line"
        case .engineer:   return "hammer.fill"
        case .designer:   return "paintbrush.pointed.fill"
        case .reviewer:   return "checkmark.seal.fill"
        case .analyst:    return "chart.bar.fill"
        case .marketer:   return "megaphone.fill"
        case .planner:    return "calendar.badge.clock"
        case .editor:     return "text.book.closed.fill"
        case .ops:        return "shippingbox.fill"
        }
    }

    private var hex: String {
        switch self {
        case .researcher: return "#4F46E5"
        case .strategist: return "#16A34A"
        case .writer:     return "#0EA5E9"
        case .engineer:   return "#EA580C"
        case .designer:   return "#06B6D4"
        case .reviewer:   return "#DC2626"
        case .analyst:    return "#8B5CF6"
        case .marketer:   return "#F59E0B"
        case .planner:    return "#0D9488"
        case .editor:     return "#DB2777"
        case .ops:        return "#65A30D"
        }
    }

    /// 职位身份色
    var tint: Color { Color(hex: hex) ?? .gray }
}

// MARK: - 公司类型(各行各业的"花名册库")

struct CompanyType: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let tintHex: String
    let roles: [FleetRole]      // 这家公司的标准团队

    var tint: Color { Color(hex: tintHex) ?? .indigo }
}

/// 内置公司库(未来可像 WorkflowRegistry 那样远程下发 / 可复用 / 可买卖)。
enum CompanyRegistry {
    static let all: [CompanyType] = [
        CompanyType(id: "general", name: "通用万能团队",
                    summary: "什么活都能接的全能小队",
                    symbol: "sparkles", tintHex: "#7C6CFF",
                    roles: [.planner, .researcher, .strategist, .writer, .analyst, .reviewer]),
        CompanyType(id: "software", name: "软件研发公司",
                    summary: "做软件 / 网站 / 工具",
                    symbol: "hammer.fill", tintHex: "#EA580C",
                    roles: [.planner, .researcher, .strategist, .designer, .engineer, .reviewer]),
        CompanyType(id: "marketing", name: "营销品牌公司",
                    summary: "做品牌 / 推广 / 活动",
                    symbol: "megaphone.fill", tintHex: "#E85C8A",
                    roles: [.researcher, .strategist, .marketer, .writer, .designer, .reviewer]),
        CompanyType(id: "content", name: "内容工作室",
                    summary: "做文章 / 脚本 / 新媒体",
                    symbol: "pencil.and.scribble", tintHex: "#0EA5E9",
                    roles: [.researcher, .strategist, .editor, .writer, .designer, .reviewer]),
        CompanyType(id: "ecommerce", name: "电商运营公司",
                    summary: "做店铺 / 选品 / 详情页",
                    symbol: "cart.fill", tintHex: "#16A34A",
                    roles: [.analyst, .strategist, .ops, .marketer, .writer, .designer]),
        CompanyType(id: "consulting", name: "咨询调研公司",
                    summary: "做调研 / 分析 / 方案",
                    symbol: "chart.bar.doc.horizontal.fill", tintHex: "#4F46E5",
                    roles: [.planner, .researcher, .analyst, .strategist, .writer, .reviewer]),
    ]

    static var fallback: CompanyType { all[0] }

    static func company(id: String) -> CompanyType? { all.first { $0.id == id } }

    /// 用队长输出的一段文字(可能含公司名或 id)宽松匹配出一家公司。
    static func match(_ raw: String) -> CompanyType? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let byID = all.first(where: { s.contains($0.id) }) { return byID }
        if let byName = all.first(where: { s.contains($0.name) }) { return byName }
        return nil
    }
}

// MARK: - 反问(开工前澄清,带选项)

@MainActor
@Observable
final class ClarifyQuestion: Identifiable {
    let id: String
    let question: String
    let options: [String]
    let allowsMultiple: Bool        // 队长标注:这题能不能选多个(可叠加的需求→多选;互斥的二选一→单选)
    var selectedSet: Set<String> = []   // 选中的选项(单选时最多 1 个)
    var customText: String = ""     // 用户额外补充

    init(id: String, question: String, options: [String], allowsMultiple: Bool = false) {
        self.id = id
        self.question = question
        self.options = options
        self.allowsMultiple = allowsMultiple
    }

    /// 点一个选项:多选=切换成员(可同时选多个);单选=互斥替换(再点一次取消)。
    func toggle(_ opt: String) {
        if allowsMultiple {
            if selectedSet.contains(opt) { selectedSet.remove(opt) } else { selectedSet.insert(opt) }
        } else {
            selectedSet = selectedSet.contains(opt) ? [] : [opt]
        }
    }

    func isSelected(_ opt: String) -> Bool { selectedSet.contains(opt) }

    /// 这道题用户给出的最终答案(选中项按原顺序用「、」连,再接自定义补充)。
    var answer: String? {
        var parts = options.filter { selectedSet.contains($0) }   // 保持选项原顺序
        let c = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { parts.append(c) }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }
}

/// 已答完的一道澄清题(多轮逼近的历史,给后续轮次 + UI 回顾用)。
struct ClarifyAnswered: Identifiable, Hashable {
    let id = UUID()
    let question: String
    let answer: String
}

/// 产物的一个历史版本(done 后每轮打磨各存一版,可回看)。v0=初版;之后每次 refine 成功生成 v1/v2…
struct FleetProductVersion: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    let product: String
    let feedback: String?        // 触发这版的用户反馈(初版 nil)
    let changedRoles: [String]   // 这版重派了哪些职位(中文名)
    let createdAt: Date
}

// MARK: - 子探索 agent(广度型角色派出的"孙 agent",专攻一个方向)

@MainActor
@Observable
final class FleetSubAgent: Identifiable {
    let id: String
    var direction: String      // 探索方向标题
    var backend: AgentMode     // 这一路分摊到哪个 HTTP 后端(在线AI/OpenClaw/Hermes 轮流,避免挤单点)
    var status: String         // pending / running / succeeded / failed
    var partialText: String
    var output: String
    var activityText: String = ""   // 实时活动(工具动作"🌐 抓 xxx"),答案还没出时显它,治"看着像死的"
    init(id: String, direction: String, backend: AgentMode) {
        self.id = id
        self.direction = direction
        self.backend = backend
        self.status = "pending"
        self.partialText = ""
        self.output = ""
    }
}

// MARK: - 一个子 Agent(舰队里的一名员工 / 一张卡片)

@MainActor
@Observable
final class FleetAgent: Identifiable {
    let id: String
    var role: FleetRole?       // 职位(可空 = 通用)
    var title: String          // 这名员工具体负责啥(taskBrief)
    var backend: AgentMode     // 实际派给哪个 AI(已做配置降级)
    var stage: Int             // 流程阶段(同阶段并发,后阶段等前阶段)
    var status: String         // pending / running / succeeded / failed / waiting
    var partialText: String    // 实时吐字
    var output: String         // 完整产出(点卡片展开看)
    var activityText: String = ""   // 实时活动(工具动作"🌐 抓 xxx"),答案还没出时显它,治"看着像死的"
    var subAgents: [FleetSubAgent] = []   // 广度型角色派出的并行子探索(空=没分派)
    /// ⭐ 依赖的同事(agent id):这一路只在它们都产出后才开跑、并拿它们的产出当输入。
    /// 空 = 根/采集层(最先开跑、且只有根才做 fan-out)。`stage` 字段由依赖深度计算填充。
    var dependsOn: [String] = []
    /// ⭐ 动态派发:true = 开跑时再从 HTTP 空闲池"谁有空位谁接"地挑后端(不预先定死)。
    /// 只给"动脑"的非根角色用;数据采集→Claude Code、写代码→CLI 这些是固定后端、不走动态。
    var dynamicDispatch: Bool = false
    /// ⭐ 返工模式专用:只针对**本角色**的复核意见(非空 = 这一趟是返工)。
    /// 设了它 → runAgent 走单流精修(带上自己上一版 + 只属于自己的意见),不再重拆方向、不连累别人、
    /// 也绝不把别人的意见塞进来(修掉"策划师被分析师的意见带跑、去写分析师的事"那个 bug)。
    var fixNote: String = ""
    var startedAt: Date?
    var endedAt: Date?

    init(id: String, role: FleetRole?, title: String, backend: AgentMode, stage: Int) {
        self.id = id
        self.role = role
        self.title = title
        self.backend = backend
        self.stage = stage
        self.status = "pending"
        self.partialText = ""
        self.output = ""
    }

    /// 卡片上显示的标题:有职位用职位名,否则截取任务前几个字。
    var displayHeading: String { role?.title ?? "成员" }
    var accentTint: Color { role?.tint ?? backend.railTint }
}

// MARK: - 一次舰队运行的执行态(剧场窗口绑定)

enum FleetPhase: String {
    case idle           // 等用户给任务
    case clarifying     // 反问中(等用户确认)
    case decomposing    // 队长选公司 + 派活
    case dispatched     // 员工并行干
    case synthesizing   // 收回来汇总
    case reviewing      // 产物拼好后,独立质检 gate 正在审
    case fixing         // 质检不通过,被点名角色返工中
    case refining       // done 之后用户提反馈、正在定向重派打磨
    case done
    case failed
    case aborted
}

// MARK: - 交付前质检结论

/// 质检 gate 对最终产物的一条问题(点名某角色去修)。
struct ReviewIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: String         // blocker / major / minor(仅 blocker/major 触发返工)
    let targetRole: FleetRole?   // 该谁修;nil = 不确定
    let detail: String           // 问题描述
    let fixHint: String          // 怎么改(喂回返工 prompt)
}

/// 一轮质检的完整结论。
struct ReviewVerdict: Identifiable, Hashable {
    let id = UUID()
    let round: Int
    let passed: Bool
    let summary: String
    let issues: [ReviewIssue]

    /// 需返工的角色(去重,只取 blocker/major)。
    var rolesToFix: [FleetRole] {
        let severe = issues.filter { $0.severity == "blocker" || $0.severity == "major" }
        var seen = Set<FleetRole>(); var out: [FleetRole] = []
        for r in severe.compactMap({ $0.targetRole }) where !seen.contains(r) {
            seen.insert(r); out.append(r)
        }
        return out
    }
}

// MARK: - 显式作战计划(⑤「脚本本质」可见载体)

/// 队长派给一名成员的计划条目。可保存、可复用为模板。
struct PlannedMember: Identifiable, Hashable, Codable {
    var id: String { roleKey + "·" + title }
    let roleKey: String   // FleetRole.rawValue(回退时若没匹配上,可能为空,用 title 兜底显示)
    let title: String     // 中文职位名(展示用)
    let task: String      // 具体到能直接动手的任务
    let stage: Int        // 执行深度(0 起;由依赖关系拓扑计算,决定并发批次,同深度并行)
    var dependsOn: [String] = []   // 依赖的角色 key(谁的产出是我的输入);展示"谁先谁后"也用它

    /// 还原成枚举(保存的模板里 roleKey 还能映射回角色)。
    var role: FleetRole? { FleetRole(rawValue: roleKey) }

    init(roleKey: String, title: String, task: String, stage: Int, dependsOn: [String] = []) {
        self.roleKey = roleKey; self.title = title; self.task = task
        self.stage = stage; self.dependsOn = dependsOn
    }
    // 自定义解码:老博物馆存档没有 dependsOn 字段 → 缺省为空(向后兼容)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roleKey = try c.decode(String.self, forKey: .roleKey)
        title = try c.decode(String.self, forKey: .title)
        task = try c.decode(String.self, forKey: .task)
        stage = try c.decodeIfPresent(Int.self, forKey: .stage) ?? 0
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
    }
}

/// 队长开工前产出的**结构化作战计划**:整体打法 + 选哪家公司 + 派谁干啥、谁先谁后。
/// 这是把"队长脑子里的脚本"显式落成一个可查看 / 可改 / 可存成模板复用的对象。
struct CaptainPlan: Hashable, Codable {
    let strategy: String        // 一句话整体打法(分几步、谁先谁后、最后谁把关)
    let companyId: String
    let companyName: String
    let members: [PlannedMember]

    /// 按阶段分组(UI 画"第 1 批并行 → 第 2 批"用)。
    var stages: [(stage: Int, members: [PlannedMember])] {
        let keys = Set(members.map { $0.stage }).sorted()
        return keys.map { k in (k, members.filter { $0.stage == k }) }
    }
}

@MainActor
@Observable
final class FleetRun {
    var topic: String = ""
    var phase: FleetPhase = .idle
    var leadBackend: AgentMode          // 队长(反问/拆活/汇总)用的后端
    var company: CompanyType? = nil     // 选中的公司类型
    var plan: CaptainPlan? = nil        // 队长的显式作战计划(⑤;可查看/未来可存成模板)
    var clarifyQuestions: [ClarifyQuestion] = []   // 当前这一轮的问题(空 = 队长正在想 / 已结束反问)
    var clarifyHistory: [ClarifyAnswered] = []     // 多轮逼近:已答完的全部题
    var clarifyRound: Int = 0                       // 当前是第几轮(从 1 起)
    var agents: [FleetAgent] = []
    var synthesisText: String = ""
    var product: String = ""
    var errorLine: String = ""
    var startedAt: Date? = nil          // 并行开跑时间(进度条计时用)
    var totalTokens: Int = 0            // 本次运行累计 token 消耗(各路 onUsage 汇总,UI 顶部显示)
    var workspaceURL: URL? = nil        // 本次运行的共享工作区文件夹(各 agent 在同一处协作)
    var productFileURL: URL? = nil      // 最终成品落盘的 .md 文件(完成时写入工作区)

    // 交付前质检闭环
    var reviewVerdicts: [ReviewVerdict] = []   // 历次质检结论(累积,UI 回顾)
    var reviewRound: Int = 0
    var reviewingText: String = ""             // 质检 gate 流式吐字
    var rolesUnderFix: Set<FleetRole> = []     // 当前正在返工的角色(卡片打角标)
    var latestVerdict: ReviewVerdict? { reviewVerdicts.last }

    // 产物打磨(done 之后的对话式迭代)
    var versions: [FleetProductVersion] = []   // 产物版本历史(含初版);product 永远=最新版
    var refineRound: Int = 0
    var isRefining: Bool = false               // 正在重派打磨(footer 输入框禁用+转圈)
    var lastRefineFeedback: String = ""

    /// 当前正在推进的阶段 = 最小的"还没全部完成"的阶段(给卡片判断"我是否还在排队等前一批")。
    var currentStage: Int {
        let unfinished = agents.filter { $0.status != "succeeded" && $0.status != "failed" }
        return unfinished.map { $0.stage }.min() ?? 0
    }

    /// 存档 id:首次存进博物馆时生成,打磨后再存走同一条覆盖更新(避免一次任务在馆里出现多条)。
    @ObservationIgnored var archiveID: String? = nil
    /// 在跑的所有叶子子任务(fan-out 出来的)。中止时逐个 cancel → 触发各 client 的 onTermination
    /// (HTTP 断连 / 子进程 SIGTERM / opencode POST abort)→ 真停下后台流、不再烧 token。
    @ObservationIgnored var inflightTasks: [Task<Void, Never>] = []
    /// 本次运行的 HTTP 空闲池(在线AI/OpenClaw/Hermes/qwen 中已配好的)——动态派发从这里"谁空挑谁"。
    @ObservationIgnored var httpPool: [AgentMode] = []
    /// 防串:每次新跑 / 中止换 token,引擎写状态前 `alive()` 比对。
    @ObservationIgnored var sessionToken = UUID()
    /// 按后端分别限流的并发闸组(在线AI=2/Hermes=4/OpenClaw=4/Claude=1/Codex=1)——
    /// 取代旧的单一全局闸,单点不被压垮、网关放开跑。
    @ObservationIgnored let backendGates = FleetDispatcher()
    /// 反问续命:resume 的 Bool = 用户是否要"直接开工"(true=别再问了,false=提交本轮、让队长继续逼近)。
    @ObservationIgnored private var clarifyCont: CheckedContinuation<Bool, Never>?

    init(leadBackend: AgentMode) {
        self.leadBackend = leadBackend
    }

    var isActive: Bool {
        switch phase {
        case .clarifying, .decomposing, .dispatched, .synthesizing, .reviewing, .fixing, .refining: return true
        default: return false
        }
    }
    /// 真正在跑模型(不含等用户确认的 clarifying)。
    var isCrunching: Bool {
        switch phase {
        case .decomposing, .dispatched, .synthesizing, .reviewing, .fixing, .refining: return true
        default: return false
        }
    }

    var doneAgentCount: Int { agents.filter { $0.status == "succeeded" || $0.status == "failed" }.count }

    /// 反问:挂起等用户答完本轮 ——
    /// 返回 true=用户点了"直接开工"(结束追问);false=提交本轮、让队长继续往下逼近。
    func awaitClarification() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.clarifyCont = cont
        }
    }
    /// startNow=true → 别再问了直接开工;false → 提交本轮答案、继续下一轮逼近。
    func resolveClarification(startNow: Bool) {
        let c = clarifyCont; clarifyCont = nil
        c?.resume(returning: startNow)
    }

    func abort() {
        sessionToken = UUID()
        phase = .aborted
        isRefining = false
        // 真停:cancel 所有在跑的子任务 → 各 client onTermination 收尾(断连/杀子进程/通知 server)
        for t in inflightTasks { t.cancel() }
        inflightTasks = []
        let c = clarifyCont; clarifyCont = nil
        c?.resume(returning: true)   // 解挂;token 已变,引擎会自行 bail
    }
}
