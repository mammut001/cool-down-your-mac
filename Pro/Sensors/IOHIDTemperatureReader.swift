import Foundation
import CoolDownKit

/// Reads Apple Silicon temperature sensors via IOHIDEventSystemClient.
enum IOHIDTemperatureReader {
    static func readAll() -> [TemperatureReading] {
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

        let mapped = SensorNameMapper.map(rawReadings: raw)
        let path = NSTemporaryDirectory() + "cooldown-hid-mapped.txt"
        try? "raw=\(raw.count) mapped=\(mapped.count)\n".write(toFile: path, atomically: true, encoding: .utf8)
        return mapped
    }
}
