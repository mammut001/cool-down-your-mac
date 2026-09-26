import XCTest
import CoolDownKit

final class TemperatureTrustTests: XCTestCase {
    private func reading(_ key: String, _ celsius: Double, group: SensorGroup = .other, auxiliary: Bool = false) -> TemperatureReading {
        TemperatureReading(key: key, name: key, celsius: celsius, group: group, isAuxiliary: auxiliary)
    }

    func testCorroboratedHotDieSensorDrivesControl() {
        let control = SensorCatalog.controlReadings(
            smc: [reading("Tp01", 112), reading("Tp02", 96), reading("Tg05", 70)],
            hid: []
        )
        XCTAssertEqual(control.map(\.celsius).max(), 112)
    }

    func testHotSensorsAboveOldCeilingStillCountWhenAllCPUReadingsAreHot() {
        // Previously every CPU value >= 115 was dropped and a cool GPU became
        // the control temperature, suppressing the Manual and curve safeties.
        let control = SensorCatalog.controlReadings(
            smc: [reading("Tp01", 118), reading("Tp02", 117), reading("Tg05", 80)],
            hid: [reading("hid.cpu.die", 116, group: .cpu)]
        )
        XCTAssertEqual(control.map(\.celsius).max(), 118)
    }

    func testIsolatedGlitchAndImpossibleValuesAreRejected() {
        let control = SensorCatalog.controlReadings(
            smc: [reading("Tp01", 127), reading("Tp02", 52), reading("Tp03", 200)],
            hid: []
        )
        XCTAssertEqual(control.map(\.celsius).max(), 52)
    }

    func testAuxiliaryFixedPointSensorsNeverDriveControlOrGPUList() {
        let battery = reading("TG0B", 60, auxiliary: true)
        let control = SensorCatalog.controlReadings(smc: [battery, reading("Tp01", 45)], hid: [])
        XCTAssertEqual(control.map(\.key), ["Tp01"])
        XCTAssertEqual(SensorMerge.annotateSMC(battery).group, .other)
        let curated = SensorCatalog.curated(smc: [battery, reading("Tp01", 45)], hid: [])
        XCTAssertFalse(curated.contains { $0.key == "TG0B" })
    }

    func testAlertTemperatureIncludesCorroboratedHotReading() {
        let snapshot = SensorSnapshot(
            temperatures: [reading("Tp01", 116, group: .cpu), reading("Tp02", 101, group: .cpu)]
        )
        XCTAssertEqual(snapshot.maxTemperatureC, 116)
    }
}

final class ThermalOverrideLatchTests: XCTestCase {
    func testHysteresisAndHoldPreventFlapping() {
        var latch = ThermalOverrideLatch()
        XCTAssertNil(latch.update(temperatureC: 80, now: 0))
        XCTAssertEqual(latch.update(temperatureC: 95, now: 1), 1.0)
        XCTAssertEqual(latch.update(temperatureC: 93, now: 3), 1.0)
        XCTAssertEqual(latch.update(temperatureC: 89, now: 5), 1.0, "minimum hold")
        XCTAssertEqual(latch.update(temperatureC: 89, now: 12), 0.75)
        XCTAssertEqual(latch.update(temperatureC: 86, now: 14), 0.75)
        XCTAssertEqual(latch.update(temperatureC: 84, now: 30), nil)
    }

    func testOscillationAtThresholdHoldsFullSpeed() {
        var latch = ThermalOverrideLatch()
        for step in 0..<20 {
            let temperature = step.isMultiple(of: 2) ? 95.0 : 94.9
            XCTAssertEqual(latch.update(temperatureC: temperature, now: Double(step) * 2), 1.0)
        }
    }

    func testEscalationIsImmediateDuringHold() {
        var latch = ThermalOverrideLatch()
        XCTAssertEqual(latch.update(temperatureC: 91, now: 0), 0.75)
        XCTAssertEqual(latch.update(temperatureC: 96, now: 1), 1.0)
    }

    func testMissingTemperatureResets() {
        var latch = ThermalOverrideLatch()
        XCTAssertEqual(latch.update(temperatureC: 96, now: 0), 1.0)
        XCTAssertNil(latch.update(temperatureC: nil, now: 1))
        XCTAssertNil(latch.update(temperatureC: 80, now: 2))
    }
}

final class FanCommandVerificationTests: XCTestCase {
    private func fan(target: Double?, manual: Bool) -> FanInfo {
        FanInfo(index: 0, name: "Fan", minRPM: 1000, maxRPM: 5000, currentRPM: 3000, targetRPM: target, isManual: manual)
    }

