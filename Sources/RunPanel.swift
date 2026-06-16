import SwiftUI
import AppKit

/// 工作流「执行过程」面板 —— 路线图里程碑 7。
///
/// 用户在「+」里选了工作流、跑起来之后才出现的**独立 NSWindow**（守决策 #1：绝不碰灵动岛 frame；
/// 照 WorkflowGalleryController 那套）。展示：当前工作流 / 阶段进度 / 当前步流式产出 /
/// 人工确认卡 / 失败原因 / 最终产物 + 产物动作栏（复制 / 存为对话 / 生成网页）/ 中止入口。

@MainActor
final class RunPanelController: NSObject {
    static let shared = RunPanelController()
    private var window: NSWindow?
    /// 最近一次（正在跑 / 刚跑完）的活动模型 —— 重开同一条 run 时复用它（带实时进度 + 内存里的产物）。
    private var liveModel: RunModel?
    private override init() { super.init() }

    /// 展示一次运行。产物动作（存为对话 / 生成网页）从 run 数据 + vm 内建生成，不再外部注入。
    func show(model: RunModel, vm: ChatViewModel) {
        liveModel = model
        let run = model.run
        let mode = AgentMode(rawValue: run.modeRaw) ?? vm.agentMode
        let view = RunPanelView(
            model: model,
            onOpenInChat: { [weak vm] in
                vm?.createWorkflowResultConversation(content: model.productMarkdown,
                                                     title: run.workflowName, input: run.input, mode: mode)
            },
            onMakeWebpage: { [weak vm] in
                guard let vm else { return }
                ArtifactWindowController.shared.present(markdown: model.productMarkdown,
                                                        title: run.workflowName, mode: mode,
                                                        vm: vm, sourceMessageID: nil)
            },
            onClose: { [weak self] in self?.close() })
        // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 反推约束崩。本窗 .resizable + 流式
        // 长高（partialText/productMarkdown 不断变）→ 转 NSHostingController；建窗 + 复用两条分支都换。
        let hosting = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6：禁反推 setFrame

        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.level = HermesWindowLevel.artifact
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 380, height: 440)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
            win.setContentSize(NSSize(width: 460, height: 580))
            win.center()
            window = win
        } else {
            window?.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
        }
        window?.title = model.workflow.name
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 从聊天里的"查看运行过程"按钮重开某条 run：
    /// - 正在跑 / 刚跑完那条 → 复用 liveModel（实时进度 + 内存产物）
    /// - 更早的（已落盘）→ 从 `WorkflowRunStore` 重建只读快照（产物从 product 步骤的输出还原）
    func reopen(runID: String, vm: ChatViewModel) {
        if let m = liveModel, m.run.id == runID {
            show(model: m, vm: vm)
            return
        }
        guard let run = WorkflowRunStore.shared.record(id: runID) else { return }
        let wf = WorkflowRegistry.shared.workflow(id: run.workflowID) ?? Self.fallbackWorkflow(for: run)
        let snap = RunModel(run: run, workflow: wf)
        let prod = run.steps.last(where: { $0.kind == "product" && !$0.output.isEmpty })
                ?? run.steps.last(where: { !$0.output.isEmpty })
        snap.productMarkdown = prod?.output ?? ""
        snap.currentStepIndex = max(0, run.steps.count - 1)
        show(model: snap, vm: vm)
    }

    /// run 的来源 workflow 已不在注册表（远程/被删）时，造一个最小 Workflow 仅供面板取名字/图标/配色。
    private static func fallbackWorkflow(for run: WorkflowRun) -> Workflow {
        Workflow(id: run.workflowID, nameZh: run.workflowName, nameEn: run.workflowName,
                 summaryZh: "", summaryEn: "", icon: "wand.and.stars", accent: "#7C6CFF", category: "",
                 roleZh: "", roleEn: "", userTemplateZh: "", userTemplateEn: "",
                 inputHintZh: "", inputHintEn: "")
    }

    func close() { window?.orderOut(nil) }
}

// MARK: - 面板视图

struct RunPanelView: View {
    @Bindable var model: RunModel
    let onOpenInChat: () -> Void
    let onMakeWebpage: () -> Void
    let onClose: () -> Void

