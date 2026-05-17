import Foundation

/// HermesPet 配置迁移框架。
///
/// **为什么需要这个**：升级新版本时，UserDefaults 字段语义可能变（如某 bool 改成 enum，
/// 或全局 key 改成 scoped key）。如果不写迁移代码，老用户升级后会出现"配置丢失"
/// 或"配置错乱"的体验问题。
///
/// **设计**：每次 App 启动早期跑一次。维护一个全局版本号，从当前版本逐步迁移到最新版本。
/// 每个迁移只关心自己负责的一步（version N → version N+1），不需要知道前后状态。
///
/// **添加新迁移的步骤**：
///   1. 在 `migrations` 数组末尾追加一个新元素：`(targetVersion, "描述", { ... })`
///   2. 把 `latestVersion` +1
///   3. 在 closure 里写实际的迁移逻辑（读旧 key、写新 key、删旧 key）
///   4. 迁移代码要 **幂等**：第二次跑也不能出问题（防止重启循环触发）
enum SchemaMigrator {

    /// 当前 schema 最新版本号。每加一条新迁移就 +1。
    /// v0 = v1.2.2 及以前（没有版本号字段）
    /// v1 = v1.2.3 引入 scoped directAPIKey
    private static let latestVersion = 1

    private static let versionKey = "hermesPetSchemaVersion"

    /// App 启动时调用。从当前版本逐步迁移到 latestVersion。
    /// 整个过程在主线程同步跑（迁移操作都是 UserDefaults 读写，非常快）。
    @MainActor
    static func runMigrations() {
        let currentVersion = UserDefaults.standard.integer(forKey: versionKey)
        guard currentVersion < latestVersion else {
            NSLog("[SchemaMigrator] up to date (version=%d)", currentVersion)
            return
        }

        NSLog("[SchemaMigrator] migrating: v%d → v%d", currentVersion, latestVersion)

        for migration in migrations where migration.targetVersion > currentVersion {
            NSLog("[SchemaMigrator] running v%d: %@",
                  migration.targetVersion, migration.description)
            migration.run()
            UserDefaults.standard.set(migration.targetVersion, forKey: versionKey)
        }

        NSLog("[SchemaMigrator] done, now at v%d", latestVersion)
    }

    /// 内部迁移定义结构。
    /// Sendable + @Sendable closure 让 Swift 6 strict concurrency 允许 `static let migrations` 数组。
    private struct Migration: Sendable {
        let targetVersion: Int
        let description: String
        let run: @Sendable () -> Void
    }

    /// 所有迁移按 targetVersion 升序排列。
    /// **不要在中间插入或调换顺序**，会导致用户状态错乱。
    private static let migrations: [Migration] = [
        Migration(
            targetVersion: 1,
            description: "把旧全局 directAPIKey 复制到 scoped directAPIKey.<providerID>",
            run: migrateGlobalDirectAPIKeyToScoped
        )
    ]

    // MARK: - 具体迁移实现

    /// v0 → v1：v1.2.3 引入了按 provider 分开存的 `directAPIKey.<providerID>`，
    /// 但 v1.2.2 用户只在全局 `directAPIKey` 里存了 key。
    /// 老用户升级后切换 provider 会因为 scoped key 空而读不到 key（虽然 effectiveAPIKey
    /// 有 fallback 但只 fallback 一次，且不同 provider 用同一个 key 会鉴权失败）。
    /// 迁移策略：把旧 key 复制到**当前选中** provider 的 scoped key，旧 key 保留（兜底）。
    private static func migrateGlobalDirectAPIKeyToScoped() {
        let ud = UserDefaults.standard
        let globalKey = ud.string(forKey: "directAPIKey") ?? ""
        guard !globalKey.isEmpty else { return }   // 没存过全局 key，无需迁移

        let providerID = ud.string(forKey: "directAPIProviderID") ?? "deepseek"
        let scopedKeyName = "directAPIKey.\(providerID)"

        // 已经有 scoped key 就不要覆盖（用户可能后续手动改过）
        if let existing = ud.string(forKey: scopedKeyName), !existing.isEmpty {
            return
        }
        ud.set(globalKey, forKey: scopedKeyName)
        NSLog("[SchemaMigrator] copied global directAPIKey → %@", scopedKeyName)
    }
}
