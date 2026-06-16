import AppKit
import ApplicationServices

/// 用 macOS Accessibility API 读取当前 focused element 的选中文本。
/// 用于 QuickAskWindowController：唤起时把"用户刚选中的文字"作为 AI 的上下文。
///
/// **权限**：macOS "辅助功能"权限（系统设置 → 隐私与安全性 → 辅助功能）。
/// 第一次调用前后建议引导用户授权；未授权时 readSelectedText 会返回 nil。
enum AccessibilityReader {

    /// 同步检查"辅助功能"权限。不带 prompt 参数 → 静默检测，不弹引导窗
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 检查 + 弹系统引导窗（首次使用建议调一次让用户去授权）
    @discardableResult
    static func requestTrustWithPrompt() -> Bool {
        // Apple 文档约定的字符串常量。直接用字符串避免 Swift 6 严格并发对 unsafe pointer 的报错
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true as CFBoolean] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 读取当前选中文本 —— 双路径回退。
    /// 先试 AX 直读（原生 app 走这条，0 延迟），失败回退到模拟 ⌘C 读剪贴板（Electron/Java 走这条，约 150ms 延迟）。
    /// 都失败返回 nil。**调用方需在 NSApp.activate 切焦点之前调，否则读到的是桌宠自己**
    ///
    /// ⚠️ QuickAskWindow 现在不直接用这个组合方法，而是分别调 `readSelectedTextViaAX()`（同步快路径）
    /// 和 `readSelectedTextViaClipboardAsync()`（慢路径），以便"先弹窗再异步回填"。这里保留组合版给其他场景。
    @MainActor
    static func readSelectedTextAsync() async -> String? {
        if let viaAX = readSelectedTextViaAX() {
            return viaAX
        }
        // AX 拿不到 → 试剪贴板模拟（覆盖 Electron / Java / WebView 等"AX 残废"的 app）
        return await readSelectedTextViaClipboardAsync()
    }

    /// 路径 A（同步，0 延迟）：AXUIElement 直读 focused element 的 kAXSelectedTextAttribute。
    /// 原生 app 走这条。**调用方需在 NSApp.activate 之前调**，否则读到的是桌宠自己。
    static func readSelectedTextViaAX() -> String? {
        guard isTrusted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedErr == .success,
              let focused = focusedRef
        else { return nil }
        let focusedElement = focused as! AXUIElement

        var textRef: CFTypeRef?
        let textErr = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &textRef
        )
        guard textErr == .success,
              let text = textRef as? String
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// 路径 B（异步，~轮询 ≤350ms）：模拟 ⌘C → 轮询等剪贴板写入 → 读 → 异步恢复原剪贴板。
    /// 几乎任何能响应 ⌘C 的 app 都能拿到（覆盖 Electron / Java / 网页等 AX 不行的场景）。
    ///
    /// **可靠性改造**：旧版固定等 150ms 且要求 `newText != backup`，慢 app 来不及写、或选区内容
    /// 刚好跟剪贴板已有内容相同 → 漏读。现在改成**轮询**：每 30ms 查一次 `changeCount`，最多 ~350ms，
    /// 一旦 changeCount 增长就立刻读（changeCount 是主信号，不再强制内容必须跟旧剪贴板不同），
    /// 慢 app 不必傻等满 350ms、快 app 80ms 就返回。
    ///
    /// **调用方需在 NSApp.activate 之前调**：⌘C 会发给当前前台 app，桌宠抢了焦点就复制到自己了。
    @MainActor
    static func readSelectedTextViaClipboardAsync() async -> String? {
        guard isTrusted else { return nil }   // 模拟键盘也需要 Accessibility 权限

        let pb = NSPasteboard.general
        let oldChangeCount = pb.changeCount
        let backup = pb.string(forType: .string)

        simulateCmdC()

        // 轮询：每 30ms 查一次，最多 12 次（~360ms）。changeCount 一变就读，不傻等。
        var captured: String? = nil
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pb.changeCount > oldChangeCount {
                if let newText = pb.string(forType: .string) {
                    let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        captured = newText
                    }
                }
                break   // changeCount 已增长，无论拿没拿到文本都不再等
            }
        }

        // 异步恢复原剪贴板（再延迟 350ms 避免立即覆盖被读到的内容）
        if let backup = backup {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                let now = NSPasteboard.general
                now.clearContents()
                now.setString(backup, forType: .string)
            }
        }

        return captured
    }

    /// 发一次 ⌘C 键盘事件 —— kVK_ANSI_C = 8
    private static func simulateCmdC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 当前最前台 app（用于显示"来自 XX"+ 回填粘贴时切回该 app）
    static var frontmostApp: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    /// 前台 app 的活动窗口标题（无 Accessibility 权限 / app 没暴露窗口时返回 nil）。
    /// UserIntentRecorder 用它给意图记录打标签 —— "在 Xcode 写 ChatView.swift 时按了回车"。
    static func frontWindowTitle() -> String? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedWindowAttribute as CFString,
                                            &focusedWindow) == .success,
              let window = focusedWindow else { return nil }
        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXTitleAttribute as CFString,
                                            &titleValue) == .success,
              let title = titleValue as? String,
              !title.isEmpty else { return nil }
        return title
    }

    /// 前台窗口当前打开的文档真实文件路径（仅文档类 app 暴露 kAXDocumentAttribute）。
    /// 返回本地路径（如 /Users/x/report.docx）；网页 / Electron / 非文档 app 拿不到 → nil。
    /// 用于"昨日回顾"甩出可 ⌘+点击直接打开的文档链接（v1.3 跨天续接）。
    static func frontDocumentPath() -> String? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedWindowAttribute as CFString,
                                            &focusedWindow) == .success,
              let window = focusedWindow else { return nil }
        var docValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXDocumentAttribute as CFString,
                                            &docValue) == .success,
              let docStr = docValue as? String,
              !docStr.isEmpty else { return nil }
        // kAXDocumentAttribute 通常是 file:// URL 字符串，转成本地路径；已经是普通路径就直接用
        if let url = URL(string: docStr), url.isFileURL {
            return url.path
        }
        return docStr.hasPrefix("/") ? docStr : nil
    }
}

/// 模拟键盘事件 —— 用 CGEvent 把指定文本通过 ⌘V 粘贴到当前 focused app。
/// 跟 Accessibility 共享同一权限：未授权时 simulate 也会被系统拦截
enum KeyboardSimulator {

    /// 把 text 写入剪贴板 → 激活 target app → 短延迟后模拟 ⌘V 粘贴。
    /// delay 默认 0.12s：给系统切焦点和 NSPanel 收起一帧时间，太短会粘到本应用
    @MainActor
    static func pasteText(_ text: String, into target: NSRunningApplication?, delay: TimeInterval = 0.12) {
        // 1. 写剪贴板
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 2. 切回原 app（让光标重新聚焦在原选区）
        target?.activate(options: [])

        // 3. 短延迟后模拟 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postCmdV()
        }
    }

    /// 发送一次 ⌘V 键盘事件 —— V 键的 kVK_ANSI_V = 9
    private static func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V

        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
