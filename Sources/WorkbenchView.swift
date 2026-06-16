import SwiftUI
import AppKit

/// 「HermesPet 工作空间」—— 真实 AI 工作台（多标签页，每个 tab 一个文件夹工作环境）。
///
/// 视觉基调 = **专业克制（Linear/Arc 式）**：三级明度台阶（背景→栏→卡片）、大留白、极轻阴影、
/// 彩色文件类型图标、克制的 hover/选中过渡。所有颜色读 `WorkbenchThemeStore.shared.current`（双层主题）。
///
/// 布局可灵活：左/右栏**可拖拽调宽 + 一键折叠**（@AppStorage 记住偏好）。守决策 #21（ScrollView 不被 GeometryReader 包）。
struct WorkbenchView: View {
    var onClose: (() -> Void)? = nil
    var topInset: CGFloat = 0

    @State private var ws = WorkspaceState.shared   // 单例：关掉重开保留 tab / 对话历史
    @State private var pulse = false
    @State private var showNoRepo = false
    @State private var graduatedAlert = false

    // 布局灵活：可调栏宽 + 可折叠（记住用户偏好）
    @AppStorage("workbench.leftWidth.v2")  private var leftWidth: Double = 248
    @AppStorage("workbench.rightWidth.v2") private var rightWidth: Double = 344
    @AppStorage("workbench.showLeft.v2")   private var showLeft = true
    @AppStorage("workbench.showRight.v2")  private var showRight = true
    @State private var leftDragStart: Double?
    @State private var rightDragStart: Double?
    @State private var hoveredFile: URL?
    @State private var imageZoom: CGFloat = 1
    @State private var htmlShowSource = false   // HTML 预览：渲染网页(false) / 看源码(true)
    @State private var showSkills = false   // 技能库点开才显示（不常驻右栏）
    @State private var showSchool = false   // 「AI 学校」栏（陈列 AgentForge 课程）

