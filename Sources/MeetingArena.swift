import Foundation
import AppKit

/// 🏟 工作流竞技场 —— 会议纪要垂类（第一个垂类）。
///
/// 设想（与用户 2026-06-02 定）：模型趋同后，差异化在 **workflow + harness 编排层**。
/// 让同 `vertical` 的多个**可复用 workflow**在同一份会议转写上**同题比拼**，裁判按统一 rubric
/// 客观打分排名 → 证明"接了多阶段 harness 的工作流 >> 一句话裸 prompt"，并为未来"买最优 / C 端比拼"
/// 攒可信的评分数据（脊椎 = Eval）。比拼单位 = `Workflow` 本身。

// MARK: - 成绩模型

/// 一份纪要的 5 维评分（每维 0-10）+ 加权总分。
struct ArenaScore: Codable, Hashable {
    var completeness: Int   // 完整性
    var structure: Int      // 结构
    var faithfulness: Int   // 忠实
    var concreteness: Int   // 具体性
    var conciseness: Int    // 简洁度
    var total: Double       // 加权总分 0-10
    var reason: String
}

/// 一个参赛者（= 一个 workflow）的成绩。
struct ArenaContestant: Codable, Identifiable {
    var workflowID: String
    var workflowName: String
    var output: String          // 产出的纪要 markdown
    var score: ArenaScore?
    var rank: Int               // 1 = 冠军
    var id: String { workflowID }
}

/// 一场比拼的完整结果。
struct ArenaMatch: Codable, Identifiable {
    let id: String
    var vertical: String
    var inputLabel: String      // "样例" / "粘贴的转写" / "最近录音"
    var inputPreview: String    // 转写前 200 字（展示）
    var contestants: [ArenaContestant]
    var createdAt: Date
    var note: String = ""       // 异常提示（如全部未产出时的后端/错误说明）
}

// MARK: - 竞技场引擎

@MainActor
enum MeetingArena {
    static let vertical = "meeting"

    /// rubric 5 维 + 权重（用户定：含简洁度）。总分 = Σ 维度分 × 权重，0-10。
    static let dimensions: [(key: String, name: String, weight: Double)] = [
        ("completeness", "完整性", 0.30),
        ("structure",    "结构",   0.20),
        ("faithfulness", "忠实",   0.20),
        ("concreteness", "具体性", 0.15),
        ("conciseness",  "简洁度", 0.15),
    ]

    static func contestants() -> [Workflow] {
        WorkflowRegistry.shared.workflows.filter { $0.vertical == vertical }
    }

    /// 竞技场要"稳定可比" → 默认优先 HTTP 后端（在线 AI / OpenClaw / Hermes），
    /// 不走子进程（codex / claudeCode 批量连续调用偶发返回空，不适合当评测后端）。
    static func defaultBackend(current: AgentMode) -> AgentMode {
        if [.directAPI, .qwenCode, .openclaw, .hermes].contains(current) { return current }
        for m in [AgentMode.directAPI, .qwenCode, .openclaw, .hermes] where EnabledModesStore.shared.isEnabled(m) { return m }
        return .directAPI
    }

    /// 可选后端（已启用的全部，含 codex/claudeCode，用户想比就比，但默认避开）。
    static func availableBackends() -> [AgentMode] {
        AgentMode.allCases.filter { EnabledModesStore.shared.isEnabled($0) }
    }

