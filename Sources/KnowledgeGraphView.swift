import SwiftUI

/// 阶段3·时间窗：云图默认只画最近一段时间的对话（加星的永远进），控制呈现规模。
private enum GraphWindow: Int, CaseIterable {
    case week = 0, month = 1, quarter = 2, all = 3
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }
    var labelKey: String {
        switch self {
        case .week: return "graph.window.week"
        case .month: return "graph.window.month"
        case .quarter: return "graph.window.quarter"
        case .all: return "graph.window.all"
        }
    }
}

/// 知识图谱「云图」视图（全屏覆盖层内容）。v7：按主题分团 + 搜索高亮 + 缩放平移 +
/// **拖到右侧区域 → 卡片列表**（替代不灵敏的"甩动钻入"）。
///
/// - 把一个对话点**拖到屏幕最右侧的区域**松手 → 右侧滑出面板，把这一类相关对话的摘要**从上往下卡片式排开**，可点开。
/// - 搜索框在刘海下方；点色=AI；团按主题（连通的同主题对话）+ 文字团名。
/// - 相机：捏合缩放 + 空白拖动平移；拖在点上=移动节点（联动物理）。Esc：先关卡片面板 → 再清搜索 → 再关云图。
struct KnowledgeGraphView: View {
    let viewModel: ChatViewModel
    var onOpen: (String) -> Void
    var onDismiss: () -> Void

    // 屏幕系统栏尺寸（控制器按当前屏幕实测后传入）：菜单栏(含刘海)高 + 各方向 Dock 占用
    var menuBarHeight: CGFloat = 0
    var dockBottom: CGFloat = 0
    var dockLeft: CGFloat = 0
    var dockRight: CGFloat = 0

    @State private var rows: [ConversationHistoryStore.GraphRow] = []
    @State private var loaded = false
    @State private var sim: NebulaSim?
    @State private var size: CGSize = .zero
    @State private var hoveredID: String?
    @State private var hoveredNeighbors: Set<Int> = []
    @State private var hoverPoint: CGPoint = .zero

    @State private var dragResolved = false
    @State private var isPanning = false
    @State private var draggingNearRight = false
    @State private var pressOnCard = false   // 按在悬停信息卡上（含星标按钮）→ 父手势不平移/不关闭

    @State private var camScale: CGFloat = 1
    @State private var camOffset: CGSize = .zero
    @State private var lastCamScale: CGFloat = 1
    @State private var lastCamOffset: CGSize = .zero

    @State private var searchText = ""
    @State private var matchedIDs: Set<String> = []
    @State private var appearDate = Date()   // 入场绽开动效起点
    @State private var starredIDs: Set<String> = []   // 阶段2·加星的对话 id（视图层单一数据源，Canvas + 信息卡都读它）
    @AppStorage("graphTimeWindow") private var windowRaw: Int = GraphWindow.quarter.rawValue   // 阶段3·时间窗（默认近90天）
    @State private var totalInWindow = 0   // 时间窗内候选总数（> 入选数 → 发生了上限截断）

    // 右侧卡片面板
    @State private var showCards = false
    @State private var cardDots: [NebulaLayout.Dot] = []
    @State private var cardLabel = ""

    /// 右侧投放区宽度（加大，更好拖进去）
    private let rightZoneWidth: CGFloat = 260
    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 点/团的布局安全区：顶部留出菜单栏 + 搜索框带；底部留出 Dock + 提示条；左右留出侧边 Dock。
    private var safeInsets: GraphInsets {
        GraphInsets(top: menuBarHeight + 88, left: dockLeft + 24, bottom: dockBottom + 44, right: dockRight + 24)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    nebulaCanvas
                    if !searching, let id = hoveredID, let dot = sim?.dot(id) {
                        infoCard(dot).position(cardPosition(in: geo.size))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(zoomGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        if sim?.draggedIdx != nil { hoverPoint = p; break }
                        // 鼠标移到信息卡上 → 冻结（不更新位置、不重算悬停），让用户能点卡上的星标
                        if hoveredID != nil, infoCardFrame(in: size).contains(p) { break }
                        hoverPoint = p
                        updateHover(p)
                    case .ended:
                        hoveredID = nil; sim?.hoveredIdx = nil
                    }
                }
                .onAppear { size = geo.size; rebuild() }
                .onChange(of: geo.size) { _, s in size = s; rebuild() }
            }

