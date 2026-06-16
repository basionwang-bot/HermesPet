import SwiftUI
import Foundation

/// 应用界面语言。v1.4 起支持中英双语，应用内即时切换。
enum AppLanguage: String, CaseIterable, Identifiable {
    case zh
    case en

    var id: String { rawValue }

    /// 选择器里显示的名字 —— 用各自语言的母语名，约定俗成不翻译。
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// 全局语言状态中心（`@Observable` + 单例）。
///
/// **即时切换机制**：SwiftUI 视图只要在 `body` 求值路径上调用了 `L(...)`
/// （内部读取 `shared.language`），就会被 Observation 自动追踪 →
/// 切语言时自动重渲染，**无需 `@Environment` 注入、无需 `.id()` 重建**。
///
/// 纯 AppKit 场景（NSMenu / 灵动岛通知横幅文本）不走 SwiftUI，
/// 监听 `.hermesPetLanguageChanged` 通知手动刷新即可。
@MainActor
@Observable
final class LocaleManager {
    static let shared = LocaleManager()

    nonisolated static let storageKey = "appLanguage"

    var language: AppLanguage = .zh {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            // 给纯 AppKit（菜单 / 灵动岛通知文本）一个刷新信号
            NotificationCenter.default.post(name: .hermesPetLanguageChanged, object: nil)
        }
    }

    private init() {
        // 先用临时变量算出初值再赋给 language，行为不依赖 init 中 didSet 是否触发
        let initial: AppLanguage
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let saved = AppLanguage(rawValue: raw) {
            initial = saved
        } else {
            // 首次启动：跟随系统语言猜默认值（中文系统 → 中文，其余 → 英文）
            let sys = Locale.preferredLanguages.first ?? "en"
            initial = sys.hasPrefix("zh") ? .zh : .en
        }
        language = initial
    }

    /// 翻译查询：当前语言缺失 → 回退中文 → 再缺 → 返回 key 本身（方便发现漏翻）。
    func string(for key: String) -> String {
        let table = (language == .zh) ? Self.zhTable : Self.enTable
        return table[key] ?? Self.zhTable[key] ?? key
    }

    // MARK: - 翻译表（按模块拆文件，新增模块在这两个数组里加一行）

    static let zhTable: [String: String] = [
        L10nCommon.zh,
        L10nSettings.zh,
        L10nChat.zh,
        L10nOnboarding.zh,
        L10nIsland.zh,
        L10nApp.zh,
        L10nCanvas.zh,
        L10nPet.zh,
        L10nMisc.zh,
        L10nNotes.zh,
    ].reduce(into: [:]) { acc, dict in acc.merge(dict) { _, new in new } }

    static let enTable: [String: String] = [
        L10nCommon.en,
        L10nSettings.en,
        L10nChat.en,
        L10nOnboarding.en,
        L10nIsland.en,
        L10nApp.en,
        L10nCanvas.en,
        L10nPet.en,
        L10nMisc.en,
        L10nNotes.en,
    ].reduce(into: [:]) { acc, dict in acc.merge(dict) { _, new in new } }
}

extension LocaleManager {
    /// nonisolated 读当前界面语言 —— 供后台 / nonisolated 的 prompt 构建用。
    /// 各 client 的 systemPrompt / buildPrompt 常在后台线程跑，不能碰 @MainActor 的 `shared.language`；
    /// `language` 的 didSet 每次都同步写 UserDefaults，所以这里直读 UserDefaults 拿到的总是最新值。
    nonisolated static func currentLanguage() -> AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let l = AppLanguage(rawValue: raw) { return l }
        let sys = Locale.preferredLanguages.first ?? "en"
        return sys.hasPrefix("zh") ? .zh : .en
    }

    /// 发给 AI 的「用界面语言回复」指令 —— 拼到各 client 的 prompt，
    /// 让 AI 回复语言跟随用户选的界面语言（而非靠猜输入语言）。Phase 5-3。
    nonisolated static func aiReplyLanguageInstruction() -> String {
        switch currentLanguage() {
        case .zh: return "请始终用简体中文回复用户（包括所有解释、标题、列表）。"
        case .en: return "Always respond to the user in English (including all explanations, headings, and lists)."
        }
    }
}

extension Notification.Name {
    /// 用户切换界面语言后广播 —— 纯 AppKit 文本（菜单 / 灵动岛）监听它手动刷新。
    static let hermesPetLanguageChanged = Notification.Name("HermesPetLanguageChanged")
}

// MARK: - 全局便捷函数

/// 取当前语言下 `key` 对应的文案。在 SwiftUI `body` 里调用会被 Observation 自动追踪。
@MainActor
func L(_ key: String) -> String {
    LocaleManager.shared.string(for: key)
}

/// 带格式参数的版本（错误码、数量等）。翻译表里用 `%@` / `%d` 占位。
@MainActor
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: LocaleManager.shared.string(for: key), arguments: args)
}
