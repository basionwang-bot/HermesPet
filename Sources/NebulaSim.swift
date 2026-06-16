import Foundation
import CoreGraphics

// MARK: - 主题聚类布点
//
// v2 转向（用户）：不再按 AI 分团，而是**按主题/意图分团**——把共享关键词连在一起的对话求**连通分量**，
// 每个分量 = 一个主题团（确定性、可解释，不靠 AI 猜）。团名 = 这团里最高频的关键词。点的颜色仍 = AI。
// 去掉背景 AI 色光晕。每团标文字主题，让用户一眼认出"这个问题属于哪个主题"。

/// 安全区内边距（点）：让所有团/点避开顶部菜单栏(含刘海)和底部/侧边 Dock，
/// 这样云图可以全屏铺满（背景沉浸），但可点击的点不会落在被系统栏遮挡的边缘。
struct GraphInsets {
    var top: CGFloat = 76
    var left: CGFloat = 20
    var bottom: CGFloat = 36
    var right: CGFloat = 20
}

struct NebulaLayout {
    struct Dot: Identifiable {
        let id: String
        let conversationID: String
        let title: String
        let preview: String
        let updatedAt: Date
        let messageCount: Int
        let mode: AgentMode        // 配色用（哪个 AI）
        let base: CGPoint
        let radius: CGFloat
        let phase: Double
        let keywords: Set<String>
        let recency: Double        // 0.35(久远)~1.0(最近) —— 越新越亮越大
        let salience: Double       // 阶段2·基础显著度 0~1（新鲜度+深度+回访+是否成团；不含加星，渲染时加星覆盖为 1）
    }

    /// 新鲜度：最近 ~45 天内从 1.0 渐降到 0.35（久远的也保底可见）
    static func recencyFactor(_ d: Date) -> Double {
        let days = max(0, -d.timeIntervalSinceNow / 86400)
        return max(0.35, 1 - days / 45)
    }

    /// 阶段2·基础显著度（0~1，不含加星）：本地可解释信号加权——
    /// 新鲜度 0.34 + 深度(消息数) 0.20 + 回访次数 0.30 + 是否属于主题团 0.16。
    /// 加星不在这里（渲染时强制覆盖为 1.0，永远压过算法分）。
    static func salience(recency: Double, messageCount: Int, openCount: Int, inCluster: Bool) -> Double {
        let rec = (recency - 0.35) / 0.65                       // 新鲜度归一 0~1
        let depth = min(1.0, Double(messageCount) / 20.0)       // 聊得越久越重要（20 条封顶）
        let revisit = min(1.0, Double(openCount) / 3.0)         // 回访：0→0 / 1→.33 / 3+→1（金标准信号）
        let cluster = inCluster ? 1.0 : 0.0                     // 属于主题团 vs 游离琐事
        let s = 0.34 * rec + 0.20 * depth + 0.30 * revisit + 0.16 * cluster
        return min(1.0, max(0.0, s))
    }
    /// 一个主题团（连通分量）
    struct Cluster {
        let label: String          // 主题名（最高频关键词；单点团为空不显示）
        let center: CGPoint
        let radius: CGFloat
        let members: [Int]         // dot 下标
    }

    var dots: [Dot]
    var links: [(a: Int, b: Int, w: Int)]   // w = 共享关键词数（关联强度，用于分级画线）
    var clusters: [Cluster]

    static let empty = NebulaLayout(dots: [], links: [], clusters: [])

