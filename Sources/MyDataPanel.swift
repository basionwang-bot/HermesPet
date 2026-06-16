import SwiftUI
import AppKit

// MARK: - 「我的数据」独立面板（v1.4.3 设置瘦身）
//
// 从设置·隐私页外移的数据浏览器：今日活动 / 今日观察(+黑名单) / 成长轨迹 / 共享记忆。
// 设置页只留开关和偏好，「看数据 / 删数据」都来这里。
// 窗口遵守决策 #6：NSHostingController + sizingOptions=[] + contentViewController + setContentSize 锁定几何。

@MainActor
final class MyDataWindowController {
    static let shared = MyDataWindowController()
    private var window: NSWindow?
    private static let panelSize = NSSize(width: 560, height: 540)

    func show() {
        if let w = window {
            w.title = L("settings.privacy.myData.title")
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = L("settings.privacy.myData.title")
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: MyDataPanelView())
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(Self.panelSize)   // 赋 contentViewController 后锁回原几何（决策 #6）
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - 面板主视图

struct MyDataPanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case activity, observation, growth, memory
        var id: String { rawValue }

        @MainActor
        var label: String {
            switch self {
            case .activity:    return L("settings.privacy.todayActivity.label")
            case .observation: return L("settings.privacy.observation.title")
            case .growth:      return L("settings.privacy.growth.title")
            case .memory:      return L("settings.privacy.memory.tabLabel")
            }
        }
    }

    @State private var tab: Tab = .activity

    // —— 今日活动 ——
    @State private var activityTodayStats: [AppDailyStat] = []
    @State private var showClearActivityConfirm = false

    // —— 今日观察（意图感知）+ 黑名单 ——
    @State private var intentObservations: [UserIntent] = []
    @State private var userBlacklist: [String] = []
    @State private var showClearIntentConfirm = false

    // —— 成长轨迹 ——
    @State private var journalEntries: [DailyJournalEntry] = []
    @State private var expandedJournalDate: String? = nil
    @State private var showClearJournalConfirm = false

