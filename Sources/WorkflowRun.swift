import Foundation
import AppKit

/// 工作流 harness 的「运行轨迹」—— 路线图里程碑 5。
/// 每一次工作流运行都留痕（Run + 每步 Step），落盘 `~/.hermespet/runs/index.json`，
/// 支持中断后恢复，并为将来成本统计预留字段。持久化范式克隆自 `ArtifactStore`（原子写 + iso8601）。

// MARK: - 轨迹模型

/// 一个阶段(step)的执行记录。
struct WorkflowStepRecord: Codable, Identifiable, Hashable {
    var stepID: String
    var title: String
    var kind: String                 // transform / product / eval
    var status: String = "pending"   // pending / running / succeeded / failed / skipped
    var output: String = ""
    var evalVerdict: String? = nil   // eval 阶段：通过/不通过 + 原因
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var retryCount: Int = 0
    var tokens: Int? = nil           // 预留：成本统计

    var id: String { stepID }
}

/// 一次工作流运行的完整轨迹。
struct WorkflowRun: Codable, Identifiable {
    let id: String
    var workflowID: String
    var workflowName: String
    var modeRaw: String              // 运行时 AgentMode.rawValue
    var input: String
    var status: String = "running"   // running / awaitingConfirm / succeeded / failed / aborted
    var steps: [WorkflowStepRecord] = []
    var productKind: String? = nil   // chat / artifact / note
    var productTitle: String? = nil
    var productRef: String? = nil    // 落地引用：artifactID / conversationID / 笔记路径
    var createdAt: Date
    var updatedAt: Date
    var costTokens: Int? = nil       // 预留：整轮成本

    var isTerminal: Bool { status == "succeeded" || status == "failed" || status == "aborted" }
}

/// 工作流最终产物（落地用）。
struct WorkflowProduct {
    let kind: String        // chat / artifact / note
    let markdown: String
    let title: String
}

/// 人工确认节点的决定。
enum ConfirmDecision { case allow, skip, abort }

// MARK: - 执行态模型（面板绑定，@Observable）

/// `RunPanelView` 绑定的执行态。runner 把进度写进来，面板看着动；面板按钮回写确认/中止。
@MainActor
@Observable
final class RunModel {
    var run: WorkflowRun
    @ObservationIgnored let workflow: Workflow   // 取 icon/accent/阶段标题用，不变

    /// 防串：每次新运行/中止换一个 token，runner 写任何状态前先比对，杜绝旧运行覆盖新运行
    /// （照 MeetingOverlayController.sessionToken 的教训）。
    @ObservationIgnored var sessionToken = UUID()

    // 执行中 UI 态（每个都对应面板里的渲染，守决策 #11）
    var currentStepIndex: Int = 0
    var partialText: String = ""        // 当前流式阶段的增量文本
    var statusLine: String = ""         // "撰写洞察…"
    var evalReason: String = ""
    var evalSuggestion: String = ""
    var productMarkdown: String = ""     // 完成后的最终产物（footer 操作用）
    var awaitingConfirm: Bool = false
    var pendingConfirmTitle: String = ""
    var lastError: String = ""           // 最近一次阶段调用的报错/空因（诊断用，竞技场会展示）

    @ObservationIgnored private var confirmCont: CheckedContinuation<ConfirmDecision, Never>?

    init(run: WorkflowRun, workflow: Workflow) {
        self.run = run
        self.workflow = workflow
    }

    /// 人工节点：挂起等用户点 允许/跳过/中止。
    func awaitConfirm(title: String) async -> ConfirmDecision {
        pendingConfirmTitle = title
        awaitingConfirm = true
        return await withCheckedContinuation { cont in self.confirmCont = cont }
    }
    func resolveConfirm(_ d: ConfirmDecision) {
        awaitingConfirm = false
        let c = confirmCont; confirmCont = nil
        c?.resume(returning: d)
    }

    /// 用户中止：换 token 让在跑的阶段失效，放行可能在等的确认，并复位灵动岛。
    func abort() {
        sessionToken = UUID()
        run.status = "aborted"
        run.updatedAt = Date()
        WorkflowRunStore.shared.update(run)
        resolveConfirm(.abort)
        NotificationCenter.default.post(name: .init("HermesPetTaskFinished"),
                                        object: nil, userInfo: ["success": false])
    }
}

// MARK: - 轨迹持久化（克隆 ArtifactStore）

@MainActor
@Observable
final class WorkflowRunStore {
    static let shared = WorkflowRunStore()

    /// 新的在前。
    private(set) var runs: [WorkflowRun] = []

    nonisolated static var runsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var indexURL: URL { Self.runsDir.appendingPathComponent("index.json") }

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            runs = (try? dec.decode([WorkflowRun].self, from: data)) ?? []
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(runs) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func add(_ run: WorkflowRun) {
        runs.removeAll { $0.id == run.id }
        runs.insert(run, at: 0)
        if runs.count > 50 { runs = Array(runs.prefix(50)) }   // 只留最近 50 条
        persist()
    }

    func update(_ run: WorkflowRun) {
        if let i = runs.firstIndex(where: { $0.id == run.id }) { runs[i] = run }
        else { runs.insert(run, at: 0) }
        persist()
    }

    func record(id: String) -> WorkflowRun? { runs.first { $0.id == id } }

    /// 启动时仍处于 running / 等确认的运行 —— 说明上次被退出打断，可恢复。
    func resumableRuns() -> [WorkflowRun] {
        runs.filter { $0.status == "running" || $0.status == "awaitingConfirm" }
    }

    func delete(id: String) { runs.removeAll { $0.id == id }; persist() }
}
