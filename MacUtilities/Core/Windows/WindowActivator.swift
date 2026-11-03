import AppKit
import ApplicationServices

enum WindowActivationScope: String, Codable, CaseIterable, Identifiable {
    /// Поднять только выбранное окно.
    case selectedWindow
    /// Поднять выбранное окно и все остальные окна приложения.
    case allAppWindows

    var id: String { rawValue }
    var title: String {
        switch self {
        case .selectedWindow: return L("Только выбранное окно")
        case .allAppWindows: return L("Выбранное окно и остальные окна приложения")
        }
    }
}

/// Перевод фокуса на окно другого приложения через публичный Accessibility API.
@MainActor
final class WindowActivator {
    func activate(_ window: WindowInfo, scope: WindowActivationScope = .selectedWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }

        guard let element = window.element else {
            // Окно без AX-элемента — можем только активировать приложение целиком.
            app.activate(options: scope == .allAppWindows ? [.activateAllWindows] : [])
            return
        }

        if window.isMinimized {
            AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse)
        }

        // Порядок важен: сначала делаем приложение активным через AX (kAXFrontmost работает
        // и для фонового агента, в отличие от NSRunningApplication.activate при кооперативной
        // активации macOS 14+), затем поднимаем окно и делаем его главным.
        let appElement = AXUIElementCreateApplication(window.pid)
        AX.set(appElement, kAXFrontmostAttribute, kCFBooleanTrue)
        AX.perform(element, kAXRaiseAction)
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)

        if scope == .allAppWindows {
            app.activate(options: [.activateAllWindows])
            // activateAllWindows поднимает окна приложения в их собственном порядке —
            // ещё раз поднимаем выбранное окно поверх.
            AX.perform(element, kAXRaiseAction)
        } else if !app.isActive {
            app.activate()
        }
    }

    func minimize(_ window: WindowInfo) {
        guard let element = window.element else { return }
        AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
    }

    func close(_ window: WindowInfo) {
        guard let element = window.element,
              let closeButton = AX.element(element, kAXCloseButtonAttribute) else { return }
        AX.perform(closeButton, kAXPressAction)
    }
}
