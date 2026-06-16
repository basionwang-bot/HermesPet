import Foundation
import CoreGraphics

// MARK: - 知识图谱数据模型（云图）
//
// 设计（见 memory [[conversation-memory-and-graph-vision]]）：
//   - **骨架永远对**：中心 → 各 AI mode → 各自的对话。这层 100% 准，图不会烂。
//   - **连线靠共享关键词**（不靠 AI 猜分类、也不靠不靠谱的本地向量）：两个对话共用 ≥N 个实词才连，
//     免费 / 本地 / 可解释，绝不瞎连。
//   - **力导向布局一次性算好**：确定性种子（不随机）→ 每次重建位置稳定不乱跳；静态渲染不跑实时物理。

enum GraphNodeKind: Sendable {
    case center        // 中心（桌宠 / app）
    case mode          // 一个 AI 后端
    case conversation  // 一个对话
}

struct GraphNode: Identifiable, Sendable {
    let id: String
    let kind: GraphNodeKind
    let label: String
    let mode: AgentMode?         // 配色用（center 为 nil）
    let conversationID: String?  // 点击重开用（仅 conversation）
    var size: CGFloat            // 半径（重要性：对话按消息数，mode/center 固定）
    var position: CGPoint        // 布局算出来的坐标
}

struct GraphEdge: Identifiable, Sendable {
    let id: String
    let from: String
    let to: String
    let weight: CGFloat
    let isSkeleton: Bool   // true=中心/mode 骨架（实线粗），false=话题连线（淡线）
}

struct GraphData: Sendable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var bounds: CGRect = .zero   // 所有节点的包围盒（渲染时居中/缩放用）
}

// MARK: - 建图

enum GraphBuilder {
    /// 从历史库的行构建 节点 + 连线。`minSharedKeywords` 越大连线越少越精。
    static func build(from rows: [ConversationHistoryStore.GraphRow], minSharedKeywords: Int = 2) -> GraphData {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []

        nodes.append(GraphNode(id: "center", kind: .center, label: "", mode: nil,
                               conversationID: nil, size: 26, position: .zero))

        // 出现过的 mode（保序：按 AgentMode.allCases 稳定顺序）
        let present = AgentMode.allCases.filter { m in rows.contains { $0.mode == m } }
        for m in present {
            nodes.append(GraphNode(id: "mode-\(m.rawValue)", kind: .mode, label: m.label,
                                   mode: m, conversationID: nil, size: 18, position: .zero))
            edges.append(GraphEdge(id: "sk-center-\(m.rawValue)", from: "center",
                                   to: "mode-\(m.rawValue)", weight: 1, isSkeleton: true))
        }

        for r in rows {
            let size = min(20, 7 + CGFloat(r.messageCount) * 0.4)
            nodes.append(GraphNode(id: "conv-\(r.id)", kind: .conversation, label: r.title,
                                   mode: r.mode, conversationID: r.id, size: size, position: .zero))
            edges.append(GraphEdge(id: "sk-\(r.mode.rawValue)-\(r.id)", from: "mode-\(r.mode.rawValue)",
                                   to: "conv-\(r.id)", weight: 1, isSkeleton: true))
        }

        // 话题连线：两两对话共享关键词 ≥ 阈值就连，权重 = 共享数
        let kwSets: [Set<String>] = rows.map { Set($0.keywords) }
        for i in 0..<rows.count {
            guard !kwSets[i].isEmpty else { continue }
            for j in (i + 1)..<rows.count {
                let shared = kwSets[i].intersection(kwSets[j]).count
                if shared >= minSharedKeywords {
                    edges.append(GraphEdge(id: "tp-\(rows[i].id)-\(rows[j].id)",
                                           from: "conv-\(rows[i].id)", to: "conv-\(rows[j].id)",
                                           weight: CGFloat(shared), isSkeleton: false))
                }
            }
        }

        var data = GraphData(nodes: nodes, edges: edges)
        GraphLayout.compute(&data)
        return data
    }
}

// MARK: - 力导向布局（spring-electrical，一次性算好；确定性种子保证稳定）

