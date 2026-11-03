import AppKit
import SwiftUI

/// Холст редактора: показывает снимок с пометками и создаёт новые пометки мышью.
final class EditorCanvasView: NSView, NSTextFieldDelegate {
    var document: ScreenshotDocument! {
        didSet { needsDisplay = true }
    }
    /// Сколько точек экрана приходится на пиксель снимка при масштабе 100% (1 / backingScale).
    var pointsPerPixel: CGFloat = 0.5

    private var dragStart: CGPoint?
    /// Идёт перетаскивание выбранной пометки; хранит предыдущую точку.
    private var moveLast: CGPoint?
    private var draft: Annotation?
    private var cropDraft: CGRect?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// Холст сразу получает клавиатуру — буквы выбирают инструменты без щелчка по снимку.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch document?.tool {
        case .text: cursor = .iBeam
        case .move: cursor = .openHand
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Геометрия

    /// Область, где рисуется снимок: вписан в окно, но не крупнее 100%.
    var imageRect: CGRect {
        guard let document else { return .zero }
        let size = CGSize(width: document.pixelSize.width * pointsPerPixel, height: document.pixelSize.height * pointsPerPixel)
        let available = bounds.insetBy(dx: 16, dy: 16)
        let fit = min(1, available.width / max(size.width, 1), available.height / max(size.height, 1))
        let scaled = CGSize(width: size.width * fit, height: size.height * fit)
        return CGRect(x: bounds.midX - scaled.width / 2, y: bounds.midY - scaled.height / 2,
                      width: scaled.width, height: scaled.height).integral
    }

    private var displayScale: CGFloat {
        imageRect.width / max(document.pixelSize.width, 1)
    }

