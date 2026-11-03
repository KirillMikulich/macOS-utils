import Foundation

enum ClipboardSelectionAction: String, Codable, CaseIterable, Identifiable {
    /// Только поместить элемент в системный буфер (пользователь сам нажимает ⌘V).
    case copyToClipboard
    /// Поместить в буфер и отправить ⌘V в активное приложение (нужен Accessibility).
    case copyAndPaste

    var id: String { rawValue }
    var title: String {
        switch self {
        case .copyToClipboard: return "Только скопировать в буфер (вставка — ⌘V)"
        case .copyAndPaste: return "Сразу вставить в активное приложение"
        }
    }
}

enum ClipboardPanelPosition: String, Codable, CaseIterable, Identifiable {
    case nearMouse, screenCenter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nearMouse: return "Рядом с курсором"
        case .screenCenter: return "По центру экрана"
        }
    }
}

struct ClipboardSettings: PersistedSettings {
    static let storageKey = "clipboardHistory"
    static let schemaVersion = 2
    static let defaultValue = ClipboardSettings()
    /// v1 → v2: по умолчанию выбор элемента теперь сразу вставляет его (как Win+V в Windows).
    static let migrations: [Int: (inout [String: Any]) -> Void] = [
        1: { dict in
            if dict["selectionAction"] as? String == ClipboardSelectionAction.copyToClipboard.rawValue {
                dict["selectionAction"] = ClipboardSelectionAction.copyAndPaste.rawValue
            }
        },
    ]

    static let allowedHistoryLimit = 5...1000
    static let allowedPollInterval = 0.2...3.0
    static let presetLimits = [10, 20, 50, 100]

    var isEnabled = true
    /// Максимум незакреплённых элементов. Закреплённые в лимит не входят.
    var historyLimit = 20
    /// Интервал проверки NSPasteboard.changeCount, в секундах.
    var pollInterval = 0.5
    var shortcut: KeyCombo? = .clipboardPanelDefault
    var selectionAction: ClipboardSelectionAction = .copyAndPaste
    var panelPosition: ClipboardPanelPosition = .nearMouse

    /// false — история живёт только в памяти и пропадает при выходе.
    var persistHistory = true
    var saveImages = true
    /// Добавлять в историю снимки экрана, сохранённые в файл (не только скопированные в буфер).
    var captureScreenshotFiles = true
    /// Сразу класть новый снимок экрана в системный буфер, чтобы вставить его через ⌘V.
    var copyScreenshotsToClipboard = true
    /// Элементы крупнее этого размера не сохраняются (защита памяти и диска).
    var maxItemSizeMB = 25
    /// Автоудаление незакреплённых элементов старше N дней (0 — не удалять).
    var retentionDays = 0

    /// Режим приватности: история временно не пополняется.
    var privateMode = false
    /// Пропускать элементы, помеченные приложениями как секретные (менеджеры паролей).
    var ignoreConcealedContent = true
    /// Пропускать временные/автоматически сгенерированные элементы.
    var ignoreTransientContent = true
    var excludedBundleIDs: [String] = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    var clampedHistoryLimit: Int {
        min(max(historyLimit, Self.allowedHistoryLimit.lowerBound), Self.allowedHistoryLimit.upperBound)
    }

    var clampedPollInterval: Double {
        min(max(pollInterval, Self.allowedPollInterval.lowerBound), Self.allowedPollInterval.upperBound)
    }

    var maxItemBytes: Int { max(1, maxItemSizeMB) * 1024 * 1024 }
}
