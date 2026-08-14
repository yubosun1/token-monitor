import AppKit
import Carbon

/// Global window-toggle hotkey via Carbon RegisterEventHotKey (no
/// accessibility permission needed, works while the LSUIElement app is in the
/// background — the Electron version used Electron's globalShortcut).
///
/// The shortcut string is the renderer's normalized form
/// (src/electron/windowShortcut.js): modifiers from
/// CommandOrControl|Command|Control|Alt|Shift|Super joined with '+' plus a key
/// name (A-Z, 0-9, F1-F24, Space, Tab, Enter).
final class ShortcutController {
    static let shared = ShortcutController()

    /// Called on the main thread when the hotkey is pressed.
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var currentShortcut = ""
    private let signature: OSType = 0x544D_484B // 'TMHK'

    private static let letterKeyCodes: [String: UInt32] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05,
        "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C,
        "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11, "O": 0x1F,
        "U": 0x20, "I": 0x22, "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28,
        "N": 0x2D, "M": 0x2E
    ]
    private static let digitKeyCodes: [String: UInt32] = [
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D
    ]
    private static let functionKeyCodes: [Int: UInt32] = [
        1: 0x7A, 2: 0x78, 3: 0x63, 4: 0x76, 5: 0x60, 6: 0x61, 7: 0x62,
        8: 0x64, 9: 0x65, 10: 0x6D, 11: 0x67, 12: 0x6F, 13: 0x69, 14: 0x6B,
        15: 0x71, 16: 0x6A, 17: 0x40, 18: 0x4F, 19: 0x50, 20: 0x5A
    ]

    func start(settings: [String: Any]) {
        installHandler()
        apply(settings: settings)
    }

    func stop() {
        unregister()
    }

    /// (Re)register the hotkey from a settings snapshot. An empty or
    /// unparseable value falls back to Command+E (the behaviour the app had
    /// before shortcuts became configurable).
    func apply(settings: [String: Any]) {
        apply(shortcut: settings["windowToggleShortcut"] as? String ?? "")
    }

    func apply(shortcut raw: String) {
        let shortcut = normalizeShortcut(raw) ?? "CommandOrControl+E"
        guard shortcut != currentShortcut || hotKeyRef == nil else { return }
        unregister()
        currentShortcut = shortcut
        register(shortcut)
    }

    // MARK: - Registration

    private func register(_ shortcut: String) {
        guard let (keyCode, modifiers) = keyCodeAndModifiers(shortcut) else {
            NSLog("[shortcut] cannot parse %@", shortcut)
            return
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("[shortcut] register failed (%d) for %@", status, shortcut)
            return
        }
        hotKeyRef = ref
        NSLog("[shortcut] registered %@", shortcut)
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if err == noErr {
                DispatchQueue.main.async { ShortcutController.shared.onToggle?() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = status == noErr
    }

    // MARK: - Parsing (mirror of windowShortcut.js normalization)

    private func normalizeShortcut(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2, let key = parts.last, keyName(key) != nil else { return nil }
        var modifiers: [String] = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmdorctrl", "cmdorcontrol", "commandorcontrol", "command", "cmd", "super", "meta":
                modifiers.append("Command")
            case "ctrl", "control":
                modifiers.append("Control")
            case "alt", "option":
                modifiers.append("Alt")
            case "shift":
                modifiers.append("Shift")
            default:
                return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        return (modifiers + [key]).joined(separator: "+")
    }

    private func keyName(_ value: String) -> String? {
        let upper = value.uppercased()
        if upper.count == 1, upper.first!.isLetter || upper.first!.isNumber { return upper }
        if upper.hasPrefix("F"), let n = Int(upper.dropFirst()), n >= 1, n <= 24 { return upper }
        switch upper {
        case "SPACE": return "Space"
        case "TAB": return "Tab"
        case "ENTER", "RETURN": return "Enter"
        default: return nil
        }
    }

    private func keyCodeAndModifiers(_ shortcut: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = shortcut.split(separator: "+").map(String.init)
        guard let key = parts.last, let keyName = keyName(key) else { return nil }
        var carbonMods: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "Command": carbonMods |= UInt32(cmdKey)
            case "Control": carbonMods |= UInt32(controlKey)
            case "Alt": carbonMods |= UInt32(optionKey)
            case "Shift": carbonMods |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard let code = carbonKeyCode(for: keyName) else { return nil }
        return (code, carbonMods)
    }

    private func carbonKeyCode(for key: String) -> UInt32? {
        switch key {
        case "Space": return UInt32(kVK_Space)
        case "Tab": return UInt32(kVK_Tab)
        case "Enter": return UInt32(kVK_Return)
        default:
            if let code = Self.letterKeyCodes[key] ?? Self.digitKeyCodes[key] { return code }
            if key.hasPrefix("F"), let n = Int(key.dropFirst()), let code = Self.functionKeyCodes[n] {
                return code
            }
            return nil
        }
    }
}
