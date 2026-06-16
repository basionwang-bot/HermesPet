import Foundation

// MARK: - 舰队产出存档(⑥ 统一博物馆的"舰队"那一半)
//
// FleetRun 本身是 @Observable class、纯内存、关窗即丢。要把完成的舰队运行收进博物馆,
// 就得把它"拍扁"成一份 Codable 快照落盘。范式照 ArtifactStore / WorkflowRunStore:
// Codable struct + @MainActor @Observable 单例 + ~/.hermespet/fleet/index.json 原子写。

/// 存档里的一名成员(回看"过程"用:谁、干了啥、产出摘要)。
struct ArchivedMember: Codable, Hashable, Identifiable {
    var id: String { roleKey + "·" + title }
    var roleKey: String
    var title: String
    var task: String
    var outputExcerpt: String   // 截断的产出(别把整篇塞进索引)
}

/// 一次完成的舰队运行快照。可陈列、可回看、可**按 plan 复用**(⑤ 的脚本本质在这里兑现)。
struct FleetArchive: Codable, Identifiable, Equatable {
    let id: String
    var topic: String           // 当初的任务
    var companyId: String
    var companyName: String
    var companySymbol: String
    var companyTintHex: String
    var modeRaw: String         // leadBackend.rawValue(卡片配色兜底)
    var plan: CaptainPlan?      // 可复用脚本(⑤;已 Codable)
    var product: String         // 最终成品(markdown,内联一份给预览用)
    var productPath: String?    // 成品 .md 文档的磁盘路径(可在 Finder 打开)
    var members: [ArchivedMember]
    var reviewSummary: String?  // 末轮质检结论摘要
    var versionCount: Int       // 打磨了几版
    var createdAt: Date

    var memberCount: Int { members.count }
}

@MainActor
@Observable
final class FleetArchiveStore {
    static let shared = FleetArchiveStore()

    private(set) var records: [FleetArchive] = []

    nonisolated static var fleetDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/fleet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var indexURL: URL { Self.fleetDir.appendingPathComponent("index.json") }

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([FleetArchive].self, from: data) {
            records = list
        }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 新增或按 id 覆盖(打磨产生新版时更新同一条),新的在前,最多留 60 条。
    func upsert(_ archive: FleetArchive) {
        records.removeAll { $0.id == archive.id }
        records.insert(archive, at: 0)
        if records.count > 60 { records = Array(records.prefix(60)) }
        persist()
    }

    func record(id: String) -> FleetArchive? { records.first { $0.id == id } }

    func delete(id: String) { records.removeAll { $0.id == id }; persist() }

    /// 把一次完成的舰队运行拍扁成存档并落盘。重复调用(打磨后)走同一 archiveID 覆盖更新。
    @discardableResult
    func archive(run: FleetRun) -> FleetArchive? {
        let product = run.product.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty else { return nil }
        let id = run.archiveID ?? UUID().uuidString
        run.archiveID = id

        let members: [ArchivedMember] = run.agents.map { a in
            ArchivedMember(roleKey: a.role?.rawValue ?? "",
                           title: a.role?.title ?? "成员",
                           task: a.title,
                           outputExcerpt: String(a.output.prefix(800)))
        }
        let company = run.company
        let archive = FleetArchive(
            id: id,
            topic: run.topic,
            companyId: company?.id ?? run.plan?.companyId ?? "",
            companyName: company?.name ?? run.plan?.companyName ?? "舰队",
            companySymbol: company?.symbol ?? "person.3.fill",
            companyTintHex: company?.tintHex ?? "8C6CFF",
            modeRaw: run.leadBackend.rawValue,
            plan: run.plan,
            product: String(product.prefix(60000)),
            productPath: run.productFileURL?.path,
            members: members,
            reviewSummary: run.latestVerdict?.summary,
            versionCount: max(1, run.versions.count),
            createdAt: Date())
        upsert(archive)
        return archive
    }
}
