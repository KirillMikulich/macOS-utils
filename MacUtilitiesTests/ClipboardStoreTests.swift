import AppKit
import XCTest
@testable import MacUtilities

@MainActor
final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        directory = TestSupport.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(limit: Int = 20, persistent: Bool = false) -> ClipboardStore {
        let storage: ClipboardStorage = persistent ? FileClipboardStorage(root: directory) : MemoryClipboardStorage()
        let store = ClipboardStore(storage: storage, historyLimit: limit)
        store.now = { [unowned self] in
            clock = clock.addingTimeInterval(1)
            return clock
        }
        return store
    }

    func testAddText() {
        let store = makeStore()
        let item = store.add(TestSupport.textContent("hello"), sourceBundleID: "com.apple.TextEdit", sourceAppName: "TextEdit")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.sourceAppName, "TextEdit")
        XCTAssertEqual(store.content(for: item)?.first?.data(for: "public.utf8-plain-text"), Data("hello".utf8))
    }

    func testNewestFirst() {
        let store = makeStore()
        store.add(TestSupport.textContent("one"))
        store.add(TestSupport.textContent("two"))
        XCTAssertEqual(store.items.map(\.previewText), ["two", "one"])
    }

    func testDeduplicationMovesToTop() {
        let store = makeStore()
        let first = store.add(TestSupport.textContent("dup"))
        store.add(TestSupport.textContent("other"))
        let again = store.add(TestSupport.textContent("dup"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.items.first?.previewText, "dup")
        XCTAssertGreaterThan(again.lastUsedAt, first.lastUsedAt)
    }

    func testLimitRemovesOldestUnpinned() {
        let store = makeStore(limit: 3)
        for i in 1...5 { store.add(TestSupport.textContent("item \(i)")) }
        XCTAssertEqual(store.items.map(\.previewText), ["item 5", "item 4", "item 3"])
    }

    func testPinnedItemsAreOutsideLimit() {
        let store = makeStore(limit: 2)
        let pinned = store.add(TestSupport.textContent("pinned"))
        store.setPinned(pinned.id, true)
        for i in 1...4 { store.add(TestSupport.textContent("item \(i)")) }
        XCTAssertEqual(store.unpinnedItems.count, 2)
        XCTAssertTrue(store.items.contains { $0.id == pinned.id }, "закреплённый элемент не удаляется лимитом")
    }

    func testReducingLimitTrimsHistory() {
        let store = makeStore(limit: 10)
        for i in 1...6 { store.add(TestSupport.textContent("item \(i)")) }
        store.historyLimit = 2
        XCTAssertEqual(store.items.count, 2)
    }

    func testRetention() {
        let store = makeStore()
        store.add(TestSupport.textContent("old"))
        clock = clock.addingTimeInterval(3 * 86_400)
        store.add(TestSupport.textContent("new"))
        store.retentionDays = 1
        XCTAssertEqual(store.items.map(\.previewText), ["new"])
    }

    func testSearch() {
        let store = makeStore()
        store.add(TestSupport.textContent("Купить молоко"))
        store.add(TestSupport.textContent("Meeting at 10"))
        store.add(TestSupport.textContent("https://example.com"))
        XCTAssertEqual(store.search("молоко").map(\.previewText), ["Купить молоко"])
        XCTAssertEqual(store.search("MEETING").count, 1, "поиск без учёта регистра")
        XCTAssertEqual(store.search("Ссылка").count, 1, "поиск по типу элемента")
        XCTAssertEqual(store.search("").count, 3)
        XCTAssertTrue(store.search("nothing").isEmpty)
    }

    func testDeleteAndClear() {
        let store = makeStore()
        let a = store.add(TestSupport.textContent("a"))
        let b = store.add(TestSupport.textContent("b"))
        store.add(TestSupport.textContent("c"))
        store.setPinned(b.id, true)

        store.delete(a.id)
        XCTAssertNil(store.item(a.id))
        XCTAssertNil(store.content(for: a))

        store.clear()
        XCTAssertEqual(store.items.map(\.id), [b.id], "очистка оставляет закреплённые")
        store.clear(includingPinned: true)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testTouchMovesToTop() {
        let store = makeStore()
        let a = store.add(TestSupport.textContent("a"))
        store.add(TestSupport.textContent("b"))
        store.touch(a.id)
        XCTAssertEqual(store.items.first?.id, a.id)
    }

    func testImageRoundTripThroughStoreAndPasteboard() throws {
        let png = TestSupport.pngData(width: 64, height: 48)
        let source = TestSupport.privatePasteboard()
        defer { source.releaseGlobally() }
        source.clearContents()
        source.setData(png, forType: .png)
        guard case .content(let content) = ClipboardContentReader.read(source, options: ClipboardReaderOptions()) else {
            return XCTFail("изображение не прочитано")
        }

        let store = makeStore(persistent: true)
        let item = store.add(content)
        store.flush()
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.imageSizeDescription, "64×48")
        XCTAssertEqual(store.imageData(for: item), png)

        let target = TestSupport.privatePasteboard()
        defer { target.releaseGlobally() }
        ClipboardContentWriter.write(try XCTUnwrap(store.content(for: item)), to: target)
        XCTAssertEqual(target.data(forType: .png), png)
    }

    func testHistoryRestoredAfterRestart() throws {
        let store = makeStore(persistent: true)
        let text = store.add(TestSupport.textContent("persisted"))
        let image = store.add(ClipboardContentReader.analyze(items: [CapturedPasteboardItem(representations: [
            ClipboardRepresentation(type: "public.png", data: TestSupport.pngData()),
        ])])!)
        store.setPinned(text.id, true)
        store.flush()

        let reopened = ClipboardStore(storage: FileClipboardStorage(root: directory), historyLimit: 20)
        XCTAssertEqual(reopened.items.map(\.id), [image.id, text.id])
        XCTAssertTrue(reopened.item(text.id)?.isPinned ?? false)
        XCTAssertEqual(reopened.content(for: text)?.first?.data(for: "public.utf8-plain-text"), Data("persisted".utf8))
        XCTAssertEqual(reopened.imageData(for: image), TestSupport.pngData())
    }

    func testCorruptedIndexStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "garbage".write(to: directory.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        let store = ClipboardStore(storage: FileClipboardStorage(root: directory))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSwitchToMemoryStorageKeepsItemsAndRemovesFiles() throws {
        let store = makeStore(persistent: true)
        let item = store.add(TestSupport.textContent("move me"))
        store.flush()
        store.switchStorage(to: MemoryClipboardStorage())
        FileClipboardStorage(root: directory).flush()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(store.content(for: item)?.first?.data(for: "public.utf8-plain-text"), Data("move me".utf8))
        XCTAssertTrue(ClipboardStore(storage: FileClipboardStorage(root: directory)).items.isEmpty, "на диске ничего не осталось")
    }
}

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    func testStoppedMonitorIgnoresChanges() {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        var calls = 0
        monitor.onChange = { calls += 1 }

        pasteboard.clearContents()
        pasteboard.setString("x", forType: .string)
        XCTAssertFalse(monitor.checkNow(), "выключенный модуль не записывает буфер")
        XCTAssertEqual(calls, 0)
    }

    func testRunningMonitorDetectsChangeOnce() {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        var calls = 0
        monitor.onChange = { calls += 1 }
        monitor.start(interval: 60)
        defer { monitor.stop() }

        XCTAssertFalse(monitor.checkNow(), "содержимое до запуска не записывается")
        pasteboard.clearContents()
        pasteboard.setString("x", forType: .string)
        XCTAssertTrue(monitor.checkNow())
        XCTAssertFalse(monitor.checkNow(), "одно изменение обрабатывается один раз")
        XCTAssertEqual(calls, 1)
    }

    func testOwnWritesAreIgnored() {
        let pasteboard = TestSupport.privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        monitor.start(interval: 60)
        defer { monitor.stop() }

        let count = ClipboardContentWriter.write([CapturedPasteboardItem(representations: [
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("mine".utf8)),
        ])], to: pasteboard)
        monitor.ignoreChange(upTo: count)
        XCTAssertFalse(monitor.checkNow())
    }
}
