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
    /// v2 = AI 档案中心：把现有后端配置转成默认档案
    private static let latestVersion = 2

    private static let versionKey = "hermesPetSchemaVersion"

    /// App 启动时调用。从当前版本逐步迁移到 latestVersion。
    /// 整个过程在主线程同步跑（迁移操作都是 UserDefaults 读写，非常快）。
    @MainActor
    static func runMigrations() {
        // 先做 bundle ID 域迁移（独立 flag，跟 schema 版本无关，只跑一次）：
        // 必须赶在读取任何配置之前，把旧 bundle ID 域的设置 / API Key 搬到当前域，让老用户升级无感。
        migrateLegacyBundleIDDomain()

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
        ),
        Migration(
            targetVersion: 2,
            description: "把现有 directAPI/hermes/qwen 配置转成「AI 档案中心」的默认档案",
            run: { MainActor.assumeIsolated { AIProfileStore.shared.seedFromLegacyIfNeeded() } }
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

    // MARK: - 一次性 bundle ID 域迁移

    /// v1.2.11：bundle ID 从 `com.nousresearch.hermespet` 改成 `com.basionwang.hermespet`。
    /// macOS 把新 bundle ID 当成全新 app，UserDefaults 域随之改变，老用户的设置 / API Key
    /// 会"消失"。这里把旧域的所有键值搬到当前域，让升级无感。独立 flag 记录，保证只跑一次、幂等。
    @MainActor
    static func migrateLegacyBundleIDDomain() {
        let flag = "didMigrateLegacyBundleIDDomain"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: flag) else { return }

        let legacyDomain = "com.nousresearch.hermespet"
        if let keys = CFPreferencesCopyKeyList(legacyDomain as CFString,
                                               kCFPreferencesCurrentUser,
                                               kCFPreferencesAnyHost) as? [String] {
            var moved = 0
            // 不覆盖当前域已有值（保险）；逐个把旧域键值搬过来
            for key in keys where ud.object(forKey: key) == nil {
                if let value = CFPreferencesCopyAppValue(key as CFString, legacyDomain as CFString) {
                    ud.set(value, forKey: key)
                    moved += 1
                }
            }
            if moved > 0 {
                NSLog("[SchemaMigrator] 从旧 bundle ID 域迁移了 %d 个设置项", moved)
            }
        }
        ud.set(true, forKey: flag)
    }
}
