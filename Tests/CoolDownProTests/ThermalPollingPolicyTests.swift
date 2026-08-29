import XCTest
import CoolDownKit

final class ThermalPollingPolicyTests: XCTestCase {
    func testIntelCoolTemperatureUsesFourSecondCache() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(controlTemperatureC: 55, isIntel: true),
            4.0,
            accuracy: 0.0001
        )
    }

    func testIntelWarmTemperatureTightensToThreeSeconds() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(controlTemperatureC: 75, isIntel: true),
            3.0,
            accuracy: 0.0001
        )
    }

    func testIntelHotTemperatureReturnsToTwoSecondCadence() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(controlTemperatureC: 80, isIntel: true),
            2.0,
            accuracy: 0.0001
        )
    }

    func testAppleSiliconKeepsTwoSecondCadence() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(controlTemperatureC: 55, isIntel: false),
            2.0,
            accuracy: 0.0001
        )
    }

    func testMissingOrInvalidTemperatureUsesSafeTwoSecondCadence() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(controlTemperatureC: nil, isIntel: true),
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(controlTemperatureC: .nan, isIntel: true),
            2.0,
            accuracy: 0.0001
        )
    }
}