    func testMatchingManualStateIsNotDrift() {
        XCTAssertFalse(FanCommandVerification.manualCommandHasDrifted(percent: 0.5, fans: [fan(target: 3000, manual: true)]))
        XCTAssertFalse(FanCommandVerification.manualCommandHasDrifted(percent: 0.5, fans: [fan(target: nil, manual: true)]))
        XCTAssertFalse(FanCommandVerification.manualCommandHasDrifted(percent: 0.5, fans: []))
    }

    func testExternalAutoOrTargetChangeIsDrift() {
        XCTAssertTrue(FanCommandVerification.manualCommandHasDrifted(percent: 0.5, fans: [fan(target: 3000, manual: false)]))
        XCTAssertTrue(FanCommandVerification.manualCommandHasDrifted(percent: 1.0, fans: [fan(target: 1200, manual: true)]))
    }

    func testExpectedTargetMirrorsHelperFallbacks() {
        XCTAssertEqual(FanCommandVerification.expectedTargetRPM(percent: 0, minRPM: 0, maxRPM: 0), 1350)
        XCTAssertEqual(FanCommandVerification.expectedTargetRPM(percent: 1, minRPM: 0, maxRPM: 0), 6000)
    }
}

final class ReplyTimeoutTests: XCTestCase {
    func testMissingReplyTimesOutAndReportsIt() async {
        let timedOut = expectation(description: "onTimeout")
        do {
            let _: Int = try await awaitReply(timeout: 0.05, onTimeout: { timedOut.fulfill() }) { _ in }
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error is ReplyTimeoutError)
        }
        await fulfillment(of: [timedOut], timeout: 1)
    }

    func testReplyWinsAndTimeoutIsIgnored() async throws {
        let timedOut = expectation(description: "onTimeout")
        timedOut.isInverted = true
        let value: Int = try await awaitReply(timeout: 0.05, onTimeout: { timedOut.fulfill() }) { finish in
            finish(.success(7))
        }
        XCTAssertEqual(value, 7)
        await fulfillment(of: [timedOut], timeout: 0.2)
    }
}

final class SettingsBoundsTests: XCTestCase {
    func testStoredOutOfRangeValuesAreClamped() throws {
        let json = #"{"sampleIntervalSeconds": 60, "curve": {"hysteresisC": 50}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sampleIntervalSeconds, 10)
        XCTAssertEqual(settings.curve.hysteresisC, 5)
    }
}

final class SMCDeeperFaultTests: XCTestCase {
    override func tearDown() {
        HelperService.resetForTests()
        super.tearDown()
    }

    private func ioft(_ celsius: Double) -> [UInt8] {
        let raw = UInt64(celsius * 65536)
        return (0..<8).map { UInt8((raw >> ($0 * 8)) & 0xff) }
    }

    func testFixedPointTemperatureDecodesLittleEndianAndIsAuxiliary() {
        let device = FakeSMC()
        device.setRaw("TG0B", type: "ioft", bytes: ioft(27.6))
        device.enableKeyIndex()
        let kit = SMCKit(injecting: device.invoke)

        let reading = kit.readTemperatures().first { $0.key == "TG0B" }
        XCTAssertEqual(reading?.celsius ?? 0, 27.6, accuracy: 0.01)
        XCTAssertEqual(reading?.isAuxiliary, true)
        XCTAssertEqual(kit.readTemperatures().first { $0.key == "TC0P" }?.isAuxiliary, false)
    }

    func testHotTemperatureIsNotDiscardedAtSource() {
        let device = FakeSMC()
        device.setTemperature(112)
        let kit = SMCKit(injecting: device.invoke)
        XCTAssertEqual(kit.readTemperatures().first?.celsius, 112)
    }

    func testUnreadableModeIsReportedAsManual() throws {
        let device = FakeSMC()
        let kit = SMCKit(injecting: device.invoke)
        XCTAssertEqual(try kit.readFans().map(\.isManual), [false, false])

        device.failedReads["F0md"] = 1
        XCTAssertEqual(try kit.readFans().map(\.isManual), [true, false])
    }

    func testAutoRestoreWithoutModeKeysIsANoOp() throws {
        let device = FakeSMC()
        device.removeKey("F0md")
        device.removeKey("F1md")
        let kit = SMCKit(injecting: device.invoke)

        try kit.setAllFansAuto()
        XCTAssertFalse(device.writtenKeys.contains { $0.hasSuffix("Tg") })
    }

    func testHelperLaunchRestoresManualFansWithoutLease() {
        let device = FakeSMC()
        device.setMode(0, 1)
        device.setMode(1, 1)
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })

        HelperService.reconcileAfterLaunch()
        HelperService.drainForTests()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testHelperLaunchLeavesAutoFansUntouched() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })

        HelperService.reconcileAfterLaunch()
        HelperService.drainForTests()
        XCTAssertTrue(device.writtenKeys.isEmpty)
    }
}
