import SwiftUI
import AppKit

/// 🏟 工作流竞技场窗口（会议纪要垂类）。
/// 入口在 设置 → 竞技场（发 `HermesPetOpenArena` 通知，AppDelegate 用 vm 开本窗）。
/// 守决策 #6（hosting.sizingOptions=[]）/ #21（ScrollView 不套 GeometryReader）。

@MainActor
final class ArenaWindowController: NSObject {
    static let shared = ArenaWindowController()
    private var window: NSWindow?
    private override init() { super.init() }

    func show(vm: ChatViewModel) {
        if window == nil {
            // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 显示周期反推约束 → NSException 崩。
            // 转 NSHostingController + sizingOptions=[] + contentViewController + autoresizingMask + setContentSize。
            let hosting = NSHostingController(rootView: ArenaView(vm: vm))
            if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "工作流竞技场 · 会议纪要"
            win.level = HermesWindowLevel.artifact
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 540, height: 440)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
            win.setContentSize(NSSize(width: 760, height: 640))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }
}

struct ArenaView: View {
    let vm: ChatViewModel

    @State private var transcript = ""
    @State private var running = false
    @State private var progress = ""
    @State private var match: ArenaMatch?
    @State private var expandedID: String?
    @State private var backend: AgentMode = .directAPI
    @State private var didInitBackend = false

    var body: some View {
        ScrollView {   // 决策 #21：不套 GeometryReader
            VStack(alignment: .leading, spacing: 16) {
                header
                inputCard
                if running { progressRow }
                if let m = match { resultsView(m) }
                leaderboardView
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if !didInitBackend { backend = MeetingArena.defaultBackend(current: vm.agentMode); didInitBackend = true }
        }
    }

    // MARK: 头部说明

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("会议纪要 · 同题比拼")
                .font(.system(size: 17, weight: .bold))
            Text("同一份会议转写，让 \(MeetingArena.contestants().count) 个工作流各出一份纪要，裁判按统一标准打分排名 —— 直观看到「多阶段精读」比「一句话总结」强多少。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("会议转写").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("用样例") { transcript = MeetingArena.sampleTranscript }
                    .buttonStyle(.link).font(.system(size: 12))
                Button("用当前对话") { transcript = vm.currentConversationTranscript() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            TextEditor(text: $transcript)
                .font(.system(size: 12))
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
                .overlay(alignment: .topLeading) {
                    if transcript.isEmpty {
                        Text("粘贴一段会议转写，或点「用样例」…")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 12).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("\(transcript.count) 字").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    ForEach(MeetingArena.availableBackends()) { m in
                        Button { backend = m } label: {
                            Text((backend == m ? "✓ " : "   ") + L(m.labelKey))
                        }
                    }
                } label: {
                    Label("评测后端：\(L(backend.labelKey))", systemImage: "cpu")
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(running)
                Button(action: start) {
                    Label(running ? "比拼中…" : "开始比拼", systemImage: "flag.checkered")
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || transcript.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progress).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: 结果

    @ViewBuilder
    private func resultsView(_ m: ArenaMatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本场结果").font(.system(size: 13, weight: .semibold))
            if !m.note.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(m.note).font(.system(size: 12)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }
            ForEach(m.contestants.sorted { $0.rank < $1.rank }) { c in
                contestantCard(c)
            }
        }
    }

    private func contestantCard(_ c: ArenaContestant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(rankBadge(c.rank)).font(.system(size: 16))
                Text(c.workflowName).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f", c.score?.total ?? 0))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(c.rank == 1 ? .green : .primary)
                Text("/10").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            // 5 维分数
            if let s = c.score {
                HStack(spacing: 10) {
                    dimPill("完整", s.completeness)
                    dimPill("结构", s.structure)
                    dimPill("忠实", s.faithfulness)
                    dimPill("具体", s.concreteness)
                    dimPill("简洁", s.conciseness)
                }
                if !s.reason.isEmpty {
                    Text(s.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 看纪要（展开）
            Button {
                expandedID = (expandedID == c.workflowID) ? nil : c.workflowID
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expandedID == c.workflowID ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(expandedID == c.workflowID ? "收起纪要" : "看这份纪要").font(.system(size: 11))
                }.foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if expandedID == c.workflowID {
                MarkdownTextView(content: c.output.isEmpty ? "（未产出）" : c.output)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.04)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(c.rank == 1 ? Color.green.opacity(0.06) : .primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(c.rank == 1 ? Color.green.opacity(0.3) : .primary.opacity(0.08), lineWidth: c.rank == 1 ? 1 : 0.5))
    }

    private func dimPill(_ name: String, _ v: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(v)").font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(v >= 8 ? .green : (v <= 4 ? .orange : .primary))
            Text(name).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(width: 34)
    }

    private func rankBadge(_ rank: Int) -> String {
        switch rank { case 1: return "🥇"; case 2: return "🥈"; case 3: return "🥉"; default: return "#\(rank)" }
    }

    // MARK: 榜单（飞轮种子）

    @ViewBuilder
    private var leaderboardView: some View {
        let rows = ArenaStore.shared.leaderboard()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("累计榜单").font(.system(size: 13, weight: .semibold))
                Text("跑得越多越准 —— 这些数据就是未来「买最优 / 比拼」的依据。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        Text(r.name).font(.system(size: 12))
                        Spacer()
                        Text("均分 \(String(format: "%.1f", r.avg))").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("胜 \(r.wins)/\(r.runs)").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.03)))
                }
            }
        }
    }

    // MARK: 跑一场

    private func start() {
        let input = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count >= 10 else { return }
        running = true; progress = "准备参赛者…"; match = nil; expandedID = nil
        let label = (input == MeetingArena.sampleTranscript.trimmingCharacters(in: .whitespacesAndNewlines)) ? "样例" : "粘贴的转写"
        Task { @MainActor in
            let m = await MeetingArena.run(transcript: input, inputLabel: label, backend: backend, vm: vm,
                                           onProgress: { progress = $0 })
            match = m
            running = false
            if m == nil { progress = "没有可参赛的工作流，或转写太短。" }
        }
    }
}
