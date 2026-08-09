import Foundation
import IOKit
import Darwin

// Read-only diagnostic utility for the legacy AppleSMC interface.

func blankKeyData() -> SMCKeyData {
    var data = SMCKeyData()
    memset(&data, 0, MemoryLayout<SMCKeyData>.size)
    return data
}

func fourCC(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for scalar in string.utf8.prefix(4) {
        result = (result << 8) | UInt32(scalar)
    }
    return result
}

func fourCCString(_ value: UInt32) -> String {
    let chars = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(bytes: chars, encoding: .macOSRoman) ?? ""
}

final class Probe {
    var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw NSError(domain: "smc", code: 1) }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else {
            throw NSError(domain: "smc", code: 2)
        }
        connection = conn
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func invoke(input: inout SMCKeyData, output: inout SMCKeyData) throws {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(connection, UInt32(kSMCHandleYPCEvent), &input, inputSize, &output, &outputSize)
        guard kr == KERN_SUCCESS, output.result == 0 else {
            throw NSError(domain: "smc", code: Int(kr))
        }
    }

    func keyCount() throws -> Int {
        var input = blankKeyData()
        var output = blankKeyData()
        input.key = fourCC("#KEY")
        input.data8 = CChar(bitPattern: UInt8(kSMCGetKeyInfo))
        try invoke(input: &input, output: &output)

        var readIn = blankKeyData()
        var readOut = blankKeyData()
        readIn.key = input.key
        readIn.data8 = CChar(bitPattern: UInt8(kSMCReadKey))
        readIn.keyInfo.dataSize = output.keyInfo.dataSize
        readIn.keyInfo.dataType = output.keyInfo.dataType
        try invoke(input: &readIn, output: &readOut)

        // ui32 big-endian in first 4 bytes of bytes tuple
        let b = byteArray(readOut.bytes)
        let value = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        return Int(value)
    }

    func keyAt(index: Int) throws -> String {
        var input = blankKeyData()
        var output = blankKeyData()
        input.data8 = CChar(bitPattern: UInt8(kSMCGetKeyFromIndex))
        input.data32 = UInt32(index)
        try invoke(input: &input, output: &output)
        return fourCCString(output.key)
    }

    func read(key: String) throws -> (type: String, size: UInt32, bytes: [UInt8]) {
        var input = blankKeyData()
        var output = blankKeyData()
        input.key = fourCC(key)
        input.data8 = CChar(bitPattern: UInt8(kSMCGetKeyInfo))
        try invoke(input: &input, output: &output)

        var readIn = blankKeyData()
        var readOut = blankKeyData()
        readIn.key = input.key
        readIn.data8 = CChar(bitPattern: UInt8(kSMCReadKey))
        readIn.keyInfo.dataSize = output.keyInfo.dataSize
        readIn.keyInfo.dataType = output.keyInfo.dataType
        try invoke(input: &readIn, output: &readOut)
        return (fourCCString(output.keyInfo.dataType), output.keyInfo.dataSize, byteArray(readOut.bytes))
    }

    func celsius(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "sp78", "sp87", "sp96", "sp5a", "sp4b", "sp69":
            let hi = Int8(bitPattern: bytes[0])
            let lo = bytes[1]
            return Double(hi) + Double(lo) / 256.0
        case "flt ":
            let be = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            return Double(Float(bitPattern: be))
        case "ui16", "ui8 ", "ui32":
            return nil
        default:
            // Heuristic: treat 2-byte as sp78-like if plausible
            if type.hasPrefix("sp") {
                let hi = Int8(bitPattern: bytes[0])
                let lo = bytes[1]
                let v = Double(hi) + Double(lo) / 256.0
                return (v > -20 && v < 150) ? v : nil
            }
            return nil
        }
    }
}

private func byteArray(_ tuple: SMCBytes_t) -> [UInt8] {
    withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: UInt8.self)) }
}

do {
    let probe = try Probe()
    let count = try probe.keyCount()
    print("SMC key count: \(count)")

    var temps: [(String, String, Double)] = []
    var fans: [String] = []

    for i in 0..<count {
        guard let key = try? probe.keyAt(index: i), key.count == 4 else { continue }
        guard let info = try? probe.read(key: key) else { continue }
        if key.hasPrefix("F") && (key.contains("Ac") || key.contains("Tg") || key == "FNum") {
            fans.append("\(key) type=\(info.type) size=\(info.size)")
        }
        if let c = probe.celsius(type: info.type, bytes: info.bytes), c > -10, c < 120 {
            // Prefer keys that look thermal: start with T, or known patterns
            if key.first == "T" || key.hasPrefix("t") || key.hasPrefix("Tp") || key.hasPrefix("Tg") || key.hasPrefix("Ts") || key.hasPrefix("TB") || key.hasPrefix("TW") || key.hasPrefix("Th") || key.hasPrefix("Ta") || key.hasPrefix("TC") || key.hasPrefix("TG") || key.hasPrefix("TM") || key.hasPrefix("Td") || key.hasPrefix("Te") {
                temps.append((key, info.type, c))
            }
        }
    }

    temps.sort { $0.0 < $1.0 }
    print("\nTemperature-like keys (\(temps.count)):")
    for (key, type, c) in temps {
        print(String(format: "  %-4s  %-4s  %6.1f°C", key, type, c))
    }
    print("\nFan-related:")
    for f in fans.sorted() { print("  \(f)") }
} catch {
    print("Failed: \(error)")
    exit(1)
}
