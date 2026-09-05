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
    private var cachedTemperatureKeys: [SMCTempKey]?
    private var cachedTemperatureKeysUptime: TimeInterval = 0
    private var cachedFanMetas: [FanMeta]?
    private var cachedFanMetasUptime: TimeInterval = 0
    private var cachedCanControlFans: Bool?
    private var lastCanControlProbeUptime: TimeInterval = 0

    /// Temperature key discovery is expensive (up to 512 IOConnect calls).
    /// Cache the result for this many seconds before re-scanning.
    private let temperatureKeyCacheSeconds: TimeInterval = 120
    /// Fan metadata changes even less often, but a longer cache is fine.
    private let fanMetaCacheSeconds: TimeInterval = 300

    private struct SMCTempKey {
        let key: String
        let type: String
        let size: UInt32
    }

    private struct FanMeta {
        let index: Int
        let name: String
        let minRPM: Double
        let maxRPM: Double
        let modeKey: String
    }

    init(allowKeysEndpointFallback: Bool = false) throws {
        // Apple Silicon exposes both services. KeysEndpoint accepts F*Tg
        // writes without applying them, so fan control must use AppleSMC.
        // Telemetry-only callers may fall back to KeysEndpoint.
        var candidates = ["AppleSMC"]
        if allowKeysEndpointFallback {
            candidates.append("AppleSMCKeysEndpoint")
        }
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
        let declared = min(8, max(0, Int(try readBytes(key: "FNum")[0])))
        if declared > 0 { return declared }
        // Newer Apple Silicon models can expose per-fan keys while reporting
        // zero (or an unavailable value) for the legacy FNum key.
        return discoverFanIndices().count
    }

    func readFans() throws -> [SMCFanReading] {
        let metas = try fanMetas()
        var fans: [SMCFanReading] = []
        fans.reserveCapacity(metas.count)
        for meta in metas {
            let current = Double((try? readFloat(key: "F\(meta.index)Ac")) ?? 0)
            let target = try? readFloat(key: "F\(meta.index)Tg")
            let mode = (try? readBytes(key: meta.modeKey))?.first ?? 0
            fans.append(
                SMCFanReading(
                    index: meta.index,
                    name: meta.name,
                    minRPM: meta.minRPM,
                    maxRPM: meta.maxRPM,
                    currentRPM: current,
                    targetRPM: target.map(Double.init),
                    isManual: mode != 0
                )
            )
        }
        return fans
    }

    func readTemperatures() -> [SMCTempReading] {
        let keys = discoveredTemperatureKeys()
        var results: [SMCTempReading] = []
        results.reserveCapacity(keys.count)
        var failures = 0
        for entry in keys {
            guard let value = try? readTemperatureValue(key: entry.key, type: entry.type, size: entry.size) else {
                failures += 1
                continue
            }
            guard value > 5, value < 110 else { continue }
            results.append(
                SMCTempReading(key: entry.key, name: SMCKnownNames.name(for: entry.key), celsius: value)
            )
        }
        if !keys.isEmpty, failures * 2 > keys.count {
            cachedTemperatureKeys = nil
        }
        return results
    }

    func invalidateCaches() {
        cachedTemperatureKeys = nil
        cachedTemperatureKeysUptime = 0
        cachedFanMetas = nil
        cachedFanMetasUptime = 0
        cachedCanControlFans = nil
        lastCanControlProbeUptime = 0
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
        try writeTypedFanTarget(key: "F\(index)Tg", rpm: clamped)
    }

    func setAllFansAuto() throws {
        let indices = try fanIndices()
        guard !indices.isEmpty else { throw SMCError.noControllableFans }
        var failures: [Error] = []
        for index in indices {
            do {
                try setFanManual(index: index, enabled: false)
            } catch {
                failures.append(error)
            }
        }
        if failures.count == indices.count {
            for index in indices {
                try writeTypedFanTarget(key: "F\(index)Tg", rpm: 0)
            }
            throw SMCError.ioFailed("setAllFansAuto")
        }
        if !failures.isEmpty {
            throw SMCError.ioFailed("setAllFansAuto")
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
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedCanControlFans {
            if cachedCanControlFans { return true }
            if now - lastCanControlProbeUptime < 8 { return false }
        }
        lastCanControlProbeUptime = now
        let value: Bool = {
            guard let indices = try? fanIndices(), !indices.isEmpty else { return false }
            return indices.contains { index in
                (try? readInfo(key: "F\(index)Md")) != nil || (try? readInfo(key: "F\(index)md")) != nil
            }
        }()
        cachedCanControlFans = value
        return value
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

    private func fanMetas() throws -> [FanMeta] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedFanMetas, !cachedFanMetas.isEmpty, now - cachedFanMetasUptime < fanMetaCacheSeconds {
            return cachedFanMetas
        }
        let indices = try fanIndices()
        let metas = indices.map { index -> FanMeta in
            let modeKey: String
            if (try? readBytes(key: "F\(index)Md")) != nil {
                modeKey = "F\(index)Md"
            } else if (try? readBytes(key: "F\(index)md")) != nil {
                modeKey = "F\(index)md"
            } else {
                modeKey = "F\(index)Md"
            }
            return FanMeta(
                index: index,
                name: (try? fanName(index: index)) ?? "Fan \(index)",
                minRPM: Double((try? readFloat(key: "F\(index)Mn")) ?? 1000),
                maxRPM: Double((try? readFloat(key: "F\(index)Mx")) ?? 6000),
                modeKey: modeKey
            )
        }
        cachedFanMetas = metas
        cachedFanMetasUptime = now
        return metas
    }

    private func discoveredTemperatureKeys() -> [SMCTempKey] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedTemperatureKeys, now - cachedTemperatureKeysUptime < temperatureKeyCacheSeconds {
            return cachedTemperatureKeys
        }
        var discovered: [SMCTempKey] = []
        let count = (try? keyCount()) ?? 0
        if count > 0 {
            // Binary search to find the start of 'T' keys in the sorted SMC key table
            var low = 0
            var high = count - 1
            var firstTIndex = -1
            while low <= high {
                let mid = (low + high) / 2
                guard let key = try? keyAt(index: mid), !key.isEmpty else { break }
                if key >= "T" {
                    if SMCKnownNames.isTemperatureKey(key) {
                        firstTIndex = mid
                    }
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }

            if firstTIndex >= 0 {
                var idx = firstTIndex
                while idx < count {
                    guard let key = try? keyAt(index: idx), !key.isEmpty else { break }
                    if !SMCKnownNames.isTemperatureKey(key) {
                        if key > "T" { break }
                        idx += 1
                        continue
                    }
                    if let info = try? keyInfo(key: key) {
                        discovered.append(SMCTempKey(key: key, type: info.type, size: info.size))
                    }
                    idx += 1
                }
            }

            // Fallback: if binary search found nothing (e.g. non-standard key ordering), scan linearly
            if discovered.isEmpty {
                for index in 0..<min(count, 2048) {
                    guard let key = try? keyAt(index: index), SMCKnownNames.isTemperatureKey(key) else { continue }
                    guard let info = try? keyInfo(key: key) else { continue }
                    discovered.append(SMCTempKey(key: key, type: info.type, size: info.size))
                }
            }
        }

        // Fallback: probe known static keys (crucial on Intel if #KEY is unavailable or incomplete)
        if discovered.isEmpty {
            for entry in SMCKnownNames.fallbackKeys {
                guard let info = try? keyInfo(key: entry.key) else { continue }
                discovered.append(SMCTempKey(key: entry.key, type: info.type, size: info.size))
            }
        }

        if !discovered.isEmpty {
            cachedTemperatureKeys = discovered
            cachedTemperatureKeysUptime = now
        }
        return discovered
    }

    private func fanIndices() throws -> [Int] {
        let declared = min(8, max(0, Int(try readBytes(key: "FNum")[0])))
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
        return min(Int(count), 4096)
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

    private func readTemperatureValue(key: String, type: String, size: UInt32) throws -> Double {
        let bytes = try readBytes(key: key, type: type, size: size)
        if type == "ioft", size >= 8 {
            let raw = bytes.prefix(8).enumerated().reduce(UInt64(0)) { acc, item in
                acc | (UInt64(item.element) << (56 - item.offset * 8))
            }
            return Double(raw) / 65536.0
        }
        if type == "flt " || type == "ioft" {
            return Double(nativeFloat(bytes))
        }
        if type == "fpe2", size >= 2 {
            return Double(decodeFPE2(bytes))
        }
        if type.hasPrefix("sp"), size >= 2 {
            let hi = Int8(bitPattern: bytes[0])
            return Double(hi) + Double(bytes[1]) / 256.0
        }
        if type == "ui8 ", size >= 1 {
            return Double(bytes[0])
        }
        if type == "ui16", size >= 2 {
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw)
        }
        throw SMCError.ioFailed(key)
    }

    private func readFloat(key: String) throws -> Float {
        let info = try readInfo(key: key)
        if info.type == "fpe2" {
            return decodeFPE2(info.bytes)
        }
        return nativeFloat(info.bytes)
    }

    private func writeTypedFanTarget(key: String, rpm: Double) throws {
        if let info = try? readInfo(key: key), info.type == "fpe2" {
            var bytes = [UInt8](repeating: 0, count: 32)
            let encoded = encodeFPE2(Float(rpm))
            bytes[0] = encoded.0
            bytes[1] = encoded.1
            try writeBytes(key: key, bytes: bytes, type: "fpe2", size: 2)
            return
        }
        try writeFloat(key: key, value: Float(rpm))
    }

    private func writeFloat(key: String, value: Float) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        var v = value
        withUnsafeBytes(of: &v) { buf in
            for i in 0..<4 { bytes[i] = buf[i] }
        }
        try writeBytes(key: key, bytes: bytes, type: "flt ", size: 4)
    }

    private func decodeFPE2(_ bytes: [UInt8]) -> Float {
        guard bytes.count >= 2 else { return 0 }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Float(raw) / 4
    }

    private func encodeFPE2(_ value: Float) -> (UInt8, UInt8) {
        let raw = UInt16(min(max(value * 4, 0), Float(UInt16.max)))
        return (UInt8(raw >> 8), UInt8(raw & 0xff))
    }

    private func readBytes(key: String) throws -> [UInt8] {
        try readInfo(key: key).bytes
    }

    private func keyInfo(key: String) throws -> (type: String, size: UInt32) {
        var input = blankKeyData()
        var output = blankKeyData()
        input.key = fourCC(key)
        input.data8 = CChar(bitPattern: UInt8(kSMCGetKeyInfo))
        try invoke(input: &input, output: &output)
        return (fourCCString(output.keyInfo.dataType), output.keyInfo.dataSize)
    }

    private func readBytes(key: String, type: String, size: UInt32) throws -> [UInt8] {
        var readInput = blankKeyData()
        var readOutput = blankKeyData()
        readInput.key = fourCC(key)
        readInput.data8 = CChar(bitPattern: UInt8(kSMCReadKey))
        readInput.keyInfo.dataSize = size
        readInput.keyInfo.dataType = fourCC(type)
        try invoke(input: &readInput, output: &readOutput)

        var bytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: readOutput.bytes) { buf in
            let raw = buf.bindMemory(to: UInt8.self)
            for i in 0..<min(32, raw.count) {
                bytes[i] = raw[i]
            }
        }
        return bytes
    }

    private func readInfo(key: String) throws -> (type: String, size: UInt32, bytes: [UInt8]) {
        let info = try keyInfo(key: key)
        let bytes = try readBytes(key: key, type: info.type, size: info.size)
        return (info.type, info.size, bytes)
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
        guard kr == KERN_SUCCESS else {
            throw SMCError.ioFailed(fourCCString(input.key))
        }
        guard output.result == 0 else {
            throw SMCError.keyNotFound(fourCCString(input.key))
        }
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
        var count = 0
        for byte in string.utf8 {
            if count == 4 { break }
            result = (result << 8) | UInt32(byte)
            count += 1
        }
        while count < 4 {
            result = (result << 8) | 0x20
            count += 1
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


