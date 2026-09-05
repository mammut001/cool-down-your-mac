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
        if let gauge = hid.first(where: {
            $0.name == "Battery Gas Gauge" || $0.key.hasPrefix("hid.battery.")
        }) {
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

        // CPU cores: Tp/TC/Te keys around SoC temps (deduped; last write wins).
        let cpuKeys = uniqueSMC.values
            .filter { isCPUKey($0.key) && $0.key.count == 4 }
            .filter { $0.celsius.isFinite && $0.celsius > 5 && $0.celsius < 150 }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

        // Prefer the dense Tp0* block first (Performance + Super on M-series Pro).
        let primaryCPU = cpuKeys.filter {
            $0.key.hasPrefix("Tp0") || $0.key.hasPrefix("TC") || $0.key.hasPrefix("Te")
                || ($0.key.hasPrefix("Tp1") && $0.key <= "Tp1g")
        }
        let orderedCPU = primaryCPU.isEmpty ? Array(cpuKeys.prefix(18)) : Array(primaryCPU.prefix(18))

        let isAppleSiliconSMC = orderedCPU.contains { $0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te") }
        if isAppleSiliconSMC {
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
        } else {
            for reading in orderedCPU {
                let friendly = reading.name != reading.key ? reading.name : SMCKnownNames.name(for: reading.key)
                list.append(
                    TemperatureReading(
                        key: reading.key,
                        name: friendly,
                        celsius: reading.celsius,
                        group: .cpu
                    )
                )
            }
        }

        if orderedCPU.isEmpty {
            // The mapper may already contain a synthetic average. Exclude it here
            // because this catalog inserts one canonical average below.
            let hidCPU = hid.filter {
                $0.group == .cpu
                    && $0.key != "hid.cpu.avg"
                    && $0.celsius.isFinite
                    && $0.celsius > 5
                    && $0.celsius < 150
            }
            list.append(contentsOf: hidCPU.prefix(18))
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

        // GPU clusters: pick 4 evenly spaced Tg/TG samples (deduped; last write wins).
        let gpuKeys = uniqueSMC.values
            .filter { isGPUKey($0.key) && $0.key.count == 4 }
            .filter { $0.celsius.isFinite && $0.celsius > 5 && $0.celsius < 150 }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        if gpuKeys.isEmpty {
            let hidGPU = hid.filter { $0.group == .gpu && $0.celsius.isFinite && $0.celsius > 5 && $0.celsius < 150 }
            list.append(contentsOf: hidGPU.prefix(4))
        } else if !gpuKeys.isEmpty {
            let isAppleSiliconGPU = gpuKeys.contains { $0.key.hasPrefix("Tg") }
            let picks = evenlyPick(gpuKeys, count: min(4, gpuKeys.count))
            for (index, reading) in picks.enumerated() {
                let name = isAppleSiliconGPU
                    ? "GPU Cluster \(index + 1)"
                    : (reading.name != reading.key ? reading.name : SMCKnownNames.name(for: reading.key))
                list.append(
                    TemperatureReading(
                        key: reading.key,
                        name: name,
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
        addSMC("TM0P", name: "Memory Proximity", group: .other)
        addSMC("TA0P", name: "Ambient Airflow", group: .other)
        addSMC("TN0P", name: "Platform Controller Hub", group: .other)
        addSMC("Th0H", name: "Heatsink", group: .other)

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

        return list.sorted { lhs, rhs in
            let li = displayRank(for: lhs.name)
            let ri = displayRank(for: rhs.name)
            if li != ri { return li < ri }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    @inline(__always)
    private static func displayRank(for name: String) -> Int {
        switch name {
        case "Airport Proximity": return 0
        case "Battery": return 1
        case "Battery Gas Gauge": return 2
        case "CPU Core Average": return 3
        default:
            if name.hasPrefix("CPU") { return 10 }
            if name.hasPrefix("GPU") { return 30 }
            return 40
        }
    }

    static func allMerged(smc: [TemperatureReading], hid: [TemperatureReading]) -> [TemperatureReading] {
        SensorMerge.merge(smc: smc, hid: hid)
    }

    /// CPU/GPU readings used for fan decisions. Independent of the curated UI list
    /// and of the "show all sensors" toggle.
    static func controlReadings(smc: [TemperatureReading], hid: [TemperatureReading]) -> [TemperatureReading] {
        let uniqueSMC = lastWriteWinsByKey(smc)
        var readings = uniqueSMC.values.filter { reading in
            reading.celsius.isFinite
                && reading.celsius > 5
                && reading.celsius < 150
                && (isCPUKey(reading.key) || isGPUKey(reading.key) || reading.group.affectsThermalControl)
        }
        for item in hid where item.group.affectsThermalControl {
            guard item.celsius.isFinite, item.celsius > 5, item.celsius < 150 else { continue }
            readings.append(item)
        }
        return readings
    }

    private static func isCPUKey(_ key: String) -> Bool {
        key.hasPrefix("Tp") || key.hasPrefix("TC") || key.hasPrefix("Te") || key.hasPrefix("tp")
    }

    private static func isGPUKey(_ key: String) -> Bool {
        key.hasPrefix("Tg") || key.hasPrefix("TG") || key.hasPrefix("tg")
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
