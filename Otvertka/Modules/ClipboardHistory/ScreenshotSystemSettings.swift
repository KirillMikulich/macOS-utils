import Foundation

/// Системные настройки снимков экрана macOS (домен `com.apple.screencapture`) —
/// те же, что в утилите «Снимок экрана» (⌘⇧5 → Параметры).
///
/// - `location` — папка, куда сохраняются снимки;
/// - `show-thumbnail` — плавающая миниатюра в углу после снимка. Пока она видна (~5 с),
///   файл не записывается, поэтому снимок попадает в историю и буфер с задержкой.
///   Без миниатюры файл появляется сразу.
///
/// После изменения процесс снимков перезапускается, чтобы настройки применились сразу.
enum ScreenshotSystemSettings {
    private static let domain = "com.apple.screencapture" as CFString

    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Снимки экрана", isDirectory: true)
    }

    static var location: URL {
        ScreenshotWatcher.screenshotDirectory()
    }

    static var showsThumbnail: Bool {
        get { (CFPreferencesCopyAppValue("show-thumbnail" as CFString, domain) as? Bool) ?? true }
        set { write("show-thumbnail", newValue as CFBoolean) }
    }

    /// Создаёт папку (если её нет) и делает её папкой снимков экрана.
    static func setLocation(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write("location", folder.path as CFString)
    }

    private static func write(_ key: String, _ value: CFPropertyList) {
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
        reloadScreenshotService()
    }

    /// Процесс снимков `screencaptureui` читает настройки при запуске и может жить днями,
    /// поэтому новая папка не применялась бы до перезагрузки. Завершаем его — macOS
    /// запустит его заново при следующем снимке уже с новыми настройками.
    private static func reloadScreenshotService() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["screencaptureui"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
