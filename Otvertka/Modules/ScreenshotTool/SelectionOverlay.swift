import AppKit
import Carbon.HIToolbox

/// Полноэкранное окно выделения области: показывает «замороженный» снимок экрана,
/// затемняет всё вокруг выделения и подписывает размер в пикселях.
@MainActor
final class SelectionOverlayController {
    private var window: SelectionWindow?
    private var completion: ((CGImage?) -> Void)?

    /// `image` — снимок всего экрана в пикселях; результат — вырезанная область или nil (отмена).
    func begin(image: CGImage, screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        self.completion = completion
        let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        view.onFinish = { [weak self] rect in self?.finish(rect) }
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.crosshair.push()
        self.window = window
    }

    private func finish(_ selection: CGRect?) {
        NSCursor.pop()
        guard let view = window?.contentView as? SelectionView else { return }
        let result = selection.flatMap { view.crop($0) }
        let completion = completion
        self.completion = nil
        // Сначала результат (редактор открывается и становится key), затем убираем окно выделения.
        // В обратном порядке macOS успевала вернуть фокус предыдущему приложению, а забрать его
        // обратно фоновому приложению в macOS 14+ не разрешается.
        completion?(result)
        window?.orderOut(nil)
        window = nil
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    private let image: CGImage
    private var start: CGPoint?
    private var selection: CGRect?
    var onFinish: ((CGRect?) -> Void)?

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pixelScale: CGFloat { CGFloat(image.width) / max(bounds.width, 1) }

    /// Вырезает область (координаты вида, начало внизу слева) из снимка.
    func crop(_ rect: CGRect) -> CGImage? {
        let scale = pixelScale
        let pixelRect = CGRect(x: rect.minX * scale, y: (bounds.height - rect.maxY) * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        return image.cropping(to: pixelRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)
        ctx.saveGState()
        ctx.addRect(bounds)
        if let selection { ctx.addRect(selection) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        guard let selection else {
            drawHint("Выделите область · ↩ — весь экран · Esc — отмена", at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(selection.insetBy(dx: 0.5, dy: 0.5))
        let scale = pixelScale
        let label = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        let labelPoint = CGPoint(x: selection.minX + 40, y: selection.maxY + 14 < bounds.maxY ? selection.maxY + 14 : selection.maxY - 14)
        drawHint(label, at: labelPoint)
    }

    private func drawHint(_ text: String, at center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: center.x - size.width / 2 - 6, y: center.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            selection = nil
            needsDisplay = true
            return
        }
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: onFinish?(nil)
        case kVK_Return, kVK_ANSI_KeypadEnter: onFinish?(selection ?? bounds)
        default: super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }
}

/// Невидимый «щит» на всех экранах на время подготовки снимка (0,2–0,5 с):
/// без него щелчки и перетаскивание, начатые сразу после горячей клавиши,
/// попадали в приложение под курсором. Окно прозрачное, поэтому в снимок не попадает.
@MainActor
final class ClickShield {
    private var windows: [NSWindow] = []

    func show() {
        hide()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            // Явное false: окно ловит события даже в полностью прозрачных областях.
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = ShieldView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class ShieldView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    // События мыши поглощаются (пустые обработчики).
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}
