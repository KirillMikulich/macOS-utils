import AppKit
import Observation
import SwiftUI

/// Поведение Dock и мыши.
///
/// Dock: убирает паузу перед выездом и ускоряет анимацию при автоскрытии. Значения
/// пишутся в системные настройки Dock и сохраняются после выхода из Mac Utilities;
/// при выключении модуля возвращаются исходные значения пользователя.
///
/// Мышь: ускорение указателя — системная настройка macOS 14+ (Мышь → «Ускорение указателя»).
/// Применить её на лету может только сама macOS, поэтому модуль показывает её состояние
/// и открывает нужный раздел настроек.
@MainActor
@Observable
final class MouseDockModule: AppModule {
    let id = ModuleID.mouseDock
    let title = "Мышь и Dock"
    let summary = "Плавная прокрутка колесом мыши и своё направление (отдельно от трекпада); Dock выезжает без задержки."
    let systemImage = "computermouse"
    /// Колесо перехватывается, только если включены плавность или переворот направления.
    var wheelActive: Bool {
        settings.wheel.smooth || settings.wheel.reverseVertical || settings.wheel.reverseHorizontal
    }

    /// «Универсальный доступ» нужен только для перехвата колеса мыши.
    var requiredPermissions: [PermissionKind] { wheelActive ? [.accessibility] : [] }

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: MouseDockSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            guard settings.isEnabled == oldValue.isEnabled else {
                // Модуль выключен — Dock возвращается к прежним значениям (колесо остановит stop()).
                if !settings.isEnabled { restoreDock() }
                return
            }
            if settings.wheel != oldValue.wheel {
                wheelSettingsChanged(wasActive: oldValue.wheel.smooth || oldValue.wheel.reverseVertical || oldValue.wheel.reverseHorizontal)
            }
            if settings.dockTweaksEnabled != oldValue.dockTweaksEnabled {
                if settings.dockTweaksEnabled { if runState == .running { applyDock() } } else { restoreDock() }
            } else if runState == .running, settings.dockTweaksEnabled,
                      settings.dockDelay != oldValue.dockDelay || settings.dockAnimation != oldValue.dockAnimation {
                scheduleApply()
            }
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    var shortcuts: [ModuleShortcutInfo] { [] }

    /// Состояние системной настройки «Ускорение указателя» (true — ускорение выключено).
    var isPointerLinear: Bool {
        (CFPreferencesCopyAppValue("com.apple.mouse.linear" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? false
    }

    @ObservationIgnored private let dockTuning: DockTuning
    @ObservationIgnored private let wheel = ScrollWheelInterceptor()
    private(set) var wheelError: String?
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    init(context: ModuleContext, dockTuning: DockTuning = DockTuning()) {
        self.context = context
        self.dockTuning = dockTuning
        self.settings = context.settingsStore.load(MouseDockSettings.self)
    }

    // MARK: - Lifecycle

    func activate() throws {
        if settings.dockTweaksEnabled { applyDock() } else { restoreDock() }
        updateWheel()
    }

    private func updateWheel() {
        // Параметры плавности — в единицах Mos (см. MosScrollEngine), по умолчанию его значения.
        var effective = WheelSettings()
        effective.isEnabled = wheelActive
        effective.smooth = settings.wheel.smooth
        effective.reverseVertical = settings.wheel.reverseVertical
        effective.reverseHorizontal = settings.wheel.reverseHorizontal
        effective.excludedBundleIDs = settings.wheel.excludedBundleIDs
        effective.smoothStep = settings.wheel.smoothStep
        effective.smoothSpeed = settings.wheel.smoothSpeed
        effective.smoothDuration = settings.wheel.smoothDuration
        effective.fastScrollWithOption = settings.wheel.fastScrollWithOption
        wheel.settings = effective
        if wheelActive {
            wheel.start()
            wheelError = wheel.lastError
        } else {
            wheel.stop()
            wheelError = nil
        }
    }

    private func wheelSettingsChanged(wasActive: Bool) {
        guard settings.isEnabled else { return }
        if wheelActive && !wasActive {
            // Колесо требует «Универсального доступа»: запрашиваем при включении и перезапускаем модуль.
            for kind in context.permissions.missing(requiredPermissions) { context.permissions.request(kind) }
            start()
        } else if runState == .running {
            updateWheel()
        } else {
            start()
        }
    }

    /// Системные настройки Dock остаются применёнными и при паузе, и после выхода из Mac Utilities —
    /// фоновых задач у модуля нет. Откат делается только при выключении модуля.
    func deactivate() {
        applyTask?.cancel()
        applyTask = nil
        wheel.stop()
    }

    // MARK: - Dock

    private func applyDock() {
        let original = dockTuning.apply(delay: settings.dockDelay, animation: settings.dockAnimation,
                                         original: settings.originalDock)
        if settings.originalDock == nil {
            settings.originalDock = original
        }
    }

    /// Ползунок двигают плавно — Dock перезапускается один раз, когда значение перестало меняться.
    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.runState == .running else { return }
            self.applyDock()
        }
    }

    private func restoreDock() {
        applyTask?.cancel()
        guard let original = settings.originalDock else { return }
        dockTuning.restore(original)
        settings.originalDock = nil
    }

    func openMouseSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Mouse-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(MouseDockSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(MouseDockQuickSettingsView(module: self))
    }
}
