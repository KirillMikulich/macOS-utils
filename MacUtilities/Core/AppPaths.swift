import Foundation

/// Расположение локальных данных приложения.
/// Всё хранится только в ~/Library/Application Support/Mac Utilities — сеть не используется.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mac Utilities", isDirectory: true)
    }

    static var settingsDirectory: URL {
        supportDirectory.appendingPathComponent("Settings", isDirectory: true)
    }

    static var clipboardDirectory: URL {
        supportDirectory.appendingPathComponent("ClipboardHistory", isDirectory: true)
    }

    /// Перенос данных после переименований (Thundercloud → Otvertka → Mac Utilities):
    /// если новой папки ещё нет, переносится самая свежая из старых (настройки и история буфера).
    static func migrateLegacyDataIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: supportDirectory.path) else { return }
        let parent = supportDirectory.deletingLastPathComponent()
        for name in ["Otvertka", "Thundercloud"] {
            let legacy = parent.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            do {
                try fileManager.moveItem(at: legacy, to: supportDirectory)
                Log.app.info("Migrated data from the \(name, privacy: .public) folder")
            } catch {
                Log.app.error("Failed to migrate legacy data: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// true, когда процесс запущен как хост для XCTest. В этом случае приложение
    /// не запускает модули, чтобы тесты не трогали системный буфер и горячие клавиши.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