    /// 跑一场比拼：每个参赛 workflow 在同一转写、同一后端上出纪要 → 裁判打分排名 → 落盘。
    static func run(transcript: String, inputLabel: String, backend: AgentMode, vm: ChatViewModel,
                    onProgress: @escaping (String) -> Void) async -> ArenaMatch? {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 10 else { return nil }
        let wfs = contestants()
        guard !wfs.isEmpty else { return nil }
        NSLog("[Arena] 开赛 backend=\(backend.rawValue) 参赛=\(wfs.count) 转写=\(clean.count)字 connection=\(vm.connectionStatus)")

        var dbg = "===== Arena \(inputLabel) backend=\(backend.rawValue) connection=\(vm.connectionStatus) 转写=\(clean.count)字 =====\n"
        var contestants: [ArenaContestant] = []
        var firstError = ""
        for (i, wf) in wfs.enumerated() {
            onProgress("第 \(i + 1)/\(wfs.count) 位：「\(wf.name)」生成纪要中…")
            let run = WorkflowRun(
                id: UUID().uuidString, workflowID: wf.id, workflowName: wf.name,
                modeRaw: backend.rawValue, input: inputLabel, status: "running",
                steps: wf.effectiveStages.map { WorkflowStepRecord(stepID: $0.id, title: $0.title, kind: $0.kind, status: "pending") },
                createdAt: Date(), updatedAt: Date())
            let model = RunModel(run: run, workflow: wf)
            let product = await WorkflowRunner.run(workflow: wf, input: clean, backend: backend, vm: vm, model: model)
            let len = product?.markdown.count ?? -1
            if len <= 0 && firstError.isEmpty { firstError = model.lastError }
            let line = "[\(wf.id)] 产物=\(len)字 err=\(model.lastError.isEmpty ? "无" : model.lastError)"
            NSLog("[Arena] \(line)")
            dbg += line + "\n"
            contestants.append(ArenaContestant(workflowID: wf.id, workflowName: wf.name,
                                               output: String((product?.markdown ?? "").prefix(12000)),
                                               score: nil, rank: 0))
        }

        // 诊断写文件（unified log 读不到 NSLog，落盘最可靠）
        let dbgURL = ArenaStore.dir.appendingPathComponent("arena-debug.log")
        try? dbg.write(to: dbgURL, atomically: true, encoding: .utf8)

        onProgress("裁判按 rubric 打分中…")
        let scored = await judge(transcript: clean, contestants: contestants, backend: backend, vm: vm)

        // 全部未产出 → 给用户清晰提示（多半是当前后端不可用/不适合）
        var note = ""
        if scored.allSatisfy({ ($0.output.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty }) {
            note = "所有参赛者都没产出内容。当前后端：\(backend.rawValue)。\(firstError.isEmpty ? "" : "原因：\(firstError)。")建议换到「在线 AI」模式再试（Codex/Claude Code 是子进程，可能未就绪或不适合纯文本任务）。"
        }

        let match = ArenaMatch(id: UUID().uuidString, vertical: vertical, inputLabel: inputLabel,
                               inputPreview: String(clean.prefix(200)), contestants: scored,
                               createdAt: Date(), note: note)
        ArenaStore.shared.add(match)
        return match
    }

    // MARK: - 裁判（listwise 模型评分 + 确定性兜底/纠偏，保证可信可复现）

    private static func judge(transcript: String, contestants: [ArenaContestant],
                              backend: AgentMode, vm: ChatViewModel) async -> [ArenaContestant] {
        let capped = String(transcript.prefix(40000))
        var blocks = ""
        for (i, c) in contestants.enumerated() {
            blocks += "\n\n#\(i + 1)【\(c.workflowName)】\n\(c.output.isEmpty ? "(空)" : c.output)"
        }
        let prompt = """
        你是严格的会议纪要评审。下面是【会议转写原文】和 \(contestants.count) 份候选纪要。请对每份按 5 个维度打分（0-10 整数）：
        完整性（关键结论/决定/待办/数字是否抓全）、结构（主题/要点/决议/待办 板块是否清晰）、忠实（有没有转写里没有的编造）、具体性（有没有「进行了讨论」这类空话，越少越高）、简洁度（无冗余、好读）。
        **每份严格只输出一行**，格式（不要任何别的内容）：
        #序号 完整性=x 结构=x 忠实=x 具体性=x 简洁度=x | 理由：一句话

        【会议转写原文】
        \(capped)

        【候选纪要】\(blocks)
        """
        var raw = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: "arena-judge-\(UUID().uuidString.prefix(6))") {
                raw += chunk
            }
        } catch { /* 模型评分拿不到 → 全走确定性兜底 */ }

