import Foundation
import CoolDownKit

enum SensorNameMapper {
    /// Convert raw HID product names into UI-friendly readings with stable keys.
    static func map(rawReadings: [(String, Double)]) -> [TemperatureReading] {
        let indexed = rawReadings.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        // Split PMU tdie sensors into Performance / Super style labels on Apple Silicon.
        let tdie = indexed.compactMap { item -> (String, Double)? in
            guard item.0.hasPrefix("PMU tdie") else { return nil }
            return item
        }

        var readings: [TemperatureReading] = []
        var consumed = Set<String>()

        if !tdie.isEmpty {
            let sortedDie = tdie.sorted { lhs, rhs in
                dieIndex(lhs.0) < dieIndex(rhs.0)
            }
            // Heuristic for M-series Pro/Max: first N → Performance, next → Super/Efficiency.
            let performanceCount = min(12, sortedDie.count)
            for (index, item) in sortedDie.enumerated() {
                consumed.insert(item.0)
                if index < performanceCount {
                    let n = index + 1
                    readings.append(
                        TemperatureReading(
                            key: "hid.cpu.perf.\(n)",
                            name: "CPU Performance Core \(n)",
                            celsius: item.1,
                            group: .cpu
                        )
                    )
                } else {
                    let n = index - performanceCount + 1
                    readings.append(
                        TemperatureReading(
                            key: "hid.cpu.super.\(n)",
                            name: "CPU Super Core \(n)",
                            celsius: item.1,
                            group: .cpu
                        )
                    )
                }
            }

            let cpuValues = readings.filter { $0.group == .cpu }.map(\.celsius)
            if !cpuValues.isEmpty {
                readings.append(
                    TemperatureReading(
                        key: "hid.cpu.avg",
                        name: "CPU Core Average",
                        celsius: cpuValues.reduce(0, +) / Double(cpuValues.count),
                        group: .cpu
                    )
                )
            }
        }

        for (raw, value) in indexed where !consumed.contains(raw) {
            let lower = raw.lowercased()
            if !tdie.isEmpty && (lower.contains("pacc") || lower.contains("eacc") || lower.contains("performance") || lower.contains("efficiency") || lower.contains("super")) {
                continue
            }
            let mapped = friendly(raw: raw, value: value)
            readings.append(mapped)
        }

        // Synthetic GPU average if we have GPU cluster-like sensors.
        let gpu = readings.filter { $0.group == .gpu }.map(\.celsius)
        if gpu.count >= 2, !readings.contains(where: { $0.key == "hid.gpu.avg" }) {
            readings.append(
                TemperatureReading(
                    key: "hid.gpu.avg",
                    name: "GPU Cluster Average",
                    celsius: gpu.reduce(0, +) / Double(gpu.count),
                    group: .gpu
                )
            )
        }

        var unique: [String: TemperatureReading] = [:]
        for reading in readings {
            unique[reading.key] = reading
        }
        return unique.values.sorted { lhs, rhs in
            if lhs.group.sortOrder != rhs.group.sortOrder {
                return lhs.group.sortOrder < rhs.group.sortOrder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func dieIndex(_ name: String) -> Int {
        let digits = name.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func friendly(raw: String, value: Double) -> TemperatureReading {
        let lower = raw.lowercased()

        if lower.contains("gas gauge") || lower == "battery" {
            return TemperatureReading(key: "hid.battery.\(slug(raw))", name: "Battery Gas Gauge", celsius: value, group: .battery)
        }
        if lower.contains("nand") || lower.contains("ssd") {
            return TemperatureReading(key: "hid.storage.\(slug(raw))", name: storageName(raw), celsius: value, group: .storage)
        }
        if lower.contains("airport") || lower.contains("wifi") {
            return TemperatureReading(key: "hid.wireless.\(slug(raw))", name: "Airport Proximity", celsius: value, group: .wireless)
        }
        if lower.contains("trackpad") {
            let name = lower.contains("actuator") ? "Trackpad Actuator" : "Trackpad"
            return TemperatureReading(key: "hid.input.\(slug(raw))", name: name, celsius: value, group: .other)
        }
        if raw.hasPrefix("PMU tcal") {
            return TemperatureReading(key: "hid.pmu.tcal.\(slug(raw))", name: "Power Manager Die Average", celsius: value, group: .other)
        }
        if lower.contains("gpu") {
            return TemperatureReading(key: "hid.gpu.\(slug(raw))", name: gpuName(raw), celsius: value, group: .gpu)
        }
        if lower.contains("pacc") || lower.contains("performance") {
            return TemperatureReading(key: "hid.raw.\(slug(raw))", name: performanceName(raw), celsius: value, group: .cpu)
        }
        if lower.contains("eacc") || lower.contains("efficiency") || lower.contains("super") {
            return TemperatureReading(key: "hid.raw.\(slug(raw))", name: efficiencyName(raw), celsius: value, group: .cpu)
        }
        if raw.hasPrefix("PMU ") {
            return TemperatureReading(key: "hid.pmu.\(slug(raw))", name: raw, celsius: value, group: .other)
        }

        return TemperatureReading(key: "hid.\(slug(raw))", name: titleCase(raw), celsius: value, group: .other)
    }

    static func storageName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "SSD" }
        if let range = trimmed.range(of: "NAND", options: .caseInsensitive) {
            return String(trimmed[range.lowerBound...]).replacingOccurrences(of: "temp", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func gpuName(_ raw: String) -> String {
        if let n = trailingNumber(raw) { return "GPU Cluster \(n)" }
        return titleCase(raw)
    }

    private static func performanceName(_ raw: String) -> String {
        if let n = trailingNumber(raw) { return "CPU Performance Core \(n)" }
        return titleCase(raw)
    }

    private static func efficiencyName(_ raw: String) -> String {
        if let n = trailingNumber(raw) { return "CPU Super Core \(n)" }
        return titleCase(raw)
    }

    private static func trailingNumber(_ raw: String) -> Int? {
        let digits = raw.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }

    private static func slug(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: ".")
            .replacingOccurrences(of: "/", with: ".")
    }

    private static func titleCase(_ raw: String) -> String {
        raw.split(separator: " ").map { part in
            guard let first = part.first else { return String(part) }
            return String(first).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }
}
