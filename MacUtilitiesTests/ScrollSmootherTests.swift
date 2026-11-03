import XCTest
@testable import MacUtilities

final class ScrollSmootherTests: XCTestCase {
    private func run(_ smoother: inout ScrollSmoother, frames: Int = 300) -> (x: Int, y: Int, frames: Int) {
        var x = 0, y = 0, used = 0
        for _ in 0..<frames where !smoother.isIdle {
            let (dx, dy) = smoother.step(dt: 1.0 / 120)
            x += Int(dx); y += Int(dy); used += 1
        }
        return (x, y, used)
    }

    func testWholeDistanceIsDelivered() {
        var smoother = ScrollSmoother(duration: 0.25)
        smoother.add(dx: 0, dy: 120)
        let result = run(&smoother)
        XCTAssertEqual(result.y, 120, accuracy: 1)
        XCTAssertTrue(smoother.isIdle)
        XCTAssertGreaterThan(result.frames, 5, "путь распределён на несколько кадров — плавно")
        XCTAssertLessThan(result.frames, 120, "и завершается за разумное время")
    }

    func testNegativeAndHorizontal() {
        var smoother = ScrollSmoother(duration: 0.2)
        smoother.add(dx: -75, dy: -33)
        let result = run(&smoother)
        XCTAssertEqual(result.x, -75, accuracy: 1)
        XCTAssertEqual(result.y, -33, accuracy: 1)
    }

    func testDirectionChangeDropsOldRemainder() {
        var smoother = ScrollSmoother(duration: 0.3)
        smoother.add(dx: 0, dy: 200)
        _ = smoother.step(dt: 1.0 / 120)
        smoother.add(dx: 0, dy: -60)
        let result = run(&smoother)
        XCTAssertEqual(result.y, -60, accuracy: 1, "после смены направления едем только в новую сторону")
    }

    func testAccelerationOnlyForFastTicks() {
        var acceleration = ScrollAcceleration()
        XCTAssertEqual(acceleration.register(at: 0, strength: 1), 1)
        XCTAssertGreaterThan(acceleration.register(at: 0.05, strength: 1), 1)
        XCTAssertEqual(acceleration.register(at: 1.0, strength: 1), 1, "после паузы ускорение сбрасывается")
        XCTAssertEqual(acceleration.register(at: 1.05, strength: 0), 1, "ускорение выключено")
    }
}