    private var theme: WorkbenchTheme { WorkbenchThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            if topInset > 0 { Color.black.frame(height: topInset) }
            workbenchBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, theme.colorScheme)
        .onAppear { withAnimation(AnimTok.breathe) { pulse = true } }
        // 真实 AI 工具事件 → 归到发起命令的 tab（决策 #13）。
        // ⭐ 审计 #7 串扰修复：task 生命周期改听**带 tag 的**工作台专属通知（runWorkbenchCommand 发），
        // 按 sessionTag 精确落到发起命令的 tab；不再听全局 HermesPetTaskStarted/Finished —— 否则舰队/
        // 工作流/早报等任何地方的全局 TaskFinished 都会把工作台当前 tab 的 aiWorking 翻 false、给最后一轮标错。
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetWorkbenchTaskStarted"))) { note in
            (ws.tab(forTag: note.userInfo?["tag"] as? String) ?? ws.active).taskStarted()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetWorkbenchTaskFinished"))) { note in
            (ws.tab(forTag: note.userInfo?["tag"] as? String) ?? ws.active).taskFinished(success: note.userInfo?["success"] as? Bool ?? true)
        }
        // 工具明细（哪个文件）来自 client 全局通知、无 tag → 只在 active tab 真在干活时才装饰，
        // 避免别处 AI 的工具事件污染空闲的工作台 tab（残留：工作台与舰队同时跑时 active tab 会蹭到对方明细，可接受）。
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolStarted"))) { note in
            guard ws.active.aiWorking else { return }
            ws.active.toolStarted(name: note.userInfo?["name"] as? String ?? "处理中",
                                  filePath: note.userInfo?["file_path"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetToolEnded"))) { note in
            guard ws.active.aiWorking else { return }
            ws.active.toolEnded(filePath: note.userInfo?["file_path"] as? String)
        }
        // AI 流式文字回复 → 按 tag 落到发起命令的 tab（决策 #13 之外的文字通道）
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetWorkbenchReply"))) { note in
            guard let delta = note.userInfo?["delta"] as? String else { return }
            (ws.tab(forTag: note.userInfo?["tag"] as? String) ?? ws.active).appendReply(delta)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("HermesPetGraduated"))) { _ in
            graduatedAlert = true
        }
        .alert("🎓 毕业啦！", isPresented: $graduatedAlert) {
            Button("好的") {}
        } message: {
            Text("AI 上学回来了，新技能已经进了技能库。看看右边技能墙上的 🎓 新卡片吧。")
        }
        .alert("没找到 AgentForge 仓库", isPresented: $showNoRepo) {
            Button("知道了") {}
        } message: {
            Text("请把 agent-forge 仓库放到 ~/agent-forge（或在设置里指定 agentForgePath）。")
        }
    }

    private var workbenchBody: some View {
        VStack(spacing: 0) {
            topBar
            if showSchool {
                Rectangle().fill(theme.hairline).frame(height: 1)
                WorkbenchSchoolView(theme: theme) { course in
                    if ws.enrollInCourse(course) { showSchool = false } else { showNoRepo = true }
                }
            } else {
                tabBar
                Rectangle().fill(theme.hairline).frame(height: 1)
                columns
            }
        }
        .background(
            LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: 顶栏（导航 / 标题 / 折叠 / 主题）

    private var topBar: some View {
        HStack(spacing: 12) {
            if let onClose {
                Button { onClose() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                        Text("收回").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(theme.surface1))
                    .overlay(Capsule().strokeBorder(theme.panelStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            ModeSpriteView(mode: .directAPI, isWorking: ws.active.aiWorking, size: 24)
            Text("工作空间").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)

            // 「AI 学校」开关 —— 进/出课程目录
            Button { withAnimation(AnimTok.smooth) { showSchool.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 11))
                    Text(showSchool ? "返回工作台" : "学校").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(showSchool ? .white : theme.textSecondary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(showSchool ? theme.accent : theme.surface1))
                .overlay(Capsule().strokeBorder(showSchool ? Color.clear : theme.panelStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("AI 学校 —— 挑一门 AgentForge 课程让 AI 去学")
            .padding(.leading, 4)

            Spacer()

            // 折叠左 / 右栏
            iconToggle(systemName: "sidebar.left", on: showLeft) { withAnimation(AnimTok.smooth) { showLeft.toggle() } }
                .help("折叠/展开文件栏")
            iconToggle(systemName: "sidebar.right", on: showRight) { withAnimation(AnimTok.smooth) { showRight.toggle() } }
                .help("折叠/展开 AI 栏")

            // 尺寸档（仅刘海全屏模式）
            if onClose != nil {
                ForEach(WorkbenchSize.allCases, id: \.self) { s in
                    Button {
                        WorkbenchThemeStore.shared.selectSize(s)
                        SystemStatsPanelController.shared?.relayoutWorkspace()
                    } label: {
                        Image(systemName: s.symbol).font(.system(size: 11))
                            .foregroundStyle(WorkbenchThemeStore.shared.size == s ? .white : theme.textSecondary)
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7).fill(WorkbenchThemeStore.shared.size == s ? theme.accent : theme.surface1))
                    }
                    .buttonStyle(.plain).help(s.label)
                }
            }

            // 主题切换（segmented）
            HStack(spacing: 2) {
                ForEach(WorkbenchTheme.all) { t in
                    Button {
                        withAnimation(AnimTok.smooth) { WorkbenchThemeStore.shared.select(t) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: t.symbol).font(.system(size: 10))
                            Text(t.name).font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(t.id == theme.id ? .white : theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(t.id == theme.id ? theme.accent : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(theme.surface1))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.panelStroke, lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func iconToggle(systemName: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 13))
                .foregroundStyle(on ? theme.accent : theme.textSecondary)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.accent.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: 标签页栏（浏览器式）

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(ws.tabs) { tab in tabChip(tab) }
                Button { ws.newTab() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface1))
                }
                .buttonStyle(.plain).help("新建工作环境")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == ws.activeID
        return HStack(spacing: 6) {
            Image(systemName: tab.isSchool ? "graduationcap.fill" : (tab.folderURL == nil ? "square.dashed" : "folder.fill"))
                .font(.system(size: 10))
                .foregroundStyle(isActive ? (tab.isSchool ? Color.green : theme.accent) : theme.textTertiary)
            Text(tab.title).font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary).lineLimit(1)
            if ws.tabs.count > 1 {
                Button { ws.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isActive ? theme.surface2 : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isActive ? theme.panelStroke : Color.clear, lineWidth: 1))
        .shadow(color: isActive ? theme.cardShadow : .clear, radius: isActive ? theme.cardShadowRadius : 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { ws.activeID = tab.id }
    }

    // MARK: 三栏（可拖拽调宽 + 可折叠）

    private var columns: some View {
        HStack(spacing: 0) {
            if showLeft {
                fileColumn.frame(width: leftWidth)
                resizeHandle(left: true)
            }
            previewColumn.frame(maxWidth: .infinity)
            if showRight {
                resizeHandle(left: false)
                activityColumn.frame(width: rightWidth)
            }
        }
    }

    private func resizeHandle(left: Bool) -> some View {
        Rectangle().fill(theme.hairline).frame(width: 1)
            .overlay(
                Rectangle().fill(Color.clear).frame(width: 10).contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.resizeLeftRight.set() : NSCursor.arrow.set() }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            if left {
                                if leftDragStart == nil { leftDragStart = leftWidth }
                                leftWidth = clampD((leftDragStart ?? leftWidth) + Double(v.translation.width), 190, 440)
                            } else {
                                if rightDragStart == nil { rightDragStart = rightWidth }
                                rightWidth = clampD((rightDragStart ?? rightWidth) - Double(v.translation.width), 290, 540)
                            }
                        }
                        .onEnded { _ in leftDragStart = nil; rightDragStart = nil })
            )
    }

    // MARK: 左：真实文件树

    private var fileColumn: some View {
        let tab = ws.active
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(tab.folderURL?.lastPathComponent ?? "文件", "folder", trailing: tab.folderURL != nil ? { AnyView(
                Button { tab.pickFolder() } label: {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }.buttonStyle(.plain).help("换文件夹")
            ) } : nil)
            if tab.folderURL == nil {
                emptyState(icon: "folder.badge.plus", title: "打开一个文件夹开始",
                           action: ("打开文件夹", { tab.pickFolder() }))
            } else {
                breadcrumbBar(tab)
                Rectangle().fill(theme.hairline).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if tab.folderURL?.path != "/" {
                            plainRow(name: "..", icon: "arrow.up", color: theme.textTertiary) { tab.goUp() }
                        }
                        ForEach(tab.entries) { e in fileRow(e, tab: tab) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
        .background(theme.surface1)
    }

    private func fileRow(_ e: WorkspaceTab.FileEntry, tab: WorkspaceTab) -> some View {
        let isSel = tab.selected == e.url
        let isHover = hoveredFile == e.url
        let (icon, color) = fileGlyph(e.url, isDir: e.isDir)
        let changed = tab.changedNames.contains(e.name)
        return HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13.5)).foregroundStyle(color).frame(width: 18)
            Text(e.name).font(.system(size: 13)).foregroundStyle(theme.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            if changed { Circle().fill(Color.green).frame(width: 6, height: 6) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSel ? theme.accent.opacity(0.14) : (isHover ? theme.textPrimary.opacity(0.05) : .clear))
        )
        .overlay(alignment: .leading) {
            if isSel { Capsule().fill(theme.accent).frame(width: 2.5, height: 15) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredFile = e.url } else if hoveredFile == e.url { hoveredFile = nil }
        }
        .onTapGesture { tab.select(e) }
    }

    private func plainRow(name: String, icon: String, color: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color).frame(width: 18)
                Text(name).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    /// 彩色文件类型图标（专业克制的关键质感）
    private func fileGlyph(_ url: URL, isDir: Bool) -> (String, Color) {
        if isDir { return ("folder.fill", theme.accent) }
        switch url.pathExtension.lowercased() {
        case "png","jpg","jpeg","gif","heic","webp","bmp","tiff","svg":
            return ("photo.fill", Color(red: 0.96, green: 0.55, blue: 0.32))
        case "md","txt","rtf","markdown":
            return ("doc.text.fill", Color(red: 0.30, green: 0.62, blue: 0.98))
        case "swift","js","ts","tsx","jsx","py","c","cpp","h","go","rs","java","sh","rb":
            return ("chevron.left.forwardslash.chevron.right", Color(red: 0.66, green: 0.52, blue: 0.98))
        case "json","yaml","yml","toml","xml","plist":
            return ("curlybraces", Color(red: 0.36, green: 0.78, blue: 0.52))
        case "pdf":
            return ("doc.richtext.fill", Color(red: 0.92, green: 0.36, blue: 0.36))
        case "csv","xlsx","xls","numbers":
            return ("tablecells.fill", Color(red: 0.36, green: 0.78, blue: 0.52))
        case "zip","tar","gz","dmg","7z":
            return ("shippingbox.fill", theme.textSecondary)
        case "html","css":
            return ("globe", Color(red: 0.30, green: 0.62, blue: 0.98))
        default:
            return ("doc.fill", theme.textSecondary)
        }
    }

    // MARK: 中：真实预览

    private var previewColumn: some View {
        let tab = ws.active
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(tab.selected?.lastPathComponent ?? "预览", previewHeaderIcon(tab),
                         trailing: previewHeaderTrailing(tab))
            previewContent(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
        )
        .onChange(of: tab.selected) { _ in imageZoom = 1; htmlShowSource = false }
    }

    /// 预览列头右侧附件：图片→缩放条；HTML→预览/源码切换；其余无。
    private func previewHeaderTrailing(_ tab: WorkspaceTab) -> (() -> AnyView)? {
        switch tab.previewKind {
        case .image: return { AnyView(imageZoomBar) }
        case .web:   return { AnyView(htmlSourceToggle) }
        default:     return nil
        }
    }

    /// HTML 预览/源码 分段切换。
    private var htmlSourceToggle: some View {
        HStack(spacing: 2) {
            ForEach([("预览", "globe", false), ("源码", "chevron.left.forwardslash.chevron.right", true)], id: \.0) { item in
                Button { htmlShowSource = item.2 } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.1).font(.system(size: 10))
                        Text(item.0).font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(htmlShowSource == item.2 ? .white : theme.textSecondary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(htmlShowSource == item.2 ? theme.accent : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.surface1))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.panelStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func previewContent(_ tab: WorkspaceTab) -> some View {
        switch tab.previewKind {
        case .image:
            if let img = tab.previewImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(width: 520 * imageZoom)
                        .padding(20)
                }
            }
        case .markdown:
            ScrollView {
                MarkdownTextView(content: tab.previewText ?? "", tint: theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        case .code:
            CodeTextView(attributed: tab.previewAttributed ?? NSAttributedString(string: tab.previewText ?? ""),
                         background: theme.backgroundTop)
        case .web:
            if htmlShowSource {
                CodeTextView(attributed: tab.previewAttributed ?? NSAttributedString(string: tab.previewText ?? ""),
                             background: theme.backgroundTop)
            } else {
                ArtifactWebView(fileURL: tab.selected)   // WKWebView 渲染本地 HTML
            }
        case .pdf:
            PDFKitView(url: tab.selected)
        case .plain:
            ScrollView {
                Text(tab.previewText ?? "")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).padding(20)
            }
        case .none:
            if tab.selected != nil { centerHint("此文件类型暂不支持预览", "doc") }
            else { centerHint("从左边选一个文件查看内容", "sidebar.left") }
        }
    }

    private func previewHeaderIcon(_ tab: WorkspaceTab) -> String {
        switch tab.previewKind {
        case .image: return "photo"
        case .markdown: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .web: return "globe"
        case .pdf: return "doc.richtext.fill"
        case .plain: return "doc.text"
        case .none: return "doc.text.magnifyingglass"
        }
    }

    private var imageZoomBar: some View {
        HStack(spacing: 8) {
            Button { imageZoom = max(0.2, imageZoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
            Text("\(Int(imageZoom * 100))%").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.textTertiary).frame(width: 40)
            Button { imageZoom = min(5, imageZoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(theme.textSecondary)
            Button { imageZoom = 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(theme.textSecondary).help("适应")
        }
        .font(.system(size: 12))
    }

    // MARK: 面包屑（可点击各级跳转）

    private func breadcrumbBar(_ tab: WorkspaceTab) -> some View {
        let comps = pathChain(tab.folderURL)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(comps.enumerated()), id: \.offset) { i, item in
                    Button { tab.openFolder(item.url) } label: {
                        Text(item.name).font(.system(size: 11, weight: i == comps.count - 1 ? .semibold : .regular))
                            .foregroundStyle(i == comps.count - 1 ? theme.textPrimary : theme.textSecondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if i < comps.count - 1 {
                        Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
    }

    /// 当前文件夹路径拆成可点击层级（到 Home 停、太长只留尾部 4 级）。
    private func pathChain(_ url: URL?) -> [(name: String, url: URL)] {
        guard let url else { return [] }
        var chain: [(String, URL)] = []
        var cur = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while true {
            let name = cur.lastPathComponent
            chain.insert((name.isEmpty || name == "/" ? "Mac" : name, cur), at: 0)
            if cur.path == home { break }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        if chain.count > 4 { chain = Array(chain.suffix(4)) }
        return chain
    }

    private func centerHint(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(theme.textTertiary)
            Text(text).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(theme.textTertiary)
            Text(title).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(theme.accent))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 右：AI 工作面板 + 技能墙 + 指挥

    private var activityColumn: some View {
        let tab = ws.active
        // 有对话记录 / 在干活 / 改过文件 → 都算「有内容」（完成后历史对话留得住）
        let hasContent = tab.aiWorking || !tab.liveFiles.isEmpty || !tab.turns.isEmpty
        return VStack(spacing: 0) {
            columnHeader("AI 对话", "bubble.left.and.bubble.right.fill",
                         trailing: { AnyView(aiHeaderTrailing(tab)) })
            if hasContent {
                // 决策 #21：ScrollView 不被 GeometryReader 包；自动贴底只用单一数据驱动 scrollTo
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(tab.turns) { turn in turnView(turn) }
                            if tab.aiWorking || !tab.liveFiles.isEmpty { workFooter(tab) }
                            Color.clear.frame(height: 1).id("wb-bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: tab.turns.count) { _ in proxy.scrollTo("wb-bottom", anchor: .bottom) }
                    .onChange(of: tab.turns.last?.ai) { _ in proxy.scrollTo("wb-bottom", anchor: .bottom) }
                }
            } else {
                aiIdlePanel
            }
            Rectangle().fill(theme.hairline).frame(height: 1)
            commandBar(tab)
        }
        .background(theme.surface1)
    }

    /// AI 对话栏列头右侧：清空记录（有历史且不在干活时才显示）+ 技能入口。
    private func aiHeaderTrailing(_ tab: WorkspaceTab) -> some View {
        HStack(spacing: 8) {
            if !tab.turns.isEmpty && !tab.aiWorking {
                Button { tab.clearTurns() } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain).help("清空这个标签页的对话记录")
            }
            skillLibraryButton
        }
    }

    /// 一轮对话：用户气泡（右，accent 实色）+ AI 气泡（左，Markdown，出错转橙）。
    private func turnView(_ turn: WorkspaceTab.Turn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !turn.user.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 28)
                    Text(turn.user)
                        .font(.system(size: 12.5)).foregroundStyle(.white)
                        .multilineTextAlignment(.leading).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.accent))
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: turn.errored ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 11)).foregroundStyle(turn.errored ? Color.orange : theme.accent)
                    .frame(width: 18).padding(.top, 3)
                Group {
                    if turn.ai.isEmpty {
                        Text("正在思考…").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    } else {
                        MarkdownTextView(content: turn.ai, tint: theme.accent).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(turn.errored ? Color.orange.opacity(0.12) : theme.surface2))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(turn.errored ? Color.orange.opacity(0.4) : theme.panelStroke, lineWidth: 1))
            }
        }
    }

    /// 干活态页脚：转圈 + ticker + 正在改的文件（对话气泡之下）。
    private func workFooter(_ tab: WorkspaceTab) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if tab.aiWorking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text(tab.ticker.isEmpty ? "正在干活…" : tab.ticker)
                        .font(.system(size: 10.5)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            if !tab.liveFiles.isEmpty {
                Text("正在改的文件").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                ForEach(tab.liveFiles) { f in
                    LiveFileRow(name: f.name, done: f.done, theme: theme, pulse: pulse)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.surface2.opacity(0.5)))
    }

    /// 技能库入口（点开才看、不常驻）——展示这个 Agent 当前会哪些技能 + 去上学。
    private var skillLibraryButton: some View {
        Button { showSkills.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "graduationcap.fill").font(.system(size: 10))
                Text("技能").font(.system(size: 11, weight: .medium))
                Text("\(SkillLibraryStore.shared.cards.count)").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent.opacity(0.16)))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(theme.surface2))
            .overlay(Capsule().strokeBorder(theme.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("看看这个 AI 现在会哪些技能")
        .popover(isPresented: $showSkills, arrowEdge: .bottom) {
            SkillLibraryPanel(theme: theme,
                              onApply: { card in ws.active.activeSkill = card; showSkills = false },
                              onEnroll: { showSkills = false; startSchool() })
                .frame(width: 330, height: 440)
        }
    }

    private var aiIdlePanel: some View {
        VStack(spacing: 12) {
            Spacer()
            ModeSpriteView(mode: .directAPI, isWorking: false, size: 48).frame(height: 54)
            Text("AI 待命中").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.textPrimary)
            Text("下面说一句话，让我在这个文件夹里帮你干活")
                .font(.system(size: 11.5)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            Text("想看我会哪些技能？点右上角「技能」")
                .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commandBar(_ tab: WorkspaceTab) -> some View {
        let canSend = !tab.aiWorking
            && !ws.draftCommand.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: 0) {
            if let skill = tab.activeSkill { activeSkillChip(skill, tab) }
            HStack(spacing: 9) {
                Menu {
                    ForEach(WorkbenchView.commandModes, id: \.self) { m in
                        Button(modeLabel(m)) { tab.mode = m }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: modeIcon(tab.mode)).font(.system(size: 10))
                        Text(modeLabel(tab.mode)).font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.panelStroke, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(tab.aiWorking)

                TextField("说一句话，让 AI 帮你干活…", text: $ws.draftCommand)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(theme.textPrimary)
                    .disabled(tab.aiWorking)
                    .onSubmit { if canSend { ws.sendCommand(tab) } }

                Button { ws.sendCommand(tab) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(canSend ? theme.accent : theme.textTertiary)
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
            .padding(12)
        }
        .background(theme.surface1)
    }

    /// 指挥框上方的绿色技能条 —— 提示「正在运用 XX 技能」，✕ 取下。
    private func activeSkillChip(_ skill: SkillCard, _ tab: WorkspaceTab) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "graduationcap.fill").font(.system(size: 10)).foregroundStyle(.white)
            Text("运用技能：\(skill.displayName)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Button { tab.activeSkill = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain).help("取消运用这个技能")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(red: 0.18, green: 0.70, blue: 0.39))
    }

    static let commandModes: [AgentMode] = [.directAPI, .claudeCode, .codex]
    private func modeLabel(_ m: AgentMode) -> String {
        switch m {
        case .directAPI: return "在线 AI"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        case .qwenCode: return "QwenCode"
        }
    }
    private func modeIcon(_ m: AgentMode) -> String {
        switch m {
        case .directAPI: return "cloud.fill"
        case .claudeCode: return "terminal.fill"
        case .codex: return "wand.and.stars"
        default: return "sparkle"
        }
    }

    private func startSchool() {
        if !ws.enrollInSchool() { showNoRepo = true }
    }

    // MARK: 通用列头

    private func columnHeader(_ title: String, _ icon: String, trailing: (() -> AnyView)? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(theme.textSecondary)
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.textSecondary).lineLimit(1)
            Spacer()
            if let trailing { trailing() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 1) }
    }
}

// MARK: - AI 正在改的文件行（真实工具事件驱动，亮起 / 呼吸辉光）

private struct LiveFileRow: View {
    let name: String
    let done: Bool
    let theme: WorkbenchTheme
    let pulse: Bool

    private var glow: Double {
        guard theme.glowEnabled, !done else { return 0 }
        return theme.breatheEnabled ? (pulse ? theme.glowStrength * 0.4 : 0.08) : theme.glowStrength * 0.25
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 13)).foregroundStyle(done ? Color.green : theme.accent)
            Text(name).font(.system(size: 12)).foregroundStyle(theme.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(done ? theme.panelStroke : theme.accent.opacity(0.5), lineWidth: done ? 1 : 1.5))
        .shadow(color: theme.accent.opacity(glow), radius: done ? 0 : 8)
    }
}

// MARK: - 技能库面板（点「技能」入口才弹出；列表 ↔ 详情切换，无嵌套 popover）

private struct SkillLibraryPanel: View {
    let theme: WorkbenchTheme
    var onApply: (SkillCard) -> Void = { _ in }
    var onEnroll: () -> Void = {}
    @State private var detail: SkillCard?

    var body: some View {
        VStack(spacing: 0) {
            if let card = detail { detailView(card) } else { listView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface1)
        .environment(\.colorScheme, theme.colorScheme)
    }

    // 列表态
    private var listView: some View {
        let cards = SkillLibraryStore.shared.cards
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "graduationcap.fill").font(.system(size: 13)).foregroundStyle(theme.accent)
                Text("Agent 技能库").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text("\(cards.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(theme.surface2))
                Spacer()
                Button { SkillLibraryStore.shared.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain).help("重新从 AgentForge 扫描技能卡")
            }
            .padding(14)
            Rectangle().fill(theme.hairline).frame(height: 1)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(cards) { card in skillCardRow(card) }
                    if SkillLibraryStore.shared.graduatedCount == 0 {
                        Text("还没有上学带回的技能。点下面「去上学」让 AI 去 AgentForge 上课，毕业的技能会标 🎓 出现在这里。")
                            .font(.system(size: 10.5)).foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                }
                .padding(14)
            }

            Rectangle().fill(theme.hairline).frame(height: 1)
            Button { onEnroll() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 12))
                    Text("去上学（学个新技能回来）").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent))
            }
            .buttonStyle(.plain).padding(12)
            .help("需装 Claude Code")
        }
    }

    private func skillCardRow(_ card: SkillCard) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((card.isGraduated ? Color.green : theme.accent).opacity(0.14)).frame(width: 32, height: 32)
                Image(systemName: card.isGraduated ? "graduationcap.fill" : "sparkles")
                    .font(.system(size: 14)).foregroundStyle(card.isGraduated ? Color.green : theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.textPrimary).lineLimit(1)
                Text(card.summary).font(.system(size: 10.5)).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { detail = card } label: {
                Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain).help("看技能详情")
            Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(theme.accent)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.panelStroke, lineWidth: 1))
        .shadow(color: theme.cardShadow, radius: theme.cardShadowRadius, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { onApply(card) }
        .help("点这张卡 → 运用这个技能")
    }

    // 详情态（带返回，不用嵌套 popover）
    private func detailView(_ card: SkillCard) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { detail = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
                }.buttonStyle(.plain).help("返回")
                Image(systemName: card.isGraduated ? "graduationcap.fill" : "sparkles")
                    .font(.system(size: 12)).foregroundStyle(card.isGraduated ? Color.green : theme.accent)
                Text(card.displayName).font(.system(size: 13.5, weight: .bold)).foregroundStyle(theme.textPrimary).lineLimit(1)
                Spacer()
                Text(card.isGraduated ? "🎓 毕业" : "内置").font(.system(size: 9.5))
                    .foregroundStyle(card.isGraduated ? Color.green : theme.textTertiary)
            }
            .padding(14)
            Rectangle().fill(theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if let src = card.source { Text("来自：\(src)").font(.system(size: 10.5)).foregroundStyle(theme.textTertiary) }
                    Text(card.summary).font(.system(size: 11.5)).foregroundStyle(theme.textSecondary)
                    Rectangle().fill(theme.hairline).frame(height: 1)
                    Text(card.body).font(.system(size: 11.5)).foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(14)
            }
        }
    }
}

