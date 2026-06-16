import SwiftUI

// MARK: - 后台 → 主线程的用量明细交接

/// 一次 AI 回合的真实/估算用量明细（Sendable，可从各 client 的后台回调里填）。
struct TokenUsageBreakdown: Sendable {
    var input: Int = 0        // 输入（非缓存）token
    var output: Int = 0       // 输出 token
    var cacheRead: Int = 0    // 缓存命中读取
    var cacheCreate: Int = 0  // 缓存写入
}

/// 线程安全的"信箱"：client 在后台流里把明细 `set` 进来，
/// ChatViewModel 在流结束（同一个 Task）`take` 出去记账。纯锁、不带执行器断言（守决策 #5/#22）。
final class TokenUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TokenUsageBreakdown?
    func set(_ v: TokenUsageBreakdown) { lock.lock(); value = v; lock.unlock() }
    func take() -> TokenUsageBreakdown? { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 记账存档（按天 / 按模型）

private struct ModelDayUsage: Codable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreate = 0
    var paidCostUSD = 0.0           // 按量付费实付（订阅后端 = 0）
    var apiValueUSD = 0.0           // 按 API 标价折算的价值（订阅省钱用：跟月费对比）
    var savedCacheUSD = 0.0         // 缓存命中省下（仅付费后端的差额）
    var subscriptionBacked = false  // 订阅制后端（卡片显示"订阅"、月费另算）
    var modeRaw = ""

    var tokensTotal: Int { input + output + cacheRead + cacheCreate }
}

private struct DayUsage: Codable {
    var models: [String: ModelDayUsage] = [:]
    var localSavedUSD = 0.0    // 本地处理省下的 token 价值（PDF/OCR/读屏 代替发图）
    var localSavedTokens = 0
}

private struct UsageArchive: Codable {
    var days: [String: DayUsage] = [:]   // key = "y-m-d"（同 UsageLedger 口径）
    var lifetimeTokens: Int = 0
}

// MARK: - 卡片要用的聚合结果

/// 单个模型在某段时间的汇总（给卡片画消耗条用）。
struct ModelUsageSummary: Identifiable {
    var id: String { model }
    let model: String
    let tokens: Int
    let costCNY: Double           // 实付（¥，按量付费后端）
    let subscriptionBacked: Bool  // true → 显示"订阅"
}

// MARK: - 中枢

/// Token 消耗 / 计费记账中枢。每完成一次 AI 回合记一笔，按天按模型累计实付与省钱。
/// `@MainActor @Observable` 单例 + JSON 持久化（范式同 `AIProfileStore`）。
@MainActor
@Observable
final class TokenUsageStore {
    static let shared = TokenUsageStore()

    // 订阅月费的 UserDefaults key（设置里填）
    static let claudeFeeKey = "claudeCodeSubFeeCNY"
    static let codexFeeKey  = "codexSubFeeCNY"

    private var archive = UsageArchive()

