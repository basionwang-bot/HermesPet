import Foundation
import AppKit

/// ⭐ 统一并发派发器(@MainActor)—— 取代旧的"每后端一个 actor 闸"。
/// 核心修复"2 个 Hermes 同时干活"的竞态:**pick + reserve 是同步 MainActor 方法、原子不可分**
/// (无 await → 并发调用被 MainActor 串行化,第一个占完 Hermes 计数即变 1,第二个就改挑别的)。
/// 指标也从旧的"挑空闲位最多"(永远偏向大容量 Hermes)改成 **"挑 inflight 最少"** → 活真正铺开到不同后端。
@MainActor
final class FleetDispatcher {
    /// 各后端并发容量(同时最多几路)。directAPI=2(单 opencode 瓶颈)/hermes=6(有 keepalive 扛得住)/
    /// openclaw=2(daemon 真实吞吐只~2-3、无心跳,多塞撞 90s 看门狗)/qwenCode=5(node 子进程)/
    /// claudeCode=4(数据采集主力,并行抓;每个独立 --no-session-persistence,最坏 429 限流非封号)/codex=1。
    static func capacity(for m: AgentMode) -> Int {
        switch m {
        case .directAPI:          return 2
        case .hermes:             return 6
        case .openclaw:           return 2
        case .qwenCode:           return 5
        case .claudeCode:         return 4
        case .codex:              return 1
        }
    }
    /// 并列时的偏好顺序(fast-first):同样 inflight 最少时优先派给更快/更稳的。
    private static let preference: [AgentMode] = [.hermes, .directAPI, .openclaw, .qwenCode, .claudeCode, .codex]

    private var inflight: [AgentMode: Int] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    private func count(_ m: AgentMode) -> Int { inflight[m] ?? 0 }
    private func hasSlot(_ m: AgentMode) -> Bool { count(m) < Self.capacity(for: m) }

    /// 同步原子:从 pool 里挑 **inflight 最少且有空位** 的(并列 fast-first),占额(inflight++)并返回;全满返回 nil。
    /// ⭐ 无 await → 并发调用不会都挑到同一个(MainActor 串行 + 即时占额),根治"2 个 Hermes"。
    private func reserveLeastLoaded(_ pool: [AgentMode]) -> AgentMode? {
        let avail = pool.filter { hasSlot($0) }
        guard !avail.isEmpty else { return nil }
        let best = avail.min { a, b in
            let ca = count(a), cb = count(b)
            if ca != cb { return ca < cb }
            return (Self.preference.firstIndex(of: a) ?? 99) < (Self.preference.firstIndex(of: b) ?? 99)
        }!
        inflight[best, default: 0] += 1
        return best
    }

    /// 固定后端:有空位即占;满则挂起等 release 唤醒重试。被取消抛 CancellationError(没占额)。
    func acquire(_ m: AgentMode) async throws {
        while true {
            if hasSlot(m) { inflight[m, default: 0] += 1; return }
            try await waitForRelease()
        }
    }
    /// 动态派发:从 pool 原子挑 inflight 最少的占额;全满则挂起等 release 重试。被取消抛错。
    func acquireDynamic(_ pool: [AgentMode]) async throws -> AgentMode {
        while true {
            if let m = reserveLeastLoaded(pool) { return m }
            try await waitForRelease()
        }
    }
    /// 还额 + 唤醒所有等待者重试(MainActor 串行、重试 cheap,惊群无害)。
    func release(_ m: AgentMode) {
        inflight[m] = max(0, count(m) - 1)
        let w = waiters; waiters.removeAll()
        for (_, cont) in w { cont.resume(returning: ()) }
    }

    private func waitForRelease() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                waiters[id] = cont
            }
        } onCancel: {
            Task { @MainActor in
                if let c = self.waiters.removeValue(forKey: id) { c.resume(throwing: CancellationError()) }
            }
        }
    }
}

/// 舰队工作流并行编排器(第 1 期)—— AI 公司版。
///
/// 五段式:
///  0. **反问**(clarify):队长先问 2~3 个带选项的澄清问题 → 等用户确认,把目标逼清楚。
///  1. **选公司 + 派活**(plan):队长挑最匹配的公司类型,给该公司每位员工分配具体任务。
///  2. **配置降级**(selectBackend):每个角色优先用建议后端,没配置好就回退到已配置的 HTTP 后端。
///  3. **并行 fan-out**:HTTP 后端不限并发、子进程后端限并发(每批 2,纯异步、不阻塞主线程)。
///  4. **汇总**(synthesize):队长把各部门产出整合成一篇最终成果。
///
/// 守决策 #5:`@MainActor enum`,状态全主线程写;真并发发生在各 client 内部(HTTP/子进程),靠 await 挂起交错。
@MainActor
enum FleetEngine {

    /// 整体"空闲"超时:不看从开工算的总时长,而看**连续多久毫无进展**(没有任何 agent 吐字/完成)。
    /// 只要还在推进就永不超时——复杂任务排多久队都行;只有真卡死(连续 idle)才收尾。
    static let progressCheckInterval: UInt64 = 30   // 每 30s 查一次进展
    static let maxIdleChecks = 10                   // 连续 10 次(=5 分钟)毫无进展 → 判卡死

    /// 把"当前总进展"压成一个数;只要有任何一路在吐字/完成,这个数就会变 → watchdog 据此判断是否真卡死。
    private static func progressSnapshot(_ run: FleetRun) -> Int {
        var h = run.doneAgentCount &* 1_000_003
        for a in run.agents {
            h = h &+ a.partialText.count &+ a.output.count
            for s in a.subAgents { h = h &+ s.partialText.count &+ s.output.count }
        }
        h = h &+ run.synthesisText.count &+ run.reviewingText.count &+ (run.reviewVerdicts.count &* 7)
        return h
    }

    /// 过并发派发器跑一段活(固定后端):拿到额才执行 body、结束必还额;被取消(没拿到额)则直接退出、**不还额**(守恒)。
    private static func withGate(_ dispatcher: FleetDispatcher, _ m: AgentMode, _ body: () async -> Void) async {
        do { try await dispatcher.acquire(m) } catch { return }   // 被中止:没占额,跳过 body 与 release
        await body()
        dispatcher.release(m)
    }

    static func run(topic: String, vm: ChatViewModel, run: FleetRun) async {
        let token = run.sessionToken
        func alive() -> Bool { run.sessionToken == token }
        let lead = run.leadBackend

        // 复位
        run.topic = topic
        run.company = nil
        run.plan = nil
        run.archiveID = nil
        run.inflightTasks = []
        run.clarifyQuestions = []
        run.agents = []
        run.synthesisText = ""
        run.product = ""
        run.errorLine = ""
        run.startedAt = nil

        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)

        // —— Phase 0:多轮反问逼近 ——
        // 反复追问、一步步把范围收窄到用户真正想要的;每轮基于已确认的答案再深挖。
        // 队长觉得够清楚了会自己收口(回"无");用户随时能点"直接开工"提前结束;maxRounds 兜底防失控。
        run.phase = .clarifying
        run.clarifyHistory = []
        run.clarifyRound = 0
        run.clarifyQuestions = []
        let maxRounds = 6
        while run.clarifyRound < maxRounds {
            // 生成本轮问题前先清空(UI 显示"队长在想要问啥…")
            run.clarifyQuestions = []
            let questions = await generateClarifyQuestions(
                topic: topic, history: run.clarifyHistory, round: run.clarifyRound, backend: lead, vm: vm)
            guard alive() else { return }
            if questions.isEmpty { break }              // 队长认为已经够清楚

            run.clarifyQuestions = questions
            run.clarifyRound += 1
            let startNow = await run.awaitClarification()   // 挂起等用户答完本轮
            guard alive() else { return }

            // 收集本轮回答进历史(供下一轮深挖 + UI 回顾)
            for q in questions {
                if let a = q.answer {
                    run.clarifyHistory.append(ClarifyAnswered(question: q.question, answer: a))
                }
            }
            run.clarifyQuestions = []
            if startNow { break }                       // 用户喊"够了,直接开工"
        }

        // —— Phase 1:选公司 + 派活 ——
        run.phase = .decomposing
        let enriched = enrichedTopic(topic: topic, history: run.clarifyHistory)
        let (company, assignments, plan) = await planTeam(enriched: enriched, backend: lead, vm: vm)
        guard alive() else { return }
        run.company = company
        run.plan = plan

