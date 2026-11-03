import XCTest
@testable import MacUtilities

final class QuitOnCloseTests: XCTestCase {
    func testAllExceptExcluded() {
        var settings = QuitOnCloseSettings.defaultValue
        settings.excludedBundleIDs.append("com.apple.Music")
        XCTAssertTrue(settings.shouldQuit(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(settings.shouldQuit(bundleID: "com.apple.Music"))
        XCTAssertFalse(settings.shouldQuit(bundleID: nil))
    }

    func testOnlySelected() {
        var settings = QuitOnCloseSettings.defaultValue
        settings.mode = .onlySelected
        settings.selectedBundleIDs = ["com.apple.Preview"]
        XCTAssertTrue(settings.shouldQuit(bundleID: "com.apple.Preview"))
        XCTAssertFalse(settings.shouldQuit(bundleID: "com.apple.TextEdit"))
    }

    func testFinderAndSelfAreNeverQuit() {
        var settings = QuitOnCloseSettings.defaultValue
        settings.excludedBundleIDs = []
        settings.mode = .onlySelected
        settings.selectedBundleIDs = ["com.apple.finder", "com.otvertka.Otvertka"]
        XCTAssertFalse(settings.shouldQuit(bundleID: "com.apple.finder"))
        XCTAssertFalse(settings.shouldQuit(bundleID: "com.otvertka.Otvertka"))
    }
}
