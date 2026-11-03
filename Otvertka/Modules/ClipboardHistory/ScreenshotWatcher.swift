import Foundation
import UniformTypeIdentifiers

/// Следит за папкой, куда macOS сохраняет снимки экрана (⌘⇧3, ⌘⇧4, ⌘⇧5), и сообщает
/// о новых снимках, чтобы они появлялись в истории, даже если не копировались в буфер.
///
/// - Папка берётся из настройки `com.apple.screencapture location` (по умолчанию — Рабочий стол).
/// - Снимок отличается от любой другой картинки по атрибуту
///   `com.apple.metadata:kMDItemIsScreenCapture`, который ставит сама macOS.
/// - Используется kqueue-источник на каталог (DispatchSource): он срабатывает только при
///   изменении содержимого папки, постоянного опроса нет.
/// - Доступ к Рабочему столу защищён macOS: при первом запуске система спросит разрешение.
@MainActor
final class ScreenshotWatcher {
    var onScreenshot: ((URL) -> Void)?
    private(set) var directory: URL?
    private(set) var lastError: String?

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var startDate = Date()
    private var scanScheduled = false

    var isRunning: Bool { source != nil }

    /// `directory` задаётся в тестах; по умолчанию — папка снимков из настроек macOS.
    func start(directory overrideDirectory: URL? = nil) {
        guard source == nil, !isStarting else { return }
        let directory = overrideDirectory ?? Self.screenshotDirectory()
        self.directory = directory
        startDate = Date()
        isStarting = true
        generation += 1
        let generation = generation

        // Первое обращение к Рабочему столу может вызвать системный запрос доступа, и
        // open() ждёт ответа пользователя — поэтому папка открывается не на главном потоке.
        DispatchQueue.global(qos: .utility).async {
            let descriptor = open(directory.path, O_EVTONLY)
            let existing = descriptor >= 0
                ? Set(((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                    .map(Self.identity(of:)))
                : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishStart(directory: directory, descriptor: descriptor, existing: existing, generation: generation)
                }
            }
        }
    }

    private var isStarting = false
    private var generation = 0

    private func finishStart(directory: URL, descriptor: Int32, existing: Set<String>, generation: Int) {
        isStarting = false
        // stop() вызван, пока папка открывалась, — запуск отменён.
        guard generation == self.generation else {
            if descriptor >= 0 { close(descriptor) }
            return
        }
        guard descriptor >= 0 else {
            lastError = "Нет доступа к папке снимков: \(directory.path)"
            Log.clipboard.error("Screenshot watcher: cannot open \(directory.path, privacy: .public)")
            return
        }
        // Уже существующие файлы не добавляем — только новые снимки.
        known = existing

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        lastError = nil
        Log.clipboard.info("Screenshot watcher started for \(directory.path, privacy: .public)")
    }

    func stop() {
        generation += 1
        isStarting = false
        source?.cancel()
        source = nil
    }

    /// macOS сначала пишет скрытый временный файл, затем переименовывает его —
    /// небольшая задержка гарантирует, что файл записан полностью.
    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.scanScheduled = false
                self?.scan()
            }
        }
    }

    private func scan() {
        guard let directory else { return }
        for url in listFiles(in: directory) {
            // Имя + дата создания: файл, перезаписанный под тем же именем, считается новым.
            let identity = Self.identity(of: url)
            guard known.insert(identity).inserted else { continue }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentTypeKey])
            guard let created = values?.creationDate, created >= startDate.addingTimeInterval(-2),
                  values?.contentType?.conforms(to: .image) == true,
                  Self.isScreenshot(url) else { continue }
            onScreenshot?(url)
        }
    }

    nonisolated static func identity(of url: URL) -> String {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent)|\(created)"
    }

    private func listFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.creationDateKey, .contentTypeKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    nonisolated static func screenshotDirectory() -> URL {
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }
}

/// Следит сразу за несколькими папками, куда macOS может сохранять снимки.
///
/// Зачем: начиная с macOS 26 папка, выбранная в «Снимок экрана» (⌘⇧5 → Параметры),
/// хранится в защищённом контейнере утилиты и недоступна другим приложениям, а старая
/// настройка `com.apple.screencapture location` может с ней не совпадать. Поэтому
/// отслеживаются все типичные места: папка из старой настройки, Рабочий стол и
/// «Документы/Снимки экрана». Лишние файлы не попадают в историю — снимок распознаётся
/// по системной пометке `kMDItemIsScreenCapture`.
@MainActor
final class ScreenshotWatcherGroup {
    var onScreenshot: ((URL) -> Void)?
    private var watchers: [ScreenshotWatcher] = []

    var lastError: String? { watchers.compactMap(\.lastError).first }
    var directories: [URL] { watchers.compactMap(\.directory) }

    nonisolated static func candidateDirectories() -> [URL] {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        var seen = Set<String>()
        return [ScreenshotWatcher.screenshotDirectory(), desktop, ScreenshotSystemSettings.defaultFolder].filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    func start() {
        stop()
        watchers = Self.candidateDirectories().map { directory in
            let watcher = ScreenshotWatcher()
            watcher.onScreenshot = { [weak self] url in self?.onScreenshot?(url) }
            watcher.start(directory: directory)
            return watcher
        }
    }

    func stop() {
        watchers.forEach { $0.stop() }
        watchers = []
    }
}