    static func compute(rows: [ConversationHistoryStore.GraphRow], size: CGSize, insets: GraphInsets = GraphInsets()) -> NebulaLayout {
        let n = rows.count
        guard n > 0 else { return .empty }
        let kwSet = rows.map { Set($0.keywords) }
        var df: [String: Int] = [:]
        for s in kwSet { for k in s { df[k, default: 0] += 1 } }
        let genericCutoff = max(4, Int(Double(n) * 0.30))

        // 连线（共享 ≥2 个**具体**关键词；w=共享数=关联强度）—— 先有连线，才能按关系分团
        let spec = kwSet.map { $0.filter { (df[$0] ?? 0) <= genericCutoff } }
        var links: [(a: Int, b: Int, w: Int)] = []
        for i in 0..<n where !spec[i].isEmpty {
            for j in (i + 1)..<n {
                let sh = spec[i].intersection(spec[j]).count
                if sh >= 2 { links.append((i, j, sh)) }
            }
        }

        // 按**关系网密度**分团（标签传播社区检测，加权）：互相连得密的对话归到同一团 → 有关系的点聚一块；
        // 又不像连通分量那样一根线就全连。无连线的对话 → 零散单点。
        let comm = detectCommunities(n: n, links: links)
        var groups: [Int: [Int]] = [:]
        for i in 0..<n { groups[comm[i], default: []].append(i) }
        var tmp: [(label: String, members: [Int])] = []
        var loose: [Int] = []
        for (_, mem) in groups.sorted(by: { $0.key < $1.key }) {
            if mem.count >= 2 { tmp.append((clusterLabel(mem, rows, df), mem)) } else { loose.append(contentsOf: mem) }
        }
        for s in loose { tmp.append(("", [s])) }
        tmp.sort { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.label < $1.label }

        // 团的排布：按**团间关联度**做力导向摆位 —— 相关的团（跨团共享关键词多）互相吸拢、
        // 不相关的推开、整体向心。这样"相同/相似主题挨在一起"，连接性也看得出来。
        let golden = Double.pi * (3 - (5.0).squareRoot())
        let nC = tmp.count
        let crArr = tmp.map { CGFloat(min(150, 34 + Double($0.members.count).squareRoot() * 24)) }
        // 每个 dot 属于哪个团 + 团间关联权重（跨团连线数）
        var clusterOfDot = Array(repeating: 0, count: n)
        for (k, cl) in tmp.enumerated() { for m in cl.members { clusterOfDot[m] = k } }
        var w = Array(repeating: Array(repeating: 0.0, count: nC), count: nC)
        for l in links {
            let a = clusterOfDot[l.a], b = clusterOfDot[l.b]
            if a != b { w[a][b] += 1; w[b][a] += 1 }
        }
        // 元布局力导向（团中心）—— 向心点 = **安全区中心**（避开菜单栏/Dock 后的可用区中点）
        let sc = CGPoint(x: (insets.left + size.width - insets.right) / 2,
                         y: (insets.top + size.height - insets.bottom) / 2)
        var cx = [Double](repeating: 0, count: nC), cy = [Double](repeating: 0, count: nC)
        let seedR = Double(min(size.width, size.height)) * 0.30
        for k in 0..<nC {
            let ang = 2 * Double.pi * Double(k) / Double(max(1, nC)) - Double.pi / 2
            cx[k] = Double(sc.x) + cos(ang) * seedR
            cy[k] = Double(sc.y) + sin(ang) * seedR
        }
        let iters = 340
        for it in 0..<iters {
            let cool = max(0.05, 1 - Double(it) / Double(iters))
            var dx = [Double](repeating: 0, count: nC), dy = [Double](repeating: 0, count: nC)
            for i in 0..<nC {
                for j in (i + 1)..<nC {
                    var ddx = cx[i] - cx[j], ddy = cy[i] - cy[j]
                    var dist = (ddx * ddx + ddy * ddy).squareRoot()
                    if dist < 0.5 { ddx = Double((i % 5) - 2) + 0.3; ddy = Double((j % 7) - 3) + 0.3; dist = (ddx * ddx + ddy * ddy).squareRoot() }
                    let ux = ddx / dist, uy = ddy / dist
                    let minSep = Double(crArr[i] + crArr[j]) + 46
                    let rep = 95000.0 / (dist * dist)               // 互斥
                    dx[i] += ux * rep; dy[i] += uy * rep; dx[j] -= ux * rep; dy[j] -= uy * rep
                    if dist < minSep {                              // 不重叠硬约束
                        let push = (minSep - dist) * 0.5
                        dx[i] += ux * push; dy[i] += uy * push; dx[j] -= ux * push; dy[j] -= uy * push
                    }
                    if w[i][j] > 0 {                                // 相关 → 吸拢
                        let rest = minSep + 16
                        let att = (dist - rest) * 0.012 * min(3.0, w[i][j])
                        dx[i] -= ux * att; dy[i] -= uy * att; dx[j] += ux * att; dy[j] += uy * att
                    }
                }
                dx[i] += (Double(sc.x) - cx[i]) * 0.004              // 向心
                dy[i] += (Double(sc.y) - cy[i]) * 0.004
            }
            for k in 0..<nC {
                var sx = dx[k], sy = dy[k]
                let mag = (sx * sx + sy * sy).squareRoot()
                if mag > 40 { sx = sx / mag * 40; sy = sy / mag * 40 }
                cx[k] += sx * cool; cy[k] += sy * cool
            }
        }
        // 收尾：硬分离消重叠 + 收进屏幕（交替松弛，像圆堆积）
        for _ in 0..<70 {
            for i in 0..<nC {
                for j in (i + 1)..<nC {
                    var ddx = cx[i] - cx[j], ddy = cy[i] - cy[j]
                    var d = (ddx * ddx + ddy * ddy).squareRoot()
                    if d < 0.5 { ddx = Double((i % 5) - 2) + 0.4; ddy = Double((j % 7) - 3) + 0.4; d = (ddx * ddx + ddy * ddy).squareRoot() }
                    let need = Double(crArr[i] + crArr[j]) + 28
                    if d < need {
                        let push = (need - d) * 0.5, ux = ddx / d, uy = ddy / d
                        cx[i] += ux * push; cy[i] += uy * push
                        cx[j] -= ux * push; cy[j] -= uy * push
                    }
                }
            }
            for k in 0..<nC {
                cx[k] = min(Double(size.width - insets.right) - Double(crArr[k]) - 12,
                            max(Double(insets.left) + Double(crArr[k]) + 12, cx[k]))
                cy[k] = min(Double(size.height - insets.bottom) - Double(crArr[k]) - 12,
                            max(Double(insets.top) + Double(crArr[k]) + 12, cy[k]))
            }
        }

        var clusters: [Cluster] = []
        var base = Array(repeating: CGPoint.zero, count: n)
        for (k, cl) in tmp.enumerated() {
            let center = CGPoint(x: cx[k], y: cy[k])
            let cnt = cl.members.count
            let cr = crArr[k]
            let hole = cl.label.isEmpty ? 0.0 : 22.0   // 留个中心空给主题标题
            for (j, di) in cl.members.enumerated() {
                let rr = cnt == 1 ? 0.0 : hole + (Double(cr) - hole) * (Double(j) + 0.5).squareRoot() / Double(cnt).squareRoot()
                let a = Double(j) * golden
                base[di] = CGPoint(x: center.x + CGFloat(cos(a) * rr), y: center.y + CGFloat(sin(a) * rr))
            }
            clusters.append(Cluster(label: cl.label, center: center, radius: cr, members: cl.members))
        }

        var dots: [Dot] = []
        for i in 0..<n {
            let c = rows[i]
            let rec = NebulaLayout.recencyFactor(c.updatedAt)
            let inCluster = tmp[clusterOfDot[i]].members.count >= 2   // 属于主题团 vs 游离单点
            let sal = NebulaLayout.salience(recency: rec, messageCount: c.messageCount,
                                            openCount: c.openCount, inCluster: inCluster)
            dots.append(Dot(id: "conv-\(c.id)", conversationID: c.id, title: c.title, preview: c.preview,
                            updatedAt: c.updatedAt, messageCount: c.messageCount, mode: c.mode,
                            base: base[i], radius: min(12, max(4, 4 + CGFloat(c.messageCount) * 0.35)),
                            phase: Double(i) * 0.618 * .pi, keywords: kwSet[i],
                            recency: rec, salience: sal))
        }
        return NebulaLayout(dots: dots, links: links, clusters: clusters)
    }

