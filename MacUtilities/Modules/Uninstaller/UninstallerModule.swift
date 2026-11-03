import AppKit
import Observation
import SwiftUI

struct UninstallerSettings: PersistedSettings {
    static let storageKey = "uninstaller"
    static let schemaVersion = 1
    static let defaultValue = UninstallerSettings()

    var isEnabled = true
}

struct UninstallReport: Equatable {
    var trashed: [URL] = []
    var failed: [(url: URL, reason: String)] = []

    static func == (lhs: UninstallReport, rhs: UninstallReport) -> Bool {
        lhs.trashed == rhs.trashed && lhs.failed.map(\.url) == rhs.failed.map(\.url)
    }
}

/// Удаление приложений вместе с их файлами в ~/Library и /Library.
/// Всё перемещается в Корзину — восстановить можно обычным «Вернуть».
@MainActor
@Observable
final class UninstallerModule: AppModule {
    let id = ModuleID.uninstaller
    var title: String { L("Удаление программ") }
    var summary: String { L("Удаляет приложение вместе с настройками, кэшами и другими файлами — в Корзину.") }
    let systemImage = "xmark.bin"
    let requiredPermissions: [PermissionKind] = []

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: UninstallerSettings {
        didSet { if settings != oldValue { context.settingsStore.save(settings) } }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    var shortcuts: [ModuleShortcutInfo] { [] }

    init(context: ModuleContext) {
        self.context = context
        self.settings = context.settingsStore.load(UninstallerSettings.self)
    }

    // Фоновых задач нет — модуль работает только по запросу из окна.
    func activate() throws {}
    func deactivate() {}

    // MARK: - Список приложений

    nonisolated static func installedApps() -> [AppBundleInfo] {
        let fileManager = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var result: [AppBundleInfo] = []
        var seen = Set<String>()
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                // Приложения и папки с приложениями на один уровень вглубь (например, /Applications/Utilities).
                let candidates: [URL]
                if entry.pathExtension == "app" {
                    candidates = [entry]
                } else {
                    candidates = ((try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension == "app" }
                }
                for url in candidates {
                    guard let info = AppBundleInfo(url: url), !info.isProtected, seen.insert(info.bundleID).inserted else { continue }
                    result.append(info)
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Есть ли «Полный доступ к диску». Без него часть данных других приложений
    /// (контейнеры, Safari и т.п.) не видна или macOS спрашивает доступ отдельно.
    nonisolated static var hasFullDiskAccess: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Удаление

    /// Завершает приложение, если оно запущено. Возвращает false, если оно не закрылось за 5 секунд.
    func quitIfRunning(_ app: AppBundleInfo) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<50 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return running.allSatisfy(\.isTerminated)
    }

    func uninstall(_ app: AppBundleInfo, items: [LeftoverItem]) async -> UninstallReport {
        var report = UninstallReport()
        guard !app.isProtected else {
            report.failed.append((app.url, L("Системные приложения удалять нельзя")))
            return report
        }
        guard await quitIfRunning(app) else {
            report.failed.append((app.url, L("Приложение не закрылось — закройте его и повторите")))
            return report
        }
        var needsFinder: [URL] = []
        for url in [app.url] + items.filter(\.isSelected).map(\.url) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                report.trashed.append(url)
            } catch {
                needsFinder.append(url)
            }
        }
        // Файлы, принадлежащие администратору: Finder удаляет их с запросом пароля, как при ручном удалении.
        for url in needsFinder {
            if let failure = Self.trashWithFinder(url) {
                report.failed.append((url, failure))
            } else {
                report.trashed.append(url)
            }
        }
        Log.modules.info("Uninstalled \(app.bundleID, privacy: .public): \(report.trashed.count) trashed, \(report.failed.count) failed")
        return report
    }

    /// nil — успех, иначе текст ошибки.
    private static func trashWithFinder(_ url: URL) -> String? {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return L("Отменено") }
        return (error[NSAppleScript.errorMessage] as? String) ?? L("Не удалось переместить в Корзину")
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(UninstallerView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(Text(L("Откройте раздел, чтобы выбрать приложение")).font(.caption).foregroundStyle(.secondary))
    }
}
