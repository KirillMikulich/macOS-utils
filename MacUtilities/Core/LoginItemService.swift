import Foundation
import Observation
import ServiceManagement

/// Запуск при входе через SMAppService (macOS 13+). Дополнительный helper-процесс не нужен:
/// регистрируется само приложение. Источник истины — состояние в системе, а не наши настройки.
@MainActor
@Observable
final class LoginItemService {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusDescription: String {
        switch status {
        case .enabled: return L("Включено")
        case .notRegistered: return L("Выключено")
        case .requiresApproval: return L("Требует подтверждения в Системных настройках → Основные → Объекты входа")
        case .notFound: return L("Служба не найдена (запустите приложение из папки «Программы»)")
        @unknown default: return L("Неизвестно")
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