    /// 团主题名（约 6-7 字，方便快速联想）：取本团**共享得最多**（freq 高 = 大家都聊）的关键词打头，
    /// 再补 freq 高的词；只用本团出现 ≥2 次的（避 fluke 冷词），同 freq 时按区分度(freq/df)排。
    private static func clusterLabel(_ members: [Int], _ rows: [ConversationHistoryStore.GraphRow], _ df: [String: Int]) -> String {
        var freq: [String: Int] = [:]
        for m in members { for k in rows[m].keywords { freq[k, default: 0] += 1 } }
        func score(_ k: String) -> Double { Double(freq[k] ?? 0) / Double(max(1, df[k] ?? 1)) }
        var pool = freq.keys.filter { (freq[$0] ?? 0) >= 2 }
        if pool.isEmpty { pool = Array(freq.keys) }   // 极端：没有共享词，用任意高频词兜底
        let sorted = pool.sorted {
            freq[$0]! != freq[$1]! ? freq[$0]! > freq[$1]! : (score($0) != score($1) ? score($0) > score($1) : $0 < $1)
        }
        var parts: [String] = []
        var chars = 0
        for k in sorted {
            parts.append(k); chars += k.count
            if (parts.count >= 2 && chars >= 6) || parts.count >= 3 { break }
        }
        return parts.joined(separator: " ")
    }

