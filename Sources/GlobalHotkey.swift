import Foundation
import Carbon

/// 全局热键管理（Carbon Event Manager）。
/// 全局热键可在设置页自定义，默认值：
///   - Cmd+Shift+H → 切换聊天窗口（id=1，仅 down）
///   - Cmd+Shift+J → 截屏并附加到聊天（id=2，仅 down）
///   - Cmd+Shift+V → 按住说话（id=3，监听 down + up，实现 push-to-talk）
///   - Cmd+Shift+Space → Spotlight 风快问（id=4，仅 down）
///   - Cmd+Shift+P → Pin 当前对话最新 AI 回答到桌面（id=5，仅 down）
final class GlobalHotkey {
    private var toggleHotKeyRef:  EventHotKeyRef?
    private var captureHotKeyRef: EventHotKeyRef?
    private var voiceHotKeyRef:   EventHotKeyRef?
    private var quickAskHotKeyRef: EventHotKeyRef?
    private var pinLastAnswerHotKeyRef: EventHotKeyRef?
    private var knowledgeGraphHotKeyRef: EventHotKeyRef?
    private var notesHotKeyRef: EventHotKeyRef?
    private var meetingHotKeyRef: EventHotKeyRef?
    private var voiceChatHotKeyRef: EventHotKeyRef?
    /// 陪聊「空格打断」动态热键（仅陪聊会话期间注册，退出注销，避免常驻拦截空格）
    private var spaceInterruptRef: EventHotKeyRef?

    private nonisolated(unsafe) static var _toggleHandler:    (() -> Void)?
    private nonisolated(unsafe) static var _captureHandler:   (() -> Void)?
    private nonisolated(unsafe) static var _voiceDownHandler: (() -> Void)?
    private nonisolated(unsafe) static var _voiceUpHandler:   (() -> Void)?
    private nonisolated(unsafe) static var _quickAskHandler:  (() -> Void)?
    private nonisolated(unsafe) static var _pinLastAnswerHandler: (() -> Void)?
    private nonisolated(unsafe) static var _knowledgeGraphHandler: (() -> Void)?
    private nonisolated(unsafe) static var _notesHandler: (() -> Void)?
    private nonisolated(unsafe) static var _meetingHandler: (() -> Void)?
    private nonisolated(unsafe) static var _voiceChatHandler: (() -> Void)?
    private nonisolated(unsafe) static var _voiceChatInterruptHandler: (() -> Void)?
    nonisolated(unsafe) static let shared = GlobalHotkey()

    private nonisolated(unsafe) static var handlerInstalled = false
    private var isObservingChanges = false

