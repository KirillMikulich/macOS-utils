import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Окно редактора снимка.
@MainActor
final class ScreenshotEditorController: NSObject, NSWindowDelegate, ObservableObject {
    let document: ScreenshotDocument
    private let window: NSWindow
    private unowned let module: ScreenshotToolModule
    var onClose: (() -> Void)?

    init(image: CGImage, pointsPerPixel: CGFloat, module: ScreenshotToolModule) {
        self.module = module
        document = ScreenshotDocument(image: image)
        document.color = module.settings.lastColor.nsColor
        document.lineWidth = module.settings.lastLineWidth

        let screen = NSScreen.withMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let imageSize = CGSize(width: CGFloat(image.width) * pointsPerPixel, height: CGFloat(image.height) * pointsPerPixel)
        let size = NSSize(width: min(max(imageSize.width + 40, 760), visible.width * 0.9),
                          height: min(max(imageSize.height + 110, 420), visible.height * 0.9))

        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Снимок — \(image.width)×\(image.height)"
        window.contentMinSize = NSSize(width: 620, height: 360)
        super.init()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ScreenshotEditorView(controller: self, pointsPerPixel: pointsPerPixel))
        window.setContentSize(size)
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        module.rememberStyle(color: document.color, lineWidth: document.lineWidth)
        onClose?()
    }

    // MARK: - Действия

    @Published var status: String?

    func copy() {
        guard document.copyToPasteboard() else { return }
        if module.settings.closeEditorAfterCopy {
            close()
        } else {
            status = "Скопировано в буфер"
        }
    }

    func save() {
        do {
            let url = try document.save(in: module.saveFolder)
            status = "Сохранено: \(url.lastPathComponent)"
            lastSavedURL = url
        } catch {
            status = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = module.saveFolder
        panel.nameFieldStringValue = "Снимок.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.document.save(to: url)
                self.status = "Сохранено: \(url.lastPathComponent)"
                self.lastSavedURL = url
            } catch {
                self.status = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }

    @Published var lastSavedURL: URL?

    func updateTitle() {
        window.title = "Снимок — \(document.image.width)×\(document.image.height)"
    }
}


struct ScreenshotEditorView: View {
    @ObservedObject var controller: ScreenshotEditorController
    let pointsPerPixel: CGFloat
    @State private var customWidth = ""
    @State private var showResize = false

    private var document: ScreenshotDocument { controller.document }

