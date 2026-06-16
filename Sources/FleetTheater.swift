import SwiftUI
import AppKit

/// 「桌宠舰队剧场」—— 舰队工作流可视化(第 1 期 · AI 公司版)。
///
/// 流程剧场化:输入任务 → Clawd 队长**反问**(带选项确认)→ 选定公司 + 派出有职位的员工 →
/// 卡片先"排队中"、拆解完齐刷刷**同时开跑**、实时吐字/计时 → 顶部并行进度条 →
/// 点卡片看某员工**完整产出** → 收回汇总成最终成果。
///
/// 窗口范式照 RunPanelController(独立 NSWindow + NSHostingView.sizingOptions=[],守决策 #6;不碰灵动岛 #1)。
/// 滚动/动画严守决策 #21:ScrollView 不被 GeometryReader 包、纯数据驱动 scrollTo、无 preference 反馈环;
/// 进度用 ProgressView(.linear) 不自己量宽;详情用独立 sheet(渲染树隔离,不反推窗口 frame)。

@MainActor
final class FleetTheaterController: NSObject {
    static let shared = FleetTheaterController()
    private var window: NSWindow?
    private var run: FleetRun?
    private weak var vm: ChatViewModel?
    private var task: Task<Void, Never>?
    private override init() { super.init() }

    func present(vm: ChatViewModel) {
        self.vm = vm
        let run = self.run ?? FleetRun(leadBackend: vm.agentMode)
        if !run.isActive { run.leadBackend = vm.agentMode }
        self.run = run

        let view = FleetTheaterView(
            run: run,
            onDispatch: { [weak self] topic in self?.dispatch(topic: topic) },
            onResolveClarify: { [weak self] startNow in self?.run?.resolveClarification(startNow: startNow) },
            onAbort: { [weak self] in self?.abort() },
            onOpenInChat: { [weak self] in
                guard let self, let vm = self.vm, let run = self.run else { return }
                vm.createWorkflowResultConversation(content: run.product,
                                                    title: "舰队工作流" + (run.company.map { " · \($0.name)" } ?? ""),
                                                    input: run.topic,
                                                    mode: run.leadBackend)
            },
            onRefine: { [weak self] feedback in self?.refine(feedback: feedback) },
            onMakeWebpage: { [weak self] in
                guard let self, let vm = self.vm, let run = self.run, !run.product.isEmpty else { return }
                ArtifactWindowController.shared.present(
                    markdown: run.product,
                    title: run.topic.isEmpty ? "舰队成果" : run.topic,
                    mode: run.leadBackend, vm: vm, sourceMessageID: nil)
            },
            onClose: { [weak self] in self?.close() })

        // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 显示周期反推约束 → NSException 崩。
        // 本窗 .resizable + 流式长高（综合/精炼时 markdown 不断变），高发场景 → 转 NSHostingController；
        // 建窗 + 复用两条分支都要换（复用分支不 setContentSize，保住用户拖过的尺寸）。
        let hosting = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6

        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.level = HermesWindowLevel.artifact
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 520, height: 560)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
            win.setContentSize(NSSize(width: 660, height: 720))
            win.center()
            window = win
        } else {
            window?.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
        }
        window?.title = "舰队工作流（实验）"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 从聊天输入框「全量模式」拦截进来：弹剧场窗 + 直接用聊天文本派活（自带输入退居二线）。
    func presentAndDispatch(vm: ChatViewModel, topic: String) {
        present(vm: vm)
        if run?.isActive == true {
            // 上一单还在跑：只把窗带到前面，不打断（dispatch 内 guard 也会挡，这里更直观）
            return
        }
        dispatch(topic: topic)
    }

    private func dispatch(topic: String) {
        guard let vm = self.vm, let run = self.run else { return }
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !run.isActive else { return }
        run.sessionToken = UUID()
        task?.cancel()
        task = Task { @MainActor in
            await FleetEngine.run(topic: t, vm: vm, run: run)
        }
    }

    /// 博物馆「复用这套流程」:开剧场窗 + 按存档计划直接开跑(跳过反问+重新规划)。
    func presentAndReuse(vm: ChatViewModel, plan: CaptainPlan, topic: String) {
        present(vm: vm)
        guard let run = self.run, !run.isActive else { return }
        run.sessionToken = UUID()
        task?.cancel()
        task = Task { @MainActor in
            await FleetEngine.runFromPlan(topic: topic, plan: plan, vm: vm, run: run)
        }
    }

    /// done 后的对话式打磨。**不换 sessionToken**(同一会话,共享 workspace/agents/versions)。
    private func refine(feedback: String) {
        guard let vm = self.vm, let run = self.run else { return }
        guard run.phase == .done, !run.isRefining else { return }
        task?.cancel()
        task = Task { @MainActor in
            await FleetEngine.refine(feedback: feedback, vm: vm, run: run)
        }
    }

    private func abort() {
        run?.abort()
        task?.cancel()
        NotificationCenter.default.post(name: .init("HermesPetTaskFinished"),
                                        object: nil, userInfo: ["success": false])
    }

    func close() { window?.orderOut(nil) }
}

