import SwiftUI

/// 历史对话面板 —— 覆盖在聊天窗内的一层。
///
/// 形态选择：**窗内覆盖层（不开新 NSWindow）**，避开决策 #1/#6 的跨窗口 setFrame 崩溃风险；
/// ScrollView **不裹 GeometryReader、不用 preference 测滚动**，守决策 #21。
///
/// 内容：顶部搜索框（中文走 LIKE 子串，稳）+ 按时间分组（今天/昨天/本周/更早）列出**全部**历史对话，
/// 点一条 → `openFromHistory` 重新打开继续聊。满 8 个被挤掉的对话都在这里能找回。
struct ConversationHistoryView: View {
    let viewModel: ChatViewModel
    var onClose: () -> Void

    @State private var query = ""
    @State private var summaries: [ConversationHistoryStore.Summary] = []
    @State private var archivedSummaries: [ConversationHistoryStore.Summary] = []
    @State private var showArchived = false
    @State private var totalCount = 0
    @State private var pendingDelete: ConversationHistoryStore.Summary?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .background(.regularMaterial)   // 盖住底下的聊天内容
        .task(id: query) { await reload() }
        .confirmationDialog(
            L("history.delete.confirm.title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button(L("history.delete"), role: .destructive) {
                viewModel.deleteFromHistory(id: item.id)
                pendingDelete = nil
                Task { await reload() }
            }
            Button(L("history.delete.cancel"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(L("history.delete.confirm.message"))
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            Text(L("history.title"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                KnowledgeGraphOverlayController.shared.show(viewModel: viewModel)
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text(L("history.view.graph"))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("graph.overlay.openHint"))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("history.close.help"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField(L("history.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if summaries.isEmpty {
            emptyState
        } else if trimmedQuery.isEmpty {
            groupedList
        } else {
            flatList
        }
    }

    /// 浏览态：按时间分组（粘性分组头）+ 底部归档折叠区
    private var groupedList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedSections, id: \.title) { section in
                    Section {
                        ForEach(section.items, id: \.rowKey) { row($0) }
                    } header: {
                        sectionHeader(section.title)
                    }
                }
                if !archivedSummaries.isEmpty { archivedDisclosure }
            }
            .padding(.bottom, 8)
        }
    }

    /// 已归档折叠区：默认收起，点开列出归档对话（每条可"恢复"）。归档≠删除，仍可搜可恢复。
    private var archivedDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showArchived.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Image(systemName: "archivebox").font(.system(size: 11))
                    Text(L("history.archived.section", archivedSummaries.count)).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showArchived {
                ForEach(archivedSummaries, id: \.rowKey) { archivedRow($0) }
            }
        }
    }

    /// 搜索态：扁平列表，保留相关度排序（标题命中在前）
    private var flatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(summaries, id: \.rowKey) { row($0) }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ item: ConversationHistoryStore.Summary) -> some View {
        Button { open(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(PetPaletteStore.shared.palette(for: item.mode).primary)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? L("history.title") : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !item.preview.isEmpty {
                        Text(item.preview)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                Text(relativeTime(item.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                starButton(item)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(HistoryRowButtonStyle())
        .contextMenu {
            Button { archive(item) } label: {
                Label(L("history.archive"), systemImage: "archivebox")
            }
            Button(role: .destructive) { pendingDelete = item } label: {
                Label(L("history.delete"), systemImage: "trash")
            }
        }
    }

    /// 行内加星按钮（加星 → 历史面板置顶 + 云图放大变亮）
    private func starButton(_ item: ConversationHistoryStore.Summary) -> some View {
        Button { toggleStar(item) } label: {
            Image(systemName: item.starred ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(item.starred ? Color.yellow : Color.secondary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.starred ? L("history.unstar") : L("history.star"))
    }

    /// 归档区的行（淡显 + "恢复"按钮）
    private func archivedRow(_ item: ConversationHistoryStore.Summary) -> some View {
        Button { open(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(PetPaletteStore.shared.palette(for: item.mode).primary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? L("history.title") : item.title)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if !item.preview.isEmpty {
                        Text(item.preview).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Button { restore(item) } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("history.archived.restore"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(HistoryRowButtonStyle())
        .contextMenu {
            Button { restore(item) } label: {
                Label(L("history.archived.restore"), systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { pendingDelete = item } label: {
                Label(L("history.delete"), systemImage: "trash")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(.regularMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: trimmedQuery.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(trimmedQuery.isEmpty ? L("history.empty") : L("history.empty.search"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func open(_ item: ConversationHistoryStore.Summary) {
        viewModel.openFromHistory(id: item.id)
        onClose()
    }

    /// 后台读库（不阻塞主线程），结果回主线程赋值。`.task(id: query)` 在 query 变化时自动重跑。
    private func reload() async {
        let q = trimmedQuery
        // 打开/刷新时先自动归档老对话（超 90 天没碰、未加星）→ 默认列表干净
        await Task.detached(priority: .utility) {
            ConversationHistoryStore.shared.autoArchive(olderThanDays: 90)
        }.value
        let results = await Task.detached(priority: .userInitiated) {
            q.isEmpty
                ? ConversationHistoryStore.shared.recent()
                : ConversationHistoryStore.shared.search(q)
        }.value
        let archived = await Task.detached(priority: .utility) {
            ConversationHistoryStore.shared.recent(scope: .archived)
        }.value
        let total = await Task.detached(priority: .utility) {
            ConversationHistoryStore.shared.count()
        }.value
        summaries = results
        archivedSummaries = archived
        totalCount = total
    }

    // MARK: - 加星 / 归档动作

    private func toggleStar(_ item: ConversationHistoryStore.Summary) {
        let newVal = !item.starred
        ConversationHistoryStore.shared.setStarred(id: item.id, newVal)   // 后台写库
        // 乐观更新：本地立刻翻转 → 即时变黄 + 跳「置顶」分组（带动画），不等后台往返
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if let idx = summaries.firstIndex(where: { $0.id == item.id }) {
                summaries[idx].starred = newVal
            }
        }
        Task { await reload() }   // 后台最终校正（一致性 + 自动归档）
    }
    private func archive(_ item: ConversationHistoryStore.Summary) {
        ConversationHistoryStore.shared.setArchived(id: item.id, true)
        // 乐观更新：立刻从默认列表移除（收进归档区由 reload 补齐）
        withAnimation(.easeOut(duration: 0.22)) {
            summaries.removeAll { $0.id == item.id }
        }
        Task { await reload() }
    }
    private func restore(_ item: ConversationHistoryStore.Summary) {
        ConversationHistoryStore.shared.setArchived(id: item.id, false)
        // 乐观更新：立刻从归档区移除（回到默认列表由 reload 补齐）
        withAnimation(.easeOut(duration: 0.22)) {
            archivedSummaries.removeAll { $0.id == item.id }
        }
        Task { await reload() }
    }

    // MARK: - 时间分组

    private struct Section2 { let title: String; let items: [ConversationHistoryStore.Summary] }

    private var groupedSections: [Section2] {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) ?? startToday
        let startWeek = cal.date(byAdding: .day, value: -7, to: startToday) ?? startToday

        var today: [ConversationHistoryStore.Summary] = []
        var yesterday: [ConversationHistoryStore.Summary] = []
        var thisWeek: [ConversationHistoryStore.Summary] = []
        var earlier: [ConversationHistoryStore.Summary] = []
        var pinned: [ConversationHistoryStore.Summary] = []
        for s in summaries {   // 已按 starred DESC, updated_at 倒序
            if s.starred { pinned.append(s); continue }   // 加星 → 置顶分组，不再进时间组
            if s.updatedAt >= startToday { today.append(s) }
            else if s.updatedAt >= startYesterday { yesterday.append(s) }
            else if s.updatedAt >= startWeek { thisWeek.append(s) }
            else { earlier.append(s) }
        }
        var out: [Section2] = []
        if !pinned.isEmpty { out.append(Section2(title: L("history.section.pinned"), items: pinned)) }
        if !today.isEmpty { out.append(Section2(title: L("history.section.today"), items: today)) }
        if !yesterday.isEmpty { out.append(Section2(title: L("history.section.yesterday"), items: yesterday)) }
        if !thisWeek.isEmpty { out.append(Section2(title: L("history.section.thisWeek"), items: thisWeek)) }
        if !earlier.isEmpty { out.append(Section2(title: L("history.section.earlier"), items: earlier)) }
        return out
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: LocaleManager.currentLanguage() == .zh ? "zh_CN" : "en_US")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// 列表行的悬停高亮（按下/悬停加一层淡背景）
private struct HistoryRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : (hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
