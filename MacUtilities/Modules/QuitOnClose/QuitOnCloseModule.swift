import AppKit
import Observation
import SwiftUI

enum QuitOnCloseMode: String, Codable, CaseIterable, Identifiable {
    case allExceptExcluded
    case onlySelected

    var id: String { rawValue }
    var title: String {
        switch self {
        case .allExceptExcluded: return L("Все приложения, кроме исключений")
        case .onlySelected: return L("Только выбранные приложения")
        }
    }
}

struct QuitOnCloseSettings: PersistedSettings {
    static let storageKey = "quitOnClose"
    static let schemaVersion = 1
    static let defaultValue = QuitOnCloseSettings()

    /// По умолчанию выключен: модуль завершает приложения и требует Accessibility.
    var isEnabled = false
    var mode: QuitOnCloseMode = .allExceptExcluded
    var excludedBundleIDs: [String] = [
        "com.apple.finder",
        "com.otvertka.Otvertka",
    ]
    var selectedBundleIDs: [String] = []

    /// Решение, завершать ли приложение. Finder и Mac Utilities не завершаются никогда.
    func shouldQuit(bundleID: String?) -> Bool {
        guard let bundleID, !Self.neverQuit.contains(bundleID) else { return false }
        switch mode {
        case .allExceptExcluded: return !excludedBundleIDs.contains(bundleID)
        case .onlySelected: return selectedBundleIDs.contains(bundleID)
        }
    }

    static let neverQuit: Set<String> = ["com.apple.finder", "com.otvertka.Otvertka"]
}

/// Завершает приложение, когда закрыто его последнее окно (как в Windows).
/// Поведение повторяет идею Swift Quit (onebadidea/swiftquit, GPL-3.0); код написан независимо.
@MainActor
@Observable
final class QuitOnCloseModule: AppModule {
    let id = ModuleID.quitOnClose
    var title: String { L("Автовыход") }
    var summary: String { L("Приложение завершается, когда закрыто его последнее окно (красная кнопка или ⌘W).") }
    let systemImage = "rectangle.portrait.and.arrow.right"
    let requiredPermissions: [PermissionKind] = [.accessibility]

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: QuitOnCloseSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            if QuitOnClosePolicy.active != nil { QuitOnClosePolicy.active = settings }
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    var shortcuts: [ModuleShortcutInfo] { [] }

    /// Последнее завершённое приложение — показывается в настройках.
    private(set) var lastQuitApp: String?

    @ObservationIgnored private let watcher = WindowCloseWatcher()

    init(context: ModuleContext) {
        self.context = context
        self.settings = context.settingsStore.load(QuitOnCloseSettings.self)
        watcher.onLastWindowClosed = { [weak self] app in self?.lastWindowClosed(app) }
    }

    func activate() throws {
        watcher.start()
        QuitOnClosePolicy.active = settings
    }

    func deactivate() {
        watcher.stop()
        QuitOnClosePolicy.active = nil
    }

    private func lastWindowClosed(_ app: NSRunningApplication) {
        guard settings.shouldQuit(bundleID: app.bundleIdentifier) else { return }
        // Обычное завершение: приложение само спросит о несохранённых документах.
        if app.terminate() {
            lastQuitApp = app.localizedName
            Log.modules.info("Quit \(app.bundleIdentifier ?? "?", privacy: .public) after its last window closed")
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(QuitOnCloseSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(QuitOnCloseQuickSettingsView(module: self))
    }
}

struct QuitOnCloseSettingsView: View {
    @Bindable var module: QuitOnCloseModule

    var body: some View {
        let permissions = module.context.permissions
        Form {
            Section(L("Основное")) {
                Toggle(L("Завершать приложение, когда закрыто его последнее окно"),
                       isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                if module.isEnabled && !permissions.isGranted(.accessibility) {
                    PermissionBanner(kind: .accessibility, permissions: permissions)
                }
                SettingsCaption(text: L("Как в Windows: закрыли последнее окно красной кнопкой или ⌘W — приложение завершается. Несохранённые документы приложение предложит сохранить само. Если у приложения есть окна на другом рабочем столе или свёрнутые окна, оно не завершается."))
                SettingsCaption(text: L("Кнопки на миниатюрах в превью Dock и переключателе окон: ✕ закрывает только это окно, ⏻ сразу завершает приложение со всеми окнами. Если окно последнее, ✕ становится оранжевым — после закрытия приложение завершится."))
                if let app = module.lastQuitApp {
                    LabeledContent(L("Последнее завершённое"), value: app)
                }
            }
            Section(L("Какие приложения")) {
                Picker(L("Режим"), selection: $module.settings.mode) {
                    ForEach(QuitOnCloseMode.allCases) { Text($0.title).tag($0) }
                }
                switch module.settings.mode {
                case .allExceptExcluded:
                    LabeledContent(L("Не завершать")) {
                        AppExclusionEditor(bundleIDs: $module.settings.excludedBundleIDs)
                    }
                case .onlySelected:
                    LabeledContent(L("Завершать только")) {
                        AppExclusionEditor(bundleIDs: $module.settings.selectedBundleIDs, emptyText: L("Приложения не выбраны"))
                    }
                }
                SettingsCaption(text: L("Finder и Mac Utilities не завершаются никогда. Приложения, которые работают без окон (плееры, мессенджеры в фоне), лучше добавить в исключения."))
            }
        }
        .formStyle(.grouped)
    }
}

struct QuitOnCloseQuickSettingsView: View {
    @Bindable var module: QuitOnCloseModule

    var body: some View {
        Picker(L("Режим"), selection: $module.settings.mode) {
            ForEach(QuitOnCloseMode.allCases) { Text($0.title).tag($0) }
        }
    }
}

/// Для подсказок в превью и переключателе окон: завершит ли «Автовыход» приложение,
/// если закрыть это окно (оно последнее у приложения).
@MainActor
enum QuitOnClosePolicy {
    /// Настройки работающего модуля; nil — модуль выключен или на паузе.
    static var active: QuitOnCloseSettings?

    static func closeQuitsApp(_ window: WindowInfo) -> Bool {
        guard let active, active.shouldQuit(bundleID: window.bundleID) else { return false }
        // Свёрнутые окна тоже считаются: с ними приложение не завершается.
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let windows = AX.elements(app, kAXWindowsAttribute).filter(WindowCloseWatcher.isStandardWindow)
        return windows.count <= 1
    }
}
