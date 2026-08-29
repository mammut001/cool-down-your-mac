import XCTest
import CoolDownKit

final class ThermalPollingPolicyTests: XCTestCase {
    func testIntelCoolLowLoadTemperatureUsesFourSecondCache() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(
                controlTemperatureC: 55,
                isIntel: true,
                cpuLoadPercent: 20
            ),
            4.0,
            accuracy: 0.0001
        )
    }

    func testIntelSeventyDegreesReturnsToTwoSecondCadence() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(
                controlTemperatureC: 70,
                isIntel: true,
                cpuLoadPercent: 20
            ),
            2.0,
            accuracy: 0.0001
        )
    }

    func testIntelHighCPULoadAcceleratesCoolTemperaturePolling() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(
                controlTemperatureC: 55,
                isIntel: true,
                cpuLoadPercent: 85
            ),
            2.0,
            accuracy: 0.0001
        )
    }

    func testIntelModerateWorkloadAlsoReturnsToTwoSecondPolling() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(
                controlTemperatureC: 55,
                isIntel: true,
                cpuLoadPercent: 65
            ),
            2.0,
            accuracy: 0.0001
        )
    }

    func testAppleSiliconKeepsTwoSecondCadence() {
        XCTAssertEqual(
            ThermalPollingPolicy.temperatureCacheLifetime(
                controlTemperatureC: 55,
                isIntel: false,
                cpuLoadPercent: 10
            ),
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
