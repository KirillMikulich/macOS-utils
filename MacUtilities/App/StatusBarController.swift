import AppKit
import Observation

/// Значок в строке меню: быстрый доступ к настройкам, паузе модулей и выходу.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private unowned let coordinator: AppCoordinator
    private var statusItem: NSStatusItem?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        observePause()
    }

    /// Значок меняется при паузе, откуда бы она ни была включена (меню, Dashboard, настройки).
    private func observePause() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observePause() }
            }
        }
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func updateIcon() {
        let paused = coordinator.registry.isPaused
        let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Mac Utilities")
        image?.isTemplate = true
        statusItem?.button?.image = image
        // На паузе значок приглушён.
        statusItem?.button?.appearsDisabled = paused
        statusItem?.button?.toolTip = paused ? L("Mac Utilities — приостановлен") : "Mac Utilities"
    }

    // Меню собирается заново при каждом открытии — так состояние всегда актуально.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(L("Открыть Mac Utilities…"), #selector(openMain)))
        menu.addItem(.separator())

        let header = NSMenuItem(title: L("Модули"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for module in coordinator.registry.modules {
            let entry = item(module.title, #selector(toggleModule(_:)))
            entry.state = module.isEnabled ? .on : .off
            entry.representedObject = module.id.rawValue
            entry.image = NSImage(systemSymbolName: module.systemImage, accessibilityDescription: nil)
            if module.isEnabled, module.runState != .running {
                entry.toolTip = module.runState.title
                entry.title = "\(module.title) — \(module.runState.title.lowercased())"
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        if let clipboard = coordinator.registry.module(.clipboardHistory) as? ClipboardHistoryModule {
            let show = item(L("Показать историю буфера"), #selector(showClipboard))
            show.isEnabled = clipboard.runState == .running
            if let combo = clipboard.settings.shortcut { show.title += "  \(combo.displayString)" }
            menu.addItem(show)
            let privateItem = item(L("Режим приватности буфера"), #selector(togglePrivate))
            privateItem.state = clipboard.settings.privateMode ? .on : .off
            menu.addItem(privateItem)
        }

        let pause = item(coordinator.registry.isPaused ? L("Возобновить все модули") : L("Приостановить все модули"), #selector(togglePause))
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item(L("Выйти из Mac Utilities"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openMain() {
        coordinator.showMainWindow()
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw),
              let module = coordinator.registry.module(id) else { return }
        module.setEnabled(!module.isEnabled)
    }

    @objc private func showClipboard() {
        (coordinator.registry.module(.clipboardHistory) as? ClipboardHistoryModule)?.showPanel()
    }

    @objc private func togglePrivate() {
        guard let clipboard = coordinator.registry.module(.clipboardHistory) as? ClipboardHistoryModule else { return }
        clipboard.settings.privateMode.toggle()
    }

    @objc private func togglePause() {
        coordinator.registry.setPaused(!coordinator.registry.isPaused)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