// MARK: - 多标签页容器：每个 tab 一个独立文件夹工作环境（逻辑层，视觉无关）

@MainActor
@Observable
final class WorkspaceState {
    /// 全局单例：活在内存里、不随工作台窗口关闭而销毁 → 关掉重开仍保留所有 tab / 对话历史，
    /// tab.id 不变 → 底层 AI 会话（opencode 按 sessionTag 复用）能接着之前的上下文继续干活。
    static let shared = WorkspaceState()

    var tabs: [WorkspaceTab]
    var activeID: UUID { didSet { saveIfLoaded() } }
    var draftCommand = ""
    @ObservationIgnored private var loaded = false   // init 期间为 false → 恢复时不回写

    init() {
        if let snap = WorkbenchStore.load(), !snap.tabs.isEmpty {
            let restored = snap.tabs.map { WorkspaceState.restoreTab($0) }
            tabs = restored
            activeID = restored.contains(where: { $0.id == snap.activeID }) ? snap.activeID : restored[0].id
            draftCommand = snap.draftCommand
        } else {
            let first = WorkspaceTab()
            first.openFolder(WorkspaceTab.defaultStartDir)   // 打开工作台即有内容、能直接干活
            tabs = [first]
            activeID = first.id
        }
        loaded = true
        tabs.forEach { wire($0) }   // loaded 之后再注入 save 回调（避开单例初始化重入 + 恢复期误存）
    }

