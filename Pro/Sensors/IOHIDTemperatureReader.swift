import Foundation
import CoolDownKit

/// Reads Apple Silicon temperature sensors via IOHIDEventSystemClient.
/// The ObjC bridge keeps a persistent HID client; creating one every poll
/// tick is expensive enough to dominate app CPU.
enum IOHIDTemperatureReader {
    static func readAll() -> [TemperatureReading] {
        #if arch(arm64)
        var raw: [(String, Double)] = []
        raw.reserveCapacity(64)
        CoolDownEnumerateHIDTemperatures { name, celsius in
            raw.append((name, celsius))
        }
        return SensorNameMapper.map(rawReadings: raw)
        #else
        // Intel Macs do not expose the Apple Silicon IOHID thermal services.
        // Avoid rebuilding an IOHIDEventSystemClient every polling tick for an
        // empty result; Intel temperature telemetry comes from AppleSMC.
        return []
        #endif
    }
}
