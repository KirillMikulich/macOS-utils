import AppKit
import Carbon.HIToolbox
import CoreImage
import CoreImage.CIFilterBuiltins

enum AnnotationTool: String, CaseIterable, Identifiable {
    case move, arrow, rectangle, ellipse, line, pen, marker, text, pixelate, counter, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return L("Выбор и перемещение")
        case .arrow: return L("Стрелка")
        case .rectangle: return L("Прямоугольник")
        case .ellipse: return L("Овал")
        case .line: return L("Линия")
        case .pen: return L("Карандаш")
        case .marker: return L("Маркер")
        case .text: return L("Текст")
        case .pixelate: return L("Размытие (пикселизация)")
        case .counter: return L("Нумерация")
        case .crop: return L("Обрезка")
        }
    }

    var systemImage: String {
        switch self {
        case .move: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "pencil"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "mosaic"
        case .counter: return "1.circle"
        case .crop: return "crop"
        }
    }

    /// Физическая клавиша (не зависит от раскладки: при русской T даёт «е»).
    var keyCode: Int {
        switch self {
        case .move: return kVK_ANSI_V
        case .arrow: return kVK_ANSI_A
        case .rectangle: return kVK_ANSI_R
        case .ellipse: return kVK_ANSI_O
        case .line: return kVK_ANSI_L
        case .pen: return kVK_ANSI_P
        case .marker: return kVK_ANSI_M
        case .text: return kVK_ANSI_T
        case .pixelate: return kVK_ANSI_B
        case .counter: return kVK_ANSI_N
        case .crop: return kVK_ANSI_C
        }
    }

    var shortcut: Character {
        switch self {
        case .move: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .pen: return "p"
        case .marker: return "m"
        case .text: return "t"
        case .pixelate: return "b"
        case .counter: return "n"
        case .crop: return "c"
        }
    }
}

