import XCTest
@testable import MacUtilities

final class WindowListBuilderTests: XCTestCase {
    private let windows = [
        TestSupport.window("safari-1", pid: 1, app: "Safari", title: "Apple", z: 2),
        TestSupport.window("notes-1", pid: 2, app: "Notes", title: "Shopping", z: 0),
        TestSupport.window("safari-2", pid: 1, app: "Safari", title: "Bing", z: 1),
        TestSupport.window("mail-1", pid: 3, app: "Mail", title: "Inbox", z: 20_000, minimized: true),
        TestSupport.window("music-1", pid: 4, app: "Music", title: "Player", z: 10_000, hidden: true),
    ]

    func testRecentlyUsedOrder() {
        let result = WindowListBuilder.build(windows, configuration: WindowListConfiguration())
        XCTAssertEqual(result.map(\.id), ["notes-1", "safari-2", "safari-1", "music-1", "mail-1"])
    }

    func testSortByAppName() {
        let result = WindowListBuilder.build(windows, configuration: WindowListConfiguration(sortOrder: .appName))
        XCTAssertEqual(result.map(\.appName), ["Mail", "Music", "Notes", "Safari", "Safari"])
        XCTAssertEqual(result.suffix(2).map(\.id), ["safari-2", "safari-1"], "внутри приложения — по недавности")
    }

    func testSortByTitle() {
        let result = WindowListBuilder.build(windows, configuration: WindowListConfiguration(sortOrder: .windowTitle))
        XCTAssertEqual(result.map(\.title), ["Apple", "Bing", "Inbox", "Player", "Shopping"])
    }

    func testExclusions() {
        let config = WindowListConfiguration(excludedBundleIDs: ["com.test.safari"])
        let result = WindowListBuilder.build(windows, configuration: config)
        XCTAssertFalse(result.contains { $0.appName == "Safari" })
        XCTAssertEqual(result.count, 3)
    }

    func testHideMinimizedAndHidden() {
        let config = WindowListConfiguration(showMinimized: false, showHiddenApps: false)
        let result = WindowListBuilder.build(windows, configuration: config)
        XCTAssertEqual(result.map(\.id), ["notes-1", "safari-2", "safari-1"])
    }

    func testGroupingByApp() {
        let mixed = [
            TestSupport.window("a1", pid: 1, app: "A", z: 0),
            TestSupport.window("b1", pid: 2, app: "B", z: 1),
            TestSupport.window("a2", pid: 1, app: "A", z: 2),
            TestSupport.window("b2", pid: 2, app: "B", z: 3),
        ]
        let result = WindowListBuilder.build(mixed, configuration: WindowListConfiguration(groupByApp: true))
        XCTAssertEqual(result.map(\.id), ["a1", "a2", "b1", "b2"])
    }

    func testCustomFilter() {
        var config = WindowListConfiguration()
        config.filter = { $0.pid == 2 }
        XCTAssertEqual(WindowListBuilder.build(windows, configuration: config).map(\.id), ["notes-1"])
    }
}

final class SwitcherSessionTests: XCTestCase {
    private let windows = (0..<5).map { TestSupport.window("w\($0)", pid: pid_t($0), app: "App\($0)", z: $0) }

    func testForwardStartsOnSecondWindow() {
        let session = SwitcherSession(windows: windows, direction: .forward)
        XCTAssertEqual(session.selectedWindow?.id, "w1", "как Alt+Tab: сразу следующее окно")
    }

    func testBackwardStartsOnLastWindow() {
        let session = SwitcherSession(windows: windows, direction: .backward)
        XCTAssertEqual(session.selectedWindow?.id, "w4")
    }

    func testSingleWindow() {
        let session = SwitcherSession(windows: [windows[0]])
        XCTAssertEqual(session.selectedWindow?.id, "w0")
    }

    func testStepWrapsAround() {
        var session = SwitcherSession(windows: windows)
        for _ in 0..<4 { session.step(.forward) }
        XCTAssertEqual(session.selectedWindow?.id, "w0")
        session.step(.backward)
        XCTAssertEqual(session.selectedWindow?.id, "w4")
    }

    func testGridMovement() {
        var session = SwitcherSession(windows: windows) // выбран w1
        session.move(rows: 1, columns: 3)
        XCTAssertEqual(session.selectedWindow?.id, "w4")
        session.move(rows: 1, columns: 3)
        XCTAssertEqual(session.selectedWindow?.id, "w4", "за пределы сетки не уходим")
        session.move(rows: -1, columns: 3)
        XCTAssertEqual(session.selectedWindow?.id, "w1")
    }

    func testConfirmReturnsSelectionOnce() {
        var session = SwitcherSession(windows: windows)
        session.step(.forward)
        XCTAssertEqual(session.confirm()?.id, "w2")
        XCTAssertNil(session.confirm(), "повторное подтверждение ничего не делает")
    }

    func testCancelPreventsActivation() {
        var session = SwitcherSession(windows: windows)
        session.cancel()
        XCTAssertNil(session.confirm())
        session.step(.forward)
        XCTAssertTrue(session.isFinished)
    }

    func testUpdateKeepsPreviousSelection() {
        var session = SwitcherSession(windows: windows)
        session.select(id: "w3")
        // Окно w0 закрылось, порядок изменился — выбор остаётся на w3.
        session.update(windows: [windows[4], windows[3], windows[1], windows[2]])
        XCTAssertEqual(session.selectedWindow?.id, "w3")
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testUpdateWhenSelectedWindowDisappears() {
        var session = SwitcherSession(windows: windows)
        session.select(id: "w4")
        session.update(windows: Array(windows.prefix(2)))
        XCTAssertEqual(session.selectedWindow?.id, "w1", "индекс ограничивается новым размером")
    }

    func testEmptySession() {
        var session = SwitcherSession(windows: [])
        session.step(.forward)
        XCTAssertNil(session.selectedWindow)
        XCTAssertNil(session.confirm())
    }
}