    /// 从快照重建一个 tab（不注入 onMutate、不写 lastFolder，避免恢复期间触发存盘）。
    private static func restoreTab(_ s: TabSnapshot) -> WorkspaceTab {
        let t = WorkspaceTab(id: s.id, mode: AgentMode(rawValue: s.modeRaw) ?? .directAPI, isSchool: s.isSchool)
        // 上次 App 被关时若有「发了但没收到回复」的半截轮 → 标记一下，别显示成永远「正在思考…」
        t.turns = s.turns.map { var x = $0; if x.ai.isEmpty { x.ai = "（上次会话已结束，未收到回复）"; x.errored = true }; return x }
        t.activeSkill = s.activeSkill
        if let fp = s.folderPath, FileManager.default.fileExists(atPath: fp) {
            t.openFolder(URL(fileURLWithPath: fp), remember: false)   // 同步加载 entries
            if let sp = s.selectedPath { t.selectPath(sp) }
        }
        return t
    }

    /// 给一个 tab 接上「变更即存盘」回调（弱引用 self，绝不引用 WorkspaceState.shared，避免重入）。
    private func wire(_ tab: WorkspaceTab) {
        tab.onMutate = { [weak self] in self?.saveIfLoaded() }
    }

    func saveIfLoaded() { guard loaded else { return }; save() }

