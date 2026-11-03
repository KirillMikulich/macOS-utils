import AppKit
import ApplicationServices
import CoreGraphics
import Observation

enum PermissionKind: String, CaseIterable, Identifiable, Codable {
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Универсальный доступ (Accessibility)"
        case .screenRecording: return "Запись экрана (Screen Recording)"
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            return "Нужно для перечисления окон других приложений, переключения фокуса на выбранное окно, отслеживания наведения на значки Dock и (по желанию) автоматической вставки ⌘V из истории буфера."
        case .screenRecording:
            return "Нужно только для миниатюр окон в Переключение окон и Превью в Dock. Без него вместо миниатюр показываются значки приложений. Изображения окон не сохраняются на диск и никуда не передаются."
        }
    }

    var instructions: String {
        switch self {
        case .accessibility:
            return "Системные настройки → Конфиденциальность и безопасность → Универсальный доступ → включите Mac Utilities. Если приложение уже есть в списке, но не работает — удалите его кнопкой «–» и добавьте заново (так бывает после пересборки)."
        case .screenRecording:
            return "Системные настройки → Конфиденциальность и безопасность → Запись экрана и аудио → включите Mac Utilities. macOS может потребовать перезапустить приложение."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}

/// Проверка и запрос системных разрешений. Разрешения не запрашиваются при запуске:
/// модуль просит их только когда пользователь его включает.
@MainActor
@Observable
final class PermissionManager {
    private(set) var granted: [PermissionKind: Bool] = [:]
    private(set) var lastChecked: Date?

    /// Вызывается при изменении любого разрешения (реестр перезапускает ожидающие модули).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watched: Set<PermissionKind> = []

    init() {
        refresh()
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        granted[kind] ?? false
    }

    func missing(_ kinds: [PermissionKind]) -> [PermissionKind] {
        kinds.filter { !isGranted($0) }
    }

    func refresh() {
        let new: [PermissionKind: Bool] = [
            .accessibility: AXIsProcessTrusted(),
            .screenRecording: CGPreflightScreenCaptureAccess(),
        ]
        lastChecked = Date()
        if new != granted {
            let isInitial = granted.isEmpty
            granted = new
            Log.permissions.info("Permissions: accessibility=\(new[.accessibility] ?? false), screen=\(new[.screenRecording] ?? false)")
            if !isInitial { onChange?() }
        }
        updateTimer()
    }

    /// Показывает системный запрос (если macOS ещё не спрашивала) и открывает нужный раздел настроек.
    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            // Системный диалог показывается только один раз; дальше — только через настройки.
            if !CGRequestScreenCaptureAccess() {
                openSettings(for: kind)
            }
        }
        watch([kind])
        refresh()
    }

    func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
        watch([kind])
    }

    /// Пока нужное разрешение не выдано, периодически проверяем статус (раз в 2 с).
    /// Как только всё выдано — таймер останавливается, нагрузки в покое нет.
    func watch(_ kinds: Set<PermissionKind>) {
        watched.formUnion(kinds)
        updateTimer()
    }

    func setWatched(_ kinds: Set<PermissionKind>) {
        watched = kinds
        updateTimer()
    }

    private func updateTimer() {
        let needsPolling = watched.contains { !isGranted($0) }
        if needsPolling, timer == nil {
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needsPolling, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }
}
