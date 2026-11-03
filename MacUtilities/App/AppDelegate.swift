import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build()
        // В режиме unit-тестов приложение-хост не запускает модули и не трогает систему.
        guard !AppPaths.isRunningTests else { return }
        if handOffToRunningInstance() { return }
        AppPaths.migrateLegacyDataIfNeeded()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Допускается только один экземпляр: две копии (например, установленная и Debug-сборка)
    /// дублировали бы значок в строке меню, горячие клавиши и запись буфера, а при ad-hoc
    /// подписи macOS считает их разными приложениями с разными разрешениями.
    /// Новая копия открывает окно уже запущенной и завершается.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0 != NSRunningApplication.current && !$0.isTerminated }) else { return false }
        Log.app.notice("Another instance is running at \(other.bundleURL?.path ?? "?", privacy: .public), handing off")
        if let url = other.bundleURL {
            // Повторное «открытие» запущенного приложения присылает ему событие reopen → главное окно.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.terminate(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    /// Повторный запуск из Finder/Launchpad открывает главное окно — так приложение
    /// доступно, даже если значки в строке меню и Dock скрыты.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showMainWindow()
        return true
    }

    /// Закрытие главного окна не завершает приложение: модули работают в фоне.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showMainWindow(_ sender: Any?) {
        coordinator?.showMainWindow()
    }

    @objc func showAbout(_ sender: Any?) {
        coordinator?.showMainWindow(section: .about)
    }
}