    // —— 共享记忆 ——
    @State private var userMemoryText: String = ""
    @State private var userMemoryDirty = false
    @State private var showClearMemoryConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .activity:    activityTab
                    case .observation: observationTab
                    case .growth:      growthTab
                    case .memory:      memoryTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 540)
        .onAppear {
            refreshActivityStats()
            loadObservations()
            loadBlacklist()
            loadJournals()
            loadUserMemory()
        }
    }

    // MARK: - Tab 1：今日活动

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("settings.privacy.todayActivity.label"), systemImage: "chart.bar.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refreshActivityStats()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L("settings.common.refresh"))
            }

            if activityTodayStats.isEmpty {
                Text(L("settings.privacy.todayActivity.noDataEnabled"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(activityTodayStats) { stat in
                    HStack {
                        Text(stat.appName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(formatDuration(stat.totalSeconds))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(4)
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    showClearActivityConfirm = true
                } label: {
                    Label(L("settings.privacy.clearActivity.button"), systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    L("settings.privacy.clearActivity.confirmTitle"),
                    isPresented: $showClearActivityConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L("settings.common.confirmClear"), role: .destructive) {
                        ActivityRecorder.shared.clearAll()
                        refreshActivityStats()
                    }
                    Button(L("settings.common.reset"), role: .cancel) {}
                } message: {
                    Text(L("settings.privacy.clearActivity.confirmMessage"))
                }
            }
        }
    }

    private func refreshActivityStats() {
        // SQLite 聚合挪后台跑，结果回主 actor 赋值（与原设置页同款写法，避免主线程同步阻塞）
        let store = ActivityRecorder.shared.queryStore
        Task {
            let stats = await Task.detached(priority: .userInitiated) { () -> [AppDailyStat] in
                store.aggregateDailyStats(for: Date())
                return store.dailyStats(for: Date())
            }.value
            activityTodayStats = stats
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - Tab 2：今日观察 + 黑名单

    private var observationTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("settings.privacy.observation.title"), systemImage: "list.bullet.below.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !intentObservations.isEmpty {
                    Text(observationSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    loadObservations()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(L("settings.common.refresh"))
            }

            if intentObservations.isEmpty {
                Text(L("settings.privacy.observation.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 4) {
                    ForEach(intentObservations, id: \.id) { item in
                        observationRow(item)
                    }
                }
            }

            // 黑名单（仅有自定义黑名单时显示）
            if !userBlacklist.isEmpty {
                Divider().padding(.vertical, 4)
                blacklistList
            }

            HStack {
                Spacer()
                Button {
                    exportIntentsToJSON()
                } label: {
                    Label(L("settings.privacy.intent.exportJSON"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    showClearIntentConfirm = true
                } label: {
                    Label(L("settings.privacy.intent.clearButton"), systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    L("settings.privacy.intent.clearConfirmTitle"),
                    isPresented: $showClearIntentConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L("settings.common.confirmClear"), role: .destructive) {
                        ActivityRecorder.shared.queryStore.clearUserIntents()
                        loadObservations()
                    }
                    Button(L("settings.common.reset"), role: .cancel) {}
                } message: {
                    Text(L("settings.privacy.intent.clearConfirmMessage"))
                }
            }
        }
    }

    /// 单条观察记录（时间 + app 名 + window title + OCR 摘要 + 操作菜单）
    private func observationRow(_ item: UserIntent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(observationTime(item))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.appName ?? "?")
                        .font(.system(size: 11, weight: .medium))
                    if item.isBlacklisted {
                        Text(L("settings.privacy.observation.metaOnly"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let title = item.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let ocr = item.ocrText, !ocr.isEmpty {
                    Text(ocr.prefix(60))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                if let bid = item.appBundleID, !bid.isEmpty,
                   !userBlacklist.contains(bid) {
                    Button {
                        addToBlacklist(bundleID: bid, appName: item.appName)
                    } label: {
                        Label(L("settings.privacy.observation.dontRecord", item.appName ?? bid), systemImage: "eye.slash")
                    }
                }
                Button(role: .destructive) {
                    deleteObservation(id: item.id)
                } label: {
                    Label(L("settings.privacy.observation.deleteThis"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(4)
    }

    /// "今天 X 次 · 跨 Y 个应用"
    private var observationSummary: String {
        let count = intentObservations.count
        let uniqueApps = Set(intentObservations.compactMap { $0.appBundleID }).count
        return L("settings.privacy.observation.summary", count, uniqueApps)
    }

    private func observationTime(_ item: UserIntent) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: item.timestamp)
    }

    private func loadObservations() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let all = ActivityRecorder.shared.queryStore.recentUserIntents(limit: 500)
        intentObservations = all.filter { $0.timestamp >= startOfDay }
    }

    private func deleteObservation(id: Int) {
        ActivityRecorder.shared.queryStore.deleteUserIntent(id: id)
        loadObservations()
    }

    // —— 黑名单 ——

    private var blacklistList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(L("settings.privacy.blacklist.title"), systemImage: "eye.slash.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("settings.privacy.blacklist.count", userBlacklist.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 3) {
                ForEach(userBlacklist, id: \.self) { bundleID in
                    HStack {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(bundleID)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeFromBlacklist(bundleID: bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(4)
                }
            }
        }
    }

    private func loadBlacklist() {
        userBlacklist = UserDefaults.standard.array(forKey: "userIntentAppBlacklist") as? [String] ?? []
    }

    private func addToBlacklist(bundleID: String, appName: String?) {
        var arr = userBlacklist
        guard !arr.contains(bundleID) else { return }
        arr.append(bundleID)
        UserDefaults.standard.set(arr, forKey: "userIntentAppBlacklist")
        userBlacklist = arr
        NSLog("[UserIntent] 已加黑名单：\(appName ?? bundleID)")
    }

    private func removeFromBlacklist(bundleID: String) {
        let arr = userBlacklist.filter { $0 != bundleID }
        UserDefaults.standard.set(arr, forKey: "userIntentAppBlacklist")
        userBlacklist = arr
    }

    private func exportIntentsToJSON() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let all = ActivityRecorder.shared.queryStore.recentUserIntents(limit: 5000)
        let today = all.filter { $0.timestamp >= startOfDay }

        struct ExportRow: Codable {
            let timestamp: String
            let trigger: String
            let app: String?
            let windowTitle: String?
            let ocrText: String?
            let isBlacklisted: Bool
        }
        let fmt = ISO8601DateFormatter()
        let rows = today.map { item in
            ExportRow(
                timestamp: fmt.string(from: item.timestamp),
                trigger: item.triggerType.rawValue,
                app: item.appName,
                windowTitle: item.windowTitle,
                ocrText: item.ocrText,
                isBlacklisted: item.isBlacklisted
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rows) else {
            NSLog("[UserIntent] 导出 JSON 编码失败")
            return
        }

        let panel = NSSavePanel()
        panel.title = L("settings.privacy.export.panelTitle")
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "HermesPet-intents-\(fileFmt.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                NSLog("[UserIntent] 已导出到 \(url.path) (\(rows.count) 条)")
            } catch {
                NSLog("[UserIntent] 导出失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Tab 3：成长轨迹

    private var growthTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("settings.privacy.growth.title"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !journalEntries.isEmpty {
                    Text(L("settings.privacy.growth.days", journalEntries.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(L("settings.privacy.growth.caption"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if journalEntries.isEmpty {
                Text(L("settings.privacy.growth.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 4) {
                    ForEach(journalEntries) { entry in
                        journalRow(entry)
                    }
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        showClearJournalConfirm = true
                    } label: {
                        Label(L("settings.privacy.growth.clearButton"), systemImage: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .confirmationDialog(
                        L("settings.privacy.growth.clearConfirmTitle"),
                        isPresented: $showClearJournalConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L("settings.common.confirmClear"), role: .destructive) {
                            ActivityRecorder.shared.queryStore.clearDailyJournal()
                            loadJournals()
                        }
                        Button(L("settings.common.reset"), role: .cancel) {}
                    } message: {
                        Text(L("settings.privacy.growth.clearConfirmMessage"))
                    }
                }
            }
        }
    }

    /// 单条日报行：日期 + 一行预览，点开展开当天回顾全文；尾部菜单可删这天
    private func journalRow(_ entry: DailyJournalEntry) -> some View {
        let expanded = expandedJournalDate == entry.date
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.date)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                Text(journalPreview(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 1)
                Spacer(minLength: 4)
                Menu {
                    Button(role: .destructive) {
                        deleteJournal(date: entry.date)
                    } label: {
                        Label(L("settings.privacy.growth.deleteThisDay"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
            if expanded {
                Text(strippedJournal(entry.summaryMarkdown))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 82)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedJournalDate = expanded ? nil : entry.date
            }
        }
    }

    /// 去掉正文里的 ```docs 围栏（那是给聊天渲染可点卡片用的，纯文本预览里不显示）
    private func strippedJournal(_ md: String) -> String {
        guard let start = md.range(of: "```docs") else {
            return md.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = String(md[..<start.lowerBound])
        if let end = md.range(of: "```", range: start.upperBound..<md.endIndex) {
            result += String(md[end.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一行预览：取首个非空行，去掉 markdown 标记符号，截 60 字
    private func journalPreview(_ entry: DailyJournalEntry) -> String {
        let text = strippedJournal(entry.summaryMarkdown)
        let firstLine = text
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*-· "))
            .replacingOccurrences(of: "**", with: "")
        return String(cleaned.prefix(60))
    }

    private func loadJournals() {
        journalEntries = ActivityRecorder.shared.queryStore.recentDailyJournals(limit: 60)
    }

    private func deleteJournal(date: String) {
        ActivityRecorder.shared.queryStore.deleteDailyJournal(date: date)
        loadJournals()
    }

    // MARK: - Tab 4：共享记忆

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L("settings.privacy.memory.contentLabel"), systemImage: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("settings.privacy.memory.charCount", userMemoryText.count, UserMemoryStore.maxChars))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $userMemoryText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 280)
                .padding(6)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .onChange(of: userMemoryText) { _, _ in userMemoryDirty = true }

            if userMemoryText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(L("settings.privacy.memory.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button {
                    saveUserMemory()
                } label: {
                    Label(L("settings.privacy.memory.save"), systemImage: "checkmark")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!userMemoryDirty)

                Spacer()

                Button(role: .destructive) {
                    showClearMemoryConfirm = true
                } label: {
                    Label(L("settings.privacy.memory.clear"), systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    L("settings.privacy.memory.clearConfirmTitle"),
                    isPresented: $showClearMemoryConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L("settings.common.confirmClear"), role: .destructive) {
                        UserMemoryStore.shared.clear()
                        loadUserMemory()
                    }
                    Button(L("settings.common.reset"), role: .cancel) {}
                } message: {
                    Text(L("settings.privacy.memory.clearConfirmMessage"))
                }
            }
        }
    }

    private func loadUserMemory() {
        userMemoryText = UserMemoryStore.shared.load()
        userMemoryDirty = false
    }

    private func saveUserMemory() {
        UserMemoryStore.shared.save(userMemoryText)
        loadUserMemory()   // 回读（应用了截断等），并清 dirty
    }
}