    /// 标签传播社区检测（加权）：每轮每个节点采纳"邻居里连线权重之和最大"的标签；
    /// 当前标签若已是最大则保留（减少抖动）。互相连得密的归一类。
    private static func detectCommunities(n: Int, links: [(a: Int, b: Int, w: Int)]) -> [Int] {
        guard n > 0 else { return [] }
        var adj = Array(repeating: [(Int, Double)](), count: n)
        for l in links { adj[l.a].append((l.b, Double(l.w))); adj[l.b].append((l.a, Double(l.w))) }
        var label = Array(0..<n)
        for _ in 0..<16 {
            var changed = false
            for i in 0..<n where !adj[i].isEmpty {
                var sc: [Int: Double] = [:]
                for (nb, w) in adj[i] { sc[label[nb], default: 0] += w }
                let mx = sc.values.max() ?? 0
                let best = sc.filter { $0.value == mx }.keys
                if best.contains(label[i]) { continue }   // 当前已是最优 → 不动
                if let chosen = best.min(), chosen != label[i] { label[i] = chosen; changed = true }
            }
            if !changed { break }
        }
        return label
    }
}

// MARK: - 弹簧物理引擎（联动拖拽 + 甩动钻入主题团）

final class NebulaSim {
    private(set) var dots: [NebulaLayout.Dot]
    let clusters: [NebulaLayout.Cluster]
    let links: [(a: Int, b: Int, w: Int)]

    private var px: [Double], py: [Double], vx: [Double], vy: [Double]
    private var homeX: [Double], homeY: [Double]
    private let baseHomeX: [Double], baseHomeY: [Double]
    private let clusterIdx: [Int]
    private let idToIndex: [String: Int]

    private let size: CGSize
    private let insets: GraphInsets       // 安全区：物理积分后把点夹回，绝不飘到菜单栏/Dock 下
    private(set) var focusedSet: Set<Int>?
    private(set) var focusedLabel: String = ""
    private var lastT: Double = 0
    var fadeAlpha: Double = 1

    var draggedIdx: Int?
    var dragTarget: CGPoint = .zero
    var hoveredIdx: Int?        // 鼠标悬停的点 → 冻住不动，方便点中

    private let kSpring = 0.020, restLen = 78.0, kRep = 4500.0
    private let kCohesion = 0.022, kHome = 0.0045   // 内聚到动态质心(联动) + 弱锚回固定位置(归位)
    private let damping = 0.86, vClamp = 16.0

    var count: Int { dots.count }
    var isFocused: Bool { focusedSet != nil }

    init(layout: NebulaLayout, size: CGSize, insets: GraphInsets = GraphInsets()) {
        self.size = size
        self.insets = insets
        self.dots = layout.dots
        self.clusters = layout.clusters
        self.links = layout.links
        var ci = Array(repeating: 0, count: layout.dots.count)
        for (k, cl) in layout.clusters.enumerated() { for m in cl.members { ci[m] = k } }
        self.clusterIdx = ci
        self.px = layout.dots.map { Double($0.base.x) }
        self.py = layout.dots.map { Double($0.base.y) }
        self.vx = Array(repeating: 0, count: layout.dots.count)
        self.vy = Array(repeating: 0, count: layout.dots.count)
        let hx = layout.dots.indices.map { Double(layout.clusters[ci[$0]].center.x) }
        let hy = layout.dots.indices.map { Double(layout.clusters[ci[$0]].center.y) }
        self.baseHomeX = hx; self.baseHomeY = hy
        self.homeX = hx; self.homeY = hy
        self.idToIndex = Dictionary(uniqueKeysWithValues: layout.dots.enumerated().map { ($0.element.id, $0.offset) })
    }

