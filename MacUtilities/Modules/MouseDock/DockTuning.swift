import Foundation

/// Доступ к настройкам Dock. Протокол нужен, чтобы логику применения и отката
/// можно было проверить тестами без изменения настоящего Dock.
protocol DockPreferenceBackend: AnyObject {
    func value(for key: String) -> Double?
    func setValue(_ value: Double?, for key: String)
    func restartDock()
}

/// Настоящий Dock: публичные настройки домена `com.apple.dock` (те же, что меняет
/// `defaults write com.apple.dock …`). Dock читает их при запуске, поэтому после записи
/// он перезапускается — окна и программы при этом не закрываются.
final class SystemDockPreferences: DockPreferenceBackend {
    private let domain = "com.apple.dock" as CFString

    func value(for key: String) -> Double? {
        (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.doubleValue
    }

    func setValue(_ value: Double?, for key: String) {
        CFPreferencesSetAppValue(key as CFString, value.map { NSNumber(value: $0) }, domain)
        CFPreferencesAppSynchronize(domain)
    }

    func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Применение и откат настроек автоскрытия Dock.
///
/// - `autohide-delay` — пауза перед выездом Dock, когда курсор у края экрана (по умолчанию ~0,5 с);
/// - `autohide-time-modifier` — множитель длительности анимации выезда (по умолчанию 1).
///
/// Исходные значения пользователя запоминаются при первом применении и возвращаются при откате.
final class DockTuning {
    static let delayKey = "autohide-delay"
    static let animationKey = "autohide-time-modifier"

    private let backend: DockPreferenceBackend

    init(backend: DockPreferenceBackend = SystemDockPreferences()) {
        self.backend = backend
    }

    /// Применяет значения. Возвращает обновлённый снимок исходных значений.
    /// Dock перезапускается только если что-то действительно изменилось.
    @discardableResult
    func apply(delay: Double, animation: Double, original: DockOriginalValues?) -> DockOriginalValues {
        let saved = original ?? DockOriginalValues(delay: backend.value(for: Self.delayKey),
                                                   animation: backend.value(for: Self.animationKey))
        let changed = !Self.equal(backend.value(for: Self.delayKey), delay)
            || !Self.equal(backend.value(for: Self.animationKey), animation)
        if changed {
            backend.setValue(delay, for: Self.delayKey)
            backend.setValue(animation, for: Self.animationKey)
            backend.restartDock()
        }
        return saved
    }

    /// Возвращает исходные значения (если ключа не было — удаляет его, то есть системное значение).
    func restore(_ original: DockOriginalValues) {
        let changed = !Self.equal(backend.value(for: Self.delayKey), original.delay)
            || !Self.equal(backend.value(for: Self.animationKey), original.animation)
        guard changed else { return }
        backend.setValue(original.delay, for: Self.delayKey)
        backend.setValue(original.animation, for: Self.animationKey)
        backend.restartDock()
    }

    private static func equal(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l - r) < 0.001
        default: return false
        }
    }
}

struct DockOriginalValues: Codable, Equatable {
    var delay: Double?
    var animation: Double?
}
