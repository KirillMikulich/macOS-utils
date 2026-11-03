import SwiftUI

enum ModuleID: String, CaseIterable, Codable, Identifiable {
    case clipboardHistory
    case windowSwitcher
    case dockPreview
    case mouseDock
    case quitOnClose
    case uninstaller
    case screenshotTool
    case finderMenu

    var id: String { rawValue }

    /// Цвет плашки значка раздела (как в Системных настройках).
    var tint: Color {
        switch self {
        case .clipboardHistory: return .blue
        case .windowSwitcher: return .indigo
        case .dockPreview: return .purple
        case .mouseDock: return .mint
        case .quitOnClose: return .orange
        case .screenshotTool: return .teal
        case .uninstaller: return .red
        case .finderMenu: return .cyan
        }
    }
}

/// Значок раздела: тонкий символ цвета раздела на мягкой полупрозрачной подложке.
struct SectionIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

enum ModuleRunState: Equatable {
    case disabled
    case paused                                   // глобальная пауза из строки меню
    case running
    case waitingForPermissions([PermissionKind])
    case failed(String)

    var title: String {
        switch self {
        case .disabled: return L("Выключен")
        case .paused: return L("Приостановлен")
        case .running: return L("Работает")
        case .waitingForPermissions: return L("Нужны разрешения")
        case .failed: return L("Ошибка")
        }
    }

    var color: Color {
        switch self {
        case .disabled: return .secondary
        case .paused: return .orange
        case .running: return .green
        case .waitingForPermissions: return .orange
        case .failed: return .red
        }
    }
}

struct ModuleShortcutInfo: Identifiable {
    let id: ShortcutID
    let title: String
    let combo: KeyCombo?
}

enum ModuleError: LocalizedError {
    case startFailed(String)
    var errorDescription: String? {
        switch self {
        case .startFailed(let reason): return reason
        }
    }
}

/// Общий контракт встроенного модуля.
///
/// Модуль сам владеет своими настройками (отдельный JSON-файл) и фоновыми ресурсами.
/// Жизненный цикл (`start`/`stop`/`setEnabled`) реализован в расширении протокола —
/// модулю достаточно реализовать `activate()` и `deactivate()`:
/// - `activate()` должен быть идемпотентным: его вызывают и при изменении настроек;
/// - `deactivate()` обязан освободить таймеры, наблюдателей, горячие клавиши и панели.
@MainActor
protocol AppModule: AnyObject {
    var id: ModuleID { get }
    var title: String { get }
    var summary: String { get }
    var systemImage: String { get }

    /// Хранится в настройках модуля и переживает перезапуск.
    var isEnabled: Bool { get set }
    var runState: ModuleRunState { get set }
    var context: ModuleContext { get }

    /// Без этих разрешений модуль не запускается.
    var requiredPermissions: [PermissionKind] { get }
    /// Улучшают работу, но не обязательны (например, миниатюры окон).
    var optionalPermissions: [PermissionKind] { get }
    var shortcuts: [ModuleShortcutInfo] { get }

    func activate() throws
    func deactivate()

    func makeSettingsView() -> AnyView
    /// Основные настройки для карточки на Dashboard.
    func makeQuickSettingsView() -> AnyView
}

extension AppModule {
    var optionalPermissions: [PermissionKind] { [] }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Log.modules.info("\(self.id.rawValue, privacy: .public) enabled=\(enabled)")
        if enabled {
            // Разрешения запрашиваются только в момент включения модуля.
            for kind in context.permissions.missing(requiredPermissions) {
                context.permissions.request(kind)
            }
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isEnabled else {
            deactivate()
            runState = .disabled
            return
        }
        guard !context.isPaused else {
            deactivate()
            runState = .paused
            return
        }
        let missing = context.permissions.missing(requiredPermissions)
        guard missing.isEmpty else {
            deactivate()
            runState = .waitingForPermissions(missing)
            context.permissions.watch(Set(missing))
            return
        }
        do {
            try activate()
            runState = .running
        } catch {
            deactivate()
            runState = .failed(error.localizedDescription)
            Log.modules.error("\(self.id.rawValue, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        deactivate()
        runState = isEnabled ? .paused : .disabled
    }

    /// Применить изменения настроек к работающему модулю.
    func applySettingsChange() {
        if runState == .running || isEnabled {
            start()
        }
    }
}
