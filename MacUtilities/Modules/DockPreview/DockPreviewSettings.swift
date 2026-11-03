import Foundation

struct DockPreviewSettings: PersistedSettings, ThumbnailAppearanceSettings {
    static let storageKey = "dockPreview"
    static let schemaVersion = 3
    static let defaultValue = DockPreviewSettings()
    /// v1 → v2: «Не скрывать Dock» выключается — временное отключение автоскрытия у части
    /// пользователей давало чёрную полосу на месте Dock и переключало системную настройку.
    static let migrations: [Int: (inout [String: Any]) -> Void] = [
        1: { dict in dict["keepDockVisible"] = false },
        // v2 → v3: функция «Не скрывать Dock» удалена — ключ больше не нужен.
        2: { dict in dict.removeValue(forKey: "keepDockVisible") },
    ]
    static let delayRange = 0.0...1.5

    /// По умолчанию выключен: нужен доступ Accessibility, он запрашивается при включении.
    var isEnabled = false
    /// Показывать предпросмотр при наведении на значок в Dock.
    var showOnDockHover = true
    var hoverDelay = 0.35
    /// Показывать превью, только когда курсор остановился на значке (не при проходе мимо).
    var requireCursorStop = true
    var thumbnailSize = 220.0
    var showThumbnails = true
    /// Название приложения над миниатюрами.
    var showAppName = false
    var iconSize = 48.0
    var cellPadding = 8.0
    var itemSpacing = 6.0
    var panelPadding = 12.0
    var showTitles = true
    /// Делить окна по дисплеям (полезно при нескольких мониторах).
    var groupByDisplay = false
    var showMinimized = true
    var activationScope: WindowActivationScope = .selectedWindow
    var excludedBundleIDs: [String] = []
    /// Панель с окнами активного приложения по горячей клавише (работает и без наведения на Dock).
    var panelShortcut: KeyCombo? = .dockPreviewPanelDefault
}
