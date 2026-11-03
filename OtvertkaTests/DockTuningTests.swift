import XCTest
@testable import Otvertka

private final class FakeDock: DockPreferenceBackend {
    var values: [String: Double] = [:]
    var restarts = 0
    func value(for key: String) -> Double? { values[key] }
    func setValue(_ value: Double?, for key: String) { values[key] = value }
    func restartDock() { restarts += 1 }
}

final class DockTuningTests: XCTestCase {
    func testApplyRemembersOriginalAndRestartsOnce() {
        let dock = FakeDock()
        dock.values[DockTuning.animationKey] = 0.8
        let tuning = DockTuning(backend: dock)

        let original = tuning.apply(delay: 0, animation: 0.25, original: nil)
        XCTAssertEqual(original, DockOriginalValues(delay: nil, animation: 0.8))
        XCTAssertEqual(dock.values[DockTuning.delayKey], 0)
        XCTAssertEqual(dock.values[DockTuning.animationKey], 0.25)
        XCTAssertEqual(dock.restarts, 1)

        // Повторное применение тех же значений не перезапускает Dock и не теряет исходные.
        let again = tuning.apply(delay: 0, animation: 0.25, original: original)
        XCTAssertEqual(again, original)
        XCTAssertEqual(dock.restarts, 1)
    }

    func testRestoreReturnsUserValues() {
        let dock = FakeDock()
        let tuning = DockTuning(backend: dock)
        let original = tuning.apply(delay: 0, animation: 0, original: nil)
        tuning.restore(original)
        XCTAssertNil(dock.values[DockTuning.delayKey], "ключа не было — системное значение")
        XCTAssertNil(dock.values[DockTuning.animationKey])
        XCTAssertEqual(dock.restarts, 2)

        tuning.restore(original)
        XCTAssertEqual(dock.restarts, 2, "уже восстановлено — Dock не трогаем")
    }
}
