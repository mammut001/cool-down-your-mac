import XCTest
import CoolDownKit

final class CurveProfileTests: XCTestCase {
    private let profile = CurveProfile(
        name: "Test",
        points: [
            CurvePoint(temperatureC: 45, fanPercent: 0.15),
            CurvePoint(temperatureC: 55, fanPercent: 0.30),
            CurvePoint(temperatureC: 65, fanPercent: 0.50)
        ]
    )

    func testFanPercentBelowFirstPointUsesFirstPercent() {
        XCTAssertEqual(profile.fanPercent(for: 30), 0.15, accuracy: 0.0001)
        XCTAssertEqual(profile.fanPercent(for: 45), 0.15, accuracy: 0.0001)
    }

    func testFanPercentBetweenPointsInterpolatesLinearly() {
        // Midway between 45°C/15% and 55°C/30% is 50°C → 22.5%.
        XCTAssertEqual(profile.fanPercent(for: 50), 0.225, accuracy: 0.0001)
    }

    func testFanPercentAboveLastPointUsesLastPercent() {
        XCTAssertEqual(profile.fanPercent(for: 65), 0.50, accuracy: 0.0001)
        XCTAssertEqual(profile.fanPercent(for: 90), 0.50, accuracy: 0.0001)
    }

    func testEmptyPointsUseSafeDefault() {
        let empty = CurveProfile(name: "Empty", points: [])
        XCTAssertEqual(empty.fanPercent(for: 80), 0.3, accuracy: 0.0001)
    }

    func testDecodeMissingHysteresisKeepsCurve() throws {
        let data = """
        {"name":"Saved","points":[{"temperatureC":50,"fanPercent":0.2},{"temperatureC":80,"fanPercent":0.8}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CurveProfile.self, from: data)
        XCTAssertEqual(decoded.hysteresisC, 2.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.fanPercent(for: 65), 0.5, accuracy: 0.0001)
    }
}
