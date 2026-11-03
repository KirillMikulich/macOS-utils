import Foundation

enum WindowSortOrder: String, Codable, CaseIterable, Identifiable {
    case recentlyUsed
    case appName
    case windowTitle

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentlyUsed: return "По недавнему использованию"
        case .appName: return "По названию приложения"
        case .windowTitle: return "По заголовку окна"
        }
    }
}

enum SwitcherLayout: String, Codable, CaseIterable, Identifiable {
    case horizontal, vertical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .horizontal: return "Сетка миниатюр"
        case .vertical: return "Вертикальный список"
        }
    }
}

enum OverlayPosition: String, Codable, CaseIterable, Identifiable {
    case center, top, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .center: return "По центру"
        case .top: return "Сверху"
        case .bottom: return "Снизу"
        }
    }
}

struct WindowSwitcherSettings: PersistedSettings, ThumbnailAppearanceSettings {
    static let storageKey = "windowSwitcher"
    static let schemaVersion = 2
    static let defaultValue = WindowSwitcherSettings()
    /// v1 → v2: переключатель окон по умолчанию открывается системным ⌘⇥.
    static let migrations: [Int: (inout [String: Any]) -> Void] = [
        1: { dict in dict["replaceCommandTab"] = true },
    ]

    static let opacityRange = 0.4...1.0

    /// По умолчанию выключен: модулю нужны разрешения, и они запрашиваются только при включении.
    var isEnabled = false
    var forwardShortcut: KeyCombo? = .switcherForwardDefault
    var backwardShortcut: KeyCombo? = .switcherBackwardDefault
    /// ⌘⇥ / ⌘⇧⇥ открывают переключатель окон вместо системного переключателя приложений.
    var replaceCommandTab = true
    /// Подтверждать выбор отпусканием модификатора (как Alt+Tab). Иначе — клавишей ↩ или щелчком.
    var confirmOnModifierRelease = true

    var sortOrder: WindowSortOrder = .recentlyUsed
    var groupByApp = false
    var showTitles = true
    var showMinimized = true
    var showHiddenApps = true
    /// Показывать только окна с экрана, на котором курсор.
    var onlyMouseScreen = false
    var activationScope: WindowActivationScope = .selectedWindow
    var excludedBundleIDs: [String] = []

    var layout: SwitcherLayout = .horizontal
    var thumbnailSize = 200.0
    var showThumbnails = true
    var iconSize = 48.0
    var cellPadding = 8.0
    var itemSpacing = 6.0
    var panelPadding = 14.0
    var backgroundOpacity = 0.92
    var position: OverlayPosition = .center
    var appearance: AppearanceMode = .system
    var selectOnHover = true
}
