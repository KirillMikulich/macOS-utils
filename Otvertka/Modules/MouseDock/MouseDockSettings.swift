import Foundation

struct MouseDockSettings: PersistedSettings {
    static let storageKey = "mouseDock"
    static let schemaVersion = 1
    static let defaultValue = MouseDockSettings()

    static let delayRange = 0.0...1.0
    static let animationRange = 0.0...1.0

    /// По умолчанию выключен: модуль меняет системные настройки Dock.
    var isEnabled = false
    /// Ускорять появление Dock (пауза и анимация ниже).
    var dockTweaksEnabled = true
        /// Пауза перед выездом Dock, в секундах (системное значение ~0,5 с).
    var dockDelay = 0.0
    /// Множитель длительности анимации выезда: 0 — без анимации, 1 — как в системе.
    var dockAnimation = 0.25
    /// Значения пользователя до первого применения — возвращаются при выключении модуля.
    var originalDock: DockOriginalValues?
    /// Колесо мыши: плавная прокрутка и направление отдельно от трекпада.
    /// Колесо работает, если включено хоть что-то: плавность или переворот направления.
    var wheel = WheelSettings()
}