    /// 建快照（主线程）→ 后台原子写盘（决策 #5：snapshot 是 Sendable 值类型，detached 安全）。
    func save() {
        let snap = WorkbenchSnapshot(
            tabs: tabs.map { t in
                TabSnapshot(id: t.id, modeRaw: t.mode.rawValue, isSchool: t.isSchool,
                            folderPath: t.folderURL?.path, selectedPath: t.selected?.path,
                            turns: t.turns, activeSkill: t.activeSkill)
            },
            activeID: activeID, draftCommand: draftCommand)
        Task.detached { WorkbenchStore.save(snap) }
    }

    // 不变量：tabs 永不为空（init 播种 + closeTab 守 count>1）。兜底用 `?? WorkspaceTab()` 而非 `tabs[0]`
    // 强下标——万一未来某路径清空了 tabs，返回一个一次性 tab 而不是越界崩（审计 #8）。不在 getter 里
    // append/改 activeID（那会在 SwiftUI body 求值中改观察状态）。正常运行永远走前两个分支。
    var active: WorkspaceTab { tabs.first { $0.id == activeID } ?? tabs.first ?? WorkspaceTab() }

    /// 按 sessionTag（"workbench-<id8>" / "school-<id8>"）找回发起命令的 tab，让流式回复落到正确标签页。
    func tab(forTag tag: String?) -> WorkspaceTab? {
        guard let tag else { return nil }
        return tabs.first { tag.hasSuffix(String($0.id.uuidString.prefix(8))) }
    }

