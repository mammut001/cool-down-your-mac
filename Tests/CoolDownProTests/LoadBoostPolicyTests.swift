import XCTest
import CoolDownKit

final class LoadBoostPolicyTests: XCTestCase {
    func testActivationDelayShrinksAsLoadRises() {
        let moderate = LoadBoostPolicy.activationDelaySeconds(loadPercent: 70, threshold: 60)
        let high = LoadBoostPolicy.activationDelaySeconds(loadPercent: 90, threshold: 60)
        XCTAssertGreaterThan(moderate, high)
        XCTAssertEqual(moderate, 2.5, accuracy: 0.0001)
        XCTAssertEqual(high, 1.5, accuracy: 0.0001)
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
