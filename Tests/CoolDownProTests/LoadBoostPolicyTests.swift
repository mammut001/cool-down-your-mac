import XCTest
import CoolDownKit

final class LoadBoostPolicyTests: XCTestCase {
    func testActivationDelayShrinksAsLoadRises() {
        let moderate = LoadBoostPolicy.activationDelaySeconds(loadPercent: 70, threshold: 60)
        let high = LoadBoostPolicy.activationDelaySeconds(loadPercent: 90, threshold: 60)
        XCTAssertGreaterThan(moderate, high)
        XCTAssertEqual(moderate, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(high, 0.0, accuracy: 0.0001)
    }

    func testThresholdBoundaryHasNoNormalizedExcessOrBoost() {
        for load in [0.0, 60.0] {
            XCTAssertEqual(
                LoadBoostPolicy.normalizedExcess(loadPercent: load, threshold: 60),
                0,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                LoadBoostPolicy.desiredBoost(loadPercent: load, threshold: 60, boostMax: 0.20),
                0,
                accuracy: 0.0001
            )
        }
    }

    func testNearThresholdActivationFitsTheNextTwoSecondTick() {
        for load in [62.0, 65.0, 66.5] {
            XCTAssertLessThanOrEqual(
                LoadBoostPolicy.activationDelaySeconds(loadPercent: load, threshold: 60),
                2.0
            )
        }

        XCTAssertEqual(
            LoadBoostPolicy.activationDelaySeconds(loadPercent: 66.5, threshold: 60),
            47.0 / 30.0,
            accuracy: 0.0001
        )
    }

    func testActivationDelayGetsShorterThroughModerateAndHighLoad() {
        let nearThreshold = LoadBoostPolicy.activationDelaySeconds(loadPercent: 66.5, threshold: 60)
        let moderate = LoadBoostPolicy.activationDelaySeconds(loadPercent: 70, threshold: 60)
        let high = LoadBoostPolicy.activationDelaySeconds(loadPercent: 80, threshold: 60)
        let veryHigh = LoadBoostPolicy.activationDelaySeconds(loadPercent: 90, threshold: 60)

        XCTAssertLessThan(moderate, nearThreshold)
        XCTAssertLessThanOrEqual(high, 1.0)
        XCTAssertLessThan(high, moderate)
        XCTAssertLessThan(veryHigh, high)
    }

    func testVeryHighLoadCanActivateImmediately() {
        XCTAssertEqual(
            LoadBoostPolicy.activationDelaySeconds(loadPercent: 90, threshold: 60),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LoadBoostPolicy.activationDelaySeconds(loadPercent: 100, threshold: 60),
            0,
            accuracy: 0.0001
        )
    }

    func testActivationDelayIsMonotonicAsLoadRises() {
        let loads = [61.0, 65.0, 70.0, 80.0, 90.0, 100.0]
        let delays = loads.map {
            LoadBoostPolicy.activationDelaySeconds(loadPercent: $0, threshold: 60)
        }

        for pair in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1, pair.0)
        }
    }

    func testModerateLoadGetsUsefulProgressiveBoost() {
        let boost = LoadBoostPolicy.desiredBoost(
            loadPercent: 70,
            threshold: 60,
            boostMax: 0.20
        )
        XCTAssertGreaterThan(boost, 0.075)
        XCTAssertLessThan(boost, 0.09)
    }

    func testHighLoadApproachesConfiguredBoostMax() {
        let boost = LoadBoostPolicy.desiredBoost(
            loadPercent: 90,
            threshold: 60,
            boostMax: 0.20
        )
        XCTAssertGreaterThan(boost, 0.16)
        XCTAssertLessThanOrEqual(boost, 0.20)
    }

    func testLoadBelowThresholdHasNoBoost() {
        XCTAssertEqual(
            LoadBoostPolicy.desiredBoost(loadPercent: 55, threshold: 60, boostMax: 0.20),
            0,
            accuracy: 0.0001
        )
    }

    func testRiseTimeGetsFasterAtHigherLoad() {
        let moderate = LoadBoostPolicy.riseTimeConstantSeconds(loadPercent: 70, threshold: 60)
        let high = LoadBoostPolicy.riseTimeConstantSeconds(loadPercent: 90, threshold: 60)
        XCTAssertGreaterThan(moderate, high)
        XCTAssertEqual(moderate, 2.625, accuracy: 0.0001)
        XCTAssertEqual(high, 1.875, accuracy: 0.0001)
    }
}