enum GraphLayout {
    static func compute(_ data: inout GraphData, iterations: Int = 240) {
        let n = data.nodes.count
        guard n > 0 else { return }

        // id → index
        var index: [String: Int] = [:]
        for (i, node) in data.nodes.enumerated() { index[node.id] = i }

        var px = [Double](repeating: 0, count: n)
        var py = [Double](repeating: 0, count: n)

        // mode 的固定"环位"（半锚定，保住 4 簇结构）
        let modeIdx = data.nodes.enumerated().filter { $0.element.kind == .mode }.map { $0.offset }
        var modeSlot: [Int: (Double, Double)] = [:]
        let modeRingR = 230.0
        for (k, mi) in modeIdx.enumerated() {
            let a = 2 * Double.pi * Double(k) / Double(max(1, modeIdx.count)) - Double.pi / 2
            modeSlot[mi] = (cos(a) * modeRingR, sin(a) * modeRingR)
        }

        // 确定性种子：mode 放环位；对话围着自己 mode 螺旋展开；center 原点
        let golden = Double.pi * (3 - (5.0).squareRoot())   // 黄金角
        var convCountPerMode: [Int: Int] = [:]
        for (i, node) in data.nodes.enumerated() {
            switch node.kind {
            case .center:
                px[i] = 0; py[i] = 0
            case .mode:
                let s = modeSlot[i] ?? (0, 0); px[i] = s.0; py[i] = s.1
            case .conversation:
                let mi = node.mode.flatMap { m in modeIdx.first { data.nodes[$0].id == "mode-\(m.rawValue)" } } ?? -1
                let base = modeSlot[mi] ?? (0, 0)
                let c = convCountPerMode[mi, default: 0]; convCountPerMode[mi] = c + 1
                let r = 60 + Double(c) * 7
                let a = Double(c) * golden
                px[i] = base.0 + cos(a) * r
                py[i] = base.1 + sin(a) * r
            }
        }

        // 边表（索引）
        let E: [(Int, Int, Double, Bool)] = data.edges.compactMap { e in
            guard let a = index[e.from], let b = index[e.to] else { return nil }
            return (a, b, Double(e.weight), e.isSkeleton)
        }

        let kRep = 9000.0          // 斥力强度
        let restSkeleton = 105.0   // 骨架边理想长度
        let restTopic = 240.0      // 话题边理想长度
        let kSkeleton = 0.045      // 骨架吸引（强，把对话拉近自己 mode）
        let kTopic = 0.010         // 话题吸引（弱，跨簇轻拉）
        let kModeAnchor = 0.05     // mode 拉回环位
        let maxStep = 30.0

        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)

        for it in 0..<iterations {
            let cooling = max(0.05, 1.0 - Double(it) / Double(iterations))
            for i in 0..<n { dx[i] = 0; dy[i] = 0 }

            // 斥力（O(n²)，n≤~620 一次性可接受）
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = px[i] - px[j]
                    var ddy = py[i] - py[j]
                    var d2 = ddx * ddx + ddy * ddy
                    if d2 < 0.01 { ddx = Double((i % 7) - 3) + 0.1; ddy = Double((j % 7) - 3) + 0.1; d2 = ddx * ddx + ddy * ddy }
                    let d = d2.squareRoot()
                    let f = kRep / d2
                    let ux = ddx / d, uy = ddy / d
                    dx[i] += ux * f; dy[i] += uy * f
                    dx[j] -= ux * f; dy[j] -= uy * f
                }
            }

            // 吸引（沿边）
            for (a, b, w, sk) in E {
                let ddx = px[a] - px[b], ddy = py[a] - py[b]
                let d = max(1.0, (ddx * ddx + ddy * ddy).squareRoot())
                let rest = sk ? restSkeleton : restTopic
                let k = (sk ? kSkeleton : kTopic) * (sk ? 1.0 : min(3.0, w))
                let f = (d - rest) * k
                let ux = ddx / d, uy = ddy / d
                dx[a] -= ux * f; dy[a] -= uy * f
                dx[b] += ux * f; dy[b] += uy * f
            }

            // 应用位移（cooling 限步）；center 钉死；mode 半锚定回环位
            for i in 0..<n {
                if data.nodes[i].kind == .center { px[i] = 0; py[i] = 0; continue }
                if data.nodes[i].kind == .mode, let s = modeSlot[i] {
                    dx[i] += (s.0 - px[i]) * kModeAnchor
                    dy[i] += (s.1 - py[i]) * kModeAnchor
                }
                var sx = dx[i], sy = dy[i]
                let mag = (sx * sx + sy * sy).squareRoot()
                if mag > maxStep { sx = sx / mag * maxStep; sy = sy / mag * maxStep }
                px[i] += sx * cooling
                py[i] += sy * cooling
            }
        }

        // 写回 + 算包围盒
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for i in 0..<n {
            let x = px[i].isFinite ? px[i] : 0
            let y = py[i].isFinite ? py[i] : 0
            data.nodes[i].position = CGPoint(x: x, y: y)
            let r = Double(data.nodes[i].size)
            minX = min(minX, x - r); minY = min(minY, y - r)
            maxX = max(maxX, x + r); maxY = max(maxY, y + r)
        }
        data.bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
