import AppKit
import Observation

enum SidebarSection: Hashable {
    case dashboard
    case module(ModuleID)
    case general
    case permissions
    case about
}

/// Общие настройки приложения + применение их к системе (Dock, строка меню, тема).
@MainActor
@Observable
final class AppSettingsModel {
    var general: GeneralSettings {
        didSet {
            guard general != oldValue else { return }
            store.save(general)
            onChange?(oldValue)
        }
    }

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored var onChange: ((GeneralSettings) -> Void)?

    init(store: SettingsStore) {
        self.store = store
        self.general = store.load(GeneralSettings.self)
    }
}

@MainActor
@Observable
final class NavigationModel {
    var selection: SidebarSection? = .dashboard
}

/// Создаёт сервисы и модули, связывает их между собой и с интерфейсом.
@MainActor
final class AppCoordinator {
    let settingsStore = SettingsStore()
    let shortcuts = ShortcutManager()
    let permissions = PermissionManager()
    let loginItem = LoginItemService()
    let navigation = NavigationModel()
    let appSettings: AppSettingsModel
    let context: ModuleContext
    let registry: ModuleRegistry

    private var statusBar: StatusBarController?
    private var mainWindow: MainWindowController?

    init() {
        appSettings = AppSettingsModel(store: settingsStore)
        // Язык — до построения меню и окон.
        Localization.shared.language = appSettings.general.language
        context = ModuleContext(settingsStore: settingsStore, shortcuts: shortcuts, permissions: permissions)
        registry = ModuleRegistry(context: context)

        registry.register(ClipboardHistoryModule(context: context))
        registry.register(WindowSwitcherModule(context: context))
        registry.register(DockPreviewModule(context: context))
        registry.register(MouseDockModule(context: context))
        registry.register(QuitOnCloseModule(context: context))
        registry.register(ScreenshotToolModule(context: context))
        registry.register(UninstallerModule(context: context))
    }

    func start() {
        Log.app.info("Mac Utilities starting")
        appSettings.onChange = { [weak self] old in self?.applyGeneralSettings(old: old) }
        applyGeneralSettings(old: nil)

        if !appSettings.general.restoreModulesOnLaunch {
            registry.setPaused(true)
        }
        registry.startAll()

        // При запуске как объект входа (фоновый запуск) окно не открывается, если так настроено.
        if appSettings.general.openMainWindowAtLaunch || (!appSettings.general.showMenuBarIcon && !appSettings.general.showDockIcon) {
            showMainWindow()
        }
    }

    func shutdown() {
        Log.app.info("Mac Utilities shutting down")
        registry.stopAll()
        shortcuts.unregisterAll()
    }

    func showMainWindow(section: SidebarSection? = nil) {
        if let section { navigation.selection = section }
        if mainWindow == nil {
            mainWindow = MainWindowController(coordinator: self)
        }
        mainWindow?.show()
        updateActivationPolicy()
    }

    /// Пока открыто главное окно, приложение ведёт себя как обычное: значок в Dock,
    /// есть в ⌘⇥ и в Переключение окон, поэтому окно не «теряется» при переключении.
    /// После закрытия окна приложение снова уходит в строку меню (если значок в Dock выключен).
    func updateActivationPolicy() {
        let needsRegular = appSettings.general.showDockIcon || (mainWindow?.isVisible ?? false)
        let policy: NSApplication.ActivationPolicy = needsRegular ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func applyGeneralSettings(old: GeneralSettings?) {
        let general = appSettings.general
        if old?.showDockIcon != general.showDockIcon {
            updateActivationPolicy()
            if old != nil { NSApp.activate(ignoringOtherApps: true) }
        }
        if old?.showMenuBarIcon != general.showMenuBarIcon {
            if general.showMenuBarIcon {
                statusBar = statusBar ?? StatusBarController(coordinator: self)
            } else {
                statusBar?.remove()
                statusBar = nil
            }
        }
        if old?.overlay != general.overlay {
            OverlayStyle.shared.settings = general.overlay
        }
        if old?.appearance != general.appearance {
            NSApp.appearance = general.appearance.nsAppearance
        }
        if old?.language != general.language {
            Localization.shared.language = general.language
            // Окна и панели перерисуются сами; главное меню AppKit собирается заново.
            if old != nil { NSApp.mainMenu = MainMenuBuilder.build() }
        }
    }
}
