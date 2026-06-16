import AppKit

/// 全应用的提示音播放统一入口。
///
/// 5 个事件 —— 每个事件独立 UserDefaults key + 默认音效 + 各自的开关含义：
/// - 值为空 `""` 表示用户关掉了这个事件的提示音
/// - 值不以 `/` 开头 → 当作 macOS 系统内置音名（`NSSound(named:)`）
/// - 值以 `/` 开头 → 当作用户拖入的自定义音频文件绝对路径（`NSSound(contentsOf:)`）
///
/// 自定义文件用 `byReference: false` 让 NSSound 自己解码持有，避免我们再缓存 Data。
enum SoundEvent: String, CaseIterable {
    case voiceStart   // 按住 ⌘⇧V 召唤光环时
    case voiceFinish  // AI 流式回复完成时
    case dragIn       // 拖文件 / 图片成功入对话时
    case send         // 用户点发送 / 按回车时
    case error        // 出错时（errorMessage 被设置时）

    /// UserDefaults 存储 key —— 与历史版本兼容（voiceStartSound / voiceFinishSound 已存在）
    var defaultsKey: String {
        switch self {
        case .voiceStart:  return "voiceStartSound"
        case .voiceFinish: return "voiceFinishSound"
        case .dragIn:      return "dragInSound"
        case .send:        return "sendSound"
        case .error:       return "errorSound"
        }
    }

    /// 首次安装时的默认音效。`send` 默认关（容易吵），其他事件都给一个轻量音
    var fallbackValue: String {
        switch self {
        case .voiceStart:  return "Funk"
        case .voiceFinish: return "Glass"
        case .dragIn:      return "Pop"
        case .send:        return ""        // 默认静音 —— 用户主动选才开
        case .error:       return "Basso"
        }
    }

    /// 用户看到的事件名 i18n key（设置面板用）—— rawValue 即 voiceStart / voiceFinish / …
    var titleKey: String { "settings.sound.event.\(rawValue).title" }

    /// 设置面板里给用户看的说明 i18n key
    var captionKey: String { "settings.sound.event.\(rawValue).caption" }
}

enum SoundManager {

    /// 播放一个事件对应的音效。从 UserDefaults 读用户当前设置，空则静音。
    /// 必须在主线程调（NSSound 不是 Sendable）。
    @MainActor
    static func play(_ event: SoundEvent) {
        let raw = UserDefaults.standard.string(forKey: event.defaultsKey) ?? event.fallbackValue
        play(rawValue: raw)
    }

    /// 试听用：直接给一个 raw 值（系统音名 / 文件路径 / 空）播放
    @MainActor
    static func play(rawValue: String) {
        guard !rawValue.isEmpty else { return }
        if rawValue.hasPrefix("/") {
            // 自定义文件 —— 文件可能在播放期间被删/移走，NSSound 自己持有 buffer
            let url = URL(fileURLWithPath: rawValue)
            guard FileManager.default.fileExists(atPath: url.path),
                  let sound = NSSound(contentsOf: url, byReference: false) else {
                return
            }
            playKeepingAlive(sound)
        } else {
            // 系统音 —— NSSound(named:) 用框架缓存，引用不会丢
            NSSound(named: rawValue)?.play()
        }
    }

    /// 自定义文件加载的 NSSound 实例 — 如果不强引用，play() 立刻返回后实例可能被释放
    /// 导致播一半就停。这里用一个简单数组保活，播完通过 delegate 移除
    @MainActor private static var alive: [NSSound] = []
    @MainActor private static let aliveDelegate = AliveDelegate()

    @MainActor
    private static func playKeepingAlive(_ sound: NSSound) {
        sound.delegate = aliveDelegate
        // 仅在 play() 真正启动后才保活：设备被占/无效时 play() 返回 false 且不回调 didFinishPlaying，
        // 无条件 append 会让该 NSSound 永久滞留 alive 数组（缓慢泄漏）
        guard sound.play() else { return }
        alive.append(sound)
    }

    @MainActor
    fileprivate static func removeAlive(_ sound: NSSound) {
        alive.removeAll { $0 === sound }
    }
}

/// NSSound delegate 不能用 enum/struct 当目标 —— 必须是 NSObject。
/// 单例足够：所有正在播的自定义音效共享这个 delegate
private final class AliveDelegate: NSObject, NSSoundDelegate {
    func sound(_ sound: NSSound, didFinishPlaying aBool: Bool) {
        Task { @MainActor in SoundManager.removeAlive(sound) }
    }
}
