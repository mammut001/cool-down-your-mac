import XCTest
import CoolDownKit

final class SmartCurveEngineTests: XCTestCase {
    private let profile = CurveProfile(
        name: "Test",
        points: [
            CurvePoint(temperatureC: 45, fanPercent: 0.15),
            CurvePoint(temperatureC: 85, fanPercent: 0.70)
        ]
    )

    func testEmergencyTemperatureReturnsFullFan() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 92, profile: profile)
        XCTAssertEqual(percent, 1.0, accuracy: 0.0001)
    }

    func testEmergencyTemperatureAboveThresholdReturnsFullFan() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 100, profile: profile)
        XCTAssertEqual(percent, 1.0, accuracy: 0.0001)
    }

    func testFirstSampleHotTemperatureReturnsAtLeastEightyFivePercent() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 88, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.85)
    }

    func testFirstSampleJustBelowEmergencyIsHotBypass() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 91.9, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.85)
        XCTAssertLessThan(percent, 1.0 + 0.0001)
    }
}
