import Foundation
import IOKit
import Darwin

/// Userspace AppleSMC bridge. Floats on Apple Silicon are native-endian.
final class SMCKit {
    enum SMCError: Error, LocalizedError {
        case serviceNotFound
        case openFailed
        case keyNotFound(String)
        case ioFailed(String)
        case noControllableFans

        var errorDescription: String? {
            switch self {
            case .serviceNotFound: return "AppleSMC service not found"
            case .openFailed: return "Failed to open AppleSMC connection"
            case .keyNotFound(let key): return "SMC key not found: \(key)"
            case .ioFailed(let key): return "SMC I/O failed: \(key)"
            case .noControllableFans:
                return "Fan control is not available on this Mac yet"
            }
        }
    }

    private var connection: io_connect_t = 0

    init() throws {
        // Apple Silicon exposes both services. KeysEndpoint is useful for
        // telemetry, but on this Mac it accepts F*Tg writes without applying
        // them. Fan control must go through the AppleSMC connection itself.
        // Keep KeysEndpoint only as a read fallback for future hardware.
        let candidates = ["AppleSMC", "AppleSMCKeysEndpoint"]
        var lastOpenFailed = false
        for name in candidates {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }
            var conn: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
            if kr == KERN_SUCCESS, conn != 0 {
                connection = conn
                return
            }
            lastOpenFailed = true
        }
        throw lastOpenFailed ? SMCError.openFailed : SMCError.serviceNotFound
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func fanCount() throws -> Int {
        let declared = Int(try readBytes(key: "FNum")[0])
        if declared > 0 { return declared }
        // Newer Apple Silicon models can expose per-fan keys while reporting
        // zero (or an unavailable value) for the legacy FNum key.
        return discoverFanIndices().count
    }

    func readFans() throws -> [SMCFanReading] {
        let indices = try fanIndices()
        var fans: [SMCFanReading] = []
        for index in indices {
            let name = (try? fanName(index: index)) ?? "Fan \(index)"
            let minRPM = Double((try? readFloat(key: "F\(index)Mn")) ?? 1000)
            let maxRPM = Double((try? readFloat(key: "F\(index)Mx")) ?? 6000)
            let current = Double((try? readFloat(key: "F\(index)Ac")) ?? 0)
            let target = try? readFloat(key: "F\(index)Tg")
            let mode = (try? readBytes(key: "F\(index)Md"))?.first ?? 0
            fans.append(
                SMCFanReading(
                    index: index,
                    name: name,
                    minRPM: minRPM,
                    maxRPM: maxRPM,
                    currentRPM: current,
                    targetRPM: target.map(Double.init),
                    isManual: mode != 0
                )
            )
        }
        return fans
    }

    func readTemperatures() -> [SMCTempReading] {
        var results: [SMCTempReading] = []
        let count = (try? keyCount()) ?? 0
        if count > 0 {
            for index in 0..<count {
                guard let key = try? keyAt(index: index) else { continue }
                guard key.first == "T" || key.first == "t" else { continue }
                guard let value = try? readTemperatureValue(key: key) else { continue }
                guard value > 5, value < 110 else { continue }
                results.append(
                    SMCTempReading(key: key, name: SMCKnownNames.name(for: key), celsius: value)
                )
            }
        } else {
            for entry in SMCKnownNames.fallbackKeys {
                guard let value = try? readTemperatureValue(key: entry.key) else { continue }
                guard value > 5, value < 110 else { continue }
                results.append(SMCTempReading(key: entry.key, name: entry.name, celsius: value))
            }
        }
        return results
    }