// MARK: - 剧场主视图

struct FleetTheaterView: View {
    @Bindable var run: FleetRun
    let onDispatch: (String) -> Void
    let onResolveClarify: (Bool) -> Void     // true=直接开工 / false=提交本轮继续逼近
    let onAbort: () -> Void
    let onOpenInChat: () -> Void
    let onRefine: (String) -> Void           // done 后用户反馈 → 定向重派打磨
    let onMakeWebpage: () -> Void            // done 后把成品 markdown 生成网页(走现成 artifact 流水线)
    let onClose: () -> Void

    @State private var topicDraft: String = ""
    @State private var refineDraft: String = ""
    @State private var showVersions = false
    @State private var planExpanded = false
    @State private var showPlanSheet = false

    private let accent = Color(red: 0.486, green: 0.424, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            topicBar
            progressBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        leadZone
                        if run.plan != nil { planCard }
                        if run.phase == .clarifying { clarifySection }
                        if !run.agents.isEmpty { agentsSection }
                        if showSynthesis { synthesisSection }
                        if showReview { reviewSection }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
                // 决策 #21:纯数据驱动 scrollTo,无 GeometryReader / preference
                .onChange(of: run.synthesisText.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: run.agents.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: run.clarifyQuestions.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: run.reviewingText.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: run.reviewVerdicts.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: run.refineRound) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var showSynthesis: Bool {
        run.phase == .synthesizing || run.phase == .done || !run.synthesisText.isEmpty || !run.product.isEmpty
    }
    private var showReview: Bool {
        run.phase == .reviewing || run.phase == .fixing || !run.reviewVerdicts.isEmpty
    }

    // MARK: 顶部:任务输入栏

    private var topicBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered").foregroundStyle(accent)
            TextField("给舰队一个任务，比如：做一个苹果农场的网页", text: $topicDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .disabled(run.isActive)
                .onSubmit(dispatchNow)
            if run.isActive {
                Button(action: onAbort) { Label("中止", systemImage: "stop.circle") }
                    .buttonStyle(.bordered)
            } else {
                Button(action: dispatchNow) { Text("派活 🦞").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(topicDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func dispatchNow() {
        let t = topicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !run.isActive else { return }
        onDispatch(t)
    }

    // MARK: 顶部并行进度条

    @ViewBuilder
    private var progressBar: some View {
        if run.phase == .dispatched || run.phase == .synthesizing || run.phase == .reviewing || run.phase == .fixing {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.fill").font(.system(size: 10)).foregroundStyle(accent)
                    Text("\(run.agents.count) 路并行")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    if let start = run.startedAt {
                        Text("·").foregroundStyle(.secondary)
                        FleetElapsedLabel(startedAt: start, endedAt: nil, tint: accent.opacity(0.85))
                    }
                    Spacer()
                    Text("\(run.doneAgentCount)/\(run.agents.count) 完成")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(run.doneAgentCount), total: Double(max(1, run.agents.count)))
                    .progressViewStyle(.linear)
                    .tint(accent)
                    .animation(.easeInOut(duration: 0.3), value: run.doneAgentCount)
                // 指标行:在干活计数 + 当前轮次(质检/打磨时才显)。token 用量已隐藏(发版前藏起,见决策)。
                HStack(spacing: 10) {
                    if activeWorkers > 0 {
                        Label("\(activeWorkers) 个在干活", systemImage: "flame.fill")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.orange)
                    }
                    if run.phase == .reviewing || run.phase == .fixing, run.reviewRound > 0 {
                        Label("第 \(run.reviewRound) 轮质检", systemImage: "checkmark.shield")
                            .font(.system(size: 9.5)).foregroundStyle(.orange.opacity(0.85))
                    }
                    if run.refineRound > 0 {
                        Label("第 \(run.refineRound) 次打磨", systemImage: "wand.and.stars")
                            .font(.system(size: 9.5)).foregroundStyle(accent.opacity(0.85))
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    /// 此刻真正在干活的"工人"数:有子探索的算它在跑的子路、没子探索的算自己 running ——
    /// 给用户"好多人同时在干活"的并行威力感(实时跳动)。
    private var activeWorkers: Int {
        run.agents.reduce(0) { acc, a in
            a.subAgents.isEmpty
                ? acc + (a.status == "running" ? 1 : 0)
                : acc + a.subAgents.filter { $0.status == "running" }.count
        }
    }

    // MARK: 队长区(Clawd + 台词 + 公司)

    private var leadZone: some View {
        VStack(spacing: 8) {
            Text(leadLine)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(accent.opacity(0.12)))
                .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
            ModeSpriteView(mode: .claudeCode, isWorking: run.isCrunching, size: 44)
                .frame(height: 54)
            if let c = run.company {
                Label(c.name, systemImage: c.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(c.tint)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(c.tint.opacity(0.12)))
            } else {
                Text("Clawd · 队长").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 显式作战计划卡(⑤;可展开看分批、可导出成可复用脚本)

    @ViewBuilder
    private var planCard: some View {
        if let plan = run.plan {
            VStack(alignment: .leading, spacing: 10) {
                // 头部:标题 + 规模 + 展开/收起 + 查看完整
                HStack(spacing: 8) {
                    Image(systemName: "map.fill").font(.system(size: 12)).foregroundStyle(accent)
                    Text("作战计划").font(.system(size: 12.5, weight: .semibold))
                    Text("\(plan.members.count) 人 · \(plan.stages.count) 批")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { showPlanSheet = true } label: {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("查看完整计划 / 导出脚本")
                    Button { withAnimation(.easeInOut(duration: 0.2)) { planExpanded.toggle() } } label: {
                        Image(systemName: planExpanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                // 整体打法(始终可见)
                if !plan.strategy.isEmpty {
                    Text(plan.strategy)
                        .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 分批阵容(展开后)
                if planExpanded {
                    ForEach(Array(plan.stages.enumerated()), id: \.offset) { idx, group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(idx + 1) 批 · 并行 \(group.members.count) 人")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(accent.opacity(0.8))
                            ForEach(group.members) { m in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: m.role?.symbol ?? "person.fill")
                                        .font(.system(size: 10)).foregroundStyle(m.role?.tint ?? accent)
                                        .frame(width: 14)
                                    Text(m.title).font(.system(size: 11, weight: .medium)).frame(width: 56, alignment: .leading)
                                    Text(m.task).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.18), lineWidth: 1))
            .sheet(isPresented: $showPlanSheet) {
                FleetPlanSheet(plan: plan, accent: accent) { showPlanSheet = false }
            }
        }
    }

    private var leadLine: String {
        switch run.phase {
        case .idle:         return "给我个任务，我带队并行开干 🦞"
        case .clarifying:   return run.clarifyQuestions.isEmpty ? "让我想想还要确认啥…" : "先把目标一点点聊清楚，再动手 👇"
        case .decomposing:  return "目标够清楚了！我来组队、分活…"
        case .dispatched:   return "\(run.company?.name ?? "团队")已就位，\(run.agents.count) 路同时开跑！"
        case .synthesizing: return "都回来了，我来揉成一篇 ✍️"
        case .reviewing:    return "成品出来了，让质检员把把关 🔍"
        case .fixing:       return "质检发现 \(run.latestVerdict?.issues.count ?? 0) 个问题，喊 \(run.rolesUnderFix.count) 位同事回来返工 🔧"
        case .refining:     return "收到，我让相关同事按你的反馈再改改 🔧"
        case .done:         return "搞定！这是合起来的成果 🎉"
        case .failed:       return run.errorLine.isEmpty ? "这次没跑成，换个说法再试？" : run.errorLine
        case .aborted:      return "已经停手了。"
        }
    }

    // MARK: 反问区(多轮逼近,带选项)

    private var clarifySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 已确认回顾(多轮逼近的轨迹)
            if !run.clarifyHistory.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("已确认", systemImage: "checklist.checked")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(run.clarifyHistory) { h in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.question)
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("↳ " + h.answer)
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04)))
            }

            if run.clarifyQuestions.isEmpty {
                // 轮次之间:队长正在想下一组问题
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Clawd 正在想还要确认什么…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 11)).foregroundStyle(accent)
                    Text("第 \(run.clarifyRound) 轮 · 帮我把目标定得更准")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                }
                ForEach(run.clarifyQuestions) { q in
                    ClarifyQuestionRow(question: q, accent: accent)
                }
                HStack(spacing: 10) {
                    Button { onResolveClarify(true) } label: {
                        Label("够了，直接开工 🚀", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button { onResolveClarify(false) } label: {
                        Label("提交，继续问", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(accent)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.2), lineWidth: 1))
    }

    // MARK: 员工卡片区(fan-out)

    private var agentsSection: some View {
        let stageCount = Set(run.agents.map { $0.stage }).count
        return VStack(spacing: 10) {
            connector(icon: "arrow.down",
                      text: stageCount > 1 ? "\(run.agents.count) 人 · 分 \(stageCount) 批接力（同批并行，后批等前批）"
                                           : "\(run.agents.count) 人并行")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(run.agents) { agent in
                        // 每个角色一列：父卡在上，派出的子探索小卡一张张往下排
                        // 计算"它还在等哪些依赖"(还没完成的依赖同事名)→ 卡片显示"等待：X"
                        let waitingOn = agent.dependsOn
                            .compactMap { id in run.agents.first { $0.id == id } }
                            .filter { $0.status != "succeeded" && $0.status != "failed" }
                            .map { $0.displayHeading }
                        VStack(spacing: 8) {
                            FleetAgentCard(agent: agent, waitingOn: waitingOn,
                                           underFix: agent.role.map { run.rolesUnderFix.contains($0) } ?? false)
                            ForEach(agent.subAgents) { sub in
                                FleetSubCard(sub: sub, tint: agent.accentTint)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 4)
            }
        }
    }

    // MARK: 汇总区(reduce)

    private var synthesisSection: some View {
        VStack(spacing: 10) {
            connector(icon: "arrow.triangle.merge", text: "收回来 · 汇总")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: run.phase == .done ? "doc.text.fill" : "sparkles").foregroundStyle(accent)
                    Text(run.phase == .done ? "最终成果" : "汇总中…")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                }
                let text = (run.phase == .done && !run.product.isEmpty) ? run.product : run.synthesisText
                if text.isEmpty {
                    Text("队长正在把各部门结果揉成一篇…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    MarkdownTextView(content: text).font(.system(size: 13.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.06)))
        }
    }

    // MARK: 交付前质检区

    private var reviewSection: some View {
        VStack(spacing: 10) {
            connector(icon: "checkmark.seal", text: "交付前质检")
            VStack(alignment: .leading, spacing: 8) {
                if run.phase == .reviewing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("质检员正在对照目标审最终成品…")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    }
                    if !run.reviewingText.isEmpty {
                        Text(String(run.reviewingText.suffix(280)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(run.reviewVerdicts) { v in ReviewVerdictCard(verdict: v) }
                if run.phase == .fixing {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                        Text("第 \(run.reviewRound) 轮 · 被点名的同事正在返工…")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((run.latestVerdict?.passed == true ? Color.green : accent).opacity(0.06)))
        }
    }

    private func connector(icon: String, text: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(accent.opacity(0.6))
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
        }
    }

    // MARK: 底部动作栏

    @ViewBuilder
    private var footer: some View {
        if run.isActive {
            HStack(spacing: 10) {
                if run.isCrunching { ProgressView().controlSize(.small) }
                Text(phaseLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onAbort) { Label("中止", systemImage: "stop.circle") }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        } else if run.phase == .done && !run.product.isEmpty {
            refineFooter
        } else {
            HStack { Spacer(); Button("关闭", action: onClose).buttonStyle(.bordered) }
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // done 之后的「继续打磨」footer:追加反馈输入框 + 原有动作 + 版本回看
    private var refineFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.down.circle").foregroundStyle(accent)
                TextField("还想怎么改？比如：再加个联系页 / 文案更活泼些", text: $refineDraft)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .disabled(run.isRefining)
                    .onSubmit(submitRefine)
                Button(action: submitRefine) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain).foregroundStyle(accent)
                .disabled(refineDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.primary.opacity(0.05)))
            .overlay(Capsule().stroke(.primary.opacity(0.1), lineWidth: 1))

            HStack(spacing: 10) {
                Button { copyProduct() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                if let md = run.productFileURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([md]) } label: {
                        Label("MD 文档", systemImage: "doc.text")
                    }.buttonStyle(.bordered).help("在 Finder 里查看成果.md")
                }
                if run.versions.count > 1 {
                    Button { showVersions = true } label: {
                        Label("v\(run.versions.count - 1) · 看历史", systemImage: "clock.arrow.circlepath")
                    }.buttonStyle(.bordered)
                }
                Spacer()
                Button { onMakeWebpage() } label: { Label("生成网页", systemImage: "sparkles.rectangle.stack") }
                    .buttonStyle(.bordered)
                Button { onOpenInChat() } label: { Label("存为对话", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .sheet(isPresented: $showVersions) { FleetVersionHistoryView(run: run, accent: accent) }
    }

    private func submitRefine() {
        let fb = refineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fb.isEmpty, run.phase == .done, !run.isRefining else { return }
        onRefine(fb)
        refineDraft = ""
    }

    private var phaseLabel: String {
        switch run.phase {
        case .clarifying:   return run.clarifyQuestions.isEmpty ? "队长在想问题…" : "第 \(run.clarifyRound) 轮 · 等你确认…"
        case .decomposing:  return "队长组队分活中…"
        case .dispatched:   return "\(run.doneAgentCount)/\(run.agents.count) 路完成"
        case .synthesizing: return "汇总中…"
        case .reviewing:    return "质检员审最终成品中…"
        case .fixing:       return "\(run.rolesUnderFix.count) 人返工中（第 \(run.reviewRound) 轮质检）"
        case .refining:     return "正在按你的反馈重做相关部分…"
        default:            return ""
        }
    }
    private func copyProduct() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.product, forType: .string)
    }
}

// MARK: - 反问的一道题

private struct ClarifyQuestionRow: View {
    @Bindable var question: ClarifyQuestion
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if question.allowsMultiple {
                Label("可多选", systemImage: "checkmark.square")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            // 选项(单选=圆点互斥 / 多选=勾选框可多选)
            FlowChips(options: question.options,
                      isSelected: { question.isSelected($0) },
                      multi: question.allowsMultiple) { opt in
                question.toggle(opt)
            }
            TextField("或自己补充…", text: $question.customText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
        }
    }
}

/// 选项列表 —— 单列、整宽、文字**完整换行不截断**。单选=圆点(radio),多选=勾选框(checkbox)。
private struct FlowChips: View {
    let options: [String]
    let isSelected: (String) -> Bool
    var multi: Bool = false
    let onTap: (String) -> Void

    private func icon(on: Bool) -> String {
        multi ? (on ? "checkmark.square.fill" : "square")
              : (on ? "largecircle.fill.circle" : "circle")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { opt in
                let on = isSelected(opt)
                Button { onTap(opt) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(on: on))
                            .font(.system(size: 12))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            .padding(.top, 1)
                        Text(opt)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 1.4 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 单张员工卡片

private struct FleetAgentCard: View {
    @Bindable var agent: FleetAgent
    var waitingOn: [String] = []   // 还没完成的依赖同事名(非空 = 正等它们)
    var underFix: Bool = false
    @State private var pulse = false
    @State private var showDetail = false

    private var tint: Color { agent.accentTint }
    private var running: Bool { agent.status == "running" }
    /// 还没轮到:本卡有还没完成的依赖,正等它们产出。
    private var waiting: Bool { agent.status == "pending" && !waitingOn.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部:职位 + 状态
            HStack(spacing: 6) {
                Image(systemName: agent.role?.symbol ?? "person.fill")
                    .font(.system(size: 11)).foregroundStyle(tint)
                Text(agent.displayHeading)
                    .font(.system(size: 11.5, weight: .bold)).foregroundStyle(tint)
                Spacer(minLength: 0)
                if underFix {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                statusGlyph
            }
            // 后端徽标
            HStack(spacing: 4) {
                ModeSpriteView(mode: agent.backend, isWorking: running, size: 14).frame(width: 18, height: 18)
                Text(agent.backend.label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            // 这名员工负责啥
            Text(agent.title)
                .font(.system(size: 11.5))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            // 实时吐字 ticker(固定高度,不撑布局 —— 守决策 #21)
            tickerBox
            if !agent.subAgents.isEmpty {
                Text("派出 \(agent.subAgents.count) 路探索 ↓")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(tint.opacity(0.8))
            }
            FleetElapsedLabel(startedAt: agent.startedAt, endedAt: agent.endedAt, tint: tint)
        }
        .padding(11)
        .frame(width: 180, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(running ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(tint.opacity(running ? (pulse ? 0.7 : 0.28) : 0.18), lineWidth: running ? 1.6 : 1))
        .shadow(color: running ? tint.opacity(pulse ? 0.35 : 0.08) : .clear, radius: running ? 7 : 0)
        .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulse)
        .opacity(waiting ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if agent.status == "succeeded" || agent.status == "failed" { showDetail = true }
        }
        .onAppear { pulse = running }
        .onChange(of: running) { now in pulse = now }
        .sheet(isPresented: $showDetail) { FleetAgentDetailView(agent: agent) }
    }

    @ViewBuilder private var statusGlyph: some View {
        switch agent.status {
        case "running":   ProgressView().controlSize(.mini).scaleEffect(0.75)
        case "succeeded": Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case "failed":    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
        default:          Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var tickerBox: some View {
        Group {
            switch agent.status {
            case "running":
                // 答案出了就显答案;没出但有实时活动(工具动作"🌐 抓 xxx")就显活动;都没有才"思考中"
                if !tickerText.isEmpty {
                    Text(tickerText).foregroundStyle(.secondary)
                } else if !agent.activityText.isEmpty {
                    Text(agent.activityText).foregroundStyle(.secondary.opacity(0.7))
                } else {
                    Text("思考中…").foregroundStyle(.secondary)
                }
            case "succeeded":
                Text(firstLine(agent.output)).foregroundStyle(.secondary.opacity(0.9))
            case "failed":
                Text(agent.partialText.isEmpty ? "出错了" : agent.partialText).foregroundStyle(.orange.opacity(0.85))
            default:
                Text(waiting ? "⏳ 等待：\(waitingOn.prefix(3).joined(separator: "、"))" : "准备开跑…")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(3)
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .topLeading)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04)))
        .overlay(alignment: .bottomTrailing) {
            if agent.status == "succeeded" || agent.status == "failed" {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8)).foregroundStyle(.tertiary).padding(4)
            }
        }
        .clipped()
    }

    private var tickerText: String { String(agent.partialText.suffix(140)) }
    private func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return "✓ " + String(line.prefix(80))
    }
}

// MARK: - 子探索小卡(独立小卡片,从父卡下方一张张往下排)

private struct FleetSubCard: View {
    @Bindable var sub: FleetSubAgent
    let tint: Color
    @State private var pulse = false
    @State private var showDetail = false
    private var running: Bool { sub.status == "running" }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Rectangle().fill(tint.opacity(0.55)).frame(width: 2)   // 左侧连接条:挂在父卡下
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    glyph
                    Text(sub.direction)
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                // 这一路分摊到哪个后端(看得见在线AI/OpenClaw/Hermes 的分摊)
                Text(sub.backend.label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(sub.backend.railTint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(sub.backend.railTint.opacity(0.14)))
                tickerLine
            }
        }
        .padding(8)
        .frame(width: 180, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(running ? 0.10 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(tint.opacity(running ? (pulse ? 0.6 : 0.25) : 0.15), lineWidth: running ? 1.3 : 0.8))
        .shadow(color: running ? tint.opacity(pulse ? 0.25 : 0.05) : .clear, radius: running ? 5 : 0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .contentShape(Rectangle())
        .onTapGesture { if sub.status == "succeeded" || sub.status == "failed" { showDetail = true } }
        .onAppear { pulse = running }
        .onChange(of: running) { now in pulse = now }
        .sheet(isPresented: $showDetail) { FleetSubDetailView(sub: sub, tint: tint) }
    }

    @ViewBuilder private var glyph: some View {
        switch sub.status {
        case "running":   ProgressView().controlSize(.mini).scaleEffect(0.65)
        case "succeeded": Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
        case "failed":    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
        default:          Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private var tickerLine: some View {
        Group {
            switch sub.status {
            case "running":
                // 答案出了显答案;没出但有活动(claude 抓数据"🌐 抓 xxx")显活动;都没有才"探索中"
                if !String(sub.partialText.suffix(90)).isEmpty {
                    Text(String(sub.partialText.suffix(90))).foregroundStyle(.secondary)
                } else if !sub.activityText.isEmpty {
                    Text(sub.activityText).foregroundStyle(.secondary.opacity(0.7))
                } else {
                    Text("探索中…").foregroundStyle(.secondary)
                }
            case "succeeded": Text(firstLine(sub.output)).foregroundStyle(.secondary.opacity(0.9))
            case "failed":    Text(sub.partialText.isEmpty ? "这路出错" : sub.partialText).foregroundStyle(.orange.opacity(0.85))
            default:          Text("排队中…").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9.5)).lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
    }
    private func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return "✓ " + String(line.prefix(60))
    }
}

private struct FleetSubDetailView: View {
    let sub: FleetSubAgent
    let tint: Color
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 15)).foregroundStyle(tint)
                Text(sub.direction).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sub.output, forType: .string) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }.buttonStyle(.bordered)
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(14)
            Divider()
            ScrollView {
                MarkdownTextView(content: sub.output.isEmpty ? "（无产出）" : sub.output)
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - 员工完整产出详情(独立 sheet,渲染树隔离,不反推窗口 frame)

private struct FleetAgentDetailView: View {
    let agent: FleetAgent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: agent.role?.symbol ?? "person.fill")
                    .font(.system(size: 16)).foregroundStyle(agent.accentTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayHeading).font(.system(size: 14, weight: .semibold))
                    Text(agent.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { copyOutput() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(14)
            Divider()
            ScrollView {
                MarkdownTextView(content: agent.output.isEmpty ? "（无产出）" : agent.output)
                    .font(.system(size: 13.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agent.output, forType: .string)
    }
}

// MARK: - 质检结论卡

private struct ReviewVerdictCard: View {
    let verdict: ReviewVerdict
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: verdict.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(verdict.passed ? .green : .orange)
                Text("第 \(verdict.round) 轮质检 · " + (verdict.passed ? "通过" : "发现 \(verdict.issues.count) 个问题"))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(verdict.passed ? .green : .orange)
            }
            Text(verdict.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(verdict.issues) { issue in
                HStack(alignment: .top, spacing: 6) {
                    Text(badge(issue.severity)).font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(sevColor(issue.severity).opacity(0.18)))
                        .foregroundStyle(sevColor(issue.severity))
                    VStack(alignment: .leading, spacing: 1) {
                        (Text((issue.targetRole?.title).map { "→ \($0)：" } ?? "→ ")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(issue.targetRole?.tint ?? .secondary)
                         + Text(issue.detail).font(.system(size: 10.5)).foregroundStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("改法：" + issue.fixHint).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04)))
    }
    private func badge(_ s: String) -> String { s == "blocker" ? "拦截" : s == "major" ? "重要" : "次要" }
    private func sevColor(_ s: String) -> Color { s == "blocker" ? .red : s == "major" ? .orange : .secondary }
}

// MARK: - 计时标签(避免和 MiniIslandController 的 ElapsedLabel 重名)

private struct FleetElapsedLabel: View {
    let startedAt: Date?
    let endedAt: Date?
    let tint: Color

    var body: some View {
        Group {
            if let start = startedAt {
                if let end = endedAt {
                    label(end.timeIntervalSince(start))
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        label(ctx.date.timeIntervalSince(start))
                    }
                }
            } else {
                label(0).opacity(0)
            }
        }
    }

    private func label(_ t: TimeInterval) -> some View {
        Label(fmt(t), systemImage: "timer")
            .font(.system(size: 9.5))
            .foregroundStyle(tint.opacity(0.85))
            .labelStyle(.titleAndIcon)
    }

    private func fmt(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - 产物版本历史(回看上一版,独立 sheet)

private struct FleetVersionHistoryView: View {
    let run: FleetRun
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("产物历史 · 共 \(run.versions.count) 版").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.versions.reversed()) { v in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(v.index == 0 ? "初版 v0" : "v\(v.index)")
                                    .font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                                if !v.changedRoles.isEmpty {
                                    Text("改了：" + v.changedRoles.joined(separator: "、"))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { copy(v.product) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                            }
                            if let fb = v.feedback {
                                Text("反馈：\(fb)").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            MarkdownTextView(content: String(v.product.prefix(4000)))
                                .font(.system(size: 12.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.04)))
                    }
                }.padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - 完整作战计划 sheet(查看 + 导出可复用脚本)

private struct FleetPlanSheet: View {
    let plan: CaptainPlan
    let accent: Color
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill").foregroundStyle(accent)
                Text("作战计划 · \(plan.companyName)").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { copyScript() } label: {
                    Label(copied ? "已复制" : "导出脚本", systemImage: copied ? "checkmark" : "curlybraces")
                }
                .buttonStyle(.bordered)
                Button("完成") { onClose() }.buttonStyle(.borderedProminent).tint(accent)
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 整体打法
                    VStack(alignment: .leading, spacing: 4) {
                        Label("整体打法", systemImage: "scope")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        Text(plan.strategy).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.07)))

                    // 分批阵容
                    ForEach(Array(plan.stages.enumerated()), id: \.offset) { idx, group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("第 \(idx + 1) 批").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                                Text("并行 \(group.members.count) 人").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                if idx > 0 {
                                    Image(systemName: "arrow.turn.left.up").font(.system(size: 9)).foregroundStyle(.secondary)
                                    Text("等上一批产出").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(group.members) { m in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: m.role?.symbol ?? "person.fill")
                                        .font(.system(size: 12)).foregroundStyle(m.role?.tint ?? accent)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.title).font(.system(size: 12, weight: .semibold))
                                        Text(m.task).font(.system(size: 12)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04)))
                    }
                }.padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 460)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// 导出成可复用脚本(JSON):队长脑子里的"脚本"显式化,可存档 / 下次套用。
    private func copyScript() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(plan), let s = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = true
    }
}
