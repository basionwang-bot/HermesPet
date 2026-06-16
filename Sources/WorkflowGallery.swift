import SwiftUI
import AppKit

/// 工作流「陈列页」—— 复用网页展览馆(ArtifactGallery)那套:独立窗 + 卡片网格。
/// 点卡片 → 发通知激活该 workflow(AppDelegate 接住 → vm.activateWorkflow + 唤起聊天窗)。

@MainActor
final class WorkflowGalleryController: NSObject {
    static let shared = WorkflowGalleryController()
    private var window: NSWindow?
    private override init() { super.init() }

    func toggle() { if let w = window, w.isVisible { w.orderOut(nil) } else { show() } }

    func show() {
        if window == nil {
            // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 反推约束崩 → 转 NSHostingController。
            let hosting = NSHostingController(rootView: WorkflowGalleryView())
            if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "工作流"
            win.level = HermesWindowLevel.artifact
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 480, height: 380)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
            win.setContentSize(NSSize(width: 760, height: 560))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }
}

struct WorkflowGalleryView: View {
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 330), spacing: 14)]

    var body: some View {
        let items = WorkflowRegistry.shared.workflows
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("选一个工作流,桌宠帮你把这件事做好")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 14)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(items) { wf in WorkflowCard(workflow: wf) }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct WorkflowCard: View {
    let workflow: Workflow
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 渐变封面 + 图标
            ZStack {
                LinearGradient(colors: [workflow.accentColor.opacity(0.9), workflow.accentColor.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: workflow.icon)
                    .font(.system(size: 28)).foregroundStyle(.white)
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(workflow.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(workflow.summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(workflow.category)
                        .font(.system(size: 10)).foregroundStyle(workflow.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(workflow.accentColor.opacity(0.12)))
                    Spacer()
                    let n = WorkflowTelemetry.runCount(id: workflow.id)
                    if n > 0 {
                        Text("用过 \(n) 次").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            NotificationCenter.default.post(name: .init("HermesPetActivateWorkflow"),
                                            object: nil, userInfo: ["id": workflow.id])
            WorkflowGalleryController.shared.close()
        }
    }
}
