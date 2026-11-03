import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ClipboardHistoryModule: AppModule {
    let id = ModuleID.clipboardHistory
    var title: String { L("Буфер обмена") }
    var summary: String { L("История буфера обмена: текст, ссылки, форматированный текст, изображения и файлы.") }
    let systemImage = "list.clipboard"
    let requiredPermissions: [PermissionKind] = []
    var optionalPermissions: [PermissionKind] { settings.selectionAction == .copyAndPaste ? [.accessibility] : [] }

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: ClipboardSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            settingsDidChange(from: oldValue)
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    /// Последнее событие мониторинга — показывается в настройках для прозрачности.
    private(set) var lastEvent: String?

    let store: ClipboardStore
    @ObservationIgnored let thumbnails = ClipboardThumbnailCache()
    @ObservationIgnored let monitor: ClipboardMonitor
    @ObservationIgnored let screenshots = ScreenshotWatcherGroup()
    @ObservationIgnored private lazy var panel = ClipboardPanelController(module: self)

    init(context: ModuleContext, pasteboard: NSPasteboard = .general) {
        self.context = context
        let settings = context.settingsStore.load(ClipboardSettings.self)
        self.settings = settings
        let storage: ClipboardStorage = settings.persistHistory ? FileClipboardStorage() : MemoryClipboardStorage()
        self.store = ClipboardStore(storage: storage,
                                    historyLimit: settings.clampedHistoryLimit,
                                    retentionDays: settings.retentionDays)
        self.monitor = ClipboardMonitor(pasteboard: pasteboard)
        monitor.onChange = { [weak self] in self?.captureCurrentPasteboard() }
        screenshots.onScreenshot = { [weak self] url in self?.captureScreenshotFile(url) }
        declareShortcut(active: false)
    }

    var shortcuts: [ModuleShortcutInfo] {
        [ModuleShortcutInfo(id: .clipboardPanel, title: L("Панель истории буфера"), combo: settings.shortcut)]
    }

    // MARK: - Lifecycle

    func activate() throws {
        monitor.start(interval: settings.clampedPollInterval)
        if settings.captureScreenshotFiles && settings.saveImages {
            screenshots.start()
        } else {
            screenshots.stop()
        }
        declareShortcut(active: true)
        store.enforceLimits()
    }

    func deactivate() {
        monitor.stop()
        screenshots.stop()
        declareShortcut(active: false)
        panel.hide()
        store.flush()
    }

    private func declareShortcut(active: Bool) {
        context.shortcuts.update(.clipboardPanel, title: L("Панель истории буфера"), combo: settings.shortcut,
                                 active: active) { [weak self] in
            self?.panel.toggle()
        }
    }

    private func settingsDidChange(from old: ClipboardSettings) {
        store.historyLimit = settings.clampedHistoryLimit
        store.retentionDays = settings.retentionDays
        if settings.persistHistory != old.persistHistory {
            store.switchStorage(to: settings.persistHistory ? FileClipboardStorage() : MemoryClipboardStorage())
        }
        if settings.isEnabled != old.isEnabled { return } // жизненным циклом управляет setEnabled
        if runState == .running {
            try? activate()
        } else {
            declareShortcut(active: false)
        }
    }

    // MARK: - Захват

    private func captureCurrentPasteboard() {
        if settings.privateMode {
            lastEvent = L("Пропущено: включён режим приватности")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontmost?.bundleIdentifier, settings.excludedBundleIDs.contains(bundleID) {
            lastEvent = L("Пропущено: приложение \(frontmost?.localizedName ?? bundleID) в исключениях")
            return
        }
        switch ClipboardContentReader.read(monitor.pasteboard, options: ClipboardReaderOptions(settings: settings)) {
        case .content(let content):
            let item = store.add(content, sourceBundleID: frontmost?.bundleIdentifier, sourceAppName: frontmost?.localizedName)
            thumbnails.remove(item.id)
            lastEvent = L("Сохранено: \(content.kind.title.lowercased())")
        case .empty:
            lastEvent = L("Буфер пуст")
        case .skipped(let reason):
            lastEvent = Self.describe(reason)
            Log.clipboard.info("Skipped clipboard change: \(reason.rawValue, privacy: .public)")
        }
    }

    /// Снимок экрана, сохранённый в файл: в историю попадает само изображение
    /// (а не ссылка на файл), поэтому его можно вставить, даже если файл потом удалить.
    private func captureScreenshotFile(_ url: URL) {
        guard !settings.privateMode, settings.saveImages else { return }
        guard let data = try? Data(contentsOf: url) else {
            lastEvent = L("Не удалось прочитать снимок экрана")
            return
        }
        guard data.count <= settings.maxItemBytes else {
            lastEvent = Self.describe(.tooLarge)
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.png.identifier
        guard let content = ClipboardContentReader.analyze(items: [
            CapturedPasteboardItem(representations: [ClipboardRepresentation(type: type, data: data)]),
        ]) else { return }
        let item = store.add(content, sourceBundleID: "com.apple.screencaptureui", sourceAppName: L("Снимок экрана"))
        thumbnails.remove(item.id)
        if settings.copyScreenshotsToClipboard {
            // Изображение (а не ссылка на файл) — так ⌘V вставляет картинку в чаты, документы и редакторы.
            restore(item, paste: false)
            lastEvent = L("Снимок экрана скопирован в буфер: \(url.lastPathComponent)")
        } else {
            lastEvent = L("Сохранён снимок экрана: \(url.lastPathComponent)")
        }
    }

    private static func describe(_ reason: ClipboardSkipReason) -> String {
        switch reason {
        case .concealed: return L("Пропущено: данные помечены приложением как секретные")
        case .transient: return L("Пропущено: временные данные")
        case .tooLarge: return L("Пропущено: размер превышает лимит")
        case .imagesDisabled: return L("Пропущено: сохранение изображений выключено")
        case .unsupported: return L("Пропущено: неподдерживаемый формат")
        }
    }

    // MARK: - Действия

    /// Помещает элемент в системный буфер. Если `paste` — дополнительно отправляет ⌘V
    /// в активное приложение (только с разрешением Accessibility).
    @discardableResult
    func restore(_ item: ClipboardItem, paste: Bool, into target: NSRunningApplication? = nil) -> Bool {
        guard let content = store.content(for: item) else {
            lastEvent = L("Данные элемента недоступны")
            NSSound.beep()
            return false
        }
        let changeCount = ClipboardContentWriter.write(content, to: monitor.pasteboard)
        monitor.ignoreChange(upTo: changeCount)
        store.touch(item.id)

        if paste {
            guard AXIsProcessTrusted() else {
                lastEvent = L("Автовставка недоступна: нет разрешения Accessibility. Элемент скопирован — нажмите ⌘V.")
                context.permissions.request(.accessibility)
                return true
            }
            // ⌘V отправляется только когда целевое приложение действительно стало активным
            // (иначе нажатие ушло бы не туда). Ждём до 1 с.
            Self.waitUntilFrontmost(target, deadline: Date().addingTimeInterval(1.0)) {
                Self.postCommandV()
            }
        }
        return true
    }

    private static func waitUntilFrontmost(_ target: NSRunningApplication?, deadline: Date, then action: @escaping @Sendable () -> Void) {
        let isReady = target == nil
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier
        if isReady || Date() >= deadline {
            // Небольшая пауза, чтобы окно приложения успело стать key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitUntilFrontmost(target, deadline: deadline, then: action)
        }
    }

    private nonisolated static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    func delete(_ item: ClipboardItem) {
        store.delete(item.id)
        thumbnails.remove(item.id)
    }

    func clearHistory(includingPinned: Bool) {
        Log.clipboard.notice("Clipboard history cleared by user (\(self.store.items.count) items)")
        store.clear(includingPinned: includingPinned)
        thumbnails.removeAll()
    }

    /// Папка снимков изменилась — начинаем следить за новой.
    func restartScreenshotWatcher() {
        screenshots.stop()
        if runState == .running, settings.captureScreenshotFiles, settings.saveImages {
            screenshots.start()
        }
    }

    func showPanel() {
        panel.show()
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(ClipboardSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(ClipboardQuickSettingsView(module: self))
    }
}
