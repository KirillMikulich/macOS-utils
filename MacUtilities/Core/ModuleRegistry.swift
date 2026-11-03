import AppKit
import Observation

/// Общие сервисы, которые получает каждый модуль. Системные сервисы создаются
/// в одном экземпляре и не дублируются между модулями.
@MainActor
@Observable
final class ModuleContext {
    let settingsStore: SettingsStore
    let shortcuts: ShortcutManager
    let permissions: PermissionManager
    let windowDiscovery: WindowDiscoveryService
    let windowActivator: WindowActivator
    let thumbnails: WindowThumbnailService
    let overlays: OverlayCoordinator

    /// Глобальная пауза всех модулей (из строки меню). Не меняет флаги включения.
    fileprivate(set) var isPaused = false

    init(settingsStore: SettingsStore,
         shortcuts: ShortcutManager,
         permissions: PermissionManager,
         windowDiscovery: WindowDiscoveryService? = nil,
         windowActivator: WindowActivator? = nil,
         thumbnails: WindowThumbnailService? = nil,
         overlays: OverlayCoordinator? = nil) {
        self.settingsStore = settingsStore
        self.shortcuts = shortcuts
        self.permissions = permissions
        self.windowDiscovery = windowDiscovery ?? WindowDiscoveryService()
        self.windowActivator = windowActivator ?? WindowActivator()
        self.thumbnails = thumbnails ?? WindowThumbnailService()
        self.overlays = overlays ?? OverlayCoordinator()
    }
}

@MainActor
@Observable
final class ModuleRegistry {
    let context: ModuleContext
    private(set) var modules: [any AppModule] = []

    var isPaused: Bool { context.isPaused }

    init(context: ModuleContext) {
        self.context = context
        context.permissions.onChange = { [weak self] in
            self?.permissionsChanged()
        }
    }

    func register(_ module: any AppModule) {
        precondition(!modules.contains { $0.id == module.id }, "Duplicate module \(module.id)")
        modules.append(module)
    }

    func module(_ id: ModuleID) -> (any AppModule)? {
        modules.first { $0.id == id }
    }

    func startAll() {
        for module in modules { module.start() }
        updateWatchedPermissions()
    }

    func stopAll() {
        for module in modules { module.deactivate() }
    }

    func setPaused(_ paused: Bool) {
        guard paused != context.isPaused else { return }
        context.isPaused = paused
        Log.modules.info("Global pause = \(paused)")
        for module in modules {
            if paused { module.stop() } else { module.start() }
        }
    }

    /// Разрешение выдано или отозвано — перезапускаем модули, которые этого ждали
    /// (или которые теперь не могут работать).
    private func permissionsChanged() {
        for module in modules where module.isEnabled {
            module.start()
        }
        updateWatchedPermissions()
    }

    private func updateWatchedPermissions() {
        var needed = Set<PermissionKind>()
        for module in modules where module.isEnabled {
            needed.formUnion(module.requiredPermissions)
        }
        context.permissions.setWatched(needed)
    }
}
