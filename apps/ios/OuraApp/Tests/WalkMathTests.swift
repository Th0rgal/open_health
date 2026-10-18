import XCTest
@testable import OuraApp

final class WalkMathTests: XCTestCase {
    private let metersPerDegreeLat = 111_195.0

    private func walk(speed: Double, seconds: Int, every: Double = 4, t0: Double = 1_000_000, lat0: Double = 47.0) -> [RoutePoint] {
        stride(from: 0.0, through: Double(seconds), by: every).map {
            RoutePoint(t: t0 + $0, lat: lat0 + speed * $0 / metersPerDegreeLat, lon: 8.0, acc: 8)
        }
    }

    func testSteadyWalkGivesSixMinutesOfDistance() throws {
        let window = try XCTUnwrap(WalkMath.bestWindow(walk(speed: 1.5, seconds: 600)))
        XCTAssertEqual(window.distanceM, 540, accuracy: 3)
    }

    func testPauseInsideAWindowIsRejectedAndTheFasterSideWins() throws {
        let first = walk(speed: 1.4, seconds: 300)
        let last = try XCTUnwrap(first.last)
        let second = walk(speed: 1.7, seconds: 400, t0: last.t + 60, lat0: last.lat)
        let window = try XCTUnwrap(WalkMath.bestWindow(first + second))
        XCTAssertEqual(window.distanceM, 612, accuracy: 4)
    }

    func testGpsJumpAndPoorFixesAreDropped() throws {
        var jumpy = walk(speed: 1.5, seconds: 600)
        jumpy[40].lat += 0.02
        XCTAssertEqual(try XCTUnwrap(WalkMath.bestWindow(jumpy)).distanceM, 540, accuracy: 10)
        var poor = walk(speed: 1.5, seconds: 600)
        for i in poor.indices { poor[i].acc = 60 }
        XCTAssertNil(WalkMath.bestWindow(poor))
    }

    func testRunningAndShortRoutesAreNotWalkingWindows() {
        XCTAssertNil(WalkMath.bestWindow(walk(speed: 3.5, seconds: 600)))
        XCTAssertNil(WalkMath.bestWindow(walk(speed: 1.5, seconds: 300)))
    }

    func testMinuteWindowSkipsMissingMinutes() throws {
        let minutes: [Double?] = [80, 85, 90, nil, 70, 82, 88, 91, 90, 85, 79, 60]
        let window = try XCTUnwrap(WalkMath.bestMinuteWindow(minutes))
        XCTAssertEqual(window.start, 5)
        XCTAssertEqual(window.distanceM, 515, accuracy: 0.1)
    }

    func testMedian() {
        XCTAssertEqual(WalkMath.median([3, 1, 2]), 2)
        XCTAssertEqual(WalkMath.median([1, 2, 3, 4]), 2.5)
        XCTAssertNil(WalkMath.median([]))
    }
}
