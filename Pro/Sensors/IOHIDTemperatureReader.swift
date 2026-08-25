import Foundation
import CoolDownKit

/// Reads Apple Silicon temperature sensors via IOHIDEventSystemClient.
/// The ObjC bridge keeps a persistent HID client; creating one every poll
/// tick is expensive enough to dominate app CPU.
enum IOHIDTemperatureReader {
    static func readAll() -> [TemperatureReading] {
        #if arch(arm64)
        let rows = CoolDownCopyHIDTemperatures()
        var raw: [(String, Double)] = []
        raw.reserveCapacity(rows.count)

        for case let row as NSDictionary in rows {
            guard let name = row["name"] as? String else { continue }
            let celsius: Double?
            if let number = row["celsius"] as? NSNumber {
                celsius = number.doubleValue
            } else if let value = row["celsius"] as? Double {
                celsius = value
            } else {
                celsius = nil
            }
            guard let celsius else { continue }
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
