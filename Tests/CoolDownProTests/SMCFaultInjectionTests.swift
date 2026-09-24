import XCTest

final class SMCFaultInjectionTests: XCTestCase {
    func testTemperatureReadFailuresNeverReturnLastGoodSample() {
        let device = FakeSMC()
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertEqual(kit.readTemperatures().first?.celsius, 42)
        device.setTemperature(50)
        device.failedReads["TC0P"] = 2
        XCTAssertTrue(kit.readTemperatures().isEmpty)
        XCTAssertTrue(kit.readTemperatures().isEmpty)
        XCTAssertEqual(kit.readTemperatures().first?.celsius, 50)
    }

    func testSecondFanTargetWriteFailureRollsBackBothModes() throws {
        let device = FakeSMC()
        device.failedWrites["F1Tg"] = 1
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertThrowsError(try kit.setAllFansPercent(0.5))
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
        XCTAssertTrue(device.writtenKeys.contains("F0Tg"))
        XCTAssertTrue(device.writtenKeys.contains("F1Tg"))
    }

    func testSecondFanModeWriteFailureRollsBackFirstFan() {
        let device = FakeSMC()
        device.failedWrites["F1md"] = 1
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertThrowsError(try kit.setAllFansPercent(0.5))
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testMissingFNumFallsBackToActualFanKeys() throws {
        let device = FakeSMC()
        device.removeKey("FNum")
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertEqual(try kit.fanCount(), 2)
        try kit.setAllFansPercent(0.5)
        XCTAssertEqual(device.mode(0), 1)
        XCTAssertEqual(device.mode(1), 1)
    }

    func testAcknowledgedButIgnoredTargetWriteFailsReadBack() {
        let device = FakeSMC()
        device.ignoredWrites.insert("F0Tg")
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertThrowsError(try kit.setFanRPM(index: 0, rpm: 3000))
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.target(0), 1500, accuracy: 1)
    }

    func testFailedAutoRestoreRaisesAffectedTargetThenCanRetry() throws {
        let device = FakeSMC()
        device.setMode(0, 1)
        device.setMode(1, 1)
        device.failedAutoWrites["F1md"] = 1
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertThrowsError(try kit.setAllFansAuto())
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 1)
        XCTAssertEqual(device.target(1), 5000, accuracy: 1)

        try kit.setAllFansAuto()
        XCTAssertEqual(device.mode(0), 0)
        XCTAssertEqual(device.mode(1), 0)
    }

    func testDelayedTargetReadBackEventuallyConfirmsWrite() throws {
        let device = FakeSMC()
        device.staleTargetReads["F0Tg"] = 2
        let kit = SMCKit(injecting: device.invoke)

        try kit.setFanRPM(index: 0, rpm: 3000)
        XCTAssertEqual(device.mode(0), 1)
        XCTAssertEqual(device.target(0), 3000, accuracy: 1)
        XCTAssertEqual(device.staleTargetReads["F0Tg"], 0)
    }

    func testPersistentTargetReadFailureReturnsToAuto() throws {
        let device = FakeSMC()
        device.staleTargetReads["F0Tg"] = 10
        let kit = SMCKit(injecting: device.invoke)

        XCTAssertThrowsError(try kit.setFanRPM(index: 0, rpm: 3000))
        XCTAssertEqual(device.mode(0), 0)
    }
}

final class FakeSMC {
    var failedWrites: [String: Int] = [:]
    var failedAutoWrites: [String: Int] = [:]
    var failedReads: [String: Int] = [:]
    var staleTargetReads: [String: Int] = [:]
    var ignoredWrites: Set<String> = []
    private(set) var writtenKeys: [String] = []
    private var values: [String: [UInt8]] = [:]

    init() {
        values["FNum"] = [2]
        values["TC0P"] = floatBytes(42)
        for index in 0..<2 {
            values["F\(index)Ac"] = floatBytes(1500)
            values["F\(index)Tg"] = floatBytes(1500)
            values["F\(index)Mn"] = floatBytes(1000)
            values["F\(index)Mx"] = floatBytes(5000)
            values["F\(index)md"] = [0]
        }
    }

    func mode(_ index: Int) -> UInt8 { values["F\(index)md"]![0] }
    func target(_ index: Int) -> Float { values["F\(index)Tg"]!.withUnsafeBytes { $0.loadUnaligned(as: Float.self) } }
    func setMode(_ index: Int, _ mode: UInt8) { values["F\(index)md"] = [mode] }
    func setTemperature(_ value: Float) { values["TC0P"] = floatBytes(value) }
    func removeKey(_ key: String) { values.removeValue(forKey: key) }

    func invoke(_ input: inout SMCKeyData, _ output: inout SMCKeyData) throws {
        let key = keyString(input.key)
        let command = UInt8(bitPattern: input.data8)
        guard let stored = values[key] else {
            output.result = 1
            return
        }

        switch Int(command) {
        case kSMCGetKeyInfo:
            let type = key == "FNum" || key.hasSuffix("md") ? "ui8 " : "flt "
            output.keyInfo.dataSize = UInt32(stored.count)
            output.keyInfo.dataType = fourCC(type)
        case kSMCReadKey:
            if let remaining = failedReads[key], remaining > 0 {
                failedReads[key] = remaining - 1
                throw SMCKit.SMCError.ioFailed(key)
            }
            var bytes = stored
            if key.hasSuffix("Tg"), writtenKeys.contains(key),
               let remaining = staleTargetReads[key], remaining > 0 {
                staleTargetReads[key] = remaining - 1
                bytes = floatBytes(0)
            }
            withUnsafeMutableBytes(of: &output.bytes) { destination in
                destination.copyBytes(from: bytes)
            }
        case kSMCWriteKey:
            writtenKeys.append(key)
            if values[key]?.first != 0, key.hasSuffix("md"),
               let remaining = failedAutoWrites[key], remaining > 0,
               withUnsafeBytes(of: input.bytes, { $0[0] }) == 0 {
                failedAutoWrites[key] = remaining - 1
                throw SMCKit.SMCError.ioFailed(key)
            }
            if let remaining = failedWrites[key], remaining > 0 {
                failedWrites[key] = remaining - 1
                throw SMCKit.SMCError.ioFailed(key)
            }
            if ignoredWrites.contains(key) { return }
            values[key] = withUnsafeBytes(of: input.bytes) { Array($0.prefix(stored.count)) }
        default:
            XCTFail("Unexpected fake SMC command \(command)")
        }
    }

    private func keyString(_ key: UInt32) -> String {
        String(bytes: [UInt8(key >> 24), UInt8((key >> 16) & 0xff), UInt8((key >> 8) & 0xff), UInt8(key & 0xff)], encoding: .ascii)!
    }

    private func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func floatBytes(_ value: Float) -> [UInt8] {
        var copy = value
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}
