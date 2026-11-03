import AppKit
import Carbon.HIToolbox

/// Сочетание клавиш. Хранится как виртуальный код клавиши (kVK_*) и маска модификаторов Carbon,
/// потому что именно в таком виде его принимает RegisterEventHotKey.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: Int, carbonModifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = UInt32(carbonModifiers)
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, carbonModifiers: Self.carbonFlags(from: modifiers))
    }

    /// Создание из события клавиатуры (используется в редакторе сочетаний).
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        self.init(keyCode: Int(event.keyCode), modifiers: flags)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var hasModifiers: Bool {
        !modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    /// Функциональные клавиши допустимы без модификаторов, остальные — нет.
    var isValidGlobalShortcut: Bool {
        hasModifiers || Self.functionKeyCodes.contains(Int(keyCode))
    }

    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return result
    }

    // MARK: - Отображение

    var displayString: String {
        modifierSymbols + Self.keyName(for: Int(keyCode))
    }

    var modifierSymbols: String {
        let flags = modifierFlags
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func keyName(for keyCode: Int) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let char = layoutCharacter(for: keyCode) { return char.uppercased() }
        return "Key\(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Tab: "⇥", kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_KeypadEnter: "⌤", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_Grave: "`",
    ]

    /// Символ клавиши в ASCII-раскладке (как в системных настройках клавиатуры).
    /// Используется TISCopyCurrentASCIICapableKeyboardLayoutInputSource, чтобы при
    /// активной русской раскладке сочетание показывалось как ⌥⇧V, а не ⌥⇧М.
    private static func layoutCharacter(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(ptr, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }
}

extension KeyCombo {
    // Значения по умолчанию, предлагаемые модулями.
    static let clipboardPanelDefault = KeyCombo(keyCode: kVK_ANSI_V, modifiers: [.option, .shift])
    static let switcherForwardDefault = KeyCombo(keyCode: kVK_Tab, modifiers: [.option])
    static let switcherBackwardDefault = KeyCombo(keyCode: kVK_Tab, modifiers: [.option, .shift])
    static let dockPreviewPanelDefault = KeyCombo(keyCode: kVK_ANSI_W, modifiers: [.option, .shift])

    /// Известные системные сочетания macOS, которые приложение не может надёжно перехватить
    /// или которые перехватываются раньше (WindowServer / Dock / Spotlight).
    /// Список не исчерпывающий: пользовательские системные сочетания здесь не учтены.
    static let knownSystemShortcuts: [KeyCombo: String] = [
        KeyCombo(keyCode: kVK_Tab, modifiers: [.command]): L("Переключение приложений (⌘⇥)"),
        KeyCombo(keyCode: kVK_Tab, modifiers: [.command, .shift]): L("Переключение приложений (⌘⇧⇥)"),
        KeyCombo(keyCode: kVK_Space, modifiers: [.command]): "Spotlight",
        KeyCombo(keyCode: kVK_Space, modifiers: [.command, .option]): L("Окно поиска Finder"),
        KeyCombo(keyCode: kVK_Space, modifiers: [.control]): L("Переключение источника ввода"),
        KeyCombo(keyCode: kVK_ANSI_Q, modifiers: [.command]): L("Завершение приложения"),
        KeyCombo(keyCode: kVK_ANSI_Grave, modifiers: [.command]): L("Переключение окон приложения"),
        KeyCombo(keyCode: kVK_ANSI_3, modifiers: [.command, .shift]): L("Снимок экрана"),
        KeyCombo(keyCode: kVK_ANSI_4, modifiers: [.command, .shift]): L("Снимок области"),
        KeyCombo(keyCode: kVK_ANSI_5, modifiers: [.command, .shift]): L("Утилита «Снимок экрана»"),
        KeyCombo(keyCode: kVK_ANSI_Q, modifiers: [.command, .control]): L("Блокировка экрана"),
        KeyCombo(keyCode: kVK_Escape, modifiers: [.command, .option]): L("Принудительное завершение"),
        KeyCombo(keyCode: kVK_ANSI_V, modifiers: [.command]): L("Вставка"),
        KeyCombo(keyCode: kVK_ANSI_C, modifiers: [.command]): L("Копирование"),
        KeyCombo(keyCode: kVK_ANSI_X, modifiers: [.command]): L("Вырезание"),
    ]
}