    func newTab() {
        let t = WorkspaceTab()
        wire(t)
        t.openFolder(WorkspaceTab.defaultStartDir)
        tabs.append(t)
        activeID = t.id   // didSet → 存盘
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeID == id { activeID = tabs[min(idx, tabs.count - 1)].id }   // didSet → 存盘
        else { saveIfLoaded() }
    }

    /// 指挥：把指令 + 该 tab 的文件夹（作为工作目录）发给 AppDelegate 去调 AI（解耦、不持 vm 引用）。
    func sendCommand(_ tab: WorkspaceTab) {
        let text = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !tab.aiWorking else { return }
        let dir = tab.folderURL?.path ?? WorkspaceTab.defaultStartDir.path   // 没开文件夹就用默认目录
        // 选用了技能 → 把技能要点注入 prompt（在线 AI 已有 SKILL.md 自动加载，这里对 Claude Code/Codex 也生效）
        let prompt: String
        if let skill = tab.activeSkill {
            prompt = """
            请运用「\(skill.displayName)」这个技能来完成下面的任务。

            【技能：\(skill.displayName)】
            \(skill.body)

            【任务】
            \(text)
            """
        } else {
            prompt = text
        }
        // 本运行首次发送 + 有历史（来自磁盘恢复）→ 回灌最近几轮，让重启后 AI 接上上下文
        var history = ""
        if !tab.contextPrimed {
            history = tab.recentHistoryText()
            tab.contextPrimed = true
        }
        tab.beginTurn(text)   // 先记下用户这句话（AI 回复随后流式填进同一轮）
        saveIfLoaded()        // 立即落盘用户这句（即便随后崩溃/退出也不丢）
        NotificationCenter.default.post(name: .init("HermesPetWorkbenchCommand"), object: nil, userInfo: [
            "prompt": prompt,
            "history": history,
            "mode": tab.mode.rawValue,
            "directory": dir,
            "sessionTag": "workbench-\(String(tab.id.uuidString.prefix(8)))"
        ])
        draftCommand = ""
    }