            if draggingNearRight { rightZoneIndicator }
            topBar
            if showCards { cardPanel.transition(.move(edge: .trailing).combined(with: .opacity)) }
            if loaded && rows.isEmpty { emptyState }
        }
        .overlay(alignment: .bottom) {
            if loaded && !rows.isEmpty && !showCards {
                Text(L("graph.overlay.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.ultraThinMaterial)).padding(.bottom, 14 + dockBottom)
            }
        }
        .background(Button("", action: handleCancel).keyboardShortcut(.cancelAction).opacity(0))   // 可靠的 Esc
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showCards)
        .onChange(of: searchText) { _, _ in recomputeMatches() }
        .onChange(of: windowRaw) { _, _ in appearDate = Date(); Task { await load() } }   // 切时间窗 → 重筛 + 重新绽开
        .task { await load() }
    }

    private func handleCancel() {
        if showCards { showCards = false }
        else if searching { searchText = "" }
        else { onDismiss() }
    }

    // MARK: - Canvas

    private var nebulaCanvas: some View {
        // 限到 30fps（与全项目 sprite 惯例一致）：默认 .animation 跑 60/120Hz，
        // 每帧主线程跑 O(n²) 物理仿真 + 全图重绘，云图开着就占满一个核
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Canvas { ctx, csize in
                guard let sim else { return }
                sim.step(context.date.timeIntervalSinceReferenceDate)
                let sActive = searching
                ctx.translateBy(x: camOffset.width, y: camOffset.height)
                ctx.scaleBy(x: camScale, y: camScale)

                // 入场绽开：点从中心绽开到真实位置 + 淡入（easeOut，~1.2s，更柔顺）
                let raw = min(1.0, max(0.0, context.date.timeIntervalSince(appearDate) / 1.2))
                let prog = 1 - pow(1 - raw, 3)
                let wc = CGPoint(x: (csize.width / 2 - camOffset.width) / camScale,
                                 y: (csize.height / 2 - camOffset.height) / camScale)
                func entr(_ q: CGPoint) -> CGPoint { CGPoint(x: wc.x + (q.x - wc.x) * prog, y: wc.y + (q.y - wc.y) * prog) }

                // 中性团光晕（玻璃深度感，非 AI 色）
                for (ci, cl) in sim.clusters.enumerated() where !cl.label.isEmpty {
                    let center = entr(sim.clusterRenderCenter(ci))
                    let hr = cl.radius * 1.5
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - hr, y: center.y - hr, width: hr * 2, height: hr * 2)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.055 * prog), .white.opacity(0)]),
                                                   center: center, startRadius: 0, endRadius: hr))
                }

                // 连线：默认**按关联强度分级**画（强关联明显、弱关联很淡 → 主结构看得见又不乱）；
                // 悬停某点 / 搜索时把相关线高亮、其余隐去（聚光）
                let hoverIdx = hoveredID.flatMap { sim.index(of: $0) }
                let hovering = hoverIdx != nil
                for link in sim.links {
                    let touched = hovering && (link.a == hoverIdx || link.b == hoverIdx)
                    let bothMatched = sActive && matchedIDs.contains(sim.id(link.a)) && matchedIDs.contains(sim.id(link.b))
                    var path = Path(); path.move(to: entr(sim.point(link.a))); path.addLine(to: entr(sim.point(link.b)))
                    if touched || bothMatched {
                        ctx.stroke(path, with: .color(color(sim.mode(link.a)).opacity(0.72)), lineWidth: 1.7)
                    } else if !hovering && !sActive {
                        // 分级：w2 几乎看不见、w≥4 才较明显（等级分明，避免一片乱线）；入场时随 prog 淡入
                        let op = min(0.30, Double(link.w - 1) * 0.085) * prog
                        let lw = 0.5 + CGFloat(link.w - 2) * 0.35
                        ctx.stroke(path, with: .color(.white.opacity(op)), lineWidth: lw)
                    }
                }

                // 对话点：玻璃珠（径向渐变+柔影+高光）；recency 调亮度/大小（新亮大、旧暗小）；悬停=聚光灯；入场绽开
                for i in 0..<sim.count {
                    let id = sim.id(i)
                    let matched = !sActive || matchedIDs.contains(id)
                    let isHov = id == hoveredID
                    let isNeighbor = hovering && hoveredNeighbors.contains(i)
                    let emph = (sActive && matched) || isHov || isNeighbor
                    // 阶段2·显著度驱动大小/亮度：加星 → 强制 1.0（永远最大最亮，压过算法分）
                    let cid = sim.conversationID(i) ?? ""
                    let starred = starredIDs.contains(cid)
                    let sal = starred ? 1.0 : sim.dots[i].salience
                    var a: Double
                    if emph { a = 1.0 }
                    else if sActive { a = 0.13 }
                    else if hovering { a = 0.13 }
                    else { a = 0.4 + 0.6 * sal }       // 正常态：按显著度调亮度（重要的亮、琐事暗）
                    a *= prog
                    guard a > 0.01 else { continue }
                    let p = entr(sim.point(i))
                    let r = sim.radius(i) * (0.7 + 0.6 * sal) * (isHov ? 1.85 : (emph ? 1.45 : 1.0))
                    let c = color(sim.mode(i))
                    ctx.fill(circle(CGPoint(x: p.x, y: p.y + r * 0.32), r * 0.95), with: .color(.black.opacity(0.16 * a)))   // 柔影
                    ctx.fill(circle(p, r * 2.0), with: .color(c.opacity((emph ? 0.28 : 0.12) * a)))                           // 外发光
                    ctx.fill(circle(p, r), with: .radialGradient(                                                            // 玻璃珠主体
                        Gradient(colors: [Color.white.opacity(0.55 * a), c.opacity(0.95 * a), c.opacity(0.62 * a)]),
                        center: CGPoint(x: p.x - r * 0.32, y: p.y - r * 0.32), startRadius: 0, endRadius: r * 1.25))
                    ctx.fill(circle(CGPoint(x: p.x - r * 0.34, y: p.y - r * 0.34), r * 0.26), with: .color(.white.opacity(0.55 * a)))  // 高光
                    if isHov || (sActive && matched) { ctx.stroke(circle(p, r + 3), with: .color(.white.opacity(0.85)), lineWidth: 1.5) }
                    if starred {       // 加星：金色描边 + 右上角 ★
                        ctx.stroke(circle(p, r + 2.5), with: .color(.yellow.opacity(0.9 * a)), lineWidth: 1.6)
                        ctx.draw(Text("★").font(.system(size: max(8, r * 0.95)))
                            .foregroundStyle(Color.yellow.opacity(a)),
                            at: CGPoint(x: p.x + r * 1.05, y: p.y - r * 1.05))
                    }
                }

                // 主题团标签：画在团**正中央**（带淡底）。悬停聚光 / 入场时整体淡处理
                let labelA = ((hovering || sActive) ? 0.42 : 1.0) * prog
                for (i, cl) in sim.clusters.enumerated() where !cl.label.isEmpty {
                    let center = entr(sim.clusterRenderCenter(i))
                    let w = CGFloat(cl.label.count) * 12 + 18
                    ctx.fill(Path(roundedRect: CGRect(x: center.x - w / 2, y: center.y - 11, width: w, height: 22), cornerRadius: 11),
                             with: .color(.black.opacity(0.34 * labelA)))
                    ctx.draw(Text(cl.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95 * labelA)),
                             at: center)
                }
            }
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - 坐标 / 手势

    private func toWorld(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - camOffset.width) / camScale, y: (s.y - camOffset.height) / camScale)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let sim else { return }
                if !dragResolved {
                    dragResolved = true
                    // 按在悬停信息卡上（含星标按钮）→ 交给卡片自己处理，父手势啥都不做
                    if hoveredID != nil, infoCardFrame(in: size).contains(v.startLocation) {
                        pressOnCard = true; isPanning = false
                    } else if let hit = sim.hitTest(toWorld(v.startLocation)) {
                        sim.draggedIdx = hit; isPanning = false
                    } else {
                        isPanning = true
                    }
                }
                if pressOnCard { return }
                if sim.draggedIdx != nil {
                    sim.dragTarget = toWorld(v.location)
                    draggingNearRight = v.location.x > size.width - rightZoneWidth
                } else if isPanning {
                    camOffset = CGSize(width: lastCamOffset.width + v.translation.width,
                                       height: lastCamOffset.height + v.translation.height)
                }
            }
            .onEnded { v in
                let di = sim?.draggedIdx
                let nearRight = draggingNearRight
                let wasOnCard = pressOnCard
                defer { dragResolved = false; isPanning = false; draggingNearRight = false; sim?.draggedIdx = nil; pressOnCard = false }
                if wasOnCard { return }   // 卡片上的操作（加星）不触发打开/关闭
                guard let sim else { return }
                let moved = hypot(v.translation.width, v.translation.height)
                if let di, nearRight, moved >= 6 {
                    // 拖到右侧区域 → 弹出该点相关对话的卡片列表
                    let related = sim.relatedDots(forDot: di)
                    cardDots = related.dots
                    cardLabel = related.label.isEmpty ? L("graph.related") : related.label
                    showCards = true
                } else if moved < 6 {
                    if let di, let cid = sim.conversationID(di) { onOpen(cid) }
                    else if !searching && !showCards { onDismiss() }
                } else if di == nil {
                    lastCamOffset = camOffset
                }
                // 拖了点但没进右区 → 不做特殊处理，松手后物理自然回弹
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { m in
                let pivot = CGPoint(x: size.width / 2, y: size.height / 2)
                let worldAtPivot = CGPoint(x: (pivot.x - lastCamOffset.width) / lastCamScale,
                                           y: (pivot.y - lastCamOffset.height) / lastCamScale)
                let ns = min(4, max(0.4, lastCamScale * m))
                camScale = ns
                camOffset = CGSize(width: pivot.x - worldAtPivot.x * ns, height: pivot.y - worldAtPivot.y * ns)
            }
            .onEnded { _ in lastCamScale = camScale; lastCamOffset = camOffset }
    }

    // MARK: - 右侧投放区 + 卡片面板

    private var rightZoneIndicator: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right").font(.system(size: 22))
                Text(L("graph.dropRight")).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: rightZoneWidth)
            .frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                                       startPoint: .trailing, endPoint: .leading))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var cardPanel: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(cardLabel).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(L("graph.card.messages", cardDots.count)).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button { showCards = false } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(cardDots) { dot in cardRow(dot) }
                    }
                    .padding(12)
                }
            }
            .padding(.top, menuBarHeight)        // 标题/关闭按钮避开菜单栏
            .padding(.bottom, dockBottom)         // 列表底部避开 Dock
            .frame(width: 340)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(Rectangle().frame(width: 0.5).foregroundStyle(.white.opacity(0.12)), alignment: .leading)
        }
    }

    private func cardRow(_ dot: NebulaLayout.Dot) -> some View {
        Button { onOpen(dot.conversationID) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(color(dot.mode)).frame(width: 7, height: 7)
                    Text(dot.title.isEmpty ? L("history.title") : dot.title)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(relativeTime(dot.updatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if !dot.preview.isEmpty {
                    Text(dot.preview).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 顶栏 / 信息卡 / 空态

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                Text(L("graph.overlay.title")).font(.system(size: 15, weight: .semibold))
                if !rows.isEmpty {
                    // 截断时显示「最常用 N / 共 M」，否则普通计数
                    Text(totalInWindow > rows.count
                         ? L("graph.window.truncated", rows.count, totalInWindow)
                         : L("history.count", rows.count))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                windowPicker
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 26, height: 26)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain).help(L("history.close.help"))
            }
            .padding(.horizontal, 22).padding(.top, 16 + menuBarHeight)
            Spacer()
        }
        .overlay(alignment: .top) { searchField.padding(.top, 54 + menuBarHeight) }
    }

    /// 阶段3·时间窗切换（近一周 / 一月 / 90天 / 全部）
    private var windowPicker: some View {
        HStack(spacing: 5) {
            ForEach(GraphWindow.allCases, id: \.self) { w in
                let sel = w.rawValue == windowRaw
                Button { if windowRaw != w.rawValue { windowRaw = w.rawValue } } label: {
                    Text(L(w.labelKey))
                        .font(.system(size: 11, weight: sel ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(sel ? Color.white.opacity(0.22) : Color.white.opacity(0.06)))
                        .foregroundStyle(sel ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 8)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(L("graph.search.placeholder"), text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 240)
            if searching {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
    }

    private func infoCard(_ dot: NebulaLayout.Dot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color(dot.mode)).frame(width: 7, height: 7)
                Text(dot.title.isEmpty ? L("history.title") : dot.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button { toggleStar(dot) } label: {
                    Image(systemName: starredIDs.contains(dot.conversationID) ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(starredIDs.contains(dot.conversationID) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain).help(L("graph.star.help"))
            }
            if !dot.preview.isEmpty {
                Text(dot.preview).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            HStack(spacing: 6) { Text(relativeTime(dot.updatedAt)); Text("·"); Text(L("graph.card.messages", dot.messageCount)) }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(10).frame(width: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func cardPosition(in size: CGSize) -> CGPoint {
        let cardW: CGFloat = 230, cardH: CGFloat = 70
        var x = hoverPoint.x + 16 + cardW / 2
        var y = hoverPoint.y + 16 + cardH / 2
        if x + cardW / 2 > size.width { x = hoverPoint.x - 16 - cardW / 2 }
        if y + cardH / 2 > size.height { y = hoverPoint.y - 16 - cardH / 2 }
        return CGPoint(x: x, y: y)
    }

    /// 信息卡的命中矩形（带容差）——判断鼠标是否在卡上，用于"冻结悬停 + 不误触父手势"
    private func infoCardFrame(in size: CGSize) -> CGRect {
        let w: CGFloat = 230, h: CGFloat = 92, pad: CGFloat = 10
        let c = cardPosition(in: size)
        return CGRect(x: c.x - w / 2 - pad, y: c.y - h / 2 - pad, width: w + pad * 2, height: h + pad * 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(L("history.graph.empty")).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 辅助

    private func updateHover(_ p: CGPoint) {
        guard let sim else { return }
        if let idx = sim.hitTest(toWorld(p)) {
            sim.hoveredIdx = idx                 // 冻住这个点，方便点中
            let id = sim.id(idx)
            if id != hoveredID { hoveredID = id; hoveredNeighbors = sim.neighbors(of: idx) }
        } else {
            sim.hoveredIdx = nil
            if hoveredID != nil { hoveredID = nil; hoveredNeighbors = [] }
        }
    }

    private func recomputeMatches() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let sim else { matchedIDs = []; return }
        matchedIDs = Set(sim.dots.filter { d in
            d.title.lowercased().contains(q) || d.preview.lowercased().contains(q) || d.keywords.contains(where: { $0.contains(q) })
        }.map { $0.id })
    }

    private func color(_ mode: AgentMode) -> Color { PetPaletteStore.shared.palette(for: mode).primary }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: LocaleManager.currentLanguage() == .zh ? "zh_CN" : "en_US")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func load() async {
        let days = (GraphWindow(rawValue: windowRaw) ?? .quarter).days
        let r = await Task.detached(priority: .userInitiated) {
            ConversationHistoryStore.shared.allForGraph(sinceDays: days)
        }.value
        rows = r.rows; totalInWindow = r.total; loaded = true; rebuild()
    }

    private func rebuild() {
        guard loaded, size.width > 1, size.height > 1 else { return }
        let layout = NebulaLayout.compute(rows: rows, size: size, insets: safeInsets)
        sim = NebulaSim(layout: layout, size: size, insets: safeInsets)
        starredIDs = Set(rows.filter { $0.starred }.map { $0.id })   // 从库的 starred 初始化
        recomputeMatches()
    }

    /// 阶段2·加星/取消：视图层 starredIDs + 写库同步。加星点立刻放大变亮 + ★（Canvas 每帧读 starredIDs）。
    private func toggleStar(_ dot: NebulaLayout.Dot) {
        let cid = dot.conversationID
        let newVal = !starredIDs.contains(cid)
        if newVal { starredIDs.insert(cid) } else { starredIDs.remove(cid) }
        ConversationHistoryStore.shared.setStarred(id: cid, newVal)
    }
}
