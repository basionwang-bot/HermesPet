import AppKit
import SwiftUI

/// 一个已安装应用的轻量描述（名字 + 路径）。图标按需在 View 里用 NSWorkspace 取（系统有缓存），
/// 不把 NSImage 存进结构体，避免上百个应用全驻留内存。
struct InstalledApp: Identifiable, Hashable, Sendable {
    let id: String       // 用绝对路径当唯一 id
    let name: String
    let path: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// 扫描本机已安装应用 + 按关键词过滤。`@MainActor @Observable` 单例。
///
/// 扫盘在后台线程做（`Task.detached`），结果回主线程赋值；图标在网格里按需取。
/// 启动应用走 `NSWorkspace.open`（本 app 无沙盒，直接可开）。
@MainActor
@Observable
final class AppLauncherStore {
    static let shared = AppLauncherStore()

    private(set) var apps: [InstalledApp] = []
    private(set) var loading = false
    var query: String = ""

    /// 每个 app 的累计打开次数（path → 次数），持久化。用来把高频 app 排前面。
    private var launchCounts: [String: Int] = [:]
    private static let countsKey = "appLaunchCounts"

    /// 过滤后的列表：先按名字模糊匹配，再**按打开次数降序**排（高频在前），次数相同按名字。
    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) }
        return base.sorted { a, b in
            let ca = launchCounts[a.path] ?? 0
            let cb = launchCounts[b.path] ?? 0
            if ca != cb { return ca > cb }                                    // 用得多的在前
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private init() {
        launchCounts = (UserDefaults.standard.dictionary(forKey: Self.countsKey) as? [String: Int]) ?? [:]
    }

    /// 第一次需要时扫描（已扫过就不重复）
    func loadIfNeeded() {
        guard apps.isEmpty, !loading else { return }
        reload()
    }

    /// 强制重扫（设置里"刷新"用）
    func reload() {
        loading = true
        let dirs = Self.scanDirs
        Task.detached(priority: .utility) {
            let found = Self.scan(dirs)
            await MainActor.run {
                self.apps = found
                self.loading = false
            }
        }
    }

    /// 打开一个应用（顺便累计打开次数 → 下次它排更前）
    func launch(_ app: InstalledApp) {
        NSWorkspace.shared.open(app.url)
        launchCounts[app.path, default: 0] += 1
        UserDefaults.standard.set(launchCounts, forKey: Self.countsKey)
    }

    // MARK: - 扫描实现（nonisolated，跑后台线程）

    /// 标准应用目录：/Applications（含 Utilities）、系统应用、用户级 ~/Applications
    nonisolated static var scanDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// 枚举各目录下的 *.app，去重 + 取显示名 + 按名字排序
    nonisolated static func scan(_ dirs: [URL]) -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [InstalledApp] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                let path = url.path
                if seen.contains(path) { continue }
                seen.insert(path)
                let name = fm.displayName(atPath: path)
                    .replacingOccurrences(of: ".app", with: "")
                result.append(InstalledApp(id: path, name: name, path: path))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