    private func toImage(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: (point.x - rect.minX) / displayScale, y: (point.y - rect.minY) / displayScale)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + point.x * displayScale, y: rect.minY + point.y * displayScale)
    }

    // MARK: - Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        AnnotationRenderer.draw(base: document.image, annotations: document.annotations, draft: draft, in: ctx, scale: displayScale)
        ctx.restoreGState()

        // Рамка вокруг выбранной пометки: её стиль меняется ползунками и цветами сразу.
        if draft == nil, let selected = document.selectedAnnotation {
            let box = AnnotationRenderer.bounds(of: selected)
            let viewBox = CGRect(origin: toView(box.origin), size: CGSize(width: box.width * displayScale, height: box.height * displayScale))
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(viewBox.insetBy(dx: -3, dy: -3))
            ctx.restoreGState()
        }

        if let cropDraft {
            let viewCrop = CGRect(origin: toView(cropDraft.standardized.origin),
                                  size: CGSize(width: cropDraft.standardized.width * displayScale,
                                               height: cropDraft.standardized.height * displayScale))
            ctx.saveGState()
            ctx.addRect(rect)
            ctx.addRect(viewCrop)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(viewCrop)
            ctx.restoreGState()
        }
    }

    // MARK: - Мышь

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let point = toImage(convert(event.locationInWindow, from: nil))
        dragStart = point
        // Перетаскивание пометки: инструментом «Выбор» — любой, другими — уже выбранной.
        let hit = document.hitTest(point)
        let grabsSelected = hit != nil && hit == document.selectedID
        if document.tool == .move || grabsSelected {
            document.select(hit)
            if hit != nil {
                document.beginMove()
                moveLast = point
            }
            dragStart = nil
            needsDisplay = true
            return
        }
        // Текст и нумерация ставятся щелчком — щелчок по существующей пометке выбирает её.
        if document.tool == .text || document.tool == .counter, let hit = document.hitTest(point) {
            document.select(hit)
            dragStart = nil
            needsDisplay = true
            return
        }
        switch document.tool {
        case .text:
            beginText(at: convert(event.locationInWindow, from: nil))
            dragStart = nil
        case .counter:
            document.add(Annotation(kind: .counter(document.nextCounter, point), color: document.color, lineWidth: document.lineWidth))
            dragStart = nil
        case .pen:
            draft = Annotation(kind: .pen([point]), color: document.color, lineWidth: document.lineWidth)
        case .marker:
            draft = Annotation(kind: .marker([point]), color: document.color, lineWidth: document.lineWidth)
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let last = moveLast {
            let point = toImage(convert(event.locationInWindow, from: nil))
            document.moveSelected(dx: point.x - last.x, dy: point.y - last.y)
            moveLast = point
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        var point = toImage(convert(event.locationInWindow, from: nil))
        // ⇧ — ровные линии (по 45°) и квадраты/круги.
        if event.modifierFlags.contains(.shift) { point = constrain(point, from: start) }
        let rect = CGRect(x: start.x, y: start.y, width: point.x - start.x, height: point.y - start.y)
        let color = document.color, width = document.lineWidth
        switch document.tool {
        case .arrow: draft = Annotation(kind: .arrow(start, point), color: color, lineWidth: width)
        case .line: draft = Annotation(kind: .line(start, point), color: color, lineWidth: width)
        case .rectangle: draft = Annotation(kind: .rectangle(rect), color: color, lineWidth: width)
        case .ellipse: draft = Annotation(kind: .ellipse(rect), color: color, lineWidth: width)
        case .pixelate: draft = Annotation(kind: .pixelate(rect), color: color, lineWidth: width)
        case .crop: cropDraft = rect
        case .pen:
            if case .pen(let points) = draft?.kind { draft?.kind = .pen(points + [point]) }
        case .marker:
            if case .marker(let points) = draft?.kind { draft?.kind = .marker(points + [point]) }
        case .text, .counter, .move: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            moveLast = nil
            dragStart = nil
            draft = nil
            cropDraft = nil
            needsDisplay = true
        }
        if document.tool == .crop, let cropDraft {
            document.crop(to: cropDraft)
            return
        }
        guard let draft, isMeaningful(draft) else {
            // Щелчок без перетаскивания — выбор пометки под курсором (или снятие выбора).
            if let start = dragStart, document.tool != .text, document.tool != .counter {
                document.select(document.hitTest(start))
            }
            return
        }
        document.add(draft)
    }

    private func constrain(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        switch document.tool {
        case .rectangle, .ellipse, .pixelate, .crop:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + side * (dx < 0 ? -1 : 1), y: start.y + side * (dy < 0 ? -1 : 1))
        default:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case let .arrow(a, b), let .line(a, b): return hypot(b.x - a.x, b.y - a.y) > 3
        case let .rectangle(r), let .ellipse(r), let .pixelate(r): return abs(r.width) > 3 && abs(r.height) > 3
        case let .pen(points), let .marker(points): return !points.isEmpty
        default: return true
        }
    }

    // MARK: - Текст

    private func beginText(at viewPoint: CGPoint) {
        let fontSize = document.fontSize * displayScale
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - fontSize * 0.6, width: 240, height: fontSize * 1.5))
        field.font = document.textStyle.font(size: fontSize)
        field.textColor = document.color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Текст"
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = toImage(field.frame.origin)
    }

    /// Размер и цвет набираемого текста меняются сразу вместе с ползунком и палитрой.
    func updateActiveTextStyle() {
        guard let field = textField else { return }
        field.font = document.textStyle.font(size: document.fontSize * displayScale)
        field.textColor = document.color
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width + 20, 120)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width + 20, 120)
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        guard !text.isEmpty, let origin = textOrigin else { return }
        document.add(Annotation(kind: .text(text, origin, fontSize: document.fontSize), color: document.color,
                                lineWidth: document.lineWidth, textStyle: document.textStyle))
        needsDisplay = true
    }

    // MARK: - Клавиатура: быстрый выбор инструмента

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        if event.keyCode == 53 { // Esc — снять выбор
            document.select(nil)
            needsDisplay = true
            return
        }
        if flags.isEmpty, let tool = AnnotationTool.allCases.first(where: { $0.keyCode == Int(event.keyCode) }) {
            document.tool = tool
            window?.invalidateCursorRects(for: self)
            return
        }
        super.keyDown(with: event)
    }
}

/// Обёртка для SwiftUI.
struct EditorCanvas: NSViewRepresentable {
    let document: ScreenshotDocument
    let pointsPerPixel: CGFloat

    func makeNSView(context: Context) -> EditorCanvasView {
        let view = EditorCanvasView()
        view.document = document
        view.pointsPerPixel = pointsPerPixel
        return view
    }

    func updateNSView(_ view: EditorCanvasView, context: Context) {
        // Обращение к свойствам подписывает представление на их изменения (Observation).
        _ = document.annotations.count
        _ = document.image
        _ = document.tool
        _ = document.selectedID
        _ = document.fontSize
        _ = document.textStyle
        _ = document.color
        view.updateActiveTextStyle()
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }
}
