import Foundation

/// 模型上下文窗口目录 —— 从 models.dev 拉真实、最新的上下文窗口大小。
///
/// 为什么不硬编码：模型上下文一直在涨（DeepSeek、Opus 都到 1M 了），写死的表很快过时。
/// models.dev 是社区维护、覆盖几乎所有模型规格的开放库（opencode 也用它）。
/// 注意：「上下文窗口」是模型的固定**规格**，聊天 API 的 usage 只回报「已用多少」、从不带「上限」，
/// 所以上限只能查规格库拿，没有「从模型检测」的捷径（Cursor / Claude Code 同样是查自己维护的库）。
///
/// 策略：启动时同步加载本地缓存（秒级），同时异步刷新一次最新数据落盘。
/// 离线 / 首次还没拉到 → 返回 nil，让上层回退到内置兜底表。
final class ModelCatalog: @unchecked Sendable {
    static let shared = ModelCatalog()

    private let lock = NSLock()
    /// modelID(小写) → context 窗口 token 数
    private var windowByModel: [String: Int] = [:]
    /// 已解析过的"我们的模型名 → 窗口"memo，避免每次渲染都跑模糊匹配
    private var resolveMemo: [String: Int] = [:]

    private static let apiURL = URL(string: "https://models.dev/api.json")!
    private var cachePath: String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".hermespet")
        return (dir as NSString).appendingPathComponent("modelsdev.json")
    }

    private init() {}

    /// 启动调用：先同步加载本地缓存，再异步拉最新刷新。
    func loadCachedAndRefresh() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) {
            parse(data)
        }
        Task.detached { [weak self] in await self?.refresh() }
    }

    /// 异步拉 models.dev 最新数据，成功则落盘 + 重新解析。失败静默（保留旧缓存/兜底）。
    private func refresh() async {
        do {
            let (data, resp) = try await URLSession.shared.data(from: Self.apiURL)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return }
            parse(data)
            let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".hermespet")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: cachePath))
        } catch {
            // 离线 / 拉取失败 —— 用旧缓存或兜底表，不打扰用户
        }
    }

    /// 解析 models.dev：{ providerID: { models: { modelID: { limit: { context: N } } } } }
    private func parse(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var map: [String: Int] = [:]
        for (_, prov) in root {
            guard let prov = prov as? [String: Any],
                  let models = prov["models"] as? [String: Any] else { continue }
            for (modelID, m) in models {
                guard let m = m as? [String: Any],
                      let limit = m["limit"] as? [String: Any],
                      let ctx = limit["context"] as? Int, ctx > 0 else { continue }
                let key = modelID.lowercased()
                // 同名模型跨多个 provider，取较大的窗口
                map[key] = max(map[key] ?? 0, ctx)
            }
        }
        guard !map.isEmpty else { return }
        lock.lock()
        windowByModel = map
        resolveMemo.removeAll()   // 数据变了，清 memo
        lock.unlock()
    }

    /// 按我们手上的模型名查真实上下文窗口。查不到返回 nil（上层回退内置表）。
    /// 匹配顺序：精确 → 去 provider 前缀(prov/model) → 去 @ 后缀 → 子串包含（取最长匹配）。
    func contextWindow(for rawModel: String) -> Int? {
        let id = rawModel.lowercased().trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }

        lock.lock(); defer { lock.unlock() }
        guard !windowByModel.isEmpty else { return nil }
        if let memo = resolveMemo[id] { return memo > 0 ? memo : nil }

        var found: Int?
        if let c = windowByModel[id] {
            found = c
        } else if let slash = id.lastIndex(of: "/"),
                  let c = windowByModel[String(id[id.index(after: slash)...])] {
            found = c
        } else if let at = id.firstIndex(of: "@"),
                  let c = windowByModel[String(id[..<at])] {
            found = c
        } else {
            // 子串包含：找最长的能对上的 key（避免 "gpt" 误匹配到 "gpt-3.5"）
            var bestLen = 0
            for (k, v) in windowByModel where k.count > bestLen && (id.contains(k) || k.contains(id)) {
                found = v; bestLen = k.count
            }
        }
        // memo（查不到也记 0，避免反复跑模糊匹配）
        resolveMemo[id] = found ?? 0
        return found
    }
}
