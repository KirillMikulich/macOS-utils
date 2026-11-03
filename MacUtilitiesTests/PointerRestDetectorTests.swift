import XCTest
@testable import MacUtilities

final class PointerRestDetectorTests: XCTestCase {
    func testMovingPointerIsNotResting() {
        var detector = PointerRestDetector()
        for i in 0..<10 { detector.record(CGPoint(x: Double(i) * 8, y: 20), at: 10 + Double(i) * 0.02) }
        XCTAssertFalse(detector.isResting(at: CGPoint(x: 72, y: 20), now: 10.19), "проход по Dock со скоростью ~400 pt/с")
    }

    func testStoppedPointerIsResting() {
        var detector = PointerRestDetector()
        detector.record(CGPoint(x: 0, y: 20), at: 10)
        detector.record(CGPoint(x: 50, y: 20), at: 10.05)
        detector.record(CGPoint(x: 52, y: 21), at: 10.1)
        XCTAssertFalse(detector.isResting(at: CGPoint(x: 52, y: 21), now: 10.12))
        XCTAssertTrue(detector.isResting(at: CGPoint(x: 52, y: 21), now: 10.3), "после остановки на 0,15 с курсор считается остановившимся")
    }

    func testSmallJitterCountsAsResting() {
        var detector = PointerRestDetector()
        for i in 0..<8 { detector.record(CGPoint(x: 100 + Double(i % 2) * 2, y: 20), at: 10 + Double(i) * 0.02) }
        XCTAssertTrue(detector.isResting(at: CGPoint(x: 101, y: 20), now: 10.16), "дрожание руки в пару точек — это остановка")
    }

    func testNoMovementAtAllIsResting() {
        XCTAssertTrue(PointerRestDetector().isResting(at: .zero, now: 100))
    }
}
