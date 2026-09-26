import XCTest

/// Invariants from Docs/FAN_SAFETY_INVARIANTS.md that the SMC and helper
/// layers must hold on every path, including failures.
final class FanSafetyInvariantTests: XCTestCase {
    override func tearDown() {
        HelperService.resetForTests()
        super.tearDown()
    }

    private let allowedWrite = try! NSRegularExpression(pattern: "^F[0-9](Md|md|Tg)$")

    private func assertOnlyFanKeysWritten(_ device: FakeSMC, file: StaticString = #filePath, line: UInt = #line) {
        for key in device.writtenKeys {
            let range = NSRange(key.startIndex..., in: key)
            XCTAssertNotNil(allowedWrite.firstMatch(in: key, range: range), "wrote \(key)", file: file, line: line)
        }
    }

    // I1: The app writes only fan mode and fan target keys.
    func testI1EveryWritePathTouchesOnlyFanModeAndTargetKeys() throws {
        let normal = FakeSMC()
        let kit = SMCKit(injecting: normal.invoke)
        try kit.setAllFansPercent(0.5)
        try kit.setFanRPM(index: 1, rpm: 2500)
        try kit.setAllFansAuto()
        assertOnlyFanKeysWritten(normal)

        let failedTarget = FakeSMC()
        failedTarget.failedWrites["F1Tg"] = 1
        XCTAssertThrowsError(try SMCKit(injecting: failedTarget.invoke).setAllFansPercent(0.5))
        assertOnlyFanKeysWritten(failedTarget)

        let failedAuto = FakeSMC()
        failedAuto.setMode(1, 1)
        failedAuto.failedAutoWrites["F1md"] = 1
        XCTAssertThrowsError(try SMCKit(injecting: failedAuto.invoke).setAllFansAuto())
        assertOnlyFanKeysWritten(failedAuto)
    }

    // I2: A manual target never leaves the fan's reported minimum...maximum.
    func testI2ManualTargetsStayWithinReportedFanRange() throws {
        let device = FakeSMC()
        let kit = SMCKit(injecting: device.invoke)

        try kit.setFanRPM(index: 0, rpm: 1)
        XCTAssertEqual(device.target(0), 1000, accuracy: 1)
        try kit.setFanRPM(index: 0, rpm: 1_000_000)
        XCTAssertEqual(device.target(0), 5000, accuracy: 1)

        for percent in [-3.0, 0, 1, 7] {
            try kit.setAllFansPercent(percent)
            for index in 0..<2 {
                XCTAssertGreaterThanOrEqual(device.target(index), 999)
                XCTAssertLessThanOrEqual(device.target(index), 5001)
            }
        }
    }

    // I2: The helper rejects malformed requests before touching the SMC.
    func testI2HelperRejectsInvalidRequestsWithoutWriting() {
        let device = FakeSMC()
        HelperService.configureForTests(openSMC: { SMCKit(injecting: device.invoke) })
        let client = HelperService()

        for percent in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertNotNil(reply { client.setFansPercent(percent, reply: $0) })
        }
        for (index, rpm) in [(0, Double.nan), (0, 100), (0, 20_000), (9, 3000), (-1, 3000)] {
            XCTAssertNotNil(reply { client.setFanRPM(index: index, rpm: rpm, reply: $0) })
        }
        XCTAssertTrue(device.writtenKeys.isEmpty)
    }

    private func reply(_ call: (@escaping (NSError?) -> Void) -> Void) -> NSError? {
        let done = DispatchSemaphore(value: 0)
        var result: NSError?
        call { error in
            result = error
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 4), .success)
        return result
    }
}