        // —— Phase 2~5 + 收尾:与"按存档计划复用"共用同一段执行 ——
        await executeTeam(enriched: enriched, company: company, assignments: assignments,
                          lead: lead, vm: vm, run: run, token: token)
    }

    /// **按已存档的作战计划直接开跑**(⑥ 博物馆"复用这套流程"):跳过反问 + 重新规划,
    /// 用存档 plan 里的成员当 assignments,其余执行/质检/打磨完全复用 run() 那套。
    static func runFromPlan(topic: String, plan: CaptainPlan, vm: ChatViewModel, run: FleetRun) async {
        let token = run.sessionToken
        func alive() -> Bool { run.sessionToken == token }
        let lead = run.leadBackend

        // 复位(同 run(),但不走反问)
        run.topic = topic
        run.plan = plan
        run.archiveID = nil
        run.inflightTasks = []
        run.company = nil
        run.clarifyQuestions = []
        run.clarifyHistory = []
        run.clarifyRound = 0
        run.agents = []
        run.synthesisText = ""
        run.product = ""
        run.errorLine = ""
        run.startedAt = nil
        run.reviewVerdicts = []
        run.reviewRound = 0
        run.versions = []
        run.refineRound = 0

        let company = CompanyRegistry.all.first { $0.id == plan.companyId } ?? CompanyRegistry.fallback
        run.company = company
        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)

        // 计划成员 → assignments(roleKey 还能映射回角色的才要);把计划里存的依赖也带回来(角色 key → FleetRole)。
        let validRoles = Set(plan.members.compactMap { $0.role })
        let assignments: [Assignment] = plan.members.compactMap { m in
            guard let role = m.role else { return nil }
            let deps = m.dependsOn.compactMap { FleetRole(rawValue: $0) }.filter { validRoles.contains($0) && $0 != role }
            return Assignment(role: role, brief: m.task, dependsOn: deps)
        }
        guard !assignments.isEmpty else {
            run.phase = .failed
            run.errorLine = "这套计划里的角色已失效，换个任务重新派活吧。"
            return
        }
        guard alive() else { return }
        await executeTeam(enriched: topic, company: company, assignments: assignments,
                          lead: lead, vm: vm, run: run, token: token)
    }

    /// Phase 2~5 + 收尾。run() 与 runFromPlan() 共用,**零行为差异**,只是"怎么拿到 assignments"不同。
    private static func executeTeam(enriched: String, company: CompanyType, assignments: [Assignment],
                                    lead: AgentMode, vm: ChatViewModel, run: FleetRun, token: UUID) async {
        func alive() -> Bool { run.sessionToken == token }

        // 整体"空闲"超时兜底:循环查进展,连续 maxIdleChecks 次毫无变化才判卡死、停掉在跑的、用已完成部分收尾。
        // 只要还在推进就不触发 → 复杂任务排队跑多久都行(回应"总时长 10 分钟不够"的问题)。
        let watchdog = Task { @MainActor in
            var lastSnap = Int.min
            var idle = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: progressCheckInterval * 1_000_000_000)
                guard !Task.isCancelled, alive() else { return }
                let snap = progressSnapshot(run)
                if snap == lastSnap { idle += 1 } else { idle = 0; lastSnap = snap }
                if idle >= maxIdleChecks {
                    NSLog("[FleetEngine] 整体连续 \(Int(progressCheckInterval) * maxIdleChecks)s 无进展,判卡死、收尾")
                    for t in run.inflightTasks { t.cancel() }
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        // —— Phase 2:建共享工作区 + 配置降级 + 建员工(按流程阶段排序)——
        let workspace = makeWorkspace(run: run)
        run.workspaceURL = workspace

        var agents: [FleetAgent] = []
        // ⭐ 依赖关系 → 执行深度(拓扑;环自动断):取代旧的"按角色硬编码 stage 排序"。
        // 深度 = 最长依赖链;采集类(无依赖)=0 最先跑,成文/把关类深度更大、必等上游产出。
        var roleDeps: [FleetRole: [FleetRole]] = [:]
        for a in assignments { roleDeps[a.role] = a.dependsOn }
        let depthByRole = computeRoleDepth(roleDeps)
        let ordered = assignments.sorted {
            ((depthByRole[$0.role] ?? 0), $0.role.rawValue) < ((depthByRole[$1.role] ?? 0), $1.role.rawValue)
        }
        // ⭐ 能力路由(2026-06-08 用户拍板):
        //  · 数据采集(researcher,根)→ Claude Code(唯一真能联网抓数据的:有 WebFetch、能跑命令);没装则回退 HTTP 根(走 fan-out)
        //  · 写代码(engineer 等 localHeavy)→ 子进程 CLI(selectBackend,真要本机文件/命令能力)
        //  · 其余"动脑"非根角色 → HTTP 空闲池**动态派发**(开跑时 acquireFreeBackend 谁有空位谁接,不预先定死)
        let httpPool = await configuredHTTPBackends(vm: vm)
        run.httpPool = httpPool
        let claudeReady = await CLIAvailability.claudeAvailable() && EnabledModesStore.shared.enabledModes.contains(.claudeCode)
        for (i, a) in ordered.enumerated() {
            let backend: AgentMode
            var dynamic = false
            if a.role == .researcher {
                if claudeReady { backend = .claudeCode }                 // 真抓数据
                else if let h = httpPool.first { backend = h }           // 回退:HTTP 根,走 fan-out
                else { backend = await selectBackend(preferred: a.role.defaultBackend, vm: vm) }
            } else if a.role.defaultBackend.isLocalHeavy {
                backend = await selectBackend(preferred: a.role.defaultBackend, vm: vm)   // 工程师等 → CLI
            } else if !a.dependsOn.isEmpty, let h = httpPool.first {
                backend = h; dynamic = true                              // 非根动脑 → 动态空闲池
            } else if let h = httpPool.first {
                backend = h                                              // 根动脑(会 fan-out)→ 固定
            } else {
                backend = await selectBackend(preferred: a.role.defaultBackend, vm: vm)
            }
            guard alive() else { return }
            let ag = FleetAgent(id: "agent-\(i)", role: a.role, title: a.brief,
                                backend: backend, stage: depthByRole[a.role] ?? 0)
            ag.dynamicDispatch = dynamic
            agents.append(ag)
        }
        // 把"依赖的角色"映射成"依赖的 agent id"(过滤自环);供调度排序 + UI 显示"等待谁"。
        var idByRole: [FleetRole: String] = [:]
        for ag in agents { if let r = ag.role { idByRole[r] = ag.id } }
        for (i, a) in ordered.enumerated() {
            agents[i].dependsOn = a.dependsOn.compactMap { idByRole[$0] }.filter { $0 != agents[i].id }
        }
        run.agents = agents
        run.phase = .dispatched
        run.startedAt = Date()

        // ⭐ Part 3:质检员**不当普通 stage agent 跑**(否则它审一遍 + 末尾 gate 又审一遍 = 双重质检)。
        // 拎出来,等 Phase 4 汇总后用它这张卡驱动唯一的终检(见下方 Phase 5)。
        let reviewerAgent = agents.first { $0.role == .reviewer }
        let workAgents = agents.filter { $0.role != .reviewer }

        // —— Phase 3:按流程阶段推进(同阶段并行;后阶段等前阶段产出,并拿到它当依据)——
        let stageKeys = Set(workAgents.map { $0.stage }).sorted()
        for st in stageKeys {
            guard alive() else { return }
            let stageAgents = workAgents.filter { $0.stage == st }
            // priorContext 不再"把所有前序阶段一股脑塞" —— 改由 runAgent 按**本 agent 的直接依赖**构建
            // (depContextFor 从 run.agents 取依赖产出);这里传空即可。
            await runFanout(agents: stageAgents, company: company, enriched: enriched,
                            priorContext: "", workspace: workspace, vm: vm, run: run, token: token)
            guard alive() else { return }

            // 阶段边界复核(智能收口):**只在后面真有"非质检的下游角色"要拿这批产出接着干**时才做
            // (比如工程师 stage>0 要基于调研/设计来实现)。若后面只剩质检/汇总,这道纯属和最后总质检重复
            // → 跳过,免得无谓地把整批拽回来重跑。这也正是"左侧写完又被整批重跑"的根源之一。
            let hasDownstreamConsumer = stageKeys.contains { later in
                later > st && workAgents.contains { $0.stage == later }
            }
            if hasDownstreamConsumer {
                let drifts = await reviewStageBoundary(stageAgents: stageAgents, enriched: enriched,
                                                       company: company, backend: lead, vm: vm, run: run, token: token)
                guard alive() else { return }
                // 只把"真出问题的角色"映射成要返工的 agent,各自只拿"针对自己的意见"
                let fixItems: [(agent: FleetAgent, note: String)] = drifts.compactMap { d in
                    stageAgents.first { $0.role == d.role }.map { ($0, d.note) }
                }
                if !fixItems.isEmpty {
                    await refixStageAgents(fixItems, company: company, enriched: enriched,
                                           priorContext: "", workspace: workspace, vm: vm, run: run, token: token)
                    guard alive() else { return }
                }
            }
        }

        // —— Phase 4:汇总(只汇总干活的,不含质检员)——
        run.phase = .synthesizing
        var merged = await synthesize(enriched: enriched, company: company, agents: workAgents,
                                      backend: lead, vm: vm, run: run, token: token)
        guard alive() else { return }
        run.product = merged

        // —— Phase 5:唯一终检 + 定向重派闭环(自我纠错,max 2 轮兜底)——
        // ⭐ Part 3:有质检员角色就**用它这张卡**驱动终检(卡片显"审查中…→✓通过/返工"),
        //   质检只此一次,不再"质检员审一遍 + 隐藏 gate 又审一遍"。没质检员角色才跑匿名 gate。
        let reviewBackend = reviewerAgent?.backend ?? lead
        let maxReviewRounds = 2
        run.reviewVerdicts = []
        run.reviewRound = 0
        if !merged.isEmpty {
            while run.reviewRound < maxReviewRounds {
                guard alive() else { return }
                run.phase = .reviewing
                run.reviewingText = ""
                run.reviewRound += 1
                reviewerAgent?.status = "running"
                if reviewerAgent?.startedAt == nil { reviewerAgent?.startedAt = Date() }
                reviewerAgent?.partialText = "审查最终成品中…（第 \(run.reviewRound) 轮）"
                let verdict = await reviewFinalProduct(product: merged, enriched: enriched,
                                                       history: run.clarifyHistory, company: company,
                                                       round: run.reviewRound, backend: reviewBackend, vm: vm, run: run, token: token)
                guard alive() else { return }
                run.reviewVerdicts.append(verdict)
                if verdict.passed {
                    reviewerAgent?.status = "succeeded"
                    reviewerAgent?.output = "✓ 终检通过：\(verdict.summary)"
                    reviewerAgent?.partialText = "✓ 终检通过"
                    reviewerAgent?.endedAt = Date()
                    break
                }
                let targets = verdict.rolesToFix
                if targets.isEmpty {
                    reviewerAgent?.status = "succeeded"
                    reviewerAgent?.output = "终检完成：\(verdict.summary)"
                    reviewerAgent?.partialText = "终检完成"
                    reviewerAgent?.endedAt = Date()
                    break
                }
                reviewerAgent?.partialText = "终检发现问题,打回返工：\(targets.map { $0.title }.joined(separator: "、"))"

                run.phase = .fixing
                run.rolesUnderFix = Set(targets)
                await dispatchFixes(targetRoles: targets, verdict: verdict, agents: workAgents,
                                    company: company, enriched: enriched, workspace: workspace,
                                    vm: vm, run: run, token: token)
                guard alive() else { return }
                run.rolesUnderFix = []

                run.phase = .synthesizing
                merged = await synthesize(enriched: enriched, company: company, agents: workAgents,
                                          backend: lead, vm: vm, run: run, token: token)
                guard alive() else { return }
                run.product = merged
                if merged.isEmpty { break }
            }
            // 跑满 2 轮还没 pass:把质检员卡片收尾(别让它一直"审查中")
            if reviewerAgent?.status == "running" {
                reviewerAgent?.status = "succeeded"
                reviewerAgent?.output = "终检已尽力（达最大轮次）"
                reviewerAgent?.partialText = "✓ 终检完成"
                reviewerAgent?.endedAt = Date()
            }
        }

        run.phase = merged.isEmpty ? .failed : .done
        if !merged.isEmpty {
            ensureBaseVersionRecorded(run: run)         // 初版入历史(v0)
            writeProductMarkdown(run: run)              // 成品落成真实 .md 文档
            FleetArchiveStore.shared.archive(run: run)  // ⑥ 自动收进博物馆
        }
        NotificationCenter.default.post(name: .init("HermesPetTaskFinished"),
                                        object: nil, userInfo: ["success": !merged.isEmpty])
    }

    // MARK: - 产物打磨(done 之后的对话式迭代)

    /// done 之后的对话式打磨:带「当前产物 + 用户反馈」定向重派最相关的角色,再重新汇总成新版。
    /// 不反问、不重选公司;保留所有 agent 实例与历史版本。**不换 sessionToken**(同一会话)。
    static func refine(feedback: String, vm: ChatViewModel, run: FleetRun) async {
        let token = run.sessionToken
        func alive() -> Bool { run.sessionToken == token }
        guard run.phase == .done, !run.agents.isEmpty else { return }
        let fb = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fb.isEmpty else { return }

        run.isRefining = true
        run.lastRefineFeedback = fb
        run.phase = .refining
        run.errorLine = ""
        run.inflightTasks = []
        defer { if run.sessionToken == token { run.isRefining = false } }   // 所有出口复位
        ensureBaseVersionRecorded(run: run)
        NotificationCenter.default.post(name: .init("HermesPetTaskStarted"), object: nil)

        let company = run.company ?? CompanyRegistry.fallback

        // ① 队长选「这次改谁」
        let targetIDs = await pickRefineTargets(feedback: fb, run: run, backend: run.leadBackend, vm: vm)
        guard alive() else { return }
        let targets = run.agents.filter { targetIDs.contains($0.id) }
        let chosen = targets.isEmpty ? run.agents : targets   // 没指明 → 全员小迭代兜底

        // ② 定向重派(复用 runFanout;只重置被选中的,output 留到新结果覆盖)
        for ag in chosen { ag.status = "pending"; ag.partialText = ""; ag.startedAt = nil; ag.endedAt = nil }
        run.startedAt = Date()
        let enriched = enrichedTopic(topic: run.topic, history: run.clarifyHistory)
        let reason = """
        用户看了成果后提出:\(fb)
        请针对你负责的部分做出相应调整/补充,产出更新后的完整内容。

        【上一版的完整成果(供参考)】
        \(String(run.product.prefix(6000)))
        """
        await runFanout(agents: chosen, company: company, enriched: enriched,
                        priorContext: "\n\n【这是一次「继续打磨」,不要从头另起,按下面要求改】\n" + reason,
                        workspace: run.workspaceURL, vm: vm, run: run, token: token)
        guard alive() else { return }

        // ③ 重新汇总成新版
        run.phase = .synthesizing
        let merged = await synthesize(enriched: enriched, company: company, agents: run.agents,
                                      backend: run.leadBackend, vm: vm, run: run, token: token)
        guard alive() else { return }
        if merged.isEmpty {
            run.errorLine = "这次打磨没出结果，原成果已保留。"
            run.phase = .done
            return
        }
        // ④ 落新版 + 进历史
        run.product = merged
        run.refineRound += 1
        run.versions.append(FleetProductVersion(index: run.versions.count, product: merged, feedback: fb,
                                                 changedRoles: chosen.map { $0.role?.title ?? "成员" }, createdAt: Date()))
        run.phase = .done
        writeProductMarkdown(run: run)               // 打磨后的新版也刷新 .md 文档
        FleetArchiveStore.shared.archive(run: run)   // ⑥ 打磨后更新博物馆里的同一条存档
        NotificationCenter.default.post(name: .init("HermesPetTaskFinished"), object: nil, userInfo: ["success": true])
    }

    /// 队长读「反馈 + 团队名单」挑本次该重派的 agent id(1~多个;新增需求归到最相关角色;难判断回 all)。
    private static func pickRefineTargets(feedback: String, run: FleetRun, backend: AgentMode, vm: ChatViewModel) async -> Set<String> {
        let roster = run.agents.map { "· [\($0.id)] \($0.role?.title ?? "成员")：\($0.title)" }.joined(separator: "\n")
        let prompt = """
        你是这支团队的 CEO「Clawd」。用户对已交付的成果提了新的修改要求。请判断:这次修改**最该让哪些成员重做/补做**?
        只挑真正相关的(通常 1~2 个;大改可多选;实在难判断回 all)。

        【用户的修改要求】
        \(feedback)

        【团队现有成员名单】
        \(roster)

        【只回成员方括号 id,逗号分隔,例如 agent-0,agent-2;全员重做回 all。不要任何多余的话】
        """
        let raw = await callOnce(prompt: prompt, backend: backend, vm: vm, tag: "fleet-refine-pick")
        if raw.lowercased().contains("all") { return Set(run.agents.map { $0.id }) }
        let ids = raw.split(whereSeparator: { ",，、 \n".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
        let valid = Set(run.agents.map { $0.id })
        return Set(ids.filter { valid.contains($0) })
    }

    /// 第一次需要时把初版产物补登成 v0。
    private static func ensureBaseVersionRecorded(run: FleetRun) {
        guard run.versions.isEmpty, !run.product.isEmpty else { return }
        run.versions.append(FleetProductVersion(index: 0, product: run.product, feedback: nil,
                                                 changedRoles: [], createdAt: Date()))
    }

    // MARK: - Phase 0:反问

    private static func generateClarifyQuestions(topic: String, history: [ClarifyAnswered],
                                                 round: Int, backend: AgentMode, vm: ChatViewModel) async -> [ClarifyQuestion] {
        let firstRound = round == 0
        let historyText = history.isEmpty
            ? "（还没有）"
            : history.map { "· \($0.question) → \($0.answer)" }.joined(separator: "\n")
        let stopClause = firstRound
            ? "这是第一轮,**务必至少提出问题**,不要回\"无\"。"
            : "如果范围已经足够清晰、没有真正值得再追问的关键点了,就只回一行:无。否则继续追问(宁可多问,把范围一步步逼近用户心里真正想要的)。"
        let prompt = """
        你是一支 AI 公司的 CEO「Clawd」。动手前,你要通过**多轮提问**把用户的真实意图逼清楚——\
        宁可多问几轮,也别一上来就埋头做、结果做偏。每一轮都基于"已确认的答案"往更深、更具体处追问,**不要重复已问过的**。

        【用户的原始任务】
        \(topic)

        【已经和用户确认过的关键点(第 1~\(round) 轮)】
        \(historyText)

        现在是第 \(round + 1) 轮提问。请提出**这一轮最该追问的 2~3 个问题**(要比之前更具体、更深入,真正帮你把成品逼近用户想要的样子),每个问题给 2~4 个候选选项。
        \(stopClause)

        【单选 vs 多选】
        · 如果这个问题的答案**可以同时成立多个**(比如"要覆盖哪些平台""想要哪些功能模块""包含哪几类内容"),
          就在问题末尾标 `【多选】`,让用户能勾选多个。
        · 如果是**互斥的二选一/单选**(比如"偏正式还是活泼""深色还是浅色"),不要标,保持单选。

        【输出格式,严格按此,不要任何多余的话】
        问：<问题一>
        - <选项A>
        - <选项B>
        - <选项C>
        问：<问题二>【多选】
        - <选项A>
        - <选项B>
        """
        let raw = await callOnce(prompt: prompt, backend: backend, vm: vm, tag: "fleet-clarify-\(round)")
        return parseClarify(raw, firstRound: firstRound)
    }

    /// 第一轮兜底:就算队长没给出可解析的问题,也至少抛一个通用问题,保证"先问再做"。
    private static let firstRoundFallback = ClarifyQuestion(
        id: "q0",
        question: "这次的成果，你最看重哪一点？",
        options: ["又快又能直接用", "尽量完整、深入", "有新意 / 有亮点", "先给个方向我再补"])

    private static func parseClarify(_ raw: String, firstRound: Bool) -> [ClarifyQuestion] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "无" || trimmed.isEmpty {
            return firstRound ? [firstRoundFallback] : []
        }
        var result: [ClarifyQuestion] = []
        var curQ: String? = nil
        var curMulti = false
        var curOpts: [String] = []
        func flush() {
            if let q = curQ, !q.isEmpty {
                result.append(ClarifyQuestion(id: "q\(result.count)", question: q,
                                              options: Array(curOpts.prefix(4)), allowsMultiple: curMulti))
            }
            curQ = nil; curMulti = false; curOpts = []
        }
        // 识别并剥掉"多选"标记(容各种括号写法),返回(纯问题文本, 是否多选)。
        func stripMultiMarker(_ q: String) -> (String, Bool) {
            let markers = ["【多选】", "[多选]", "（多选）", "(多选)", "【可多选】", "【多选题】"]
            for m in markers where q.contains(m) {
                return (q.replacingOccurrences(of: m, with: "").trimmingCharacters(in: .whitespaces), true)
            }
            if q.contains("可多选") || q.contains("多选") {
                // 兜底:句中提到"多选"也按多选处理(剥不干净也无妨,UI 只看 allowsMultiple)
                return (q, true)
            }
            return (q, false)
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("问：") || s.hasPrefix("问:") {
                flush()
                let (q, multi) = stripMultiMarker(String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                curQ = q; curMulti = multi
            } else if s.hasPrefix("-") || s.hasPrefix("•") || s.hasPrefix("*") {
                let opt = String(s.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                if !opt.isEmpty { curOpts.append(opt) }
            }
        }
        flush()
        if result.isEmpty { return firstRound ? [firstRoundFallback] : [] }
        return Array(result.prefix(3))
    }

    /// 把多轮澄清的全部回答拼回任务,给后续阶段当更清晰的目标。
    private static func enrichedTopic(topic: String, history: [ClarifyAnswered]) -> String {
        guard !history.isEmpty else { return topic }
        let lines = history.map { "· \($0.question) → \($0.answer)" }.joined(separator: "\n")
        return topic + "\n\n【已和用户逐步确认的关键点】\n" + lines
    }

    // MARK: - Phase 1:选公司 + 派活

    private struct Assignment { let role: FleetRole; let brief: String; var dependsOn: [FleetRole] = [] }

    /// 队长结构化计划的 JSON DTO(解码用;字段全可空,模型少写一项也不崩)。
    private struct PlanDTO: Decodable {
        let company: String?
        let strategy: String?
        let members: [MemberDTO]?
        struct MemberDTO: Decodable { let role: String?; let task: String?; let dependsOn: [String]? }
    }

    private static func planTeam(enriched: String, backend: AgentMode, vm: ChatViewModel) async -> (CompanyType, [Assignment], CaptainPlan) {
        let catalog = CompanyRegistry.all.map { c in
            "· \(c.name)(\(c.id)):\(c.summary)。成员:" + c.roles.map { $0.title }.joined(separator: "、")
        }.joined(separator: "\n")

        let prompt = """
        你是一支 AI 公司的 CEO「Clawd」。下面有个任务,和几种可选的公司类型。请:
        ① 选出**最适合接这个任务的一家公司**;
        ② 从这家公司的花名册里,**按任务复杂度挑出真正需要的成员**,给每人一句具体到能直接动手的任务(别复述职能);
        ③ 用一句话讲清**整体打法**:分几步、谁先谁后、最后谁把关;
        ④ ⭐**给每位成员标明依赖关系 `dependsOn`**:它需要先拿到哪些同事的产出才能开工(写那些同事的中文职位名)。
           这决定执行顺序——**采集/调研类**通常没有依赖(最先跑);**分析/策划**依赖调研;**写作/成文/设计**依赖分析+策划;**实现/工程**依赖设计+策划;**质检**依赖最终产出。
           没有依赖就写空数组 []。**绝不要让"写报告/出成品"的人和"调研/分析"的人没有依赖关系**——否则他会在没有素材时凭空编造。

        【任务】
        \(enriched)

        【可选公司(只选一家;括号内是这家公司可调用的全部职位,你从中挑子集)】
        \(catalog)

        【挑人原则】
        · 任务只要不是特别简单,就**尽量多派几位一起并行**——用户喜欢看到一支大团队同时开工(派 4~6 人很正常)。
        · 至少派 3 人(含一名负责把关/质检的成员);只有极简单的活才派 2~3 人。
        · 每位都要真有用、有明确分工,别为凑数硬塞;但宁可 team 大一点、覆盖更全。
        · members 里的 role 和 dependsOn 都必须用上面这家公司花名册里出现过的中文职位名。

        【输出格式:只输出一段 JSON,前后不要任何解释、不要 markdown 代码围栏以外的话】
        {
          "company": "<公司名>",
          "strategy": "<一句话整体打法:分几步、谁先谁后、最后谁把关>",
          "members": [
            { "role": "<成员中文职位>", "task": "<具体任务>", "dependsOn": ["<它依赖的同事职位>", ...] }
          ]
        }
        """
        let raw = await callOnce(prompt: prompt, backend: backend, vm: vm, tag: "fleet-plan")

        // ① 优先:结构化 JSON 计划(这是「脚本本质」想要的形态)
        if let parsed = parseJSONPlan(raw: raw) { return parsed }
        // ② 回退:逐行文本解析(零回归——即便模型没吐合法 JSON 也能组出团队)
        return parseTextPlan(raw: raw)
    }

    /// 从模型输出里抠出第一个 `{` 到最后一个 `}` 的 JSON 子串(容忍前后有解释 / 代码围栏)。
    private static func extractJSONObject(_ raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return String(raw[start...end]).data(using: .utf8)
    }

    /// JSON 路线:解出公司 + 成员 + 整体打法。任一关键环节缺失 → 返回 nil 让上层回退文本解析。
    private static func parseJSONPlan(raw: String) -> (CompanyType, [Assignment], CaptainPlan)? {
        guard let data = extractJSONObject(raw),
              let dto = try? JSONDecoder().decode(PlanDTO.self, from: data),
              let memberDTOs = dto.members, !memberDTOs.isEmpty else { return nil }
        let company = dto.company.flatMap { CompanyRegistry.match($0) } ?? CompanyRegistry.fallback
        func matchRole(_ s: String) -> FleetRole? {
            let k = s.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return nil }
            return company.roles.first { k.contains($0.title) || $0.title.contains(k) }
        }
        var picked: [(role: FleetRole, brief: String)] = []
        var seen = Set<FleetRole>()
        var captainDeps: [FleetRole: [FleetRole]] = [:]   // 队长指定的依赖(角色级)
        for m in memberDTOs {
            let task = (m.task ?? "").trimmingCharacters(in: .whitespaces)
            guard let role = matchRole(m.role ?? ""), !task.isEmpty, !seen.contains(role) else { continue }
            seen.insert(role)
            picked.append((role, task))
            captainDeps[role] = (m.dependsOn ?? []).compactMap { matchRole($0) }
        }
        guard !picked.isEmpty else { return nil }   // 一个职位都没匹配上 → 当解析失败,回退文本
        let finalRoles = enforceTeamFloor(picked: picked, company: company)
        let deps = inferDependencies(roles: finalRoles.map { $0.role }, captain: captainDeps)
        let strategy = (dto.strategy ?? "").trimmingCharacters(in: .whitespaces)
        return (company,
                finalRoles.map { Assignment(role: $0.role, brief: $0.brief, dependsOn: deps[$0.role] ?? []) },
                makePlan(strategy: strategy, company: company, roles: finalRoles, deps: deps))
    }

    /// 文本路线(兜底):逐行 `职位：任务`。同时把 JSON 风格的引号/逗号剥掉,连 json-ish 输出也能抢救出角色。
    private static func parseTextPlan(raw: String) -> (CompanyType, [Assignment], CaptainPlan) {
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'，,、")).trimmingCharacters(in: .whitespaces)
        }
        // 解析公司
        var company = CompanyRegistry.fallback
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.contains("公司") || s.lowercased().contains("company") {
                if let sep = s.range(of: "：") ?? s.range(of: ":"),
                   let c = CompanyRegistry.match(clean(String(s[sep.upperBound...]))) { company = c; break }
            }
        }
        // 解析成员:只收能匹配到本公司职位的行,按出现顺序去重(动态规模:挑几个建几个)。
        var picked: [(role: FleetRole, brief: String)] = []
        var seen = Set<FleetRole>()
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let sep = s.range(of: "：") ?? s.range(of: ":") else { continue }
            let key = clean(String(s[s.startIndex..<sep.lowerBound]))
            let val = clean(String(s[sep.upperBound...]))
            guard !val.isEmpty, !key.isEmpty,
                  key != "公司", key != "人数", key.lowercased() != "company", key.lowercased() != "strategy",
                  let role = company.roles.first(where: { key.contains($0.title) || $0.title.contains(key) }),
                  !seen.contains(role) else { continue }
            seen.insert(role)
            picked.append((role, val))
        }
        // 试着抠一句"打法/strategy"作整体说明,抠不到就按团队规模生成一句兜底
        var strategy = ""
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if (s.hasPrefix("打法") || s.lowercased().hasPrefix("strategy") || s.contains("整体打法")),
               let sep = s.range(of: "：") ?? s.range(of: ":") {
                strategy = clean(String(s[sep.upperBound...])); break
            }
        }
        let finalRoles = enforceTeamFloor(picked: picked, company: company)
        // 文本路线拿不到依赖 → 全靠默认层级推断(采集→分析/策划→成文→实现→把关)。
        let deps = inferDependencies(roles: finalRoles.map { $0.role }, captain: [:])
        if strategy.isEmpty {
            strategy = "\(company.name)出动 \(finalRoles.count) 人:按依赖关系接力推进(采集→分析→成文),最后由把关者统一收口质量。"
        }
        return (company,
                finalRoles.map { Assignment(role: $0.role, brief: $0.brief, dependsOn: deps[$0.role] ?? []) },
                makePlan(strategy: strategy, company: company, roles: finalRoles, deps: deps))
    }

    /// 把最终团队(已过兜底)封成可查看 / 可存模板的 CaptainPlan。
    private static func makePlan(strategy: String, company: CompanyType,
                                 roles: [(role: FleetRole, brief: String)],
                                 deps: [FleetRole: [FleetRole]]) -> CaptainPlan {
        let depthByRole = computeRoleDepth(deps)
        let members = roles.map {
            PlannedMember(roleKey: $0.role.rawValue, title: $0.role.title, task: $0.brief,
                          stage: depthByRole[$0.role] ?? 0,
                          dependsOn: (deps[$0.role] ?? []).map { $0.rawValue })
        }
        return CaptainPlan(strategy: strategy, companyId: company.id, companyName: company.name, members: members)
    }

    // MARK: - 依赖关系(DAG)推断 + 深度计算

    /// 角色的"典型依赖层级":采集 0 → 分析/策划 1 → 成文/产出 2 → 实现 3 → 把关 4。
    /// 默认依赖据此推断,且队长指定的依赖也只允许"指向更低层"(防把下游写成上游 → 防环)。
    private static func defaultTier(_ r: FleetRole) -> Int {
        switch r {
        case .researcher:                                   return 0
        case .analyst, .strategist, .planner:               return 1
        case .writer, .editor, .designer, .marketer, .ops:  return 2
        case .engineer:                                     return 3
        case .reviewer:                                     return 4
        }
    }

    /// 给每个角色定依赖:队长给了就用(只留真实存在、层级更低的,去自环防环);没给则默认依赖"紧邻的上一非空层"全员。
    private static func inferDependencies(roles: [FleetRole], captain: [FleetRole: [FleetRole]]) -> [FleetRole: [FleetRole]] {
        let present = Set(roles)
        var result: [FleetRole: [FleetRole]] = [:]
        for r in roles {
            let tier = defaultTier(r)
            // 队长指定:只保留"团队里真实存在 + 层级严格更低"的依赖(天然无环)
            let given = (captain[r] ?? []).filter { present.contains($0) && defaultTier($0) < tier }
            if !given.isEmpty { result[r] = Array(Set(given)); continue }
            // 默认:依赖"比我低的层里、最高那一层"的全部成员(聚焦,不过度耦合)
            let lower = roles.filter { defaultTier($0) < tier }
            if let nearest = lower.map({ defaultTier($0) }).max() {
                result[r] = lower.filter { defaultTier($0) == nearest }
            } else {
                result[r] = []   // 没有更低层 → 根(最先跑、且只有它做 fan-out)
            }
        }
        return result
    }

    /// 角色级执行深度 = 最长依赖链(根=0)。环自动断(visiting 命中返 0),不会死循环。
    private static func computeRoleDepth(_ deps: [FleetRole: [FleetRole]]) -> [FleetRole: Int] {
        var memo: [FleetRole: Int] = [:]
        var visiting: Set<FleetRole> = []
        func depth(_ r: FleetRole) -> Int {
            if let m = memo[r] { return m }
            if visiting.contains(r) { return 0 }
            visiting.insert(r)
            let mx = (deps[r] ?? []).map { depth($0) }.max() ?? -1
            visiting.remove(r)
            let v = mx + 1
            memo[r] = v
            return v
        }
        for r in deps.keys { _ = depth(r) }
        return memo
    }

    /// 团队规模兜底:保证至少 minTeam 人、尽量含一名把关者;但**绝不强行全员**(动态规模的核心)。
    private static let minTeam = 3

    private static func enforceTeamFloor(picked: [(role: FleetRole, brief: String)],
                                         company: CompanyType) -> [(role: FleetRole, brief: String)] {
        var result = picked
        // ① 一个都没解析出来 → 退回花名册前 minTeam 个,避免空团队
        if result.isEmpty {
            result = company.roles.prefix(minTeam).map { ($0, "围绕任务履行你的职责:\($0.summary)") }
        }
        // ② 不足最少人数 → 按花名册顺序补(只补没选过的)
        if result.count < minTeam {
            let chosen = Set(result.map { $0.role })
            for role in company.roles where !chosen.contains(role) {
                result.append((role, "围绕任务履行你的职责:\(role.summary)"))
                if result.count >= minTeam { break }
            }
        }
        // ③ 尽量保证有把关者(reviewer/editor/analyst 之一),公司花名册里有才补
        let gatekeepers: [FleetRole] = [.reviewer, .editor, .analyst]
        if !result.contains(where: { gatekeepers.contains($0.role) }),
           let g = company.roles.first(where: { gatekeepers.contains($0) }),
           !result.contains(where: { $0.role == g }) {
            result.append((g, "审查其他成员的成果,挑错、查漏、把最终质量关"))
        }
        return result
    }

    // MARK: - Phase 2:配置降级

    /// 给角色挑后端:建议后端已**启用 + 真配好**就用;否则回退到其它已配好的 HTTP 后端;
    /// 都不行就兜底到 `vm.agentMode`(用户正在用的、必然配好的那个)—— 保证不会半数卡片因没配置而失败。
    private static func selectBackend(preferred: AgentMode, vm: ChatViewModel) async -> AgentMode {
        let enabled = EnabledModesStore.shared.enabledModes
        let d = UserDefaults.standard
        func nonEmpty(_ key: String) -> Bool { !((d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces).isEmpty) }
        /// HTTP 后端是否真配好了(有 baseURL / key)
        func httpConfigured(_ m: AgentMode) -> Bool {
            switch m {
            case .directAPI: return nonEmpty("directAPIBaseURL") || nonEmpty("directAPIKey")
            case .hermes:    return nonEmpty("apiBaseURL")
            case .openclaw:  return OpenClawGatewayManager.shared.isReady   // 本地 daemon,看就绪而非填的地址
            default:         return true
            }
        }
        func usable(_ m: AgentMode) async -> Bool {
            guard enabled.contains(m) else { return false }
            switch m {
            case .claudeCode: return await CLIAvailability.claudeAvailable()
            case .codex:      return await CLIAvailability.codexAvailable()
            case .qwenCode:   return await CLIAvailability.qwenAvailable()
            default:          return httpConfigured(m)
            }
        }
        if await usable(preferred) { return preferred }
        for m in [AgentMode.directAPI, .hermes, .openclaw] where await usable(m) { return m }
        return vm.agentMode   // 兜底:用户当前后端(必配好)
    }

    /// 所有可参与子探索分摊的后端——给广度角色的子探索轮流分摊,避免全挤单点。
    /// 含 HTTP(在线AI/Hermes/OpenClaw) + 本机 qwen CLI(当 OpenClaw/Hermes 的「扩展 worker」,用户要求)。
    private static func configuredHTTPBackends(vm: ChatViewModel) async -> [AgentMode] {
        let enabled = EnabledModesStore.shared.enabledModes
        let d = UserDefaults.standard
        func nonEmpty(_ k: String) -> Bool { !((d.string(forKey: k) ?? "").trimmingCharacters(in: .whitespaces).isEmpty) }
        var pool: [AgentMode] = []
        if enabled.contains(.hermes),    nonEmpty("apiBaseURL")    { pool.append(.hermes) }
        // OpenClaw 是本地 daemon,地址不需用户填(openclawBaseURL 几乎总是空)——
        // 正确判断是看 daemon 是否真的就绪(OpenClawGatewayManager),而不是某个 UserDefaults key。
        if enabled.contains(.openclaw),  OpenClawGatewayManager.shared.isReady { pool.append(.openclaw) }
        // QwenCode 本机 CLI 子进程：当 OpenClaw/Hermes 的「扩展 worker」也加入分摊(用户要求:多一个干活的、缩短并发等待)。
        // 排在单点 opencode 之前优先分担;子进程启动慢,但 FleetBackendGates(limit=3) 限流,最多 3 个进程不会爆。
        if enabled.contains(.qwenCode),  await CLIAvailability.qwenAvailable() { pool.append(.qwenCode) }
        // 在线 AI 走单个本地 opencode(并发瓶颈),放到**最后**——有网关后端时少分点给它,减轻单点过载。
        if enabled.contains(.directAPI), nonEmpty("directAPIBaseURL") || nonEmpty("directAPIKey") { pool.append(.directAPI) }
        return pool
    }

    // MARK: - Phase 3:并行 fan-out(全部一起开,各自按"后端闸"排队)

    private static func runFanout(agents: [FleetAgent], company: CompanyType, enriched: String,
                                  priorContext: String, workspace: URL?,
                                  vm: ChatViewModel, run: FleetRun, token: UUID) async {
        func alive() -> Bool { run.sessionToken == token }
        // 给"卡片先占位排队 → 齐刷刷开跑"留一个可见的节拍
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard alive() else { return }

        // 不再按 HTTP/子进程拆两套节奏 —— 全部一起开,真实并发由各后端的独立闸控制:
        // 在线AI 2、Hermes 6、OpenClaw 2、qwen 5、子进程(claude/codex)各 1(靠 limit=1 自动串行)。
        var tasks: [Task<Void, Never>] = []
        for agent in agents {
            let t = Task { @MainActor in
                await runAgent(agent: agent, company: company, enriched: enriched,
                               priorContext: priorContext, workspace: workspace, vm: vm, run: run, token: token)
            }
            tasks.append(t)
            run.inflightTasks.append(t)   // 登记,供中止时统一 cancel
        }
        for t in tasks { await t.value }
    }

    /// 把最终成品写成一个真实的 `.md` 文档(落在本次工作区里),并把路径记到 run 上。
    /// 这样博物馆/详情里能"打开 MD 文档",也是"再生成网页"的输入来源。
    @discardableResult
    private static func writeProductMarkdown(run: FleetRun) -> URL? {
        let product = run.product.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty, let ws = run.workspaceURL else { return nil }
        // 没有 H1 标题就补一个(用任务当标题),让 md 文档更完整
        let body = product.hasPrefix("#") ? product : "# \(run.topic)\n\n\(product)"
        let url = ws.appendingPathComponent("成果.md")
        do {
            try body.data(using: .utf8)?.write(to: url, options: .atomic)
            run.productFileURL = url
            return url
        } catch {
            NSLog("[FleetEngine] 写成果.md 失败: \(error)")
            return nil
        }
    }

    /// 建本次运行的共享工作区:`~/.hermespet/fleet/run-<token8>/`,各 agent 在同一处协作。
    private static func makeWorkspace(run: FleetRun) -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/fleet", isDirectory: true)
        let dir = base.appendingPathComponent("run-\(run.sessionToken.uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            NSLog("[FleetEngine] 建工作区失败: \(error)")
            return nil
        }
    }

    /// ⭐ 按**本 agent 的直接依赖**拼上下文(从 run.agents 取依赖的产出),喂给它当输入。
    /// 取代旧的"把所有前序阶段一股脑塞"——下游只拿它真正依赖的同事的产出,不串入无关角色。
    /// Phase 3:若依赖产出看着"没拿到真实数据"(太短/含抓不到标志),追加硬约束不许编造。
    private static func depContextFor(_ agent: FleetAgent, run: FleetRun) -> String {
        let deps = agent.dependsOn.compactMap { id in run.agents.first { $0.id == id } }
            .filter { !$0.output.isEmpty }
        guard !deps.isEmpty else { return "" }
        let blocks = deps.map { "### \($0.role?.title ?? "成员")（\($0.title)）\n\(String($0.output.prefix(6000)))" }
            .joined(separator: "\n\n")
        var ctx = "\n\n【你依赖的同事已完成的产出（请基于这些往下做，别重复他们的活、别另起炉灶）】\n" + blocks
        // Phase 3:检测上游"没真拿到数据"——别让下游在没素材时凭空编造具体数字/事实。
        let markers = ["无法访问", "抓不到", "未能获取", "暂时无法", "cloudflare", "403", "没有找到", "无法获取"]
        let lowEvidence = deps.contains { d in
            let o = d.output.lowercased()
            return d.output.count < 200 || markers.contains { o.contains($0) }
        }
        if lowEvidence {
            ctx += "\n\n【⚠️ 上游数据有限/部分缺失：请基于已有信息推进，**明确标注哪些是假设/估计**，不得编造具体数字、赔率、战绩等事实。】"
        }
        return ctx
    }

    /// 给 streamOneShotAsk 的 token 汇总闭包:每路 onUsage 回报的 token 累加到 run.totalTokens(MainActor 安全)。
    private static func tokenSink(_ run: FleetRun) -> @Sendable (Int) -> Void {
        { tok in Task { @MainActor in run.totalTokens += tok } }
    }

    private static func runAgent(agent: FleetAgent, company: CompanyType, enriched: String,
                                 priorContext: String, workspace: URL?,
                                 vm: ChatViewModel, run: FleetRun, token: UUID) async {
        func alive() -> Bool { run.sessionToken == token }
        guard alive() else { return }
        agent.status = "running"
        agent.startedAt = Date()
        // 返工模式:有"只针对自己的复核意见" → 单流精修(带上一版 + 自己的意见),不重拆方向、不连累别人。
        // runSingleStream 内部会读 agent.fixNote 切到精修 prompt。
        if !agent.fixNote.isEmpty {
            await withGate(run.backendGates, agent.backend) {
                await runSingleStream(agent: agent, company: company, enriched: enriched,
                                      priorContext: priorContext, workspace: workspace, vm: vm, run: run, token: token)
            }
            return
        }
        // 按本 agent 的直接依赖构建输入(替代外面传进来的 priorContext)。
        let depCtx = depContextFor(agent, run: run)
        // ⭐ Part 2:**广度型角色一律 fan-out**(不再限"只有采集根")——下游分析/策划/写作也并行开多个子探索
        //   (各攻一角度、消费上游产出、不重复采集——采集已集中在 Claude Code,无重复风险)→ 找回"好多人在干活"。
        //   Claude Code 采集根也 fan-out(并行抓);子进程后端(claude 已特批)其余不递归 fan-out 防进程爆。
        let canFanOut = (agent.role?.exploresInParallel == true) && (!agent.backend.isLocalHeavy || agent.backend == .claudeCode)
        if canFanOut {
            await runWithSubExploration(agent: agent, company: company, enriched: enriched,
                                        priorContext: depCtx, workspace: workspace, vm: vm, run: run, token: token)
        } else if agent.dynamicDispatch, !run.httpPool.isEmpty {
            // ⭐ Part 1:动态派发——原子从 HTTP 空闲池挑 inflight 最少的后端(已占额),跑完 release 还额。
            //   原子 reserve 根治"2 个 Hermes 同时干活":活会铺到不同后端而非都堆 Hermes。
            guard let backend = try? await run.backendGates.acquireDynamic(run.httpPool) else { return }  // 被中止
            agent.backend = backend   // 卡片更新成实际接活的后端
            await runSingleStream(agent: agent, company: company, enriched: enriched,
                                  priorContext: depCtx, workspace: workspace, vm: vm, run: run, token: token)
            run.backendGates.release(backend)
        } else {
            // 固定后端：过派发器（withGate 保证 acquire/release 配对、被取消不泄漏）
            await withGate(run.backendGates, agent.backend) {
                await runSingleStream(agent: agent, company: company, enriched: enriched,
                                      priorContext: depCtx, workspace: workspace, vm: vm, run: run, token: token)
            }
        }
    }

    /// 单 agent 普通跑法(原 runAgent 主体)。
    /// 把流式异常分类成「给用户看的简短原因 + 换后端重试是否有意义」(C 类修复)。
    /// · 超时(90s idle 或 1800s resource 硬上限) / 中止 → 换后端**无意义**:并发全开时整个后端池
    ///   同步过载,换一路只会再超时 + 往过载池多打一发负载 → retryOther=false。
    /// · 真实 HTTP 报错(429/5xx 限流·服务端 / 401·403 鉴权) → 换个后端往往能成 → retryOther=true。
    private static func classifyStreamError(_ error: Error) -> (reason: String, retryOther: Bool) {
        if case let APIError.httpError(statusCode, _) = error {
            if statusCode == 429 || statusCode >= 500 { return ("后端报错 HTTP \(statusCode)（限流/服务端）", true) }
            if statusCode == 401 || statusCode == 403 { return ("后端拒绝 HTTP \(statusCode)（鉴权/权限）", true) }
            return ("后端报错 HTTP \(statusCode)", true)
        }
        if case APIError.cancelled = error { return ("已中止", false) }
        let ns = error as NSError
        if ns.code == NSURLErrorTimedOut  { return ("响应超时（后端忙或任务过久）", false) }
        if ns.code == NSURLErrorCancelled { return ("已中止", false) }
        return (error.localizedDescription, true)
    }

    private static func runSingleStream(agent: FleetAgent, company: CompanyType, enriched: String,
                                        priorContext: String, workspace: URL?,
                                        vm: ChatViewModel, run: FleetRun, token: UUID) async {
        func alive() -> Bool { run.sessionToken == token }
        let roleLine = agent.role.map { "你的职位是「\($0.title)」(\($0.summary))。" } ?? ""
        let workspaceLine: String = (agent.backend.isLocalHeavy && workspace != nil)
            ? "\n请把要产出的文件都放到这个共享项目目录(其他同事也在这里协作,别放别处):\n\(workspace!.path)\n"
            : ""
        let prompt: String
        if !agent.fixNote.isEmpty {
            // 返工模式:只精修自己这份。**绝不**把别人的问题塞进来 —— 意见只含针对本角色的那条。
            prompt = """
            我们是「\(company.name)」团队,任务:「\(enriched)」
            \(roleLine)
            你这一趟负责:\(agent.title)
            \(workspaceLine)
            这是你上一版的产出:
            \(agent.output.isEmpty ? "（无,你上一版没产出有效内容）" : String(agent.output.prefix(6000)))

            【只针对你的返工意见 —— 请只修正你自己负责的这部分,专注做好你的本职,不要去管/评论别的同事的活】
            \(agent.fixNote)

            请据此产出**改进后的完整新版**(直接输出你这份的正文,不要复述意见、不要写"作为xx我认为"这类废话)。
            """
        } else {
            prompt = """
            我们是「\(company.name)」的一支团队,正在协作完成这个任务:
            「\(enriched)」
            \(priorContext)
            \(roleLine)
            你这一趟具体负责:\(agent.title)
            \(workspaceLine)
            请以这个职位的专业视角,给出深入、具体、可直接用的产出(直接输出正文,不要寒暄、不要复述任务、不要写"作为xx我认为"这类废话)。
            """
        }
        let tag = "fleet-\(token.uuidString.prefix(8))-\(agent.id)"
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: agent.backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: tag, onUsage: tokenSink(run),
                                                       onActivity: { act in Task { @MainActor in agent.activityText = act } }) {
                guard alive() else { return }
                acc += chunk
                agent.partialText = acc
            }
        } catch {
            guard alive() else { return }
            let (reason, _) = classifyStreamError(error)
            NSLog("[FleetEngine] \(agent.id)(\(agent.role?.rawValue ?? "-")) 出错: \(error)")
            agent.status = "failed"
            agent.partialText = "这一路失败了：\(reason)"
            agent.endedAt = Date()
            return
        }
        guard alive() else { return }
        let t = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.output = t
        agent.status = t.isEmpty ? "failed" : "succeeded"
        agent.endedAt = Date()
    }

    /// 广度型角色:拆探索方向 → 并发子 agent 各攻一方向 → 聚合成本角色产出(单路失败不影响其余)。
    private static func runWithSubExploration(agent: FleetAgent, company: CompanyType, enriched: String,
                                              priorContext: String, workspace: URL?,
                                              vm: ChatViewModel, run: FleetRun, token: UUID) async {
        func alive() -> Bool { run.sessionToken == token }
        let dirs = await decomposeDirections(agent: agent, enriched: enriched, vm: vm, token: token)
        guard alive() else { return }
        guard dirs.count >= 2 else {   // 拆不出多方向 → 退回单流(过该后端的并发闸)
            await withGate(run.backendGates, agent.backend) {
                await runSingleStream(agent: agent, company: company, enriched: enriched,
                                      priorContext: priorContext, workspace: workspace, vm: vm, run: run, token: token)
            }
            return
        }
        // ⭐ 数据采集走 Claude Code 的根 → 子路池 = [.claudeCode](只有它能真抓,闸=4 并发拆满);
        //   其余(HTTP)→ 子路池 = 所有已配置 HTTP 后端,**runSubAgent 内部动态占额"谁空挑谁"**(铺到含 OpenClaw)。
        let isClaudeGather = agent.backend == .claudeCode
        let httpPool = isClaudeGather ? [] : await configuredHTTPBackends(vm: vm)
        let subPool: [AgentMode] = isClaudeGather ? [.claudeCode] : (httpPool.isEmpty ? [agent.backend] : httpPool)
        // claude 采集固定拆 ~4 路;HTTP 随后端数 2~4 路。
        let targetCount = isClaudeGather ? min(4, max(2, dirs.count)) : min(4, max(2, subPool.count + 1))
        let useDirs = Array(dirs.prefix(targetCount))
        let placeholder = subPool.first ?? agent.backend
        agent.subAgents = useDirs.enumerated().map { (i, dir) in
            FleetSubAgent(id: "\(agent.id)-d\(i)", direction: dir, backend: placeholder)   // 占位,实际后端开跑时动态挑
        }
        agent.partialText = isClaudeGather
            ? "派出 \(agent.subAgents.count) 路 Claude 并行抓取…"
            : "派出 \(agent.subAgents.count) 路并行探索(动态铺开 \(subPool.count) 个后端)…"
        let subs = agent.subAgents
        var tasks: [Task<Void, Never>] = []
        for sub in subs {
            let t = Task { @MainActor in
                // 不再外层 withGate 预占:runSubAgent 内部按 subPool 动态占额(谁空挑谁) → 铺到含 OpenClaw 的所有后端
                await runSubAgent(sub: sub, parent: agent, company: company, enriched: enriched, pool: subPool, vm: vm, run: run, token: token)
            }
            tasks.append(t)
            run.inflightTasks.append(t)   // 登记,供中止时统一 cancel(真停下后台流)
        }
        for t in tasks { await t.value }
        guard alive() else { return }
        let done = subs.filter { $0.status == "succeeded" && !$0.output.isEmpty }
        if done.isEmpty {
            agent.status = "failed"; agent.partialText = "各方向都没探到东西"; agent.endedAt = Date(); return
        }
        agent.output = done.map { "## \($0.direction)\n\($0.output)" }.joined(separator: "\n\n")
        agent.partialText = "✓ 汇总了 \(done.count)/\(subs.count) 路探索"
        agent.status = "succeeded"
        agent.endedAt = Date()
    }

    /// 让某角色把自己的活拆成 3~4 个互不重叠的探索方向。
    private static func decomposeDirections(agent: FleetAgent, enriched: String, vm: ChatViewModel, token: UUID) async -> [String] {
        let role = agent.role?.title ?? "成员"
        let prompt = """
        你是团队里的「\(role)」。请把你这一趟的活拆成 3~4 个**互不重叠、合起来更全面**的探索方向,
        好让几个助手同时分头去查/做。每行只输出一个方向的简短标题(6~16 字),不要编号、不要解释。

        【总任务】\(enriched)
        【你负责】\(agent.title)
        """
        let raw = await callOnce(prompt: prompt, backend: agent.backend, vm: vm,
                                 tag: "fleet-\(token.uuidString.prefix(8))-\(agent.id)-dirs")
        let lines = raw.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var s = String(line).trimmingCharacters(in: .whitespaces)
            while let f = s.first, f.isNumber || f.isWhitespace || ".、)-•*·（）()".contains(f) { s.removeFirst() }
            s = s.trimmingCharacters(in: .whitespaces)
            // 滤掉模型 echo 的标题/前言行(如"拆分结果(每行一个方向):**"),只留真正的方向标题
            let isHeader = s.contains("：") || s.contains(":") || s.contains("**")
                || s.contains("方向") || s.contains("拆分") || s.contains("每行") || s.contains("如下")
            return (s.isEmpty || s.count > 22 || isHeader) ? nil : s
        }
        return Array(lines.prefix(4))
    }

    /// 单个子探索 agent:专攻一个方向,流式吐字到 sub。**走动态派发**:每次尝试从 `pool` 原子挑 inflight
    /// 最少的后端(claude 采集池就是 `[.claudeCode]`)→ 所有角色的 sub 共用一个 dispatcher → 均匀铺到含
    /// OpenClaw 在内的所有后端,不再全堆 Hermes(修"openclaw在哪、这么多hermes")。
    private static func runSubAgent(sub: FleetSubAgent, parent: FleetAgent, company: CompanyType,
                                    enriched: String, pool: [AgentMode], vm: ChatViewModel, run: FleetRun, token: UUID) async {
        func alive() -> Bool { run.sessionToken == token }
        guard alive() else { return }
        sub.status = "running"
        let isClaudeFetch = pool.count == 1 && pool.first == .claudeCode
        // ⭐ 数据采集子路(Claude Code):明确"真去抓 + 限定抓取量"——只取够用的最小量、拿到关键数据就停,
        //   别深挖别抓全网(用户要求:限定数量更快、还少烧限流)。抓不到如实说、不准编。
        let fetchBound = isClaudeFetch ? """
        \n用你的联网/命令行工具**真去抓取**这个方向的数据。**只取够用的最小量**(比如最关键的前 8~16 条/几项),
        拿到关键数据就停 —— 别深挖、别试图抓全网,**速度优先**。抓不到就如实说明,绝不编造。
        """ : ""
        let prompt = """
        我们是「\(company.name)」团队,总任务:「\(enriched)」。
        你是「\(parent.role?.title ?? "成员")」派出的探索助手,只专攻这一个方向:「\(sub.direction)」。
        请就这个方向给出深入、具体、有干货的发现(直接输出正文,聚焦本方向、别泛泛而谈)。\(fetchBound)
        """
        // 重试(max 2):每次尝试**动态占一个后端**(谁空挑谁),跑完无论成败/中止都 release 还额(守恒)。
        // 只对真实 HTTP 报错(限流/服务端/鉴权)才再换一路;超时/中止不重试(换了白耗)。
        var lastReason = "未知错误"
        for attempt in 0..<2 {
            guard alive() else { return }
            guard let backend = try? await run.backendGates.acquireDynamic(pool) else { return }  // 被中止:没占额
            sub.backend = backend   // 卡片显示实际接活的后端
            if attempt > 0 { sub.partialText = "上一路报错，换 \(backend.label) 重试…" }
            let tag = "fleet-\(token.uuidString.prefix(8))-\(sub.id)-a\(attempt)"
            var acc = ""; var caught: Error? = nil; var aborted = false
            do {
                for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                           recordToActivity: false, injectMemory: false,
                                                           sessionTag: tag, onUsage: tokenSink(run),
                                                           onActivity: { act in Task { @MainActor in sub.activityText = act } }) {
                    if !alive() { aborted = true; break }   // 用 break 退出而非 return,确保下面 release 还额
                    acc += chunk
                    sub.partialText = acc
                }
            } catch { caught = error }
            run.backendGates.release(backend)   // ⭐ 无论成败/中止都还额
            if aborted { return }
            if caught == nil {
                let t = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                sub.output = t
                sub.status = t.isEmpty ? "failed" : "succeeded"
                if t.isEmpty { sub.partialText = "这一路没探到内容" }
                return
            }
            let (reason, retryOther) = classifyStreamError(caught!)
            lastReason = reason
            NSLog("[FleetEngine] \(sub.id) 出错(\(backend.rawValue)): \(caught!)")
            if !retryOther { break }   // 超时/中止:换后端无意义
        }
        guard alive() else { return }
        sub.status = "failed"; sub.partialText = "这路失败了：\(lastReason)"
    }

    // MARK: - 阶段边界复核 + 交付前质检闭环

    /// 阶段边界复核:队长快速审一批产出,**逐角色**点名谁跑偏 + 只针对它的修正意见。
    /// 返回空 = 全过放行;非空 = [(跑偏的角色, 只针对它的意见)] —— 只返工这些角色、各拿各的意见(不串味、不连坐)。
    private static func reviewStageBoundary(stageAgents: [FleetAgent], enriched: String, company: CompanyType,
                                            backend: AgentMode, vm: ChatViewModel, run: FleetRun, token: UUID) async -> [(role: FleetRole, note: String)] {
        func alive() -> Bool { run.sessionToken == token }
        let outputs = stageAgents.filter { !$0.output.isEmpty && $0.role != nil }
        guard !outputs.isEmpty else { return [] }
        let parts = outputs.map { "### [\($0.role!.rawValue)] \($0.role!.title)（\($0.title)）\n\(String($0.output.prefix(4000)))" }
            .joined(separator: "\n\n")
        let roster = outputs.map { "\($0.role!.rawValue)=\($0.role!.title)" }.joined(separator: "、")
        let prompt = """
        你是「\(company.name)」的 CEO「Clawd」,正在做阶段验收。下面是团队这一批同事刚交的产出。
        请判断:**有没有某个同事的产出明显跑偏目标 / 答非所问 / 漏了关键要求**?

        【任务目标】
        \(enriched)

        【这一批同事(英文代号=职位)】\(roster)

        【这一批的产出】
        \(parts)

        【只按下面格式回答,不要别的】
        - 全都没问题:只回两个字「通过」。
        - 有人跑偏:**每个跑偏的同事单独一行**,格式: 返工：[英文代号] 它哪偏了、该怎么拉回来(只说这个同事自己的问题,要能直接指导它重做)
        注意:① 只在**真正明显跑偏**时才点名,细节瑕疵留给最后总质检,别在这挑刺;② 只点名真出问题的那个,没问题的同事不要写;③ 意见只针对被点名的同事本职,别让它去管别人的活。
        """
        let raw = await callOnce(prompt: prompt, backend: backend, vm: vm,
                                 tag: "fleet-\(token.uuidString.prefix(8))-boundary-s\(stageAgents.first?.stage ?? 0)")
        guard alive() else { return [] }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "无" || t.hasPrefix("通过") || t.uppercased().hasPrefix("PASS") { return [] }
        // 解析 "返工：[代号] 意见" 行;只认真实存在于本批的角色
        let present = Set(outputs.compactMap { $0.role })
        var result: [(role: FleetRole, note: String)] = []
        for line in t.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("返工：") || s.hasPrefix("返工:") else { continue }
            let body = String(s.dropFirst(3))
            guard let lb = body.firstIndex(of: "["), let rb = body.firstIndex(of: "]"), lb < rb else { continue }
            let code = String(body[body.index(after: lb)..<rb]).trimmingCharacters(in: .whitespaces)
            guard let role = FleetRole(rawValue: code), present.contains(role) else { continue }
            let note = String(body[body.index(after: rb)...]).trimmingCharacters(in: .whitespaces)
            guard !note.isEmpty, !result.contains(where: { $0.role == role }) else { continue }
            result.append((role, note))
        }
        return result
    }

    /// 让**被点名的角色各自**带着只属于自己的意见返工一次(单流精修,不重拆方向、不连坐、不清空旧产出)。
    private static func refixStageAgents(_ items: [(agent: FleetAgent, note: String)], company: CompanyType,
                                         enriched: String, priorContext: String, workspace: URL?,
                                         vm: ChatViewModel, run: FleetRun, token: UUID) async {
        let fixAgents = items.map { $0.agent }
        guard !fixAgents.isEmpty else { return }
        run.rolesUnderFix = Set(fixAgents.compactMap { $0.role })
        for (ag, note) in items {
            ag.fixNote = note            // 只属于自己的意见 → runAgent 走单流精修
            ag.status = "pending"
            ag.endedAt = nil
            ag.partialText = "↻ 返工中（按复核意见精修）…"   // 不清空 output,旧产出留到新内容覆盖
        }
        await runFanout(agents: fixAgents, company: company, enriched: enriched,
                        priorContext: priorContext, workspace: workspace, vm: vm, run: run, token: token)
        for ag in fixAgents { ag.fixNote = "" }   // 用完即清,别影响后续轮次
        run.rolesUnderFix = []
    }

    /// 交付前独立质检 gate。对照「已澄清目标 + 全部 Q&A」审最终产物。
    /// 守 WorkflowEval「确定性优先 + 模型抽风也不卡流程」:解析失败/不可用 → 放行。
    private static func reviewFinalProduct(product: String, enriched: String, history: [ClarifyAnswered],
                                           company: CompanyType, round: Int, backend: AgentMode,
                                           vm: ChatViewModel, run: FleetRun, token: UUID) async -> ReviewVerdict {
        func alive() -> Bool { run.sessionToken == token }
        let trimmed = product.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 40 {
            let fallbackRole = company.roles.first { $0 != .reviewer } ?? .writer
            return ReviewVerdict(round: round, passed: false, summary: "成品过短,疑似没真正完成。",
                                 issues: [ReviewIssue(severity: "blocker", targetRole: fallbackRole,
                                                      detail: "最终产物内容过短或被截断。", fixHint: "按目标重新产出完整内容。")])
        }
        let qa = history.isEmpty ? "（无）" : history.map { "· \($0.question) → \($0.answer)" }.joined(separator: "\n")
        let roster = company.roles.filter { $0 != .reviewer }
            .map { "\($0.title)（\($0.rawValue)）：\($0.summary)" }.joined(separator: "\n")
        let prompt = """
        你是「质检员」,对交付前的最终成品做独立验收。你**没参与制作**,只对照目标和用户的全部确认挑真问题。

        【用户的任务目标】
        \(enriched)

        【开工前和用户逐条确认过的关键点(成品必须满足)】
        \(qa)

        【可指派返工的角色(只能用下面括号里的英文代号点名)】
        \(roster)

        【待验收的最终成品】
        \(trimmed)

        请逐条核对:是否真正达成目标?是否满足每条用户确认?有没有空话、跑题、自相矛盾、漏做、明显错误?

        【严格按此格式输出,不要多余的话】
        结论：PASS 或 FAIL
        总评：<一句话总评>
        （若 FAIL,逐条列问题,每条一行;PASS 则不写问题行）
        问题：[严重度|角色英文代号] <问题描述> ||| <具体怎么改>

        严重度只能是 blocker / major / minor;只有 blocker、major 会触发返工。角色代号从上面括号里选最该负责的一个。
        """
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                    recordToActivity: false, injectMemory: false,
                    sessionTag: "fleet-\(token.uuidString.prefix(8))-review-r\(round)", onUsage: tokenSink(run)) {
                guard alive() else { return ReviewVerdict(round: round, passed: true, summary: "通过（已中止）", issues: []) }
                acc += chunk
                run.reviewingText = acc
            }
        } catch {
            return ReviewVerdict(round: round, passed: true, summary: "通过（质检不可用,放行）", issues: [])
        }
        return parseReviewVerdict(acc, round: round, company: company)
    }

    /// 把质检意见喂回被点名的角色让其重做(定向:其余角色产出不动)。
    /// ⭐ 每个返工角色**只拿针对它自己的那几条意见**(按 targetRole 过滤)+ 走单流精修(带自己上一版),
    /// 绝不把别的角色的问题塞进来 —— 修掉"被别人的意见带跑、去写别人的活"那个 bug。
    private static func dispatchFixes(targetRoles: [FleetRole], verdict: ReviewVerdict, agents: [FleetAgent],
                                      company: CompanyType, enriched: String, workspace: URL?,
                                      vm: ChatViewModel, run: FleetRun, token: UUID) async {
        let fixAgents = agents.filter { a in a.role.map { targetRoles.contains($0) } ?? false }
        guard !fixAgents.isEmpty else { return }
        for ag in fixAgents {
            let mine = verdict.issues.filter { $0.targetRole == ag.role }
            let note = mine.map { "· [\($0.severity)] \($0.detail)　改法:\($0.fixHint)" }.joined(separator: "\n")
            // 兜底也只给"针对你自己"的泛化指令,绝不回退成"全部意见"(那会重新串味)
            ag.fixNote = note.isEmpty ? "请针对你负责的这部分,按总质检的总体意见整体提升质量。" : note
            ag.status = "pending"; ag.endedAt = nil
            ag.partialText = "↻ 返工中（按质检意见精修）…"   // 不清空 output,旧产出留到新内容覆盖
        }
        await runFanout(agents: fixAgents, company: company, enriched: enriched,
                        priorContext: "", workspace: workspace, vm: vm, run: run, token: token)
        for ag in fixAgents { ag.fixNote = "" }   // 用完即清
    }

    /// 解析质检结论(容错优先:没明确 FAIL 就放行,照 WorkflowEval 哲学,避免误杀进死循环)。
    private static func parseReviewVerdict(_ raw: String, round: Int, company: CompanyType) -> ReviewVerdict {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = text.uppercased()
        let saysFail = upper.contains("FAIL") || text.contains("不通过") || text.contains("不合格")
        let passed = !saysFail
        let summary = lineValue(text, key: "总评") ?? lineValue(text, key: "结论") ?? (passed ? "通过" : "有问题需返工")
        if passed { return ReviewVerdict(round: round, passed: true, summary: summary, issues: []) }

        var issues: [ReviewIssue] = []
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("问题：") || s.hasPrefix("问题:") else { continue }
            let body = String(s.dropFirst(3))
            var severity = "major"; var role: FleetRole? = nil; var detail = body; var hint = ""
            if let lb = body.firstIndex(of: "["), let rb = body.firstIndex(of: "]"), lb < rb {
                let tag = String(body[body.index(after: lb)..<rb])
                let comps = tag.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if let sev = comps.first { severity = sev.lowercased() }
                if comps.count > 1 { role = FleetRole(rawValue: comps[1]) ?? company.roles.first { $0.title.contains(comps[1]) } }
                detail = String(body[body.index(after: rb)...]).trimmingCharacters(in: .whitespaces)
            }
            if let sep = detail.range(of: "|||") {
                hint = String(detail[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                detail = String(detail[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if role == nil { role = company.roles.first { $0 != .reviewer } }
            if !detail.isEmpty {
                issues.append(ReviewIssue(severity: severity, targetRole: role, detail: detail,
                                          fixHint: hint.isEmpty ? "请针对该问题修正。" : hint))
            }
        }
        if issues.isEmpty {
            let r = company.roles.first { $0 != .reviewer } ?? .writer
            issues = [ReviewIssue(severity: "major", targetRole: r, detail: summary, fixHint: "请整体复核并改进。")]
        }
        return ReviewVerdict(round: round, passed: false, summary: summary, issues: issues)
    }

    /// "键：值" 行取值(宽松,容 全/半角冒号)。
    private static func lineValue(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(key + "：") { return String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
            if s.hasPrefix(key + ":") { return String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: - Phase 4:汇总

    private static func synthesize(enriched: String, company: CompanyType, agents: [FleetAgent],
                                   backend: AgentMode, vm: ChatViewModel, run: FleetRun, token: UUID) async -> String {
        func alive() -> Bool { run.sessionToken == token }
        let parts = agents.filter { !$0.output.isEmpty }.map { a in
            "## \(a.role?.title ?? "成员") · \(a.title)\n\(a.output)"
        }.joined(separator: "\n\n")
        guard !parts.isEmpty else {
            run.errorLine = "各部门都没产出,没法汇总。"
            return ""
        }
        let prompt = """
        你是「\(company.name)」的 CEO「Clawd」。下面是团队各位成员就这个任务各自交上来的产出:
        「\(enriched)」

        请把它们**融会贯通成一篇高质量的最终成果**(markdown):该补的衔接补上、该去的重复去掉、该下的结论大胆下,整体要有统一观点、读起来像一份成品而不是几段拼接。直接输出成果正文。

        \(parts)
        """
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: "fleet-synthesize-\(token.uuidString.prefix(8))", onUsage: tokenSink(run)) {
                guard alive() else { return acc }
                acc += chunk
                run.synthesisText = acc
            }
        } catch {
            NSLog("[FleetEngine] synthesize 出错: \(error)")
            run.errorLine = "汇总出错:\(error.localizedDescription)"
            return acc.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return acc.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 工具:一次性(非流式累加)调用

    private static func callOnce(prompt: String, backend: AgentMode, vm: ChatViewModel, tag: String) async -> String {
        var acc = ""
        do {
            for try await chunk in vm.streamOneShotAsk(prompt: prompt, modeOverride: backend,
                                                       recordToActivity: false, injectMemory: false,
                                                       sessionTag: tag) {
                acc += chunk
            }
        } catch {
            NSLog("[FleetEngine] callOnce(\(tag)) 出错: \(error)")
            return ""
        }
        return acc.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
