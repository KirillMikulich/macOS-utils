import AppKit
import Observation
import UniformTypeIdentifiers

/// Состояние редактора одного снимка.
@MainActor
@Observable
final class ScreenshotDocument {
    private(set) var image: CGImage
    private(set) var annotations: [Annotation] = []
    var tool: AnnotationTool = .arrow
    /// Цвет, толщина и размер шрифта применяются к новым пометкам и сразу же —
    /// к выбранной пометке (только что нарисованной или выбранной щелчком).
    var color: NSColor = .systemRed {
        didSet { if color != oldValue { restyleSelected() } }
    }
    var lineWidth: CGFloat = 4 {
        didSet { if lineWidth != oldValue { restyleSelected() } }
    }
    var fontSize: CGFloat = 24 {
        didSet { if fontSize != oldValue { restyleSelected() } }
    }
    var textStyle = TextStyle() {
        didSet { if textStyle != oldValue { restyleSelected() } }
    }
    private(set) var selectedID: UUID?
    /// Серия изменений стиля одной пометки откатывается одним ⌘Z.
    private var restyleCheckpointTaken = false
    /// Следующий номер для инструмента «Нумерация».
    var nextCounter = 1

    private var undoStack: [(CGImage, [Annotation], Int)] = []
    private var redoStack: [(CGImage, [Annotation], Int)] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    init(image: CGImage) {
        self.image = image
    }

    private func checkpoint() {
        undoStack.append((image, annotations, nextCounter))
        redoStack.removeAll()
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
        selectedID = annotation.id
        restyleCheckpointTaken = false
        if case .counter = annotation.kind { nextCounter += 1 }
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        restyleCheckpointTaken = false
        redoStack.append((image, annotations, nextCounter))
        (image, annotations, nextCounter) = state
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        restyleCheckpointTaken = false
        undoStack.append((image, annotations, nextCounter))
        (image, annotations, nextCounter) = state
    }

    // MARK: - Выбор и изменение стиля

    var selectedAnnotation: Annotation? {
        annotations.first { $0.id == selectedID }
    }

    var selectedIsText: Bool {
        if case .text = selectedAnnotation?.kind { return true }
        return false
    }

    /// Выбирает пометку и подставляет её стиль в панель (без изменения самой пометки).
    func select(_ id: UUID?) {
        selectedID = id
        restyleCheckpointTaken = false
        guard let annotation = selectedAnnotation else { return }
        let previous = selectedID
        selectedID = nil // не перекрашивать пометку, пока панель принимает её значения
        color = annotation.color
        lineWidth = annotation.lineWidth
        if case let .text(_, _, size) = annotation.kind {
            fontSize = size
            textStyle = annotation.textStyle
        }
        selectedID = previous
    }

    /// Начало перетаскивания выбранной пометки — одна точка отмены на всё перемещение.
    func beginMove() {
        checkpoint()
        restyleCheckpointTaken = true
    }

    func moveSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].translate(dx: dx, dy: dy)
    }

    private func restyleSelected() {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if !restyleCheckpointTaken {
            checkpoint()
            restyleCheckpointTaken = true
        }
        annotations[index].color = color
        annotations[index].lineWidth = lineWidth
        if case let .text(string, origin, _) = annotations[index].kind {
            annotations[index].kind = .text(string, origin, fontSize: fontSize)
            annotations[index].textStyle = textStyle
        }
    }

    /// Пометка под точкой (в пикселях изображения), сверху вниз.
    func hitTest(_ point: CGPoint) -> UUID? {
        annotations.reversed().first { annotation in
            AnnotationRenderer.bounds(of: annotation).insetBy(dx: -8, dy: -8).contains(point)
                && AnnotationRenderer.distance(from: point, to: annotation) <= annotation.lineWidth / 2 + 8
        }?.id
    }

    /// Итоговое изображение с пометками.
    func rendered() -> CGImage {
        AnnotationRenderer.flatten(base: image, annotations: annotations) ?? image
    }

    /// Обрезка: пометки «впекаются» в изображение, затем оно обрезается.
    /// `rect` — в пикселях изображения, начало в левом нижнем углу.
    func crop(to rect: CGRect) {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let area = rect.standardized.integral.intersection(bounds)
        guard area.width >= 4, area.height >= 4 else { return }
        let flat = rendered()
        // CGImage.cropping считает от левого верхнего угла.
        let topLeft = CGRect(x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)
        guard let cropped = flat.cropping(to: topLeft) else { return }
        checkpoint()
        image = cropped
        annotations = []
    }

    /// Изменение размера с сохранением пропорций.
    func resize(scale: CGFloat) {
        guard scale > 0, scale != 1 else { return }
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let flat = rendered()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = ctx.makeImage() else { return }
        checkpoint()
        image = resized
        annotations = []
    }

    // MARK: - Экспорт

    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: rendered()).representation(using: .png, properties: [:])
    }

    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let png = pngData() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        // TIFF — для старых приложений, которые не понимают PNG из буфера.
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return pasteboard.writeObjects([item])
    }

    func save(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = L("yyyy-MM-dd 'в' HH.mm.ss")
        var url = folder.appendingPathComponent(L("Снимок Mac Utilities \(formatter.string(from: Date())).png"))
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(L("Снимок Mac Utilities \(formatter.string(from: Date())) (\(index)).png"))
            index += 1
        }
        try save(to: url)
        return url
    }

    func save(to url: URL) throws {
        guard let png = pngData() else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
