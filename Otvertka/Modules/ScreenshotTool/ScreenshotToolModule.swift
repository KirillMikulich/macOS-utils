import AppKit
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit
import SwiftUI

struct CodableColor: Codable, Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemRed
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent; alpha = rgb.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

enum ScreenshotAfterCapture: String, Codable, CaseIterable, Identifiable {
    case openEditor, copyToClipboard, copyAndSave

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openEditor: return "Открыть редактор"
        case .copyToClipboard: return "Сразу скопировать в буфер"
        case .copyAndSave: return "Скопировать в буфер и сохранить в папку"
        }
    }
}

struct ScreenshotToolSettings: PersistedSettings {
    static let storageKey = "screenshotTool"
    static let schemaVersion = 1
    static let defaultValue = ScreenshotToolSettings()

    /// По умолчанию выключен: нужен доступ «Запись экрана», он запрашивается при включении.
    var isEnabled = false
    var shortcut: KeyCombo? = KeyCombo(keyCode: kVK_ANSI_S, modifiers: [.option, .shift])
    var afterCapture: ScreenshotAfterCapture = .openEditor
    var closeEditorAfterCopy = true
    /// nil — «Документы/Снимки экрана».
    var saveFolderPath: String?
    var lastColor = CodableColor(.systemRed)
    var lastLineWidth = 4.0
}

/// Снимок области экрана с редактором (текст, стрелки, фигуры, маркер, размытие, нумерация,
/// обрезка, изменение размера), как Lightshot / ShareX. Работает локально, без загрузки в сеть.
@MainActor
@Observable
final class ScreenshotToolModule: AppModule {
    let id = ModuleID.screenshotTool
    let title = "Снимок экрана"
    let summary = "Снимок области экрана с редактором: текст, стрелки, фигуры, маркер, размытие, обрезка."
    let systemImage = "camera.viewfinder"
    let requiredPermissions: [PermissionKind] = [.screenRecording]

    let context: ModuleContext
    var runState: ModuleRunState = .disabled

