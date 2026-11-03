import XCTest
@testable import Otvertka

final class LeftoverScannerTests: XCTestCase {
    private var root: URL!
    private let app = AppBundleInfo(url: URL(fileURLWithPath: "/Applications/Sample.app"), name: "Sample App",
                                    bundleID: "com.example.sample", teamID: "ABCDE12345")

    override func setUp() {
        root = TestSupport.temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ path: String, directory: Bool = false) {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: directory ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !directory { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
    }

    func testFindsLeftoversAndPreselectsOnlyReliableMatches() {
        let home = "home/Library/", system = "system/Library/"
        make(home + "Application Support/com.example.sample", directory: true)
        make(home + "Application Support/Sample App", directory: true)
        make(home + "Caches/com.example.sample", directory: true)
        make(home + "Preferences/com.example.sample.plist")
        make(home + "Preferences/ByHost/com.example.sample.1234-ABCD.plist")
        make(home + "Containers/com.example.sample", directory: true)
        make(home + "Group Containers/ABCDE12345.com.example.sample", directory: true)
        make(home + "Group Containers/ABCDE12345.shared", directory: true)
        make(home + "Saved Application State/com.example.sample.savedState", directory: true)
        make(home + "HTTPStorages/com.example.sample.binarycookies")
        // Не должны находиться:
        make(home + "Preferences/com.example.sampleother.plist")
        make(home + "Application Support/Other App", directory: true)
        make(system + "LaunchDaemons/com.example.sample.helper.plist")

        let scanner = LeftoverScanner(homeLibrary: root.appendingPathComponent("home/Library"),
                                      systemLibrary: root.appendingPathComponent("system/Library"))
        let items = scanner.scan(app)
        let names = Set(items.map(\.url.lastPathComponent))

        XCTAssertTrue(names.isSuperset(of: [
            "com.example.sample", "Sample App", "com.example.sample.plist", "com.example.sample.1234-ABCD.plist",
            "ABCDE12345.com.example.sample", "ABCDE12345.shared", "com.example.sample.savedState",
            "com.example.sample.binarycookies", "com.example.sample.helper.plist",
        ]))
        XCTAssertFalse(names.contains("com.example.sampleother.plist"), "другой bundle id с тем же началом")
        XCTAssertFalse(names.contains("Other App"))

        func item(_ name: String) -> LeftoverItem? { items.first { $0.url.lastPathComponent == name } }
        XCTAssertEqual(item("com.example.sample.plist")?.isSelected, true)
        XCTAssertEqual(item("Sample App")?.match, .name)
        XCTAssertEqual(item("Sample App")?.isSelected, false, "совпадение по названию не отмечается само")
        XCTAssertEqual(item("ABCDE12345.shared")?.match, .team)
        XCTAssertEqual(item("ABCDE12345.shared")?.isSelected, false, "общая папка разработчика не отмечается само")
        XCTAssertEqual(item("com.example.sample.helper.plist")?.isSystemWide, true)
    }

    func testShortNamesAreNotMatchedByName() {
        let short = AppBundleInfo(url: URL(fileURLWithPath: "/Applications/Go.app"), name: "Go", bundleID: "com.example.go")
        XCTAssertNil(LeftoverScanner.match(name: "Go", app: short, byName: true))
    }

    func testAppleAppsAreProtected() {
        let notes = AppBundleInfo(url: URL(fileURLWithPath: "/System/Applications/Notes.app"), name: "Notes", bundleID: "com.apple.Notes")
        XCTAssertTrue(notes.isProtected)
        XCTAssertFalse(app.isProtected)
    }
}
