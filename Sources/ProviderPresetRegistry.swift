import Foundation

/// 远程可更新的「在线 AI 服务商预设」清单。
///
/// **为什么要它**：以前加一个厂商（如小米 MiMo）要改 `ProviderPreset.swift` 源码 + 重新编译发版 + 公证，
/// 用户请求"能不能加 X"要等一整个发版周期。改成「远程清单」后：
///   - 加新厂商 = 改公开仓根目录的 `presets.json` 文件 push 一下 → 用户当天就能用，**不发版、不公证**。
///   - App 内置 `ProviderPreset.bundledDefaults` 永远作离线兜底，远程拉不到/没网时零影响。
///
/// **三层数据**（优先级从高到低）：
///   1. 远程 `presets.json`（公开仓 raw）—— 拉到并校验通过就缓存到 `~/.hermespet/presets.json`
///   2. 本地缓存（上一次成功拉到的）—— 离线/本次拉取失败时用
///   3. 内置兜底 `ProviderPreset.bundledDefaults` —— 永远存在
/// 有效清单 = 内置兜底，被远程/缓存**按 id 覆盖/追加**（远程能改已有厂商的模型名、也能加全新厂商）。
final class ProviderPresetRegistry: @unchecked Sendable {
    static let shared = ProviderPresetRegistry()

    /// 远程清单地址（公开仓根目录，改 JSON push 即生效；raw CDN 缓存约几分钟）。
    private static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/basionwang-bot/HermesPet/main/presets.json")!

    private let lock = NSLock()
    /// 远程/缓存解析出的预设（不含内置兜底）。
    private var remotePresets: [ProviderPreset] = []
    /// 合并后的有效清单缓存（避免每次 `ProviderPreset.all` 都重算 merge）。
    private var mergedCache: [ProviderPreset]?

    private init() {
        loadFromDiskCache()
    }

    // MARK: - 对外

    /// 有效预设清单（内置兜底 + 远程，按 id 覆盖/追加）。`ProviderPreset.all` 走这里。
    var effectivePresets: [ProviderPreset] {
        lock.lock(); defer { lock.unlock() }
        if let cached = mergedCache { return cached }
        let merged = Self.merge(bundled: ProviderPreset.bundledDefaults, remote: remotePresets)
        mergedCache = merged
        return merged
    }

    /// 后台拉远程清单刷新（仿 UpdateChecker：启动后调一次，失败静默回落兜底/缓存）。
    func refreshFromRemote() async {
        var req = URLRequest(url: Self.remoteURL)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let parsed = Self.parse(data), !parsed.isEmpty else {
            NSLog("[PresetRegistry] 远程清单拉取失败/为空，沿用兜底+缓存")
            return
        }
        // 写盘缓存 + 更新内存 + 注册到 proxy
        try? data.write(to: Self.cacheURL(), options: .atomic)
        apply(parsed)
        NSLog("[PresetRegistry] 远程清单已更新：%d 个 provider", parsed.count)
    }

    // MARK: - 内部

    private func loadFromDiskCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL()),
              let parsed = Self.parse(data), !parsed.isEmpty else { return }
        apply(parsed)
    }

    /// 落地一份解析好的远程清单：更新内存、清 merge 缓存、把每个 provider 的真实 upstream
    /// 注册给 ReasoningProxy（远程加的推理厂商也能被过滤、不泄漏思考过程），通知 UI 刷新。
    private func apply(_ presets: [ProviderPreset]) {
        lock.lock()
        remotePresets = presets
        mergedCache = nil
        let effective = Self.merge(bundled: ProviderPreset.bundledDefaults, remote: presets)
        mergedCache = effective
        lock.unlock()

        for p in effective {
            ReasoningProxy.shared.registerUpstream(id: p.id, baseURL: p.baseURL)
        }
        NotificationCenter.default.post(name: .init("HermesPetProviderPresetsUpdated"), object: nil)
    }

    /// 合并：内置兜底打底，远程按 id 覆盖（改模型名等）；远程独有 id 追加在末尾。
    private static func merge(bundled: [ProviderPreset], remote: [ProviderPreset]) -> [ProviderPreset] {
        var byID: [String: ProviderPreset] = [:]
        var order: [String] = []
        for p in bundled { byID[p.id] = p; order.append(p.id) }
        for p in remote {
            if byID[p.id] == nil { order.append(p.id) }
            byID[p.id] = p
        }
        return order.compactMap { byID[$0] }
    }

    /// 解析 presets.json → [ProviderPreset]。校验必填字段，跳过非法条目（一条坏数据不拖垮整张表）。
    private static func parse(_ data: Data) -> [ProviderPreset]? {
        guard let file = try? JSONDecoder().decode(PresetsFile.self, from: data) else { return nil }
        let valid = file.providers.compactMap { dto -> ProviderPreset? in
            let id = dto.id.trimmingCharacters(in: .whitespaces)
            let name = dto.displayName.trimmingCharacters(in: .whitespaces)
            let base = dto.baseURL.trimmingCharacters(in: .whitespaces)
            let model = dto.defaultModel.trimmingCharacters(in: .whitespaces)
            // 必填：id / 显示名 / baseURL（须 http(s)）/ 默认模型
            guard !id.isEmpty, !name.isEmpty, !model.isEmpty,
                  base.hasPrefix("http://") || base.hasPrefix("https://") else {
                NSLog("[PresetRegistry] 跳过非法预设条目 id=%@", id)
                return nil
            }
            return ProviderPreset(
                id: id,
                displayName: name,
                baseURL: base,
                defaultModel: model,
                altModels: dto.altModels ?? [],
                signupURL: dto.signupURL,
                fastModel: dto.fastModel,
                balancedModel: dto.balancedModel,
                deepModel: dto.deepModel,
                visionModel: dto.visionModel
            )
        }
        return valid
    }

    private static func cacheURL() -> URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/.hermespet/presets.json")
    }

    // MARK: - JSON 线格式（与 ProviderPreset 解耦，字段可选）

    private struct PresetsFile: Codable {
        let version: Int?
        let providers: [PresetDTO]
    }

    private struct PresetDTO: Codable {
        let id: String
        let displayName: String
        let baseURL: String
        let defaultModel: String
        let altModels: [String]?
        let signupURL: String?
        let fastModel: String?
        let balancedModel: String?
        let deepModel: String?
        let visionModel: String?
    }
}