    func register(
        toggle: @escaping () -> Void,
        capture: @escaping () -> Void,
        voiceDown: @escaping () -> Void,
        voiceUp: @escaping () -> Void,
        quickAsk: @escaping () -> Void,
        pinLastAnswer: @escaping () -> Void,
        knowledgeGraph: @escaping () -> Void,
        notes: @escaping () -> Void,
        meeting: @escaping () -> Void,
        voiceChat: @escaping () -> Void
    ) {
        GlobalHotkey._toggleHandler        = toggle
        GlobalHotkey._captureHandler       = capture
        GlobalHotkey._voiceDownHandler     = voiceDown
        GlobalHotkey._voiceUpHandler       = voiceUp
        GlobalHotkey._quickAskHandler      = quickAsk
        GlobalHotkey._pinLastAnswerHandler = pinLastAnswer
        GlobalHotkey._knowledgeGraphHandler = knowledgeGraph
        GlobalHotkey._notesHandler = notes
        GlobalHotkey._meetingHandler = meeting
        GlobalHotkey._voiceChatHandler = voiceChat

        if !isObservingChanges {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleHotkeysChanged),
                name: .hermesPetHotkeysChanged,
                object: nil
            )
            isObservingChanges = true
        }

        // 全局事件 handler 只装一次。监听 keyPressed + keyReleased 两种事件。
        if !GlobalHotkey.handlerInstalled {
            let specs: [EventTypeSpec] = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            _ = specs.withUnsafeBufferPointer { buf in
                InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                    var hk = EventHotKeyID()
                    let err = GetEventParameter(
                        event,
                        OSType(kEventParamDirectObject),
                        OSType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hk
                    )
                    if err == noErr {
                        let kind = GetEventKind(event)
                        DispatchQueue.main.async {
                            switch (hk.id, Int(kind)) {
                            case (1, kEventHotKeyPressed):
                                GlobalHotkey._toggleHandler?()
                            case (2, kEventHotKeyPressed):
                                GlobalHotkey._captureHandler?()
                            case (3, kEventHotKeyPressed):
                                GlobalHotkey._voiceDownHandler?()
                            case (3, kEventHotKeyReleased):
                                GlobalHotkey._voiceUpHandler?()
                            case (4, kEventHotKeyPressed):
                                GlobalHotkey._quickAskHandler?()
                            case (5, kEventHotKeyPressed):
                                GlobalHotkey._pinLastAnswerHandler?()
                            case (6, kEventHotKeyPressed):
                                GlobalHotkey._knowledgeGraphHandler?()
                            case (7, kEventHotKeyPressed):
                                GlobalHotkey._notesHandler?()
                            case (8, kEventHotKeyPressed):
                                GlobalHotkey._meetingHandler?()
                            case (9, kEventHotKeyPressed):
                                GlobalHotkey._voiceChatHandler?()
                            case (10, kEventHotKeyPressed):
                                GlobalHotkey._voiceChatInterruptHandler?()
                            default: break
                            }
                        }
                    }
                    return noErr
                }, specs.count, buf.baseAddress, nil, nil)
            }
            GlobalHotkey.handlerInstalled = true
        }

        reloadRegistration()
    }

    /// 陪聊会话期间注册「空格打断」热键（无修饰空格，id=10）。退出务必调 unregisterSpaceInterrupt 恢复空格。
    func registerSpaceInterrupt(_ handler: @escaping () -> Void) {
        GlobalHotkey._voiceChatInterruptHandler = handler
        if spaceInterruptRef == nil {
            spaceInterruptRef = Self.tryRegister(keyCode: UInt32(kVK_Space), modifiers: 0, id: 10)
        }
    }

    func unregisterSpaceInterrupt() {
        if let ref = spaceInterruptRef { UnregisterEventHotKey(ref); spaceInterruptRef = nil }
        GlobalHotkey._voiceChatInterruptHandler = nil
    }

    @objc private func handleHotkeysChanged() {
        reloadRegistration()
    }

    private func reloadRegistration() {
        unregisterAll()

        // 全局热键，注册失败时弹灵动岛通知告诉用户哪个被占用。
        // 收集失败 action（title 在主线程用 L(action.titleKey) 解析，避免在非主线程调 @MainActor 的 L()）
        var failedActions: [(displayText: String, action: HotkeyAction)] = []

        for action in HotkeyAction.allCases {
            let hotkey = action.currentHotkey
            let ref = Self.tryRegister(
                keyCode: hotkey.keyCode,
                modifiers: hotkey.modifiers,
                id: action.hotkeyID
            )
            if let ref {
                setRef(ref, for: action)
            } else {
                failedActions.append((hotkey.displayText, action))
            }
        }

        if !failedActions.isEmpty {
            // 通过截图通知通道弹灵动岛提示（这条通道短暂展开胶囊显示文字）
            DispatchQueue.main.async {
                let separator = (LocaleManager.shared.language == .en) ? ", " : "、"
                let parts = failedActions.map { "\($0.displayText)（\(L($0.action.titleKey))）" }
                let msg = L("hotkey.banner.occupied", parts.joined(separator: separator))
                NotificationCenter.default.post(
                    name: .init("HermesPetScreenshotAdded"),
                    object: nil,
                    userInfo: ["text": msg, "count": 0]
                )
            }
        }
    }

    private func setRef(_ ref: EventHotKeyRef, for action: HotkeyAction) {
        switch action {
        case .toggleChat:     toggleHotKeyRef = ref
        case .captureScreen:  captureHotKeyRef = ref
        case .voiceInput:     voiceHotKeyRef = ref
        case .quickAsk:       quickAskHotKeyRef = ref
        case .pinLastAnswer:  pinLastAnswerHotKeyRef = ref
        case .knowledgeGraph: knowledgeGraphHotKeyRef = ref
        case .notes:          notesHotKeyRef = ref
        case .meeting:        meetingHotKeyRef = ref
        case .voiceChat:      voiceChatHotKeyRef = ref
        }
    }

    /// 尝试注册一个 Carbon 全局热键；成功返回 ref，失败返回 nil（被占用 / 系统限制等）
    private static func tryRegister(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> EventHotKeyRef? {
        let hkid = EventHotKeyID(signature: 0x484D4550, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkid,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        return status == noErr ? ref : nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        unregisterAll()
    }

    private func unregisterAll() {
        if let ref = toggleHotKeyRef        { UnregisterEventHotKey(ref) }
        if let ref = captureHotKeyRef       { UnregisterEventHotKey(ref) }
        if let ref = voiceHotKeyRef         { UnregisterEventHotKey(ref) }
        if let ref = quickAskHotKeyRef      { UnregisterEventHotKey(ref) }
        if let ref = pinLastAnswerHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = knowledgeGraphHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = notesHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = meetingHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = voiceChatHotKeyRef { UnregisterEventHotKey(ref) }
        toggleHotKeyRef = nil
        captureHotKeyRef = nil
        voiceHotKeyRef = nil
        quickAskHotKeyRef = nil
        pinLastAnswerHotKeyRef = nil
        knowledgeGraphHotKeyRef = nil
        notesHotKeyRef = nil
        meetingHotKeyRef = nil
        voiceChatHotKeyRef = nil
    }
}
