import Foundation
import AppKit

/// 一条「已生成网页（Artifact）」的档案。
struct ArtifactRecord: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var fileName: String           // 相对 artifacts 目录的 html 文件名
    var createdAt: Date
    var modeRaw: String?           // 生成时的 AgentMode.rawValue（画廊显示来源色）
    var sourceMessageID: String?   // 从哪条聊天消息生成（聊天里挂链接用）；会议等来源为 nil

    var fileURL: URL { ArtifactStore.artifactsDir.appendingPathComponent(fileName) }
}

/// 已生成网页的持久化索引 —— 聊天链接 + 展览馆都靠它。落盘 `~/.hermespet/artifacts/index.json`。
@MainActor
@Observable
final class ArtifactStore {
    static let shared = ArtifactStore()

    /// 新的在前。
    private(set) var records: [ArtifactRecord] = []

    /// 纯拼路径、无共享状态 → nonisolated，让 nonisolated 的 ArtifactRecord.fileURL 也能用。
    nonisolated static var artifactsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermespet/artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var indexURL: URL { Self.artifactsDir.appendingPathComponent("index.json") }

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            records = (try? dec.decode([ArtifactRecord].self, from: data)) ?? []
        }
        backfillOrphans()   // 把"有 html 文件但没建档"的旧网页补进来（这次更新前生成的）
    }

    /// 扫描目录里没索引的 `artifact-*.html`，从 `<title>` 取标题、文件改动时间当日期，补进档案。
    private func backfillOrphans() {
        let dir = Self.artifactsDir
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let known = Set(records.map { $0.fileName })
        var added = false
        for url in files where url.pathExtension == "html" && url.lastPathComponent.hasPrefix("artifact-") {
            let name = url.lastPathComponent
            if known.contains(name) { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            let title = Self.extractTitle(from: url) ?? "历史网页"
            records.append(ArtifactRecord(id: UUID().uuidString, title: title, fileName: name,
                                          createdAt: date, modeRaw: nil, sourceMessageID: nil))
            added = true
        }
        if added {
            records.sort { $0.createdAt > $1.createdAt }
            persist()
        }
    }

    /// 从 HTML 抽 `<title>` 文本（补档用）。
    private static func extractTitle(from url: URL) -> String? {
        guard let html = try? String(contentsOf: url, encoding: .utf8),
              let r = html.range(of: "<title>", options: .caseInsensitive),
              let e = html.range(of: "</title>", options: .caseInsensitive,
                                 range: r.upperBound..<html.endIndex) else { return nil }
        let t = String(html[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 写 HTML 文件 + 建档，返回记录。
    @discardableResult
    func add(title: String, html: String, modeRaw: String?, sourceMessageID: String?) -> ArtifactRecord {
        let id = UUID().uuidString
        let fileName = "artifact-\(id).html"
        let url = Self.artifactsDir.appendingPathComponent(fileName)
        try? html.write(to: url, atomically: true, encoding: .utf8)
        let rec = ArtifactRecord(id: id,
                                 title: title.isEmpty ? "未命名网页" : title,
                                 fileName: fileName,
                                 createdAt: Date(),
                                 modeRaw: modeRaw,
                                 sourceMessageID: sourceMessageID)
        records.insert(rec, at: 0)
        persist()
        return rec
    }

    /// 「换个设计」重生成 —— 用**新文件名**覆盖同一条记录（新 URL 才能让 WKWebView 重载），删旧文件。
    @discardableResult
    func update(id: String, html: String, title: String?) -> URL? {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return nil }
        let oldURL = records[idx].fileURL
        let newFile = "artifact-\(id)-\(UUID().uuidString.prefix(6)).html"
        let newURL = Self.artifactsDir.appendingPathComponent(newFile)
        try? html.write(to: newURL, atomically: true, encoding: .utf8)
        if oldURL.lastPathComponent != newFile { try? FileManager.default.removeItem(at: oldURL) }
        records[idx].fileName = newFile
        if let t = title, !t.isEmpty { records[idx].title = t }
        persist()
        return newURL
    }

    func record(id: String) -> ArtifactRecord? { records.first { $0.id == id } }

    /// 某条聊天消息生成过的网页（取最新一条同源记录）。
    func recordForMessage(_ messageID: String) -> ArtifactRecord? {
        records.first { $0.sourceMessageID == messageID }
    }

    func delete(id: String) {
        guard let rec = record(id: id) else { return }
        try? FileManager.default.removeItem(at: rec.fileURL)
        records.removeAll { $0.id == id }
        persist()
    }
}