    private var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet")
        return dir.appendingPathComponent("token_usage.json")
    }

    private init() { load() }

    // MARK: 记一笔用量

    /// 完成一次 AI 回合后记账（在 MainActor 上调用）。
    func record(mode: AgentMode, model rawModel: String, breakdown b: TokenUsageBreakdown) {
        guard b.input + b.output + b.cacheRead + b.cacheCreate > 0 else { return }

        let price = ModelPricing.price(forModel: rawModel, mode: mode)
        let subscription = ModelPricing.isSubscriptionBacked(mode)
        let modelKey = displayModelKey(rawModel: rawModel, mode: mode)

        // 这笔用量按 API 标价折算成多少美元（缓存读 / 写各用各自单价）。
        let listCostUSD = price.costUSD(input: b.input, output: b.output,
                                        cacheRead: b.cacheRead, cacheWrite: b.cacheCreate)

        var paid = 0.0, savedCache = 0.0
        if subscription {
            // 订阅后端：不按量付费（月费另算）；listCost 作为"API 等值价值"留着跟月费对比省钱。
        } else {
            // 按量付费后端（在线 AI / Hermes / OpenClaw）：实付 = listCost（缓存已按便宜价计入）；
            // 缓存省下 = 命中的缓存读 token，相比按原价 input 便宜的那部分差额。
            paid = listCostUSD
            savedCache = Double(b.cacheRead) * max(0, price.inputPerM - price.cacheReadPerM) / 1_000_000.0
        }

        let key = Self.todayString()
        var day = archive.days[key] ?? DayUsage()
        var mu = day.models[modelKey] ?? ModelDayUsage()
        mu.input += b.input
        mu.output += b.output
        mu.cacheRead += b.cacheRead
        mu.cacheCreate += b.cacheCreate
        mu.paidCostUSD += paid
        mu.apiValueUSD += listCostUSD
        mu.savedCacheUSD += savedCache
        mu.subscriptionBacked = subscription
        mu.modeRaw = mode.rawValue
        day.models[modelKey] = mu
        archive.days[key] = day
        archive.lifetimeTokens += b.input + b.output + b.cacheRead + b.cacheCreate

        save()
    }

    /// 记一笔"本地处理省 token"（PDF 抽文本 / OCR / 读屏 代替把图片发给视觉模型）。
    /// `savedTokens` 由调用方算好（省下的视觉 token 减去实际发的文本 token，floor 0）。
    /// 在后台调用 → 调用方用 `Task { @MainActor in ... }` hop 进来。
    func recordLocalSaving(savedTokens: Int, referenceModel: String, mode: AgentMode) {
        guard savedTokens > 0 else { return }
        let price = ModelPricing.price(forModel: referenceModel, mode: mode)
        let usd = Double(savedTokens) * price.inputPerM / 1_000_000.0
        let key = Self.todayString()
        var day = archive.days[key] ?? DayUsage()
        day.localSavedTokens += savedTokens
        day.localSavedUSD += usd
        archive.days[key] = day
        save()
    }

    /// 模型展示名：给得出真名用真名，给不出（openclaw 没回报真模型 / 子进程没回报）退回后端品牌名。
    private func displayModelKey(rawModel: String, mode: AgentMode) -> String {
        let m = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["claude", "codex", "qwen", "openclaw", "deepseek", ""]
        if !generic.contains(m.lowercased()) { return m }
        return mode.label
    }

    // MARK: 聚合（给卡片）

    private let rate = ModelPricing.usdToCNY

    /// 今日实付（¥，只算按量付费；订阅是月费、不按天）。
    var todayPaidCNY: Double {
        let day = archive.days[Self.todayString()]
        let usd = day?.models.values.reduce(0) { $0 + $1.paidCostUSD } ?? 0
        return usd * rate
    }

    /// 本月实付（¥）= 按量付费合计 + 本月用过的订阅后端的月费。
    var monthPaidCNY: Double {
        let perToken = monthModels().reduce(0) { $0 + $1.paidCostUSD } * rate
        return perToken + monthSubscriptionFeeCNY
    }

    /// 本月用过的订阅后端，各计一次月费（没用过就不计，避免虚高）。
    var monthSubscriptionFeeCNY: Double {
        var modes = Set<String>()
        for m in monthModels() where m.subscriptionBacked { modes.insert(m.modeRaw) }
        return modes.reduce(0) { $0 + Self.monthlyFeeCNY(forModeRaw: $1) }
    }

    /// 本月"订阅折算"省下（¥）= 订阅后端 token 按 API 标价的价值 − 实付月费（floor 0）。
    var monthSavedSubscriptionCNY: Double {
        let apiValue = monthModels().filter { $0.subscriptionBacked }.reduce(0) { $0 + $1.apiValueUSD } * rate
        return max(0, apiValue - monthSubscriptionFeeCNY)
    }

    /// 本月"缓存命中"省下（¥）。
    var monthSavedCacheCNY: Double {
        monthModels().reduce(0) { $0 + $1.savedCacheUSD } * rate
    }

    /// 本月"本地省 token"省下（¥）。
    var monthSavedLocalCNY: Double {
        monthDays().reduce(0) { $0 + $1.localSavedUSD } * rate
    }

    /// 累计为你省下（¥）= 本地省 token + 订阅折算 + 缓存命中。
    var totalSavedCNY: Double {
        monthSavedLocalCNY + monthSavedSubscriptionCNY + monthSavedCacheCNY
    }

    /// 本月各模型消耗汇总，按 token 量降序。
    func monthModelBreakdown() -> [ModelUsageSummary] {
        var merged: [String: ModelDayUsage] = [:]
        for day in monthDays() {
            for (k, v) in day.models {
                var acc = merged[k] ?? ModelDayUsage()
                acc.input += v.input; acc.output += v.output
                acc.cacheRead += v.cacheRead; acc.cacheCreate += v.cacheCreate
                acc.paidCostUSD += v.paidCostUSD
                acc.apiValueUSD += v.apiValueUSD
                acc.subscriptionBacked = v.subscriptionBacked
                merged[k] = acc
            }
        }
        return merged.map {
            ModelUsageSummary(model: $0.key, tokens: $0.value.tokensTotal,
                              costCNY: $0.value.paidCostUSD * rate,
                              subscriptionBacked: $0.value.subscriptionBacked)
        }
        .filter { $0.tokens > 0 }
        .sorted { $0.tokens > $1.tokens }
    }

    /// 近 14 天每天的总 token 量（含今天，缺失天补 0），用于趋势条。
    func last14DaysTokens() -> [Int] {
        let cal = Calendar.current
        var result: [Int] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { result.append(0); continue }
            let key = Self.dayString(for: d)
            let dayTok = archive.days[key]?.models.values.reduce(0) { $0 + $1.tokensTotal } ?? 0
            result.append(dayTok)
        }
        return result
    }

    /// 累计总 token（这辈子用过多少）。
    var lifetimeTokens: Int { archive.lifetimeTokens }

    // MARK: 内部

    /// 当前自然月所有有记录的天。
    private func monthDays() -> [DayUsage] {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        let prefix = "\(c.year ?? 0)-\(c.month ?? 0)-"
        return archive.days.filter { $0.key.hasPrefix(prefix) }.map { $0.value }
    }

    /// 当前自然月所有模型记录（拍平）。
    private func monthModels() -> [ModelDayUsage] {
        monthDays().flatMap { $0.models.values }
    }

    /// 某订阅后端的月费（¥），从 UserDefaults 读。
    private static func monthlyFeeCNY(forModeRaw raw: String) -> Double {
        let ud = UserDefaults.standard
        switch raw {
        case AgentMode.claudeCode.rawValue: return ud.double(forKey: claudeFeeKey)
        case AgentMode.codex.rawValue:      return ud.double(forKey: codexFeeKey)
        default: return 0
        }
    }

    private static func dayString(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    private static func todayString() -> String { dayString(for: Date()) }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let a = try? JSONDecoder().decode(UsageArchive.self, from: data) else { return }
        archive = a
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
