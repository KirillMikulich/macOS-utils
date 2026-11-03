import XCTest
@testable import Otvertka

@MainActor
final class ScreenshotWatcherTests: XCTestCase {
    private func markAsScreenshot(_ url: URL) {
        // Так же, как это делает macOS: бинарный plist со значением true.
        let value = try! PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = value.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, value.count, 0, 0) }
    }

    func testDetectsOnlyNewScreenshots() throws {
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.png")
        try TestSupport.pngData().write(to: old)
        markAsScreenshot(old)

        let watcher = ScreenshotWatcher()
        var found: [String] = []
        let detected = expectation(description: "screenshot detected")
        watcher.onScreenshot = { url in
            found.append(url.lastPathComponent)
            detected.fulfill()
        }
        watcher.start(directory: directory)
        defer { watcher.stop() }
        let deadline = Date().addingTimeInterval(3)
        while !watcher.isRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(watcher.isRunning)

        // Обычная картинка — не снимок экрана.
        try TestSupport.pngData().write(to: directory.appendingPathComponent("photo.png"))
        // Снимок: macOS пишет скрытый файл и переименовывает его.
        let temp = directory.appendingPathComponent(".shot.png")
        try TestSupport.pngData(width: 20, height: 20).write(to: temp)
        markAsScreenshot(temp)
        try FileManager.default.moveItem(at: temp, to: directory.appendingPathComponent("Снимок экрана.png"))

        wait(for: [detected], timeout: 3)
        XCTAssertEqual(found, ["Снимок экрана.png"])

        // Тот же файл, пересозданный под тем же именем (сначала без пометки снимка) — тоже распознаётся.
        let again = expectation(description: "recreated screenshot detected")
        watcher.onScreenshot = { url in
            found.append(url.lastPathComponent)
            again.fulfill()
        }
        let reused = directory.appendingPathComponent("photo.png")
        try FileManager.default.removeItem(at: reused)
        Thread.sleep(forTimeInterval: 1.1) // дата создания отличается хотя бы на секунду
        let temp2 = directory.appendingPathComponent(".photo.png")
        try TestSupport.pngData().write(to: temp2)
        markAsScreenshot(temp2)
        try FileManager.default.moveItem(at: temp2, to: reused)
        wait(for: [again], timeout: 3)
        XCTAssertEqual(found.last, "photo.png")
    }

    func testIsScreenshotAttribute() throws {
        let directory = TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.png")
        try TestSupport.pngData().write(to: file)
        XCTAssertFalse(ScreenshotWatcher.isScreenshot(file))
        markAsScreenshot(file)
        XCTAssertTrue(ScreenshotWatcher.isScreenshot(file))
    }
}