    var settings: ScreenshotToolSettings {
        didSet {
            guard settings != oldValue else { return }
            context.settingsStore.save(settings)
            if settings.isEnabled == oldValue.isEnabled { declareShortcut(active: runState == .running) }
        }
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    private(set) var lastError: String?

    @ObservationIgnored private let overlay = SelectionOverlayController()
    @ObservationIgnored private let shield = ClickShield()
    @ObservationIgnored private var editors: [ScreenshotEditorController] = []
    @ObservationIgnored private var isCapturing = false

    init(context: ModuleContext) {
        self.context = context
        self.settings = context.settingsStore.load(ScreenshotToolSettings.self)
        declareShortcut(active: false)
    }

    var shortcuts: [ModuleShortcutInfo] {
        [ModuleShortcutInfo(id: .screenshotCapture, title: "Снимок области", combo: settings.shortcut)]
    }

    var saveFolder: URL {
        settings.saveFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ScreenshotSystemSettings.defaultFolder
    }

    func activate() throws {
        declareShortcut(active: true)
    }

    func deactivate() {
        declareShortcut(active: false)
    }

    private func declareShortcut(active: Bool) {
        context.shortcuts.update(.screenshotCapture, title: "Снимок экрана: снимок области", combo: settings.shortcut, active: active) { [weak self] in
            self?.startCapture()
        }
    }

    func rememberStyle(color: NSColor, lineWidth: CGFloat) {
        settings.lastColor = CodableColor(color)
        settings.lastLineWidth = lineWidth
    }

    // MARK: - Захват

    func startCapture() {
        guard !isCapturing else { return }
        guard context.permissions.isGranted(.screenRecording) || CGPreflightScreenCaptureAccess() else {
            lastError = "Нет разрешения «Запись экрана»"
            context.permissions.request(.screenRecording)
            return
        }
        isCapturing = true
        // Панели Mac Utilities (например, история буфера) не закрываются до снимка — они должны в него попасть.
        // Сразу перехватываем мышь, пока готовится снимок.
        shield.show()
        let previousApp = NSWorkspace.shared.frontmostApplication
        Task {
            defer {
                isCapturing = false
                shield.hide()
            }
            guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
            do {
                let image = try await Self.captureScreen(screen)
                lastError = nil
                // Снимок готов — теперь убираем открытые панели Mac Utilities, чтобы они не мешали выделению.
                context.overlays.willShow("screenshot")
                // Модуль живёт всё время работы приложения — сильная ссылка безопасна.
                overlay.begin(image: image, screen: screen) { cropped in
                    guard let cropped else {
                        // Отмена — возвращаем фокус туда, где пользователь работал.
                        previousApp?.activate()
                        return
                    }
                    self.handleCaptured(cropped, pointsPerPixel: 1 / screen.backingScaleFactor, previousApp: previousApp)
                }
            } catch {
                lastError = "Не удалось сделать снимок: \(error.localizedDescription)"
                Log.app.error("Screenshot capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleCaptured(_ image: CGImage, pointsPerPixel: CGFloat, previousApp: NSRunningApplication?) {
        switch settings.afterCapture {
        case .openEditor:
            let editor = ScreenshotEditorController(image: image, pointsPerPixel: pointsPerPixel, module: self)
            editor.onClose = { [weak self, weak editor] in
                self?.editors.removeAll { $0 === editor }
                if self?.editors.isEmpty == true { previousApp?.activate() }
            }
            editors.append(editor)
            editor.show()
        case .copyToClipboard, .copyAndSave:
            let document = ScreenshotDocument(image: image)
            document.copyToPasteboard()
            if settings.afterCapture == .copyAndSave {
                do { _ = try document.save(in: saveFolder) } catch { lastError = error.localizedDescription }
            }
            previousApp?.activate()
        }
    }

    /// Снимок всего экрана в полном разрешении (всё, что видно на экране).
    private static func captureScreen(_ screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ModuleError.startFailed("Не удалось определить экран")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ModuleError.startFailed("Экран не найден")
        }
        // В снимок попадает всё, что видно на экране, включая окна Mac Utilities (редактор,
        // настройки) — иначе на их месте оказывалось то, что под ними. Плавающие панели
        // Mac Utilities к моменту снимка уже закрыты.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    // MARK: - UI

    func makeSettingsView() -> AnyView {
        AnyView(ScreenshotToolSettingsView(module: self))
    }

    func makeQuickSettingsView() -> AnyView {
        AnyView(ScreenshotToolQuickView(module: self))
    }
}

struct ScreenshotToolSettingsView: View {
    @Bindable var module: ScreenshotToolModule

    var body: some View {
        let permissions = module.context.permissions
        Form {
            Section("Основное") {
                Toggle("Включить «Снимок экрана»", isOn: Binding(get: { module.isEnabled }, set: { module.setEnabled($0) }))
                if module.isEnabled && !permissions.isGranted(.screenRecording) {
                    PermissionBanner(kind: .screenRecording, permissions: permissions)
                }
                LabeledContent("Снимок области") {
                    ShortcutRecorder(id: .screenshotCapture, combo: $module.settings.shortcut,
                                     defaultCombo: ScreenshotToolSettings.defaultValue.shortcut, manager: module.context.shortcuts)
                }
                Button("Сделать снимок сейчас") { module.startCapture() }
                    .disabled(module.runState != .running)
                if let error = module.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                SettingsCaption(text: "Выделите область мышью (↩ — весь экран, Esc — отмена). Снимается экран, на котором курсор. Снимки не загружаются в интернет.")
            }
            Section("После выделения") {
                Picker("Действие", selection: $module.settings.afterCapture) {
                    ForEach(ScreenshotAfterCapture.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Закрывать редактор после «Копировать» (⌘C)", isOn: $module.settings.closeEditorAfterCopy)
                LabeledContent("Папка для сохранения") {
                    HStack {
                        Text(module.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Изменить…", action: chooseFolder)
                    }
                }
            }
            Section("Редактор") {
                SettingsCaption(text: "Инструменты (клавиши): выбор и перемещение V, стрелка A, прямоугольник R, овал O, линия L, карандаш P, маркер M, текст T, размытие B, нумерация N, обрезка C. ⇧ при рисовании — ровные линии и квадраты. ⌘Z / ⇧⌘Z — отмена и повтор, ⌘C — копировать, ⌘S — сохранить, ⇧⌘S — сохранить как. Размер изображения меняется кнопкой со стрелками.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = module.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        module.settings.saveFolderPath = url.path
    }
}

struct ScreenshotToolQuickView: View {
    @Bindable var module: ScreenshotToolModule

    var body: some View {
        Picker("После выделения", selection: $module.settings.afterCapture) {
            ForEach(ScreenshotAfterCapture.allCases) { Text($0.title).tag($0) }
        }
    }
}
