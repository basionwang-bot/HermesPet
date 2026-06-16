import SwiftUI
import AppKit

// MARK: - 聊天气泡里的「查看网页」链接

/// 某条 AI 回答生成过网页时，气泡底部挂的可点链接 —— 点开重新打开那张网页。
struct ArtifactLinkChip: View {
    let record: ArtifactRecord
    @State private var hovering = false

    var body: some View {
        Button {
            ArtifactWindowController.shared.reopen(artifactID: record.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "safari.fill").font(.system(size: 11))
                Text("查看网页").font(.system(size: 12, weight: .medium))
                Text(record.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.indigo)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.indigo.opacity(hovering ? 0.16 : 0.10)))
            .overlay(Capsule().stroke(Color.indigo.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 网页展览馆窗口

@MainActor
final class ArtifactGalleryController: NSObject {
    static let shared = ArtifactGalleryController()
    private var window: NSWindow?
    private override init() { super.init() }

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil) } else { show() }
    }

    func show() {
        if window == nil {
            // 决策 #6：裸 NSHostingView 当 contentView 在 macOS 26.5+ 反推约束崩 → 转 NSHostingController。
            let hosting = NSHostingController(rootView: ArtifactGalleryView())
            if #available(macOS 13.0, *) { hosting.sizingOptions = [] }   // 决策 #6
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "网页展览馆"
            win.level = HermesWindowLevel.artifact
            win.isReleasedWhenClosed = false
            win.contentMinSize = NSSize(width: 460, height: 360)
            win.contentViewController = hosting
            hosting.view.autoresizingMask = [.width, .height]
            win.setContentSize(NSSize(width: 760, height: 560))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 展览馆视图

struct ArtifactGalleryView: View {
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)]

    var body: some View {
        let records = ArtifactStore.shared.records    // body 是 MainActor，读这里即建立 Observation 依赖
        return Group {
            if records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(records) { rec in
                            ArtifactGalleryCard(record: rec)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("还没有生成过网页").font(.system(size: 15, weight: .semibold))
            Text("在聊天里点 ✨ 生成网页，或会议纪要里生成，做过的都会收进这里")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单张网页卡 —— 顶部 mode 主色渐变 + 🌐，下方标题/时间，hover 出删除。
struct ArtifactGalleryCard: View {
    let record: ArtifactRecord
    @State private var hovering = false

    private var tint: Color {
        if let raw = record.modeRaw, let mode = AgentMode(rawValue: raw) {
            return PetPaletteStore.shared.palette(for: mode).primary
        }
        return .indigo
    }

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: record.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 渐变封面
            ZStack {
                LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "safari.fill")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.9))
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { ArtifactStore.shared.delete(id: record.id) } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 10)).foregroundStyle(.white)
                            .padding(6).background(Circle().fill(.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain).padding(6)
                    .help("删除这张网页")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(dateText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { ArtifactWindowController.shared.reopen(artifactID: record.id) }
    }
}
