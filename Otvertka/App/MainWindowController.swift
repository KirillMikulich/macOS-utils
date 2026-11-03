import AppKit
import SwiftUI

/// Главное окно настроек. Создаётся по требованию; закрытие окна не останавливает модули.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let hosting = NSHostingController(rootView: MainView(coordinator: coordinator))
        // SwiftUI задаёт только минимальный размер окна (см. frame(minWidth:minHeight:) в MainView),
        // а сам размер выбирает пользователь — окно не растягивается при переходе между разделами.
        hosting.sizingOptions = [.minSize]
        window = NSWindow(contentViewController: hosting)
        window.title = "Mac Utilities"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Заголовок прозрачный: боковая панель и фон идут до самого верха окна.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 960, height: 660))
        window.contentMinSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OtvertkaMainWindow")
        super.init()
        window.delegate = self
        if !window.setFrameUsingName("OtvertkaMainWindow") { window.center() }
    }

    func show() {
        coordinator.permissions.refresh()
        coordinator.loginItem.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window.isVisible }

    func windowWillClose(_ notification: Notification) {
        // Окно закрывается только вручную; после этого возвращаемся в режим строки меню.
        DispatchQueue.main.async { [weak self] in
            self?.coordinator.updateActivationPolicy()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        coordinator.permissions.refresh()
    }
}