    /// 「去上学」：新建一个指向 ~/agent-forge 的上学 tab，用 Claude Code 真去上一门课、沉淀技能卡。
    /// 返回 false = 本地没有 agent-forge 仓库（UI 提示用户去克隆）。
    @discardableResult
    func enrollInSchool() -> Bool {
        guard SkillLibrary.repoExists else { return false }
        let repo = SkillLibrary.repoDir
        let tab = WorkspaceTab(mode: .claudeCode, isSchool: true)   // 上学最适合 Claude Code
        wire(tab)
        tab.openFolder(repo, remember: false)   // 上学目录不污染「默认起始目录」
        tabs.append(tab)
        activeID = tab.id
        tab.beginTurn("🎓 去 AgentForge 上学，学个新技能回来")
        saveIfLoaded()
        NotificationCenter.default.post(name: .init("HermesPetWorkbenchCommand"), object: nil, userInfo: [
            "prompt": SkillLibrary.enrollPrompt,
            "mode": AgentMode.claudeCode.rawValue,
            "directory": repo.path,
            "sessionTag": "school-\(String(tab.id.uuidString.prefix(8)))"
        ])
        return true
    }

    /// 从「学校」栏选中一门具体课程 → 新建上学 tab，用 Claude Code 真去上这门课。
    @discardableResult
    func enrollInCourse(_ course: Course) -> Bool {
        guard SkillLibrary.repoExists else { return false }
        let repo = SkillLibrary.repoDir
        let tab = WorkspaceTab(mode: .claudeCode, isSchool: true)
        tab.schoolCourse = course.name
        wire(tab)
        tab.openFolder(repo, remember: false)
        tabs.append(tab)
        activeID = tab.id
        tab.beginTurn("🎓 去上课：第 \(course.id) 课 · \(course.name)")
        saveIfLoaded()
        NotificationCenter.default.post(name: .init("HermesPetWorkbenchCommand"), object: nil, userInfo: [
            "prompt": SkillLibrary.enrollPrompt(courseID: course.id, courseName: course.name),
            "history": "",
            "mode": AgentMode.claudeCode.rawValue,
            "directory": repo.path,
            "sessionTag": "school-\(String(tab.id.uuidString.prefix(8)))"
        ])
        return true
    }
}

// MARK: - 单个工作环境（真实文件系统 + 真实 AI 工具事件，无任何假数据）

@MainActor
@Observable
final class WorkspaceTab: Identifiable {
    let id: UUID

    /// WorkspaceState 注入的「我变了，去存盘」回调。restore 期间为 nil（不触发写盘、也避开单例初始化重入）。
    @ObservationIgnored var onMutate: (() -> Void)?

    var mode: AgentMode = .directAPI { didSet { onMutate?() } }   // 该 tab 用哪个 AI 干活（用户可在指挥栏切换）
    var isSchool = false               // 这个 tab 是「去 AgentForge 上学」专用环境
    var schoolCourse: String?          // 正在上的课名（上学 tab 标题更友好；不持久化）
    var activeSkill: SkillCard? { didSet { onMutate?() } }        // 当前选用的技能（指挥栏上方绿色提示 + 发送时注入 prompt）

    init(id: UUID = UUID(), mode: AgentMode = .directAPI, isSchool: Bool = false) {
        self.id = id
        self.mode = mode
        self.isSchool = isSchool
    }
    var folderURL: URL?
    var entries: [FileEntry] = []
    var selected: URL?
    var previewText: String?
    var previewImage: NSImage?
    enum PreviewKind { case none, plain, markdown, code, image, web, pdf }
    var previewKind: PreviewKind = .none
    var previewLang = ""
    var previewAttributed: NSAttributedString?   // 代码高亮结果（select 时算一次、缓存，避免 body 反复跑正则）

    static let codeExts: Set<String> = ["swift","js","ts","tsx","jsx","py","c","cpp","h","hpp","go","rs","java","sh","rb","json","yaml","yml","toml","xml","html","css","kt","php","sql"]

    var liveFiles: [LiveFile] = []
    var ticker = ""
    var aiWorking = false
    var changedNames: Set<String> = []
    var turns: [Turn] = []      // 工作台对话历史（每轮：用户问 + AI 流式答；右栏渲染成对话气泡）
    /// 本次 App 运行内是否已给后端喂过上下文。瞬态（不持久化）→ 磁盘恢复的 tab 首次发送会回灌历史，
    /// 让重启后 AI 也能接上；之后置 true，不再重复（在线 AI 同一运行内后端自带会话记忆，避免重复/膨胀）。
    @ObservationIgnored var contextPrimed = false

    struct FileEntry: Identifiable {
        let id = UUID(); let url: URL; let isDir: Bool
        var name: String { url.lastPathComponent }
    }
    struct LiveFile: Identifiable { let id = UUID(); let name: String; var done: Bool }
    struct Turn: Identifiable, Codable, Sendable { var id = UUID(); let user: String; var ai = ""; var errored = false }

    var title: String {
        if isSchool { return schoolCourse.map { "上学·\($0)" } ?? "上学中" }
        return folderURL?.lastPathComponent ?? "新标签页"
    }

    func pickFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    /// 默认起始目录：上次用过的（记住）→ 桌面 → 主目录。让工作台一打开就有内容、能直接干活。
    static var defaultStartDir: URL {
        if let p = UserDefaults.standard.string(forKey: "workbench.lastFolder.v1"),
           FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop")
        return FileManager.default.fileExists(atPath: desktop.path) ? desktop : home
    }

    func openFolder(_ url: URL, remember: Bool = true) {
        folderURL = url
        selected = nil; previewText = nil; previewImage = nil; previewKind = .none; previewAttributed = nil
        loadEntries()
        if remember {
            UserDefaults.standard.set(url.path, forKey: "workbench.lastFolder.v1")
            onMutate?()   // 用户切文件夹 → 存盘（restore 用 remember:false，不触发）
        }
    }

    /// 恢复时按路径重新选中文件（entries 已由 openFolder 同步加载）。
    func selectPath(_ path: String) {
        guard let e = entries.first(where: { $0.url.path == path }) else { return }
        select(e)
    }