        var out = contestants
        for i in out.indices {
            let parsed = parseScoreLine(raw, index: i + 1)
            var s = parsed ?? ArenaScore(completeness: 5, structure: 5, faithfulness: 5,
                                         concreteness: 5, conciseness: 5, total: 0,
                                         reason: "（模型评分缺失，按确定性规则）")
            applyDeterministic(&s, output: out[i].output)
            s.total = weightedTotal(s)
            out[i].score = s
        }
        // 排名：总分降序
        let ordered = out.sorted { ($0.score?.total ?? 0) > ($1.score?.total ?? 0) }
        for (rank, item) in ordered.enumerated() {
            if let idx = out.firstIndex(where: { $0.workflowID == item.workflowID }) {
                out[idx].rank = rank + 1
            }
        }
        return out
    }

    private static func weightedTotal(_ s: ArenaScore) -> Double {
        let map: [String: Int] = ["completeness": s.completeness, "structure": s.structure,
                                  "faithfulness": s.faithfulness, "concreteness": s.concreteness,
                                  "conciseness": s.conciseness]
        var t = 0.0
        for d in dimensions { t += Double(map[d.key] ?? 0) * d.weight }
        return (t * 10).rounded() / 10
    }

    /// 确定性纠偏（防模型抽风、保证可复现）：空产物全 0；缺板块压低结构；空话多压低具体性/简洁度。
    private static func applyDeterministic(_ s: inout ArenaScore, output: String) {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            s = ArenaScore(completeness: 0, structure: 0, faithfulness: 0, concreteness: 0,
                           conciseness: 0, total: 0, reason: "未产出内容")
            return
        }
        let sections = ["主题", "议题", "要点", "决议", "决定", "待办", "行动"]
        let hit = sections.filter { t.contains($0) }.count
        if hit < 2 { s.structure = min(s.structure, 4) }
        let fluff = ["进行了讨论", "进行了交流", "相关问题", "等问题", "展开讨论", "进行了沟通"]
        let fluffCount = fluff.reduce(0) { $0 + t.components(separatedBy: $1).count - 1 }
        if fluffCount >= 2 {
            s.concreteness = min(s.concreteness, 5)
            s.conciseness = min(s.conciseness, 6)
        }
    }

    /// 解析裁判某一行：`#1 完整性=8 结构=7 忠实=9 具体性=6 简洁度=7 | 理由：…`
    private static func parseScoreLine(_ text: String, index: Int) -> ArenaScore? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("#\(index)") else { continue }
            func val(_ key: String) -> Int? {
                guard let r = l.range(of: key + "=") else { return nil }
                let digits = l[r.upperBound...].prefix { $0.isNumber }
                return Int(digits)
            }
            let c = val("完整性"); let st = val("结构"); let f = val("忠实")
            let co = val("具体性"); let cn = val("简洁度")
            guard c != nil || st != nil else { return nil }
            func clamp(_ v: Int?) -> Int { min(max(v ?? 5, 0), 10) }
            let reason: String = {
                for sep in ["理由：", "理由:"] {
                    if let r = l.range(of: sep) { return String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
                }
                return ""
            }()
            return ArenaScore(completeness: clamp(c), structure: clamp(st), faithfulness: clamp(f),
                              concreteness: clamp(co), conciseness: clamp(cn), total: 0, reason: reason)
        }
        return nil
    }

    /// 内置样例转写 —— 让竞技场开箱即用、不依赖录音。一段有决定/数字/负责人/遗留问题的产品会。
    static let sampleTranscript = """
    主持人：今天对齐一下 HermesPet 下个版本的重点。先说数据，上周日活大概 1200，比上上周涨了差不多 15%，主要是工作流那块带起来的。
    小王：对，工作流上线后留存有改善，七日留存从 22% 提到 28%。但我看后台，真正跑过工作流的用户只有 18%，大部分人还是当普通聊天用。
    主持人：那这版重点就放在让更多人用上工作流。小王你负责，下周三之前出一个"新手第一次打开就推荐一个工作流"的方案。
    小李：我担心的是工作流跑出来的东西质量参差，有的还不如直接问。要不要做个评分？
    主持人：好主意，这个叫它工作流竞技场，李工你来设计，先做会议纪要这一个垂类验证，月底前出 demo。
    小李：行，那我需要后端给我一个能拿到转写的接口。
    小张：接口我这边提供，但提醒一下，长录音转写现在超过 1 分钟会断，得先把分段接力修了，不然纪要源头就是残缺的。这个我本周修。
    主持人：那转写这个是阻塞项，小张优先。还有个遗留问题——海外版要不要也上工作流，先不定，等这版数据出来再说。
    小王：预算这块，这版投流我建议先不加，把钱留给做内容的同学。
    主持人：同意，投流维持现状。今天就这些，散会。
    """
}

// MARK: - 比拼结果持久化（克隆 ArtifactStore；攒榜单 = 飞轮种子）

@MainActor
@Observable
final class ArenaStore {
    static let shared = ArenaStore()
    private(set) var matches: [ArenaMatch] = []

    nonisolated static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/arena", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var indexURL: URL { Self.dir.appendingPathComponent("index.json") }

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            matches = (try? dec.decode([ArenaMatch].self, from: data)) ?? []
        }
    }
    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(matches) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func add(_ m: ArenaMatch) {
        matches.insert(m, at: 0)
        if matches.count > 30 { matches = Array(matches.prefix(30)) }
        persist()
    }
    func delete(id: String) { matches.removeAll { $0.id == id }; persist() }

    /// 榜单：按 workflow 聚合 平均总分 / 胜场 / 参赛场次（飞轮的最初形态）。
    struct LeaderRow: Identifiable { let workflowID: String; let name: String; let avg: Double; let wins: Int; let runs: Int; var id: String { workflowID } }
    func leaderboard() -> [LeaderRow] {
        var byID: [String: (name: String, sum: Double, wins: Int, runs: Int)] = [:]
        for m in matches {
            for c in m.contestants {
                guard let total = c.score?.total else { continue }
                var e = byID[c.workflowID] ?? (c.workflowName, 0, 0, 0)
                e.name = c.workflowName
                e.sum += total
                e.runs += 1
                if c.rank == 1 { e.wins += 1 }
                byID[c.workflowID] = e
            }
        }
        return byID.map { LeaderRow(workflowID: $0.key, name: $0.value.name,
                                    avg: $0.value.runs > 0 ? ($0.value.sum / Double($0.value.runs) * 10).rounded() / 10 : 0,
                                    wins: $0.value.wins, runs: $0.value.runs) }
            .sorted { $0.avg > $1.avg }
    }
}
