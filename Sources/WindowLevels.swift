import AppKit

/// HermesPet 全局 NSWindow z-order 规范（从低到高）。
///
/// 修改之前先想清楚：所有 5 个 controller 都引用这里的常量，改了一处影响全局。
///
/// ```
/// 层级（rawValue 仅示意）              用途
/// ─────────────────────────────────────────────────────────
/// .floating (3)        ←  聊天窗 / Apple Intelligence 光环
///                          光环跟聊天窗同级是有意的：光环不挡灵动岛的红色麦克风脉冲。
///
/// .mainMenu (24)       ←  Clawd 气泡 / 语音字幕
///                          它们在灵动岛"下方延伸区"出现，永不挡灵动岛胶囊本体。
///
/// .statusBar (25)      ←  灵动岛胶囊（唯一锚点，最显眼）
/// ```
///
/// **历史教训**：
/// - 早期 ClawdBubble / VoiceTranscript 在 `.statusBar`，跟灵动岛同级，
///   虽然空间位置不重叠所以视觉上 OK，但分级更清晰 → 改成 `.mainMenu`
/// - IntelligenceOverlay 不能改成 statusBar 以上 —— 否则盖过灵动岛麦克风脉冲
/// - 聊天窗的 setFrame 不能同步触发其他 window setFrame（CLAUDE.md 决策 #5）
enum HermesWindowLevel {
    /// 聊天窗 —— 跟普通浮窗同级，可被 spotlight / 通知中心覆盖
    static let chat: NSWindow.Level = .floating

    /// Apple Intelligence 全屏语音光环 —— 跟聊天窗同级，不挡灵动岛麦克风
    static let intelligence: NSWindow.Level = .floating

    /// Clawd 气泡 / 语音字幕 —— 低于灵动岛，避免任何遮挡可能
    static let auxiliary: NSWindow.Level = .mainMenu

    /// 灵动岛胶囊 —— 最高层（系统刘海下方的视觉锚点）
    static let dynamicIsland: NSWindow.Level = .statusBar

    /// 会议纪要控制台 —— 贴灵动岛下方、可交互。跟字幕同级（低于灵动岛胶囊，浮于聊天 / 普通窗之上）
    static let meeting: NSWindow.Level = .mainMenu

    /// AI 网页（Artifact）预览窗 —— 跟聊天窗同级，浮于普通窗之上，方便边看网页边聊
    static let artifact: NSWindow.Level = .floating
}
