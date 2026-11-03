import AppKit
import XCTest
@testable import MacUtilities

@MainActor
final class ScreenshotDocumentTests: XCTestCase {
    private func whiteImage(width: Int = 200, height: Int = 100) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Цвет пикселя (x, y от левого нижнего угла).
    private func pixel(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: image.height - 1 - y)
    }

    func testAnnotationIsRenderedIntoOutput() throws {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 40)), color: .red, lineWidth: 6))
        let color = try XCTUnwrap(pixel(document.rendered(), x: 20, y: 40)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.3, "рамка прямоугольника нарисована красным")
        let inside = try XCTUnwrap(pixel(document.rendered(), x: 50, y: 40)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(inside.greenComponent, 0.9, "внутри рамки остаётся исходное изображение")
    }

    func testUndoRedo() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .counter(1, CGPoint(x: 50, y: 50)), color: .blue, lineWidth: 4))
        XCTAssertEqual(document.nextCounter, 2)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertEqual(document.nextCounter, 1)
        document.redo()
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.nextCounter, 2)
    }

    func testCropBakesAnnotationsAndCanBeUndone() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .line(CGPoint(x: 0, y: 50), CGPoint(x: 200, y: 50)), color: .black, lineWidth: 4))
        document.crop(to: CGRect(x: 50, y: 25, width: 100, height: 50))
        XCTAssertEqual(document.pixelSize, CGSize(width: 100, height: 50))
        XCTAssertTrue(document.annotations.isEmpty, "пометки «впечены» в обрезанное изображение")
        document.undo()
        XCTAssertEqual(document.pixelSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(document.annotations.count, 1)
    }

    func testResize() {
        let document = ScreenshotDocument(image: whiteImage())
        document.resize(scale: 0.5)
        XCTAssertEqual(document.pixelSize, CGSize(width: 100, height: 50))
    }

    func testPixelateAndTextDoNotCrash() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .pixelate(CGRect(x: 10, y: 10, width: 80, height: 50)), color: .red, lineWidth: 4))
        document.add(Annotation(kind: .text("Привет", CGPoint(x: 10, y: 10), fontSize: 20), color: .red, lineWidth: 4))
        document.add(Annotation(kind: .arrow(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 80)), color: .red, lineWidth: 4))
        document.add(Annotation(kind: .marker([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)]), color: .yellow, lineWidth: 4))
        XCTAssertEqual(document.rendered().width, 200)
    }

    func testSaveCreatesPNG() throws {
        let folder = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = ScreenshotDocument(image: whiteImage())
        let url = try document.save(in: folder)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(ClipboardContentReader.imagePixelSize(data), CGSize(width: 200, height: 100))
        let second = try document.save(in: folder)
        XCTAssertNotEqual(url, second, "второй снимок в ту же секунду не перезаписывает первый")
    }

    func testStyleChangesApplyToSelectedAnnotationImmediately() {
        let document = ScreenshotDocument(image: whiteImage())
        document.lineWidth = 4
        document.add(Annotation(kind: .arrow(CGPoint(x: 10, y: 10), CGPoint(x: 150, y: 80)), color: .red, lineWidth: 4))
        document.lineWidth = 10
        document.lineWidth = 16
        document.color = .blue
        XCTAssertEqual(document.annotations.first?.lineWidth, 16)
        XCTAssertEqual(document.annotations.first?.color, .blue)
        document.undo()
        XCTAssertEqual(document.annotations.first?.lineWidth, 4, "серия изменений стиля откатывается одним ⌘Z")
        XCTAssertEqual(document.annotations.count, 1)
    }

    func testTextSizeChangesLive() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .text("Привет", CGPoint(x: 10, y: 10), fontSize: 24), color: .red, lineWidth: 4))
        document.fontSize = 48
        guard case let .text(_, _, size)? = document.annotations.first?.kind else { return XCTFail("ожидался текст") }
        XCTAssertEqual(size, 48)
    }

    func testHitTestSelectsAndLoadsStyle() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .line(CGPoint(x: 0, y: 50), CGPoint(x: 200, y: 50)), color: .green, lineWidth: 6))
        document.select(nil)
        XCTAssertNil(document.hitTest(CGPoint(x: 100, y: 90)), "мимо линии")
        let hit = document.hitTest(CGPoint(x: 100, y: 53))
        XCTAssertNotNil(hit)
        document.lineWidth = 2
        document.select(hit)
        XCTAssertEqual(document.lineWidth, 6, "при выборе панель подхватывает стиль пометки")
        XCTAssertEqual(document.annotations.first?.lineWidth, 6, "выбор сам по себе пометку не меняет")
    }

    func testMoveSelectedAnnotationWithSingleUndo() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)), color: .red, lineWidth: 4))
        document.select(nil)
        let hit = document.hitTest(CGPoint(x: 10, y: 25))
        document.select(hit)
        document.beginMove()
        document.moveSelected(dx: 20, dy: 5)
        document.moveSelected(dx: 10, dy: 5)
        guard case let .rectangle(moved)? = document.annotations.first?.kind else { return XCTFail() }
        XCTAssertEqual(moved.origin, CGPoint(x: 40, y: 20))
        document.undo()
        guard case let .rectangle(original)? = document.annotations.first?.kind else { return XCTFail() }
        XCTAssertEqual(original.origin, CGPoint(x: 10, y: 10), "всё перемещение отменяется одним ⌘Z")
    }

    func testTextStyleAppliesToSelectedText() {
        let document = ScreenshotDocument(image: whiteImage())
        document.add(Annotation(kind: .text("Привет", CGPoint(x: 10, y: 10), fontSize: 24), color: .red, lineWidth: 4))
        var style = TextStyle()
        style.weight = .heavy
        style.italic = true
        style.background = true
        document.textStyle = style
        XCTAssertEqual(document.annotations.first?.textStyle, style)
        let font = style.font(size: 24)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic), "курсив применяется к системному шрифту")
        XCTAssertEqual(document.rendered().width, 200, "текст с подложкой рисуется без ошибок")
        document.undo()
        XCTAssertEqual(document.annotations.first?.textStyle, TextStyle())
    }

    func testCustomFontFamily() {
        var style = TextStyle()
        style.fontFamily = "Helvetica"
        style.weight = .bold
        let font = style.font(size: 20)
        XCTAssertEqual(font.familyName, "Helvetica")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
