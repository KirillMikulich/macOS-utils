import AppKit
import XCTest
@testable import Otvertka

final class ClipboardReaderWriterTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private let options = ClipboardReaderOptions()

    override func setUp() {
        pasteboard = TestSupport.privatePasteboard()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func readContent(file: StaticString = #filePath, line: UInt = #line) -> CapturedClipboardContent? {
        guard case .content(let content) = ClipboardContentReader.read(pasteboard, options: options) else {
            XCTFail("Ожидалось содержимое", file: file, line: line)
            return nil
        }
        return content
    }

    func testPlainText() {
        pasteboard.clearContents()
        pasteboard.setString("Hello world", forType: .string)
        let content = readContent()
        XCTAssertEqual(content?.kind, .text)
        XCTAssertEqual(content?.previewText, "Hello world")
    }

    func testUnicodeText() {
        let text = "Привет, мир! 你好 🌧️ — ñ"
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        XCTAssertEqual(readContent()?.previewText, text)
    }

    func testURL() {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/path?q=1")! as NSURL])
        let content = readContent()
        XCTAssertEqual(content?.kind, .link)
        XCTAssertEqual(content?.previewText, "https://example.com/path?q=1")
    }

    func testURLAsPlainText() {
        pasteboard.clearContents()
        pasteboard.setString("https://apple.com", forType: .string)
        XCTAssertEqual(readContent()?.kind, .link)
    }

    func testRichTextKeepsAllRepresentations() {
        let attributed = NSAttributedString(string: "Bold text", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length))!
        let item = NSPasteboardItem()
        item.setData(rtf, forType: .rtf)
        item.setString("<b>Bold text</b>", forType: .html)
        item.setString("Bold text", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let content = readContent()
        XCTAssertEqual(content?.kind, .richText)
        XCTAssertEqual(content?.previewText, "Bold text")
        let types = Set(content?.items.first?.types ?? [])
        XCTAssertTrue(types.isSuperset(of: ["public.rtf", "public.html", "public.utf8-plain-text"]))
    }

    func testHTMLOnlyPreviewIsStripped() {
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <i>there</i></p>", forType: .html)
        let content = readContent()
        XCTAssertEqual(content?.kind, .richText)
        XCTAssertEqual(content?.previewText, "Hello there")
    }

    func testPNGImage() {
        let png = TestSupport.pngData(width: 30, height: 20)
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let content = readContent()
        XCTAssertEqual(content?.kind, .image)
        XCTAssertEqual(content?.imagePixelSize, CGSize(width: 30, height: 20))
        XCTAssertEqual(content?.items.first?.data(for: "public.png"), png, "изображение сохраняется без перекодирования")
    }

    func testTIFFImage() {
        let image = NSImage(data: TestSupport.pngData())!
        pasteboard.clearContents()
        pasteboard.setData(image.tiffRepresentation!, forType: .tiff)
        XCTAssertEqual(readContent()?.kind, .image)
    }

    func testImageWithURLIsImage() {
        // Так выглядит «Копировать изображение» в браузерах: картинка + адрес.
        let item = NSPasteboardItem()
        item.setData(TestSupport.pngData(), forType: .png)
        item.setString("https://example.com/cat.png", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(readContent()?.kind, .image)
    }

    func testFiles() {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        let content = readContent()
        XCTAssertEqual(content?.kind, .files)
        XCTAssertEqual(content?.items.count, 2)
        XCTAssertEqual(content?.previewText, "/tmp/a.txt\n/tmp/b.png")
    }

    func testEmptyPasteboard() {
        pasteboard.clearContents()
        XCTAssertEqual(ClipboardContentReader.read(pasteboard, options: options), .empty)
    }

    func testEmptyStringIsNotStored() {
        pasteboard.clearContents()
        pasteboard.setString("", forType: .string)
        XCTAssertEqual(ClipboardContentReader.read(pasteboard, options: options), .skipped(.unsupported))
    }

    func testConcealedContentIsSkipped() {
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertEqual(ClipboardContentReader.read(pasteboard, options: options), .skipped(.concealed))

        var permissive = options
        permissive.ignoreConcealed = false
        if case .content = ClipboardContentReader.read(pasteboard, options: permissive) {} else {
            XCTFail("с выключенной опцией данные должны сохраняться")
        }
    }

    func testUnsupportedPromisedFormatIsSkipped() {
        pasteboard.clearContents()
        pasteboard.setData(Data("x".utf8), forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        XCTAssertEqual(ClipboardContentReader.read(pasteboard, options: options), .skipped(.unsupported))
    }

    func testCustomTypeIsKeptAsOther() {
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        XCTAssertEqual(readContent()?.kind, .other)
    }

    func testTooLargeIsSkipped() {
        var small = options
        small.maxBytes = 10
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "x", count: 100), forType: .string)
        XCTAssertEqual(ClipboardContentReader.read(pasteboard, options: small), .skipped(.tooLarge))
    }

    func testImagesDisabled() {
        var noImages = options
        noImages.saveImages = false
        pasteboard.clearContents()
        pasteboard.setData(TestSupport.pngData(), forType: .png)
        XCTAssertEqual(ClipboardContentReader.read(pasteboard, options: noImages), .skipped(.imagesDisabled))
    }

    func testSameContentHasSameHash() {
        pasteboard.clearContents()
        pasteboard.setString("same", forType: .string)
        let first = readContent()?.contentHash
        pasteboard.clearContents()
        pasteboard.setString("same", forType: .string)
        XCTAssertEqual(first, readContent()?.contentHash)
    }

    func testWriterRestoresImageAndRichText() throws {
        let png = TestSupport.pngData(width: 40, height: 40)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString("<img src='x'>", forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let content = try XCTUnwrap(readContent())

        let target = TestSupport.privatePasteboard()
        defer { target.releaseGlobally() }
        target.setString("old", forType: .string)
        let changeCount = ClipboardContentWriter.write(content.items, to: target)

        XCTAssertEqual(changeCount, target.changeCount)
        XCTAssertEqual(target.data(forType: .png), png, "изображение восстанавливается байт в байт")
        XCTAssertEqual(target.string(forType: .html), "<img src='x'>")
        XCTAssertNil(target.string(forType: .string), "старое содержимое заменено")
        XCTAssertNotNil(NSImage(pasteboard: target), "приложения могут вставить картинку")
    }
}