/// Оформление текста на снимке.
struct TextStyle: Equatable {
    enum Weight: String, CaseIterable, Identifiable {
        case regular, medium, semibold, bold, heavy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .regular: return L("Обычный")
            case .medium: return L("Средний")
            case .semibold: return L("Полужирный")
            case .bold: return L("Жирный")
            case .heavy: return L("Очень жирный")
            }
        }
        var systemWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            }
        }
        /// Шкала NSFontManager (0…15).
        var managerWeight: Int {
            switch self {
            case .regular: return 5
            case .medium: return 6
            case .semibold: return 8
            case .bold: return 9
            case .heavy: return 11
            }
        }
    }

    /// nil — системный шрифт.
    var fontFamily: String?
    var weight: Weight = .semibold
    var italic = false
    /// Контур вокруг букв — текст читается на любом фоне.
    var outline = true
    /// Полупрозрачная плашка под текстом.
    var background = false

    func font(size: CGFloat) -> NSFont {
        var font: NSFont
        if let family = fontFamily,
           let custom = NSFontManager.shared.font(withFamily: family, traits: italic ? .italicFontMask : [],
                                                   weight: weight.managerWeight, size: size) {
            font = custom
        } else {
            font = .systemFont(ofSize: size, weight: weight.systemWeight)
        }
        if italic && !font.fontDescriptor.symbolicTraits.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

/// Пометка на снимке. Координаты — в пикселях изображения, начало в левом нижнем углу.
struct Annotation: Identifiable {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case marker([CGPoint])
        case text(String, CGPoint, fontSize: CGFloat)
        case pixelate(CGRect)
        case counter(Int, CGPoint)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    /// Используется только текстом.
    var textStyle = TextStyle()

    /// Сдвиг пометки целиком.
    mutating func translate(dx: CGFloat, dy: CGFloat) {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        switch kind {
        case let .arrow(a, b): kind = .arrow(move(a), move(b))
        case let .line(a, b): kind = .line(move(a), move(b))
        case let .rectangle(r): kind = .rectangle(r.offsetBy(dx: dx, dy: dy))
        case let .ellipse(r): kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case let .pen(points): kind = .pen(points.map(move))
        case let .marker(points): kind = .marker(points.map(move))
        case let .text(string, origin, size): kind = .text(string, move(origin), fontSize: size)
        case let .pixelate(r): kind = .pixelate(r.offsetBy(dx: dx, dy: dy))
        case let .counter(number, center): kind = .counter(number, move(center))
        }
    }
}

/// Отрисовка снимка с пометками в любой CGContext (экран редактора и итоговый файл).
enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Рисует изображение и пометки. `scale` — сколько единиц контекста приходится на пиксель изображения.
    static func draw(base: CGImage, annotations: [Annotation], draft: Annotation? = nil, in ctx: CGContext, scale: CGFloat = 1) {
        let imageRect = CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: imageRect)
        for annotation in annotations + (draft.map { [$0] } ?? []) {
            draw(annotation, base: base, in: ctx)
        }
        ctx.restoreGState()
    }

    static func draw(_ annotation: Annotation, base: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = annotation.color.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(annotation.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch annotation.kind {
        case let .line(from, to):
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case let .arrow(from, to):
            let angle = atan2(to.y - from.y, to.x - from.x)
            // Наконечник растёт вместе с толщиной стрелки.
            let head = annotation.lineWidth * 3.5 + 8
            // Линия заканчивается у основания наконечника, чтобы конец был острым.
            let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            ctx.move(to: to)
            ctx.addLine(to: CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7)))
            ctx.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7)))
            ctx.closePath()
            ctx.fillPath()

        case let .rectangle(rect):
            ctx.stroke(rect.standardized)

        case let .ellipse(rect):
            ctx.strokeEllipse(in: rect.standardized)

        case let .pen(points):
            stroke(points, in: ctx)

        case let .marker(points):
            ctx.setStrokeColor(annotation.color.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(annotation.lineWidth * 4)
            ctx.setLineCap(.square)
            ctx.setBlendMode(.multiply)
            stroke(points, in: ctx)

        case let .text(string, origin, fontSize):
            let text = attributedText(string, size: fontSize, annotation: annotation)
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            if annotation.textStyle.background {
                let size = text.size()
                let box = CGRect(origin: origin, size: size).insetBy(dx: -fontSize * 0.25, dy: -fontSize * 0.1)
                let contrast: NSColor = annotation.color.brightnessComponentSafe > 0.6 ? .black : .white
                contrast.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: box, xRadius: fontSize * 0.2, yRadius: fontSize * 0.2).fill()
            }
            text.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()

        case let .pixelate(rect):
            let area = rect.standardized.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
            guard area.width >= 2, area.height >= 2, let pixelated = pixelate(base, rect: area, blockSize: max(10, annotation.lineWidth * 3)) else { return }
            ctx.draw(pixelated, in: area)

        case let .counter(number, center):
            let radius = max(annotation.lineWidth * 3, 14)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(2, radius * 0.12))
            ctx.strokeEllipse(in: circle)
            let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
            let text = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func attributedText(_ string: String, size: CGFloat, annotation: Annotation) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: annotation.textStyle.font(size: size),
            .foregroundColor: annotation.color,
        ]
        if annotation.textStyle.outline && !annotation.textStyle.background {
            attributes[.strokeColor] = (annotation.color.brightnessComponentSafe > 0.6 ? NSColor.black : NSColor.white).withAlphaComponent(0.6)
            attributes[.strokeWidth] = -2.5
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    private static func stroke(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.move(to: first)
        if points.count == 1 {
            ctx.addLine(to: first)
        } else {
            // Сглаживание: кривые через середины соседних точек.
            for index in 1..<points.count {
                let mid = CGPoint(x: (points[index - 1].x + points[index].x) / 2, y: (points[index - 1].y + points[index].y) / 2)
                ctx.addQuadCurve(to: mid, control: points[index - 1])
            }
            ctx.addLine(to: points[points.count - 1])
        }
        ctx.strokePath()
    }

    private static func pixelate(_ image: CGImage, rect: CGRect, blockSize: CGFloat) -> CGImage? {
        let filter = CIFilter.pixellate()
        filter.inputImage = CIImage(cgImage: image).clampedToExtent()
        filter.scale = Float(blockSize)
        filter.center = CGPoint(x: rect.minX, y: rect.minY)
        guard let output = filter.outputImage?.cropped(to: rect) else { return nil }
        return ciContext.createCGImage(output, from: rect)
    }

    // MARK: - Геометрия пометок (для выбора щелчком и рамки выделения)

    static func bounds(of annotation: Annotation) -> CGRect {
        let pad = annotation.lineWidth * 2 + 4
        switch annotation.kind {
        case let .arrow(a, b), let .line(a, b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -pad, dy: -pad)
        case let .rectangle(r), let .ellipse(r), let .pixelate(r):
            return r.standardized.insetBy(dx: -pad, dy: -pad)
        case let .pen(points), let .marker(points):
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad * 2, dy: -pad * 2)
        case let .text(string, origin, size):
            let textSize = attributedText(string, size: size, annotation: annotation).size()
            return CGRect(origin: origin, size: textSize).insetBy(dx: -max(4, size * 0.25), dy: -max(4, size * 0.1))
        case let .counter(_, center):
            let radius = max(annotation.lineWidth * 3, 14)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Расстояние от точки до пометки (0 — внутри заполненных фигур и текста).
    static func distance(from point: CGPoint, to annotation: Annotation) -> CGFloat {
        func segment(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
            let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
        }
        switch annotation.kind {
        case let .arrow(a, b), let .line(a, b):
            return segment(a, b)
        case let .rectangle(r):
            let r = r.standardized
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return (0..<4).map { segment(corners[$0], corners[($0 + 1) % 4]) }.min() ?? .infinity
        case let .ellipse(r):
            let r = r.standardized
            guard r.width > 0, r.height > 0 else { return .infinity }
            let nx = (point.x - r.midX) / (r.width / 2), ny = (point.y - r.midY) / (r.height / 2)
            return abs(hypot(nx, ny) - 1) * min(r.width, r.height) / 2
        case let .pen(points), let .marker(points):
            guard points.count > 1 else { return points.first.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .infinity }
            return (1..<points.count).map { segment(points[$0 - 1], points[$0]) }.min() ?? .infinity
        case .pixelate, .text, .counter:
            return bounds(of: annotation).contains(point) ? 0 : .infinity
        }
    }

    /// Итоговое изображение со всеми пометками.
    static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(base: base, annotations: annotations, in: ctx)
        return ctx.makeImage()
    }
}

private extension NSColor {
    var brightnessComponentSafe: CGFloat {
        usingColorSpace(.sRGB)?.brightnessComponent ?? 0.5
    }
}