    func setFanManual(index: Int, enabled: Bool) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = enabled ? 1 : 0
        // M5 models use a lowercase `md` suffix; earlier Apple Silicon uses
        // `Md`. A target write without a successful mode switch is ignored by
        // thermalmonitord, so probe both and never silently pretend it worked.
        let keys = ["F\(index)Md", "F\(index)md"]
        var lastError: Error?
        for key in keys {
            do {
                try writeBytes(key: key, bytes: bytes, type: "ui8 ", size: 1)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SMCError.keyNotFound("F\(index)Md/F\(index)md")
    }

    func setFanRPM(index: Int, rpm: Double) throws {
        let minRPM = Double((try? readFloat(key: "F\(index)Mn")) ?? 1350)
        let maxRPM = Double((try? readFloat(key: "F\(index)Mx")) ?? 6000)
        let lo = minRPM > 200 ? minRPM : 1350
        let hi = maxRPM > lo ? maxRPM : max(lo + 1000, 6000)
        let clamped = min(max(rpm, lo), hi)
        try setFanManual(index: index, enabled: true)
        try writeFloat(key: "F\(index)Tg", value: Float(clamped))
    }

    func setAllFansAuto() throws {
        let indices = try fanIndices()
        guard !indices.isEmpty else { throw SMCError.noControllableFans }
        var restored = false
        for index in indices {
            do {
                try setFanManual(index: index, enabled: false)
                restored = true
            } catch {
                continue
            }
        }
        // If mode keys are absent, clear targets so firmware resumes automatic control.
        if !restored {
            for index in indices {
                try? writeFloat(key: "F\(index)Tg", value: 0)
            }
        }
    }

    func setAllFansPercent(_ percent: Double) throws {
        let p = min(max(percent, 0), 1)
        let fans = try readFans()
        // Never report a successful manual change when discovery found no
        // writable fans. On newer Macs that would make the slider a no-op.
        guard !fans.isEmpty else { throw SMCError.noControllableFans }
        for fan in fans {
            let lo = fan.minRPM > 200 ? fan.minRPM : 1350
            let hi = fan.maxRPM > lo ? fan.maxRPM : max(lo + 1000, 6000)
            try setFanRPM(index: fan.index, rpm: lo + (hi - lo) * p)
        }
    }

    var canControlFans: Bool {
        guard let indices = try? fanIndices() else { return false }
        return !indices.isEmpty
    }

    /// Diagnostics used to select the correct write encoding on each Mac.
    func fanKeyDescriptions() -> [String] {
        let indices = (try? fanIndices()) ?? []
        return indices.flatMap { index in
            ["F\(index)Ac", "F\(index)Tg", "F\(index)Mn", "F\(index)Mx", "F\(index)Md", "F\(index)md"].map { key in
                if let info = try? readInfo(key: key) {
                    return "\(key) type=\(info.type) size=\(info.size)"
                }
                return "\(key) unavailable"
            }
        }
    }

    private func fanIndices() throws -> [Int] {
        let declared = Int(try readBytes(key: "FNum")[0])
        if declared > 0 { return Array(0..<declared) }
        return discoverFanIndices()
    }

    /// Macs Fan Control confirms this machine has two fans, but the M5 Pro's
    /// legacy FNum key reports zero. Probe the standard per-fan actual-RPM
    /// keys as a safe fallback; a key must be readable before we offer writes.
    private func discoverFanIndices() -> [Int] {
        (0..<8).filter { index in
            guard let rpm = try? readFloat(key: "F\(index)Ac") else { return false }
            return rpm.isFinite && rpm >= 0
        }
    }

    // MARK: Private

    private func keyCount() throws -> Int {
        let bytes = try readBytes(key: "#KEY")
        let count = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Int(count)
    }

    private func keyAt(index: Int) throws -> String {
        var input = blankKeyData()
        var output = blankKeyData()
        input.data8 = CChar(bitPattern: UInt8(kSMCGetKeyFromIndex))
        input.data32 = UInt32(index)
        try invoke(input: &input, output: &output)
        return fourCCString(output.key)
    }

    private func fanName(index: Int) throws -> String {
        let bytes = try readBytes(key: String(format: "F%dID", index))
        let chars = bytes.dropFirst(4).prefix(while: { $0 != 0 }).map { Character(UnicodeScalar($0)) }
        let name = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Fan \(index)" : name
    }

    private func readTemperatureValue(key: String) throws -> Double {
        let (type, size, bytes) = try readInfo(key: key)
        if type == "flt " || type == "ioft" || size == 4 {
            return Double(nativeFloat(bytes))
        }
        if type.hasPrefix("sp") || size == 2 {
            let hi = Int8(bitPattern: bytes[0])
            return Double(hi) + Double(bytes[1]) / 256.0
        }
        return Double(nativeFloat(bytes))
    }

    private func readFloat(key: String) throws -> Float {
        nativeFloat(try readBytes(key: key))
    }

    private func writeFloat(key: String, value: Float) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        var v = value
        withUnsafeBytes(of: &v) { buf in
            for i in 0..<4 { bytes[i] = buf[i] }
        }
        try writeBytes(key: key, bytes: bytes, type: "flt ", size: 4)
    }

    private func readBytes(key: String) throws -> [UInt8] {
        try readInfo(key: key).bytes
    }

    private func readInfo(key: String) throws -> (type: String, size: UInt32, bytes: [UInt8]) {
        var input = blankKeyData()
        var output = blankKeyData()
        input.key = fourCC(key)
        input.data8 = CChar(bitPattern: UInt8(kSMCGetKeyInfo))
        try invoke(input: &input, output: &output)

        var readInput = blankKeyData()
        var readOutput = blankKeyData()
        readInput.key = input.key
        readInput.data8 = CChar(bitPattern: UInt8(kSMCReadKey))
        readInput.keyInfo.dataSize = output.keyInfo.dataSize
        readInput.keyInfo.dataType = output.keyInfo.dataType
        try invoke(input: &readInput, output: &readOutput)

        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: readOutput.bytes) { buf in
            let raw = buf.bindMemory(to: UInt8.self)
            for i in 0..<min(32, raw.count) {
                bytes[i] = raw[i]
            }
        }
        return (fourCCString(output.keyInfo.dataType), output.keyInfo.dataSize, bytes)
    }

    private func writeBytes(key: String, bytes: [UInt8], type: String, size: UInt32) throws {
        var input = blankKeyData()
        var output = blankKeyData()
        input.key = fourCC(key)
        input.data8 = CChar(bitPattern: UInt8(kSMCWriteKey))
        input.keyInfo.dataSize = size
        input.keyInfo.dataType = fourCC(type)
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            let raw = buf.bindMemory(to: UInt8.self)
            for i in 0..<min(32, bytes.count, raw.count) {
                raw[i] = bytes[i]
            }
        }
        try invoke(input: &input, output: &output)
    }

    private func invoke(input: inout SMCKeyData, output: inout SMCKeyData) throws {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            UInt32(kSMCHandleYPCEvent),
            &input,
            inputSize,
            &output,
            &outputSize
        )
        let key = fourCCString(input.key)
        guard kr == KERN_SUCCESS else { throw SMCError.ioFailed(key) }
        guard output.result == 0 else { throw SMCError.keyNotFound(key) }
    }

    private func nativeFloat(_ bytes: [UInt8]) -> Float {
        var value: Float = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            bytes.prefix(4).withUnsafeBytes { src in
                src.copyBytes(to: dest)
            }
        }
        return value
    }

    private func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for scalar in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(scalar)
        }
        return result
    }

    private func fourCCString(_ value: UInt32) -> String {
        let chars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: chars, encoding: .macOSRoman) ?? ""
    }
}

private func blankKeyData() -> SMCKeyData {
    var data = SMCKeyData()
    memset(&data, 0, MemoryLayout<SMCKeyData>.size)
    return data
}


