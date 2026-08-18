import Foundation
import CoolDownKit

enum SensorMerge {
    static func merge(smc: [TemperatureReading], hid: [TemperatureReading]) -> [TemperatureReading] {
        var map: [String: TemperatureReading] = [:]
        for reading in smc.map(annotateSMC) {
            map[reading.key] = reading
        }
        for reading in hid {
            map[reading.key] = reading
        }
        return map.values.sorted { lhs, rhs in
            if lhs.group.sortOrder != rhs.group.sortOrder {
                return lhs.group.sortOrder < rhs.group.sortOrder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func annotateSMC(_ reading: TemperatureReading) -> TemperatureReading {
        var copy = reading
        copy.group = inferGroup(key: reading.key, name: reading.name)
        if copy.name == reading.key {
            copy.name = SMCKnownNames.name(for: reading.key)
        }
        return copy
    }

    private static func inferGroup(key: String, name: String) -> SensorGroup {
        let blob = (key + " " + name).lowercased()
        if blob.contains("battery") || key.hasPrefix("TB") { return .battery }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") || blob.contains("gpu") { return .gpu }
        if key.hasPrefix("Tp") || key.hasPrefix("TC") || key.hasPrefix("Te") || blob.contains("cpu") {
            return .cpu
        }
        if blob.contains("airport") || key.hasPrefix("TW") { return .wireless }
        if blob.contains("ssd") || blob.contains("nand") || key.hasPrefix("TN") { return .storage }
        return .other
    }
}
