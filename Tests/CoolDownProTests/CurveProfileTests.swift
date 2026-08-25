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

    func testDescendingFanCurveIsNormalizedToSafeNondecreasingSpeeds() {
        let unsafe = CurveProfile(
            name: "Unsafe",
            points: [
                CurvePoint(temperatureC: 45, fanPercent: 0.60),
                CurvePoint(temperatureC: 70, fanPercent: 0.20),
                CurvePoint(temperatureC: 90, fanPercent: 0.90)
            ]
        )

        XCTAssertEqual(unsafe.points.map(\.fanPercent), [0.60, 0.60, 0.90])
        XCTAssertGreaterThanOrEqual(unsafe.fanPercent(for: 70), unsafe.fanPercent(for: 45))
    }

    func testDecodedDescendingFanCurveIsNormalizedForExistingSettings() throws {
        let data = """
        {"name":"Unsafe","points":[
          {"temperatureC":45,"fanPercent":0.7},
          {"temperatureC":75,"fanPercent":0.3}
        ]}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CurveProfile.self, from: data)
        XCTAssertEqual(decoded.points.map(\.fanPercent), [0.70, 0.70])
    }

    func testEmptyPointsUseSafeDefault() {
        let empty = CurveProfile(name: "Empty", points: [])
        XCTAssertEqual(empty.fanPercent(for: 80), 0.3, accuracy: 0.0001)
    }

    func testBalancedDefaultReachesFullFanByEightyTwo() {
        let balanced = CurveProfile()
        XCTAssertEqual(balanced.fanPercent(for: 78), 0.90, accuracy: 0.0001)
        XCTAssertEqual(balanced.fanPercent(for: 82), 1.0, accuracy: 0.0001)
        XCTAssertEqual(balanced.fanPercent(for: 100), 1.0, accuracy: 0.0001)
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

    func testNewSettingsDoNotEnableAlertsBeforeUserOptIn() {
        XCTAssertFalse(AppSettings().alertsEnabled)
    }

    func testLegacySettingsWithoutAlertPreferenceRemainOptedOut() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.alertsEnabled)
    }

    @MainActor
    func testSettingsStoreFlushPersistsPendingEdits() {
        let suiteName = "CoolDownProTests.Settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.settings.manualPercent = 0.73
        store.settings.showTemperatureInMenuBar = false
        store.flush()

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.manualPercent, 0.73, accuracy: 0.0001)
        XCTAssertFalse(reloaded.settings.showTemperatureInMenuBar)
    }

    func testLegacyUntouchedDefaultMigratesToNewBalancedPreset() throws {
        let data = """
        {
          "curve": {
            "name": "Default",
            "points": [
              {"temperatureC":45,"fanPercent":0.15},
              {"temperatureC":55,"fanPercent":0.30},
              {"temperatureC":65,"fanPercent":0.50},
              {"temperatureC":75,"fanPercent":0.75},
              {"temperatureC":85,"fanPercent":1.00}
            ],
            "hysteresisC": 2.0
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.curve.fanPercent(for: 82), 1.0, accuracy: 0.0001)
        XCTAssertFalse(decoded.curve.usesLegacyDefaultPoints)
        XCTAssertTrue(decoded.curve.points.count == CurveProfile.defaultPoints.count)
    }

    func testLegacyPointsWithCustomHysteresisIsPreserved() throws {
        let data = """
        {
          "curve": {
            "name": "Default",
            "points": [
              {"temperatureC":45,"fanPercent":0.15},
              {"temperatureC":55,"fanPercent":0.30},
              {"temperatureC":65,"fanPercent":0.50},
              {"temperatureC":75,"fanPercent":0.75},
              {"temperatureC":85,"fanPercent":1.00}
            ],
            "hysteresisC": 3.5
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.curve.hysteresisC, 3.5, accuracy: 0.0001)
        XCTAssertEqual(decoded.curve.name, "Default")
        XCTAssertEqual(decoded.curve.points.count, 5)
        XCTAssertEqual(decoded.curve.fanPercent(for: 85), 1.00, accuracy: 0.0001)
        XCTAssertEqual(decoded.curve.fanPercent(for: 82), 0.925, accuracy: 0.0001)
    }

    func testLegacyPointsWithCustomNameIsPreserved() throws {
        let data = """
        {
          "curve": {
            "name": "QuietProfile",
            "points": [
              {"temperatureC":45,"fanPercent":0.15},
              {"temperatureC":55,"fanPercent":0.30},
              {"temperatureC":65,"fanPercent":0.50},
              {"temperatureC":75,"fanPercent":0.75},
              {"temperatureC":85,"fanPercent":1.00}
            ],
            "hysteresisC": 2.0
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.curve.name, "QuietProfile")
        XCTAssertEqual(decoded.curve.hysteresisC, 2.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.curve.points.count, 5)
        XCTAssertEqual(decoded.curve.fanPercent(for: 82), 0.925, accuracy: 0.0001)
    }

    func testCustomPointsArePreserved() throws {
        let data = """
        {
          "curve": {
            "name": "Default",
            "points": [
              {"temperatureC":45,"fanPercent":0.20},
              {"temperatureC":85,"fanPercent":0.80}
            ],
            "hysteresisC": 2.0
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.curve.points.count, 2)
        XCTAssertEqual(decoded.curve.fanPercent(for: 85), 0.80, accuracy: 0.0001)
    }

    func testCPULoadCalculatorComputesCorrectPercentages() {
        // 1 core: 50 user, 10 system, 140 idle, 0 nice -> 60 busy / 200 total = 30%
        let prev: [UInt32] = [1000, 500, 5000, 100]
        let cur: [UInt32] = [1050, 510, 5140, 100]
        let load = CPULoadCalculator.computeSystemLoadPercent(currentTicks: cur, previousTicks: prev)
        XCTAssertNotNil(load)
        XCTAssertEqual(load!, 30.0, accuracy: 0.001)
    }

    func testCPULoadCalculatorHandlesMultiCoreAggregate() {
        // 18-core machine: 15 cores 100% busy (100 ticks user, 0 idle), 3 cores 100% idle (0 user, 100 idle)
        var prev: [UInt32] = []
        var cur: [UInt32] = []
        for _ in 0..<15 {
            prev.append(contentsOf: [1000, 0, 1000, 0])
            cur.append(contentsOf: [1100, 0, 1000, 0]) // 100 busy, 100 total
        }
        for _ in 0..<3 {
            prev.append(contentsOf: [1000, 0, 1000, 0])
            cur.append(contentsOf: [1000, 0, 1100, 0]) // 0 busy, 100 total
        }
        // Total busy = 1500, total total = 1800 -> 83.333%
        let load = CPULoadCalculator.computeSystemLoadPercent(currentTicks: cur, previousTicks: prev)
        XCTAssertNotNil(load)
        XCTAssertEqual(load!, 1500.0 / 1800.0 * 100.0, accuracy: 0.001)
    }

    func testCPULoadCalculatorHandles32BitTickWraparound() {
        // Wraparound test: prev near max UInt32, cur wrapped around to small value
        let prev: [UInt32] = [0xFFFFFFF0, 0, 0, 0]
        let cur: [UInt32] = [0x00000010, 0, 0, 0] // 32 ticks user, 0 idle
        let load = CPULoadCalculator.computeSystemLoadPercent(currentTicks: cur, previousTicks: prev)
        XCTAssertNotNil(load)
        XCTAssertEqual(load!, 100.0, accuracy: 0.001)
    }

    func testCPULoadCalculatorReturnsNilForInvalidOrEmptyInputs() {
        XCTAssertNil(CPULoadCalculator.computeSystemLoadPercent(currentTicks: [], previousTicks: []))
        XCTAssertNil(CPULoadCalculator.computeSystemLoadPercent(currentTicks: [1, 2, 3], previousTicks: [1, 2, 3]))
        XCTAssertNil(CPULoadCalculator.computeSystemLoadPercent(currentTicks: [1, 2, 3, 4], previousTicks: [1, 2, 3, 4])) // 0 delta
    }
}
