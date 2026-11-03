import AppKit

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .light: return L("Светлая")
        case .dark: return L("Тёмная")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Настройки приложения в целом (не относящиеся к конкретному модулю).
/// Состояние «запуск при входе» не хранится здесь — его источник истины SMAppService.
struct GeneralSettings: PersistedSettings {
    static let storageKey = "general"
    static let schemaVersion = 1
    static let defaultValue = GeneralSettings()

    var showMenuBarIcon = true
    var showDockIcon = false
    var openMainWindowAtLaunch = true
    /// true — включённые модули запускаются сразу; false — приложение стартует на паузе.
    var restoreModulesOnLaunch = true
    var appearance: AppearanceMode = .system
    /// Оформление плавающих панелей (буфер, переключатель окон, превью в Dock).
    var overlay = OverlayStyleSettings()
    /// Язык интерфейса; по умолчанию английский.
    var language: AppLanguage = .english
}