    func step(_ t: Double) {
        guard count > 0 else { return }
        if lastT == 0 { lastT = t }
        let dt = min(max(t - lastT, 0), 0.033); lastT = t
        let f = dt * 60
        guard f > 0 else { return }

        let targetFade = focusedSet == nil ? 1.0 : 0.0
        fadeAlpha += (targetFade - fadeAlpha) * min(1, dt * 6)

        var fx = [Double](repeating: 0, count: count)
        var fy = [Double](repeating: 0, count: count)

        // 各团动态质心（含被拖动的点）—— 拖一个点 → 质心偏移 → 同团其他点被"内聚"拉着跟过来
        let nC = clusters.count
        var ccx = [Double](repeating: 0, count: nC), ccy = [Double](repeating: 0, count: nC)
        var ccn = [Int](repeating: 0, count: nC)
        for i in 0..<count { let c = clusterIdx[i]; ccx[c] += px[i]; ccy[c] += py[i]; ccn[c] += 1 }
        for c in 0..<nC where ccn[c] > 0 { ccx[c] /= Double(ccn[c]); ccy[c] /= Double(ccn[c]) }

        for i in 0..<count where active(i) {
            let c = clusterIdx[i]
            fx[i] += (ccx[c] - px[i]) * kCohesion      // 内聚到动态质心 → 联动跟随
            fy[i] += (ccy[c] - py[i]) * kCohesion
            fx[i] += (homeX[i] - px[i]) * kHome         // 弱锚回相关度位置（松手归位、团不漂走）
            fy[i] += (homeY[i] - py[i]) * kHome
            // ambient 大幅调小 + 放慢 → 几乎静止的轻微呼吸（柔顺、且点不乱跑好点中）
            fx[i] += sin(t * 0.32 + dots[i].phase) * 0.04
            fy[i] += cos(t * 0.28 + dots[i].phase * 1.3) * 0.04
        }
        // 弹簧只在**同团内**拉 → 不同团不互相牵扯，团才稳稳待在各自格子里、清爽分开
        for link in links where active(link.a) && active(link.b) && clusterIdx[link.a] == clusterIdx[link.b] {
            let a = link.a, b = link.b
            var ddx = px[a] - px[b], ddy = py[a] - py[b]
            var d = (ddx * ddx + ddy * ddy).squareRoot()
            if d < 0.01 { ddx = 0.1; ddy = 0.1; d = 0.14 }
            let force = (d - restLen) * kSpring
            let ux = ddx / d, uy = ddy / d
            fx[a] -= ux * force; fy[a] -= uy * force
            fx[b] += ux * force; fy[b] += uy * force
        }
        let act = (0..<count).filter { active($0) }
        for ii in 0..<act.count {
            for jj in (ii + 1)..<act.count {
                let i = act[ii], j = act[jj]
                // 只在**同一主题团内**互斥 → 不同团不互相挤，团之间留白、不黏成一坨
                if clusterIdx[i] != clusterIdx[j] { continue }
                var ddx = px[i] - px[j], ddy = py[i] - py[j]
                var d2 = ddx * ddx + ddy * ddy
                if d2 < 1 { ddx = Double((i % 5) - 2) + 0.3; ddy = Double((j % 5) - 2) + 0.3; d2 = ddx * ddx + ddy * ddy }
                let force = kRep / d2
                let d = d2.squareRoot()
                let ux = ddx / d, uy = ddy / d
                fx[i] += ux * force; fy[i] += uy * force
                fx[j] -= ux * force; fy[j] -= uy * force
            }
        }

        for i in 0..<count where active(i) {
            if i == draggedIdx {
                let nx = Double(dragTarget.x), ny = Double(dragTarget.y)
                vx[i] = nx - px[i]; vy[i] = ny - py[i]
                px[i] = nx; py[i] = ny
                continue
            }
            if i == hoveredIdx { vx[i] = 0; vy[i] = 0; continue }   // 悬停的点冻住 → 好点中
            vx[i] = (vx[i] + fx[i]) * damping
            vy[i] = (vy[i] + fy[i]) * damping
            vx[i] = max(-vClamp, min(vClamp, vx[i]))
            vy[i] = max(-vClamp, min(vClamp, vy[i]))
            px[i] += vx[i] * f
            py[i] += vy[i] * f
            // 夹回安全区：飘动/弹簧都不能把点推到菜单栏或 Dock 下面（撞边就归零该方向速度）
            let r = Double(dots[i].radius)
            let minX = Double(insets.left) + r, maxX = Double(size.width - insets.right) - r
            let minY = Double(insets.top) + r,  maxY = Double(size.height - insets.bottom) - r
            if px[i] < minX { px[i] = minX; if vx[i] < 0 { vx[i] = 0 } }
            else if px[i] > maxX { px[i] = maxX; if vx[i] > 0 { vx[i] = 0 } }
            if py[i] < minY { py[i] = minY; if vy[i] < 0 { vy[i] = 0 } }
            else if py[i] > maxY { py[i] = maxY; if vy[i] > 0 { vy[i] = 0 } }
        }
    }

