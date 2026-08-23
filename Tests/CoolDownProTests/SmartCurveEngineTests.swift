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

    func testWarmTransitionSnapsToWarmFloorImmediately() {
        let engine = SmartCurveEngine()
        let initial = engine.targetPercent(temperatureC: 50, profile: profile)
        XCTAssertLessThan(initial, 0.50)
        let percent = engine.targetPercent(temperatureC: 80, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.85)
    }

    func testHotTransitionSnapsToHotFloorImmediately() {
        let engine = SmartCurveEngine()
        let initial = engine.targetPercent(temperatureC: 50, profile: profile)
        XCTAssertLessThan(initial, 0.50)
        let percent = engine.targetPercent(temperatureC: 85, profile: profile)
        XCTAssertGreaterThanOrEqual(percent, 0.95)
    }

    func testEmergencyTransitionSnapsToFullFanImmediately() {
        let engine = SmartCurveEngine()
        let initial = engine.targetPercent(temperatureC: 50, profile: profile)
        XCTAssertLessThan(initial, 0.50)
        let percent = engine.targetPercent(temperatureC: 90, profile: profile)
        XCTAssertEqual(percent, 1.0, accuracy: 0.0001)
    }

    func testWarmFloorRetainsHigherRequestedTarget() {
        let aggressive = CurveProfile(
            name: "Aggressive",
            points: [
                CurvePoint(temperatureC: 45, fanPercent: 0.20),
                CurvePoint(temperatureC: 80, fanPercent: 0.92),
                CurvePoint(temperatureC: 85, fanPercent: 1.00)
            ]
        )
        let engine = SmartCurveEngine()
        _ = engine.targetPercent(temperatureC: 50, profile: aggressive)
        let percent = engine.targetPercent(temperatureC: 80, profile: aggressive)
        XCTAssertGreaterThanOrEqual(percent, 0.92 - 0.0001)
    }

    func testWarmFloorRetainsHigherRequestedLoadBoost() {
        let engine = SmartCurveEngine()
        _ = engine.targetPercent(temperatureC: 50, profile: profile)
        // At 80C profile requests ~0.63, with 0.30 load boost desired is 0.93 (>0.85 warm floor)
        let percent = engine.targetPercent(temperatureC: 80, profile: profile, loadBoost: 0.30)
        XCTAssertGreaterThanOrEqual(percent, 0.93)
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

    func testCooldownHoldsTargetBeforeGraduallyDecreasing() {
        let engine = SmartCurveEngine()
        var t: TimeInterval = 1000.0

        // Step 1: establish a high target at 90C (100% fan, 10s cooldown hold initiated)
        let initial = engine.targetPercent(temperatureC: 90, profile: profile, uptime: t)
        XCTAssertEqual(initial, 1.0, accuracy: 0.0001)

        // Step 2: drop temperature to 50C at t + 2s; hold is active (8s remaining)
        t += 2.0
        let hold1 = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)
        XCTAssertEqual(hold1, 1.0, accuracy: 0.0001, "Target must not fall during hold period")

        // Step 3: at t + 4s (6s since temp drop); hold is still active (4s remaining)
        t += 4.0
        let hold2 = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)
        XCTAssertEqual(hold2, 1.0, accuracy: 0.0001, "Target must remain held")

        // Step 4: at t + 5s (11s total since drop, hold period of 10s expired 1s ago)
        t += 5.0
        let rampingDown = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)
        XCTAssertLessThan(rampingDown, 1.0, "Target must begin ramping down after hold expires")
        XCTAssertGreaterThan(rampingDown, 0.90, "Target must decrease gradually, not snap down")
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
