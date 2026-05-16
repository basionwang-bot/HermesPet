import AppKit
import Carbon
import Foundation

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var storageValue: String {
        "\(keyCode):\(modifiers)"
    }

    var displayText: String {
        HotkeyFormatter.displayText(keyCode: keyCode, modifiers: modifiers)
    }

    static func load(key: String, fallback: Hotkey) -> Hotkey {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return fallback }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt32(parts[0]),
              let modifiers = UInt32(parts[1]) else {
            return fallback
        }
        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }

    func save(key: String) {
        UserDefaults.standard.set(storageValue, forKey: key)
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggleChat
    case captureScreen
    case voiceInput
    case quickAsk
    case pinLastAnswer

    var id: String { rawValue }

    var hotkeyID: UInt32 {
        switch self {
        case .toggleChat:     return 1
        case .captureScreen:  return 2
        case .voiceInput:     return 3
        case .quickAsk:       return 4
        case .pinLastAnswer:  return 5
        }
    }

    var title: String {
        switch self {
        case .toggleChat:     return "呼出聊天"
        case .captureScreen:  return "截屏附加"
        case .voiceInput:     return "按住说话"
        case .quickAsk:       return "快问浮窗"
        case .pinLastAnswer:  return "Pin 最新回答"
        }
    }

    var icon: String {
        switch self {
        case .toggleChat:     return "command"
        case .captureScreen:  return "camera.viewfinder"
        case .voiceInput:     return "mic.fill"
        case .quickAsk:       return "bolt.fill"
        case .pinLastAnswer:  return "pin.fill"
        }
    }

    var storageKey: String {
        "hotkey.\(rawValue)"
    }

    var defaultHotkey: Hotkey {
        switch self {
        case .toggleChat:
            return Hotkey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey))
        case .captureScreen:
            return Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | shiftKey))
        case .voiceInput:
            return Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        case .quickAsk:
            return Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
        case .pinLastAnswer:
            return Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey))
        }
    }

    var currentHotkey: Hotkey {
        Hotkey.load(key: storageKey, fallback: defaultHotkey)
    }

    func save(_ hotkey: Hotkey) {
        hotkey.save(key: storageKey)
    }
}

enum HotkeyFormatter {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift)   { result |= UInt32(shiftKey) }
        if flags.contains(.option)  { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.function) { result |= UInt32(kEventKeyModifierFnMask) }
        return result
    }

    static func displayText(keyCode: UInt32, modifiers: UInt32) -> String {
        "\(modifierText(modifiers))\(keyText(keyCode))"
    }

    private static func modifierText(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(cmdKey) != 0     { text += "⌘" }
        if modifiers & UInt32(shiftKey) != 0   { text += "⇧" }
        if modifiers & UInt32(optionKey) != 0  { text += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(kEventKeyModifierFnMask) != 0 { text += "fn" }
        return text
    }

    static func keyText(_ keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key\(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/"
    ]
}

extension Notification.Name {
    static let hermesPetHotkeysChanged = Notification.Name("HermesPetHotkeysChanged")
}