    private func active(_ i: Int) -> Bool { focusedSet == nil || focusedSet!.contains(i) }

    /// 抓住 root → 把它所属的**主题团**整团拽到屏幕中心摊开
    func setFocus(rootIndex: Int?, size: CGSize) {
        guard let root = rootIndex else {
            focusedSet = nil; focusedLabel = ""
            for i in 0..<count { homeX[i] = baseHomeX[i]; homeY[i] = baseHomeY[i] }
            return
        }
        let cl = clusters[clusterIdx[root]]
        focusedSet = Set(cl.members)
        focusedLabel = cl.label
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        for i in cl.members { homeX[i] = Double(c.x); homeY[i] = Double(c.y) }
    }

    // 查询
    func point(_ i: Int) -> CGPoint { CGPoint(x: px[i], y: py[i]) }
    func radius(_ i: Int) -> CGFloat { dots[i].radius }
    func mode(_ i: Int) -> AgentMode { dots[i].mode }
    func id(_ i: Int) -> String { dots[i].id }
    func conversationID(_ i: Int) -> String? { dots[i].conversationID }
    func dot(_ id: String) -> NebulaLayout.Dot? { idToIndex[id].map { dots[$0] } }
    func index(of id: String) -> Int? { idToIndex[id] }
    func isActive(_ i: Int) -> Bool { active(i) }
    func clusterIndexOf(_ i: Int) -> Int { clusterIdx[i] }
    /// 某点的直接连线邻居（下标集）—— 悬停聚光用
    func neighbors(of i: Int) -> Set<Int> {
        var s = Set<Int>()
        for l in links { if l.a == i { s.insert(l.b) }; if l.b == i { s.insert(l.a) } }
        return s
    }

    /// 取某点的"相关对话"：所属主题团（≥2 成员）的全部；若是零散单点 → 它自己 + 直接连线的邻居。
    /// 给"拖到右侧 → 卡片列表"用。按更新时间倒序。
    func relatedDots(forDot i: Int) -> (label: String, dots: [NebulaLayout.Dot]) {
        let cl = clusters[clusterIdx[i]]
        var idxs: [Int]
        if cl.members.count >= 2 {
            idxs = cl.members
        } else {
            var set: Set<Int> = [i]
            for l in links { if l.a == i { set.insert(l.b) }; if l.b == i { set.insert(l.a) } }
            idxs = Array(set)
        }
        let sorted = idxs.map { dots[$0] }.sorted { $0.updatedAt > $1.updatedAt }
        return (cl.label, sorted)
    }

    func release(_ i: Int, velocity: CGVector) {
        guard i < count else { return }
        vx[i] = max(-vClamp, min(vClamp, Double(velocity.dx)))
        vy[i] = max(-vClamp, min(vClamp, Double(velocity.dy)))
    }

    func hitTest(_ p: CGPoint) -> Int? {
        var best: Int?; var bestD = Double.greatestFiniteMagnitude
        for i in 0..<count where active(i) {
            let dx = px[i] - Double(p.x), dy = py[i] - Double(p.y)
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= Double(dots[i].radius) + 16, d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// 主题团标签的位置 = 该团活跃点的当前质心
    func clusterRenderCenter(_ clusterIndex: Int) -> CGPoint {
        let members = clusters[clusterIndex].members.filter { active($0) }
        guard !members.isEmpty else { return clusters[clusterIndex].center }
        var sx = 0.0, sy = 0.0
        for i in members { sx += px[i]; sy += py[i] }
        return CGPoint(x: sx / Double(members.count), y: sy / Double(members.count))
    }
}
