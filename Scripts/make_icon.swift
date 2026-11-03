// Генерирует иконку Mac Utilities для Assets.xcassets: тонкий контурный ключ с отвёрткой
// с сине-фиолетовым градиентом на тёмной плашке с мягкой цветной подсветкой — в стиле значков разделов.
// Запуск: swift Scripts/make_icon.swift MacUtilities/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()
    let blue = NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1)
    let violet = NSColor(red: 0.66, green: 0.42, blue: 1.0, alpha: 1)

    // Плашка: скруглённый квадрат по сетке иконок macOS (отступ 10%).
    let inset = s * 0.1
    let bg = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let u = bg.width
    let bgPath = CGPath(roundedRect: bg, cornerWidth: u * 0.225, cornerHeight: u * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bgPath)
    ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    // Тёмный фон сверху вниз и цветные «пятна» света по углам.
    let base = CGGradient(colorsSpace: space, colors: [NSColor(white: 0.17, alpha: 1).cgColor,
                                                       NSColor(white: 0.08, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: bg.midX, y: bg.maxY), end: CGPoint(x: bg.midX, y: bg.minY), options: [])
    for (color, center, alpha) in [(blue, CGPoint(x: bg.minX + u * 0.2, y: bg.maxY - u * 0.15), 0.45),
                                   (violet, CGPoint(x: bg.maxX - u * 0.15, y: bg.minY + u * 0.2), 0.40)] {
        let glow = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(alpha).cgColor,
                                                           color.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: u * 0.75, options: [])
    }
    ctx.restoreGState()

    // Тонкая светлая кромка, как у значков разделов.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg.insetBy(dx: u * 0.004, dy: u * 0.004), cornerWidth: u * 0.22, cornerHeight: u * 0.22, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.setLineWidth(max(1, u * 0.008))
    ctx.strokePath()
    ctx.restoreGState()

    // Символ: контур SF Symbols, залитый градиентом через маску прозрачного слоя.
    let config = NSImage.SymbolConfiguration(pointSize: u * 0.48, weight: .light)
    let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let aspect = symbol.size.width / symbol.size.height
    let height = u * 0.56
    let rect = CGRect(x: bg.midX - height * aspect / 2, y: bg.midY - height / 2, width: height * aspect, height: height)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: u * 0.06, color: violet.withAlphaComponent(0.55).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: rect)
    ctx.setBlendMode(.sourceIn)
    let ink = CGGradient(colorsSpace: space, colors: [blue.cgColor, violet.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ink, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(size: base * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
try! json.write(to: out.appendingPathComponent("Contents.json"))
