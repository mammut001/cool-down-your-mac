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
        let percent = engine.targetPercent(temperatureC: 90, profile: profile)
        XCTAssertEqual(percent, 1.0, accuracy: 0.0001)
    }

    func testEmergencyTemperatureAboveThresholdReturnsFullFan() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 100, profile: profile)
        XCTAssertEqual(percent, 1.0, accuracy: 0.0001)
    }

    func testFirstSampleWarmTemperatureGetsSafetyFloor() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 80, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.85)
    }

    func testFirstSampleHotTemperatureReturnsAtLeastNinetyFivePercent() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 85, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.95)
    }

    func testFirstSampleJustBelowEmergencyUsesHotFloor() {
        let engine = SmartCurveEngine()
        let percent = engine.targetPercent(temperatureC: 89.9, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.95)
        XCTAssertLessThan(percent, 1.0)
    }

    func testLaterHotSampleSnapsToFloorNotSlew() {
        let engine = SmartCurveEngine()
        _ = engine.targetPercent(temperatureC: 50, profile: profile)
        let percent = engine.targetPercent(temperatureC: 85, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.95)
    }

    func testHysteresisHoldsSmallTemperatureWiggle() {
        let sticky = CurveProfile(
            name: "Sticky",
            points: [
                CurvePoint(temperatureC: 45, fanPercent: 0.20),
                CurvePoint(temperatureC: 85, fanPercent: 0.80)
            ],
            hysteresisC: 3
        )
        let engine = SmartCurveEngine()
        let first = engine.targetPercent(temperatureC: 70, profile: sticky)
        let second = engine.targetPercent(temperatureC: 71, profile: sticky)
        XCTAssertEqual(first, second, accuracy: 0.0001)
    }
}