    private var accent: Color { model.workflow.accentColor }
    private var status: String { model.run.status }
    private var done: Bool { status == "succeeded" }
    private var hasProduct: Bool { done && !model.productMarkdown.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        stepList
                        if model.awaitingConfirm { confirmCard }
                        contentArea
                        if !model.evalReason.isEmpty && !done { evalNote }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                // 决策 #21：纯数据驱动 scrollTo，单一机制，无 GeometryReader / preference 反馈环
                .onChange(of: model.partialText.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.productMarkdown) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 440)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                Image(systemName: model.workflow.icon).font(.system(size: 16)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.workflow.name).font(.system(size: 14, weight: .semibold))
                Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if status == "running" || status == "awaitingConfirm" {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statusText: String {
        switch status {
        case "running":         return model.statusLine.isEmpty ? "运行中…" : model.statusLine
        case "awaitingConfirm": return "等待你确认…"
        case "succeeded":       return "已完成 · \(doneStepCount)/\(model.run.steps.count) 步"
        case "failed":          return "运行失败"
        case "aborted":         return "已中止"
        default:                return status
        }
    }
    private var doneStepCount: Int { model.run.steps.filter { $0.status == "succeeded" || $0.status == "skipped" }.count }

    // MARK: 阶段列表

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(model.run.steps.enumerated()), id: \.element.stepID) { idx, step in
                let isCurrent = idx == model.currentStepIndex && (status == "running" || status == "awaitingConfirm")
                HStack(alignment: .top, spacing: 9) {
                    stepGlyph(step.status, current: isCurrent)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(step.status == "pending" ? .secondary : .primary)
                        if let v = step.evalVerdict {
                            Text(v).font(.system(size: 11))
                                .foregroundStyle(step.status == "failed" ? .red : .secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stepGlyph(_ s: String, current: Bool) -> some View {
        switch s {
        case "succeeded": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case "skipped":   Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
        case "running":   ProgressView().controlSize(.small).scaleEffect(0.7)
        default:
            Image(systemName: current ? "circle.dotted" : "circle")
                .foregroundStyle(current ? accent : Color.secondary.opacity(0.5))
        }
    }

    // MARK: 主内容（产物 / 流式 / 占位）

    @ViewBuilder
    private var contentArea: some View {
        if hasProduct {
            VStack(alignment: .leading, spacing: 6) {
                Label("产物", systemImage: "doc.text.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                MarkdownTextView(content: model.productMarkdown)
                    .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04)))
        } else if !model.partialText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownTextView(content: model.partialText)
                    .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.03)))
        } else if status == "failed" {
            placeholder(icon: "exclamationmark.triangle", text: "没能产出结果，可关闭后重试。")
        } else if status == "running" {
            placeholder(icon: "sparkles", text: model.statusLine.isEmpty ? "桌宠正在按工作流一步步处理…" : model.statusLine)
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }

    // MARK: 人工确认卡

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("需要你确认：\(model.pendingConfirmTitle)")
                .font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 8) {
                Button("中止") { model.abort(); onClose() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("跳过这步") { model.resolveConfirm(.skip) }
                    .buttonStyle(.bordered)
                Button("允许") { model.resolveConfirm(.allow) }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.3), lineWidth: 1))
    }

    // MARK: 失败/扣分说明

    private var evalNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("验收提示", systemImage: "checkmark.seal").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(model.evalReason).font(.system(size: 11.5))
            if !model.evalSuggestion.isEmpty {
                Text("建议：\(model.evalSuggestion)").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    // MARK: 底部动作栏（"用户在工作流里选择之后才显示"的那些动作就在这里）

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if status == "running" || status == "awaitingConfirm" {
                Button(role: .destructive) { model.abort(); onClose() } label: {
                    Label("中止", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("运行中可随时中止").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else if hasProduct {
                Button { copyProduct() } label: { Label("复制", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                Spacer()
                Button { onOpenInChat(); onClose() } label: { Label("存为对话", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(.bordered)
                Button { onMakeWebpage() } label: { Label("生成网页", systemImage: "sparkles.rectangle.stack") }
                    .buttonStyle(.borderedProminent).tint(accent)
            } else {
                Spacer()
                Button("关闭") { onClose() }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func copyProduct() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.productMarkdown, forType: .string)
    }
}
