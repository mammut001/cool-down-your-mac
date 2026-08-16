import Foundation
import CoolDownKit

/// Builds a screenshot-style curated sensor list from SMC + HID readings.
enum SensorCatalog {
    static func curated(smc: [TemperatureReading], hid: [TemperatureReading]) -> [TemperatureReading] {
        let uniqueSMC = lastWriteWinsByKey(smc)
        var byKey = uniqueSMC
        for item in hid { byKey[item.key] = item }

        var list: [TemperatureReading] = []

        func addSMC(_ key: String, name: String, group: SensorGroup) {
            guard let reading = byKey[key] else { return }
            list.append(TemperatureReading(key: key, name: name, celsius: reading.celsius, group: group))
        }

        addSMC("TW0P", name: "Airport Proximity", group: .wireless)
        addSMC("TB0T", name: "Battery", group: .battery)
        if let gauge = hid.first(where: { $0.name == "Battery Gas Gauge" || $0.key.contains("battery") }) {
            list.append(
                TemperatureReading(
                    key: "hid.battery.gauge",
                    name: "Battery Gas Gauge",
                    celsius: gauge.celsius,
                    group: .battery
                )
            )
        } else {
            addSMC("TB1T", name: "Battery Gas Gauge", group: .battery)
        }

        // CPU cores: Tp00-style keys around SoC temps (deduped; last write wins).
        let cpuKeys = uniqueSMC.values
            .filter { $0.key.hasPrefix("Tp") && $0.key.count == 4 }
            .filter { $0.celsius > 20 && $0.celsius < 110 }
            .sorted { $0.key < $1.key }

        // Prefer the dense Tp0* block first (Performance + Super on M-series Pro).
        let primaryCPU = cpuKeys.filter { $0.key.hasPrefix("Tp0") || ($0.key.hasPrefix("Tp1") && $0.key <= "Tp1g") }
        let orderedCPU = primaryCPU.isEmpty ? Array(cpuKeys.prefix(18)) : Array(primaryCPU.prefix(18))

        let performanceCount = min(12, orderedCPU.count)
        for (index, reading) in orderedCPU.enumerated() {
            if index < performanceCount {
                list.append(
                    TemperatureReading(
                        key: reading.key,
                        name: "CPU Performance Core \(index + 1)",
                        celsius: reading.celsius,
                        group: .cpu
                    )
                )
            } else {
                list.append(
                    TemperatureReading(
                        key: reading.key,
                        name: "CPU Super Core \(index - performanceCount + 1)",
                        celsius: reading.celsius,
                        group: .cpu
                    )
                )
            }
        }

        let cpuValues = list.filter { $0.group == .cpu }.map(\.celsius)
        if !cpuValues.isEmpty {
            list.insert(
                TemperatureReading(
                    key: "calc.cpu.avg",
                    name: "CPU Core Average",
                    celsius: cpuValues.reduce(0, +) / Double(cpuValues.count),
                    group: .cpu
                ),
                at: list.firstIndex(where: { $0.group == .cpu }) ?? list.count
            )
        }

        // GPU clusters: pick 4 evenly spaced Tg* samples (deduped; last write wins).
        let gpuKeys = uniqueSMC.values
            .filter { $0.key.hasPrefix("Tg") && $0.key.count == 4 }
            .filter { $0.celsius > 15 && $0.celsius < 110 }
            .sorted { $0.key < $1.key }
        if !gpuKeys.isEmpty {
            let picks = evenlyPick(gpuKeys, count: min(4, gpuKeys.count))
            for (index, reading) in picks.enumerated() {
                list.append(
                    TemperatureReading(
                        key: reading.key,
                        name: "GPU Cluster \(index + 1)",
                        celsius: reading.celsius,
                        group: .gpu
                    )
                )
            }
            let gpuValues = picks.map(\.celsius)
            list.append(
                TemperatureReading(
                    key: "calc.gpu.avg",
                    name: "GPU Cluster Average",
                    celsius: gpuValues.reduce(0, +) / Double(gpuValues.count),
                    group: .gpu
                )
            )
        }

        if let pmu = hid.first(where: { $0.name == "Power Manager Die Average" }) {
            list.append(pmu)
        } else {
            addSMC("TPMP", name: "Power Manager Die Average", group: .other)
        }
        addSMC("TPSP", name: "Power Supply Proximity", group: .other)
        if !list.contains(where: { $0.name == "Power Supply Proximity" }) {
            addSMC("TCHP", name: "Power Supply Proximity", group: .other)
        }

        addSMC("Ts0P", name: "Trackpad", group: .other)
        addSMC("Ts1P", name: "Trackpad Actuator", group: .other)

        if let nand = hid.first(where: { $0.name.localizedCaseInsensitiveContains("NAND") || $0.name.localizedCaseInsensitiveContains("SSD") }) {
            list.append(
                TemperatureReading(
                    key: nand.key,
                    name: storageDisplayName(from: nand.name),
                    celsius: nand.celsius,
                    group: .storage
                )
            )
        } else {
            addSMC("TN00", name: "SSD", group: .storage)
        }

        // Stable display order matching the reference app.
        let order: [String] = [
            "Airport Proximity",
            "Battery",
            "Battery Gas Gauge",
            "CPU Core Average"
        ]
        return list.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.name) ?? (lhs.name.hasPrefix("CPU Performance") ? 10 : lhs.name.hasPrefix("CPU Super") ? 20 : lhs.name.hasPrefix("GPU") ? 30 : 40)
            let ri = order.firstIndex(of: rhs.name) ?? (rhs.name.hasPrefix("CPU Performance") ? 10 : rhs.name.hasPrefix("CPU Super") ? 20 : rhs.name.hasPrefix("GPU") ? 30 : 40)
            if li != ri { return li < ri }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func allMerged(smc: [TemperatureReading], hid: [TemperatureReading]) -> [TemperatureReading] {
        SensorMerge.merge(smc: smc, hid: hid)
    }

    /// Last write wins so a duplicate SMC key cannot trap `Dictionary(uniqueKeysWithValues:)`.
    static func lastWriteWinsByKey(_ readings: [TemperatureReading]) -> [String: TemperatureReading] {
        var map: [String: TemperatureReading] = [:]
        map.reserveCapacity(readings.count)
        for reading in readings {
            map[reading.key] = reading
        }
        return map
    }

    static func storageDisplayName(from sourceName: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SSD" : trimmed
    }

    private static func evenlyPick(_ items: [TemperatureReading], count: Int) -> [TemperatureReading] {
        guard count > 0, !items.isEmpty else { return [] }
        if items.count <= count { return items }
        var result: [TemperatureReading] = []
        for i in 0..<count {
            let index = Int(Double(i) * Double(items.count - 1) / Double(count - 1))
            result.append(items[index])
        }
        return result
    }
}
