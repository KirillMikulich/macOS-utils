import CoreGraphics
import XCTest
@testable import MacUtilities

final class WheelReverseTests: XCTestCase {
    func testNegateFlipsAllDeltaFields() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let points = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        ScrollWheelInterceptor.negate(event, line: .scrollWheelEventDeltaAxis1, fixed: .scrollWheelEventFixedPtDeltaAxis1, point: .scrollWheelEventPointDeltaAxis1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -lines)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -fixed, accuracy: 0.01)
        XCTAssertLessThan(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * points, 0, "пиксели тоже перевёрнуты")
    }
}
