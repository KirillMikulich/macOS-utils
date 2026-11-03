import AppKit
import FinderSync
import Observation
import SwiftUI

struct FinderMenuSettings: PersistedSettings {
    static let storageKey = "finderMenu"
    static let schemaVersion = 1
    static var defaultValue: FinderMenuSettings { FinderMenuSettings(items: FinderMenuModule.defaultItems()) }

    var isEnabled = false
    var items: [FinderMenuItem] = []
}

/// Свои пункты в контекстном меню Finder: «Открыть в VS Code», «Скопировать путь» и т.п.
/// Меню показывает расширение Finder Sync (FinderMenuExtension), а выполняет пункты приложение:
/// расширение в песочнице и не может открывать файлы в других программах и создавать файлы.
@MainActor
@Observable
final class FinderMenuModule: AppModule {
    let id = ModuleID.finderMenu
    var title: String { L("Меню Finder") }
    var summary: String { L("Свои пункты в меню правого клика Finder: открыть в VS Code или Терминале, скопировать путь, создать файл.") }
    let systemImage = "contextualmenu.and.cursorarrow"
    let requiredPermissions: [PermissionKind] = []

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: FinderMenuSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            writeConfig()
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    var shortcuts: [ModuleShortcutInfo] { [] }

    /// Включено ли расширение в Системных настройках (обновляется при открытии раздела).
    private(set) var isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    private var isActive = false

    nonisolated static let extensionID = "com.otvertka.Otvertka.FinderMenu"

    init(context: ModuleContext) {
        self.context = context
        self.settings = context.settingsStore.load(FinderMenuSettings.self)
    }

    func activate() throws {
        isActive = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleRequest(_:)), name: FinderMenuRequest.notification, object: nil)
        writeConfig()
        registerExtension()
    }

    func deactivate() {
        isActive = false
        DistributedNotificationCenter.default().removeObserver(self, name: FinderMenuRequest.notification, object: nil)
        writeConfig()
    }

    func refreshExtensionState() {
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    }

    func openExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    // MARK: - Пункты по умолчанию

    nonisolated static func defaultItems() -> [FinderMenuItem] {
        var items: [FinderMenuItem] = []
        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            items.append(FinderMenuItem(title: L("Открыть в VS Code"), action: .openWithApp, appPath: vscode.path))
        }
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            // На файле Терминал попытался бы его выполнить — только папки и фон окна.
            items.append(FinderMenuItem(title: L("Открыть в Терминале"), action: .openWithApp, appPath: terminal.path,
                                        forFiles: false))
        }
        items.append(FinderMenuItem(title: L("Скопировать путь"), action: .copyPath, forBackground: true))
        items.append(FinderMenuItem(title: L("Новый текстовый файл"), action: .newFile, forFiles: false))
        return items
    }

    func addOpenWithApp(_ appURL: URL) {
        let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        settings.items.append(FinderMenuItem(title: L("Открыть в \(name)"), action: .openWithApp, appPath: appURL.path))
    }

    // MARK: - Связь с расширением

    /// Файл, который читает расширение. Пока модуль не работает — меню пустое.
    private func writeConfig() {
        let config = FinderMenuConfig(enabled: isActive, items: settings.items)
        do {
            AppPaths.ensureDirectory(FinderMenuConfig.fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(config).write(to: FinderMenuConfig.fileURL, options: .atomic)
        } catch {
            Log.modules.error("Finder menu config write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Регистрирует встроенное расширение и включает его (то же, что галочка в Системных настройках).
    private func registerExtension() {
        let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderMenu.appex").path
        Task.detached {
            if let appex { Self.pluginkit(["-a", appex]) }
            Self.pluginkit(["-e", "use", "-i", Self.extensionID])
            await MainActor.run { [weak self] in self?.refreshExtensionState() }
        }
    }

    nonisolated private static func pluginkit(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Выполнение пунктов

    @objc private func handleRequest(_ notification: Notification) {
        guard isActive,
              let json = notification.object as? String,
              let request = try? JSONDecoder().decode(FinderMenuRequest.self, from: Data(json.utf8)),
              let item = settings.items.first(where: { $0.id == request.itemID }) else { return }
        perform(item, urls: request.paths.map { URL(fileURLWithPath: $0) })
    }

    func perform(_ item: FinderMenuItem, urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch item.action {
        case .openWithApp:
            guard let appPath = item.appPath else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: appPath), configuration: configuration) { _, error in
                if let error { Log.modules.error("Open with app failed: \(error.localizedDescription, privacy: .public)") }
            }
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .newFile:
            createFile(near: urls[0])
        }
    }

    /// Пустой файл «Без названия.txt» в папке (или рядом с выбранным файлом), затем выделить его в Finder.
    private func createFile(near url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        let base = L("Без названия")
        var target = folder.appendingPathComponent("\(base).txt")
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(index).txt")
            index += 1
        }
        guard FileManager.default.createFile(atPath: target.path, contents: Data()) else {
            Log.modules.error("Failed to create file in \(folder.path, privacy: .public)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(FinderMenuSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(FinderMenuQuickView(module: self))
    }
}
