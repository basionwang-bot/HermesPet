import SwiftUI
import AppKit

// MARK: - HermesPet 博物馆(⑥ 统一馆:网页 artifact + 舰队产出 同处陈列/回看/复用)
//
// 用户明确"别跟网页收藏分家"。所以这里是一个**统一视图**,同时读两个 Store:
// · ArtifactStore(生成过的网页)
// · FleetArchiveStore(完成的舰队运行,含可复用的 CaptainPlan 脚本)
// 卡片混排、按时间倒序;舰队卡可点开回看过程 + 一键"复用这套流程"。

@MainActor
final class MuseumController: NSObject {
    static let shared = MuseumController()
    private var window: NSWindow?
    private weak var vm: ChatViewModel?
    private override init() { super.init() }

    func show(vm: ChatViewModel) {
        self.vm = vm
        // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 反推约束崩 → 转 NSHostingController；
        // 建窗 + 复用两条分支都换（复用分支不 setContentSize，保住用户拖过的尺寸）。
        let hosting = NSHostingController(rootView: MuseumView(vm: vm))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6

        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "HermesPet 博物馆"
            win.level = HermesWindowLevel.artifact
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 520, height: 400)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
            win.setContentSize(NSSize(width: 820, height: 600))
            win.center()
            window = win
        } else {
            window?.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 统一藏品项(网页 / 舰队混排)

private enum MuseumItem: Identifiable {
    case artifact(ArtifactRecord)
    case fleet(FleetArchive)

    var id: String {
        switch self {
        case .artifact(let r): return "art-" + r.id
        case .fleet(let a):    return "fleet-" + a.id
        }
    }
    var createdAt: Date {
        switch self {
        case .artifact(let r): return r.createdAt
        case .fleet(let a):    return a.createdAt
        }
    }
}

private enum MuseumFilter: String, CaseIterable, Identifiable {
    case all = "全部", web = "网页", fleet = "舰队"
    var id: String { rawValue }
}

// MARK: - 博物馆主视图

struct MuseumView: View {
    let vm: ChatViewModel
    @State private var filter: MuseumFilter = .all
    @State private var detail: FleetArchive? = nil

    private let accent = Color(red: 0.486, green: 0.424, blue: 1.0)
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)]

    // body(MainActor)里读 .shared.records 即建立 Observation 依赖(镜像 ArtifactGalleryView)。
    private var items: [MuseumItem] {
        var list: [MuseumItem] = []
        if filter != .fleet { list += ArtifactStore.shared.records.map { .artifact($0) } }
        if filter != .web { list += FleetArchiveStore.shared.records.map { .fleet($0) } }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { item in
                            switch item {
                            case .artifact(let rec):
                                ArtifactGalleryCard(record: rec)
                            case .fleet(let arc):
                                FleetArchiveCard(archive: arc, accent: accent) { detail = arc }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(item: $detail) { arc in
            FleetArchiveDetailView(archive: arc, vm: vm, accent: accent) { detail = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "building.columns.fill").foregroundStyle(accent)
            Text("HermesPet 博物馆").font(.system(size: 15, weight: .semibold))
            Text("\(items.count) 件藏品").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $filter) {
                ForEach(MuseumFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.columns")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.5))
            Text(filter == .web ? "还没生成过网页" : filter == .fleet ? "还没有舰队产出" : "博物馆还空着")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            Text("生成的网页、跑完的全量模式任务都会自动收藏到这儿")
                .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - 舰队产出卡

private struct FleetArchiveCard: View {
    let archive: FleetArchive
    let accent: Color
    let onOpen: () -> Void
    @State private var hovering = false

    private var tint: Color { Color(hex: archive.companyTintHex) ?? accent }
    private var dateText: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: archive.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: archive.companySymbol)
                    .font(.system(size: 28)).foregroundStyle(.white.opacity(0.9))
                // 左上角"舰队"徽标 + 右上角删除
                VStack { Spacer() }   // 撑满
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                Label("舰队", systemImage: "person.3.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.28)))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { FleetArchiveStore.shared.delete(id: archive.id) } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 10)).foregroundStyle(.white)
                            .padding(6).background(Circle().fill(.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain).padding(6)
                    .help("从博物馆移除")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(archive.topic.isEmpty ? archive.companyName : archive.topic)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(archive.companyName).foregroundStyle(tint)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(archive.memberCount) 人").foregroundStyle(.secondary)
                    if archive.plan != nil {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                Text(dateText).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.18), lineWidth: 0.5))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - 舰队存档详情(回看过程 + 复用流程 + 落地)

private struct FleetArchiveDetailView: View {
    let archive: FleetArchive
    let vm: ChatViewModel
    let accent: Color
    let onClose: () -> Void
    @State private var copied = false

    private var tint: Color { Color(hex: archive.companyTintHex) ?? accent }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏 + 动作
            HStack(spacing: 8) {
                Image(systemName: archive.companySymbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(archive.topic.isEmpty ? archive.companyName : archive.topic)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(archive.companyName) · \(archive.memberCount) 人 · v\(archive.versionCount)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { onClose() }.buttonStyle(.borderedProminent).tint(accent)
            }.padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 复用 / 生成网页 / 落地 动作栏
                    HStack(spacing: 10) {
                        if archive.plan != nil {
                            Button { reuse() } label: {
                                Label("复用这套流程", systemImage: "arrow.triangle.2.circlepath")
                            }.buttonStyle(.borderedProminent).tint(accent)
                        }
                        Button { makeWebpage() } label: {
                            Label("生成网页", systemImage: "sparkles.rectangle.stack")
                        }.buttonStyle(.bordered)
                        Button { saveAsChat() } label: {
                            Label("存为对话", systemImage: "bubble.left.and.text.bubble.right")
                        }.buttonStyle(.bordered)
                        Button { copyProduct() } label: {
                            Label(copied ? "已复制" : "复制成品", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(.bordered)
                        if let path = archive.productPath, FileManager.default.fileExists(atPath: path) {
                            Button { revealMD(path) } label: {
                                Label("MD 文档", systemImage: "doc.text")
                            }.buttonStyle(.bordered).help("在 Finder 里查看成果.md")
                        }
                        Spacer()
                    }

                    // 作战计划(脚本)概览
                    if let plan = archive.plan, !plan.strategy.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("作战计划", systemImage: "map.fill")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                            Text(plan.strategy).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.06)))
                    }

                    // 回看过程:各成员干了啥
                    if !archive.members.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("过程 · \(archive.members.count) 位成员", systemImage: "person.3.sequence.fill")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(archive.members) { m in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Image(systemName: FleetRole(rawValue: m.roleKey)?.symbol ?? "person.fill")
                                            .font(.system(size: 10)).foregroundStyle(tint)
                                        Text(m.title).font(.system(size: 11.5, weight: .semibold))
                                        Text(m.task).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if !m.outputExcerpt.isEmpty {
                                        Text(m.outputExcerpt)
                                            .font(.system(size: 10.5)).foregroundStyle(.secondary.opacity(0.85))
                                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.03)))
                            }
                        }
                    }

                    // 最终成品
                    VStack(alignment: .leading, spacing: 6) {
                        Label("成品", systemImage: "doc.richtext")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        MarkdownTextView(content: String(archive.product.prefix(8000)))
                            .font(.system(size: 12.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04)))
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func reuse() {
        guard let plan = archive.plan else { return }
        onClose()
        FleetTheaterController.shared.presentAndReuse(vm: vm, plan: plan, topic: archive.topic)
    }
    private func makeWebpage() {
        // 复用现成的 Markdown→网页 流水线;生成的网页会自动进 ArtifactStore → 也出现在博物馆"网页"那半
        ArtifactWindowController.shared.present(
            markdown: archive.product,
            title: archive.topic.isEmpty ? archive.companyName : archive.topic,
            mode: AgentMode(rawValue: archive.modeRaw) ?? vm.agentMode,
            vm: vm, sourceMessageID: nil)
        onClose()
    }
    private func revealMD(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    private func saveAsChat() {
        vm.createWorkflowResultConversation(content: archive.product,
                                            title: "舰队 · " + archive.companyName,
                                            input: archive.topic,
                                            mode: AgentMode(rawValue: archive.modeRaw) ?? vm.agentMode)
        onClose()
    }
    private func copyProduct() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(archive.product, forType: .string)
        copied = true
    }
}
