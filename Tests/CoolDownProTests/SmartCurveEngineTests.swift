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

    func testTransientSpikeFiltersWithoutSnappingToFloors() {
        let engine = SmartCurveEngine()
        let initial = engine.targetPercent(temperatureC: 50, profile: profile)
        XCTAssertLessThan(initial, 0.50)
        // A single transient spike to 80C or 100C must be smoothed and not blast the fans
        let spikeWarm = engine.targetPercent(temperatureC: 80, profile: profile)
        XCTAssertLessThan(spikeWarm, 0.50)
        let spike100 = engine.targetPercent(temperatureC: 100, profile: profile)
        XCTAssertLessThan(spike100, 0.60)
    }

    func testSustainedEmergencyEngagesFullFan() {
        let engine = SmartCurveEngine()
        var t: TimeInterval = 1000.0
        let initial = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)
        XCTAssertLessThan(initial, 0.50)
        // First spike sample at t + 2s (sustained duration 2s < 3.5s): filtered and smoothed
        t += 2.0
        let sample1 = engine.targetPercent(temperatureC: 95, profile: profile, uptime: t)
        XCTAssertLessThan(sample1, 1.0)
        // Second sample at t + 2s (sustained duration 4s >= 3.5s): emergency engages!
        t += 2.0
        let sample2 = engine.targetPercent(temperatureC: 95, profile: profile, uptime: t)
        XCTAssertEqual(sample2, 1.0, accuracy: 0.0001)
    }

    func testSustainedWarmTemperatureEngagesWarmFloor() {
        let engine = SmartCurveEngine()
        var t: TimeInterval = 1000.0
        _ = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)
        // Warm temperature sustained until filtered reaches 80C
        var percent: Double = 0
        for _ in 0..<5 {
            t += 2.0
            percent = engine.targetPercent(temperatureC: 85, profile: profile, uptime: t)
        }
        XCTAssertGreaterThanOrEqual(percent, 0.85)
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
        let percent = engine.targetPercent(temperatureC: 80, profile: aggressive)
        XCTAssertGreaterThanOrEqual(percent, 0.92 - 0.0001)
    }

    func testWarmFloorRetainsHigherRequestedLoadBoost() {
        let engine = SmartCurveEngine()
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

    func testRapidPollingDoesNotAccelerateTime() {
        let engine = SmartCurveEngine()
        var t: TimeInterval = 1000.0
        // Establish baseline at 50C
        _ = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)

        // Poll 10 times with tiny dt=0.05s (total real time elapsed = 0.5s)
        // With previous 0.25s clamp bug, this would have simulated 2.5s of elapsed time
        var percent: Double = 0
        for _ in 0..<10 {
            t += 0.05
            percent = engine.targetPercent(temperatureC: 75, profile: profile, uptime: t)
        }
        // In 0.5s of real time, the filtered temperature should have moved only slightly,
        // so the fan percent should stay well below 0.50.
        XCTAssertLessThan(percent, 0.40, "Rapid polling must not artificially accelerate EMA filter")
    }

    func testOscillatingNearNinetyDegreesSustainsEmergency() {
        let engine = SmartCurveEngine()
        var t: TimeInterval = 1000.0
        _ = engine.targetPercent(temperatureC: 50, profile: profile, uptime: t)

        // Alternate between 90.5C and 89.5C every 0.5s for 5 seconds total.
        // Hysteresis prevents resetting the counter while temp is >= 85C.
        var finalPercent: Double = 0
        for i in 0..<10 {
            t += 0.5
            let temp = (i % 2 == 0) ? 90.5 : 89.5
            finalPercent = engine.targetPercent(temperatureC: temp, profile: profile, uptime: t)
        }
        // Cumulative time at >= 90C is 5 * 0.5 = 2.5s, wait: if 90.5 is fed 5 times at 0.5s each, dt=2.5s.
        // Let's run for 8 seconds total (8 samples at 90.5C * 0.5s = 4s >= 3.5s).
        for i in 0..<6 {
            t += 0.5
            let temp = (i % 2 == 0) ? 90.5 : 89.5
            finalPercent = engine.targetPercent(temperatureC: temp, profile: profile, uptime: t)
        }
        XCTAssertEqual(finalPercent, 1.0, accuracy: 0.0001, "Oscillating around 90C must sustain emergency and not reset counter")
    }

    func testSlewRateRampsSmoothlyAboveFloors() {
        let engine = SmartCurveEngine()
        var t: TimeInterval = 1000.0
        // Initial sample at 80C hits warm floor (0.85)
        let initial = engine.targetPercent(temperatureC: 80, profile: profile, uptime: t)
        XCTAssertEqual(initial, 0.85, accuracy: 0.001)

        // Profile with a target of 1.0 at 82C
        let highProfile = CurveProfile(
            name: "High",
            points: [
                CurvePoint(temperatureC: 45, fanPercent: 0.20),
                CurvePoint(temperatureC: 82, fanPercent: 1.00)
            ]
        )
        // At t + 1s, temp is 82C (warm response). It should ramp from 0.85 towards 1.0
        // at warmRisePerSecond (0.05/sec), NOT jump instantly to 1.0!
        t += 1.0
        let ramped = engine.targetPercent(temperatureC: 82, profile: highProfile, uptime: t)
        XCTAssertLessThan(ramped, 0.95, "Warm response above floor must slew gradually, not snap instantly to desired target")
        XCTAssertGreaterThan(ramped, 0.85, "Warm response must ramp upwards from floor")
    }
}