    func goUp() {
        guard let folderURL else { return }
        openFolder(folderURL.deletingLastPathComponent())
    }

    func loadEntries() {
        guard let folderURL else { entries = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        entries = items.map { url -> FileEntry in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileEntry(url: url, isDir: isDir)
        }.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func select(_ entry: FileEntry) {
        if entry.isDir { openFolder(entry.url); return }
        selected = entry.url
        previewText = nil; previewImage = nil; previewKind = .none; previewLang = ""; previewAttributed = nil
        let ext = entry.url.pathExtension.lowercased()
        if ["png","jpg","jpeg","gif","heic","webp","bmp","tiff"].contains(ext) {
            previewImage = NSImage(contentsOf: entry.url)
            previewKind = previewImage != nil ? .image : .none
        } else if ext == "pdf" {
            previewKind = .pdf                                   // PDFKit 原生渲染（不读文本）
        } else if ["html","htm"].contains(ext) {
            previewKind = .web                                  // 默认渲染成网页；header 可切「源码」
            previewLang = ext
            if let s = try? String(contentsOf: entry.url, encoding: .utf8) {
                previewText = s                                 // 备好源码（供切换）
                previewAttributed = CodeHighlighter.make(s, ext: "html", theme: WorkbenchThemeStore.shared.current)
            }
        } else if let data = try? Data(contentsOf: entry.url), data.count < 2_000_000,
                  let s = String(data: data, encoding: .utf8) {
            previewText = s
            previewLang = ext
            if ["md","markdown"].contains(ext) { previewKind = .markdown }
            else if Self.codeExts.contains(ext) {
                previewKind = .code
                previewAttributed = CodeHighlighter.make(s, ext: ext, theme: WorkbenchThemeStore.shared.current)
            }
            else { previewKind = .plain }
        }
        onMutate?()   // 选中文件变化 → 存盘（恢复 selectedPath）
    }

    // MARK: AI 真实工具事件（决策 #13）
    func taskStarted() { aiWorking = true; liveFiles = []; ticker = "开始干活…" }   // 不清 turns，保留历史对话
    /// 用户发一句话 → 新开一轮（AI 回复随后流式填进同一轮的 ai 字段）。
    func beginTurn(_ userText: String) { turns.append(Turn(user: userText)) }
    /// AI 流式增量 → 追加到当前轮（兜底：没有当前轮就补一个空 user 的轮）。
    func appendReply(_ delta: String) {
        if turns.isEmpty { turns.append(Turn(user: "")) }
        turns[turns.count - 1].ai += delta
    }
    func clearTurns() { turns = []; liveFiles = []; ticker = ""; contextPrimed = false; onMutate?() }

    /// 取最近几轮对话拼成纯文本（供重启后回灌进 prompt）。在 beginTurn 之前调用 → 反映"之前"的历史。
    func recentHistoryText(maxTurns: Int = 6, maxReplyChars: Int = 800) -> String {
        var lines: [String] = []
        for t in turns.suffix(maxTurns) {
            if !t.user.isEmpty { lines.append("用户：\(t.user)") }
            if !t.errored, !t.ai.isEmpty {
                let ai = t.ai.count > maxReplyChars ? String(t.ai.prefix(maxReplyChars)) + "…" : t.ai
                lines.append("AI：\(ai)")
            }
        }
        return lines.joined(separator: "\n")
    }
    func toolStarted(name: String, filePath: String?) {
        aiWorking = true
        if let fp = filePath, !fp.isEmpty {
            let nm = (fp as NSString).lastPathComponent
            if !liveFiles.contains(where: { $0.name == nm }) { liveFiles.append(LiveFile(name: nm, done: false)) }
            changedNames.insert(nm)
            ticker = "正在处理 \(nm)…"
        } else {
            ticker = "正在 \(name)…"
        }
    }
    func toolEnded(filePath: String?) {
        guard let fp = filePath, !fp.isEmpty else { return }
        let nm = (fp as NSString).lastPathComponent
        if let i = liveFiles.firstIndex(where: { $0.name == nm }) { liveFiles[i].done = true }
    }
    func taskFinished(success: Bool) {
        ticker = success ? "完成 ✓" : "出错了，已停下"
        aiWorking = false
        if !success, !turns.isEmpty { turns[turns.count - 1].errored = true }
        loadEntries()   // AI 干完活刷新文件列表
        onMutate?()     // AI 回复完成 → 把这一轮（含最终文字）落盘
        if isSchool && success {
            SkillLibraryStore.shared.refresh()   // 上学毕业的新技能卡进库 → 技能墙更新
            NotificationCenter.default.post(name: .init("HermesPetGraduated"), object: nil)
        }
    }
}

private func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }

// MARK: - 工作台磁盘持久化（~/.hermespet/workbench.json）—— 退出 App 重开仍恢复标签页 + 对话历史

/// 一个标签页的可持久化子集（瞬态字段如 entries/liveFiles/aiWorking/预览结果不存，恢复时重算）。
struct TabSnapshot: Codable, Sendable {
    var id: UUID
    var modeRaw: String
    var isSchool: Bool
    var folderPath: String?
    var selectedPath: String?
    var turns: [WorkspaceTab.Turn]
    var activeSkill: SkillCard?
}

struct WorkbenchSnapshot: Codable, Sendable {
    var tabs: [TabSnapshot]
    var activeID: UUID
    var draftCommand: String
}

/// 读写 `~/.hermespet/workbench.json`（nonisolated：主线程建快照、后台线程写盘都安全；NSLock 串行化）。
enum WorkbenchStore {
    private static let lock = NSLock()

    private static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workbench.json")
    }

    static func load() -> WorkbenchSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkbenchSnapshot.self, from: data)
    }

    static func save(_ snap: WorkbenchSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: fileURL, options: .atomic)
    }
}