    var body: some View {
        @Bindable var document = controller.document
        VStack(spacing: 0) {
            toolbar(document: document)
            Divider()
            EditorCanvas(document: document, pointsPerPixel: pointsPerPixel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .onChange(of: document.pixelSize) { _, _ in controller.updateTitle() }
    }

    private func toolbar(document: ScreenshotDocument) -> some View {
        @Bindable var document = document
        return VStack(spacing: 6) {
            // Строка 1: инструменты и отмена.
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button { document.tool = tool } label: {
                        Image(systemName: tool.systemImage)
                            .frame(width: 28, height: 24)
                            .background(document.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                }
                Spacer(minLength: 8)
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!document.canUndo)
                    .help("Отменить (⌘Z)")
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!document.canRedo)
                    .help("Повторить (⇧⌘Z)")
                Menu {
                    ForEach([25, 50, 75], id: \.self) { percent in
                        Button("\(percent)%") { document.resize(scale: CGFloat(percent) / 100) }
                    }
                    Divider()
                    Button("Задать ширину…") { showResize = true }
                } label: {
                    Image(systemName: "aspectratio")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Изменить размер изображения")
            }

            // Строка 2: стиль и действия.
            HStack(spacing: 12) {
                ColorSwatchButton(color: $document.color)

                HStack(spacing: 4) {
                    Image(systemName: "lineweight").foregroundStyle(.secondary)
                    Slider(value: $document.lineWidth, in: 1...30).frame(minWidth: 70, maxWidth: 110)
                    NumberField(value: $document.lineWidth, range: 1...30, width: 38)
                }
                .help("Толщина стрелок, линий и фигур — меняет и выбранную пометку")

                HStack(spacing: 4) {
                    Image(systemName: "textformat.size").foregroundStyle(.secondary)
                    Slider(value: $document.fontSize, in: 8...160).frame(minWidth: 70, maxWidth: 110)
                    NumberField(value: $document.fontSize, range: 8...160, width: 44)
                }
                .help("Размер текста — меняет и выбранный или набираемый текст")

                Spacer(minLength: 8)

                Button("Сохранить как…") { controller.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Сохранить") { controller.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Копировать") { controller.copy() }
                    .keyboardShortcut("c", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }

            // Строка 3 (только для текста): шрифт, начертание, курсив, контур, подложка.
            if document.tool == .text || document.selectedIsText {
                HStack {
                    TextStyleControls(style: $document.textStyle)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .popover(isPresented: $showResize) {
            HStack {
                TextField("Ширина, px", text: $customWidth).frame(width: 110)
                Button("Применить") {
                    if let width = Double(customWidth), width > 0 {
                        document.resize(scale: width / Double(document.pixelSize.width))
                    }
                    showResize = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(Int(document.pixelSize.width))×\(Int(document.pixelSize.height)) px")
                .monospacedDigit()
            Text("· щелчок по пометке — выбрать и изменить · ⇧ — ровные линии · буквы — инструменты")
            Spacer()
            if let status = controller.status {
                Text(status)
                if let url = controller.lastSavedURL {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Кнопка текущего цвета: по нажатию — палитра частых цветов и выбор любого другого.
private struct ColorSwatchButton: View {
    @Binding var color: NSColor
    @State private var isPresented = false

    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal,
        .systemBlue, .systemIndigo, .systemPurple, .systemPink, .black, .white,
    ]

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5)))
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Цвет")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Self.palette, id: \.self) { swatch in
                        Button {
                            color = swatch
                            isPresented = false
                        } label: {
                            Circle()
                                .fill(Color(nsColor: swatch))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(swatch == color ? Color.accentColor : Color.secondary.opacity(0.4),
                                                               lineWidth: swatch == color ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("Другой цвет…", selection: Binding(get: { Color(nsColor: color) }, set: { color = NSColor($0) }))
            }
            .padding(12)
        }
    }
}

/// Шрифт, начертание, курсив, контур и подложка текста.
private struct TextStyleControls: View {
    @Binding var style: TextStyle

    var body: some View {
        HStack(spacing: 6) {
            FontFamilyButton(family: $style.fontFamily)

            Picker("", selection: $style.weight) {
                ForEach(TextStyle.Weight.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .help("Начертание")

            Toggle(isOn: $style.italic) { Image(systemName: "italic") }
                .toggleStyle(.button)
                .help("Курсив")
            Toggle(isOn: $style.outline) { Image(systemName: "character.textbox") }
                .toggleStyle(.button)
                .help("Контур вокруг букв")
            Toggle(isOn: $style.background) { Image(systemName: "rectangle.fill") }
                .toggleStyle(.button)
                .help("Подложка под текстом")
        }
    }
}

/// Выбор шрифта: окно с поиском, каждый шрифт показан собственным начертанием.
private struct FontFamilyButton: View {
    @Binding var family: String?
    @State private var isPresented = false
    @State private var query = ""

    private static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Self.families }
        return Self.families.filter { $0.localizedStandardContains(trimmed) }
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 4) {
                Text(family ?? "Системный")
                    .font(family.map { Font.custom($0, size: 13) } ?? .system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Шрифт")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Поиск шрифта", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            row(title: "Системный", font: .system(size: 15), selected: family == nil) { family = nil }
                        }
                        ForEach(filtered, id: \.self) { name in
                            row(title: name, font: .custom(name, size: 15), selected: family == name) { family = name }
                        }
                        if filtered.isEmpty {
                            Text("Ничего не найдено").foregroundStyle(.secondary).padding(12)
                        }
                    }
                }
            }
            .frame(width: 280, height: 380)
        }
    }

    private func row(title: String, font: Font, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            isPresented = false
        } label: {
            HStack {
                Text(title).font(font).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
