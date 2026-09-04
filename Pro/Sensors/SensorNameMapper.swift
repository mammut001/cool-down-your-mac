import Foundation
import CoolDownKit

enum SensorNameMapper {
    private struct PlanItem {
        enum Kind {
            case single(rawIndex: Int)
            case average(rawIndices: [Int])
        }
        let key: String
        let name: String
        let group: SensorGroup
        let kind: Kind
    }

    private struct CachedPlan {
        let signature: [String]
        let items: [PlanItem]
    }

    private static let planLock = NSLock()
    private static var cachedPlan: CachedPlan?

    /// Convert raw HID product names into UI-friendly readings with stable keys.
    static func map(rawReadings: [(String, Double)]) -> [TemperatureReading] {
        planLock.lock()
        if let plan = cachedPlan, plan.signature.count == rawReadings.count {
            var matches = true
            for i in 0..<rawReadings.count {
                if plan.signature[i] != rawReadings[i].0 {
                    matches = false
                    break
                }
            }
            if matches {
                var results: [TemperatureReading] = []
                results.reserveCapacity(plan.items.count)
                for item in plan.items {
                    let temp: Double
                    switch item.kind {
                    case .single(let rawIndex):
                        temp = rawReadings[rawIndex].1
                    case .average(let indices):
                        guard !indices.isEmpty else { continue }
                        var sum = 0.0
                        for idx in indices { sum += rawReadings[idx].1 }
                        temp = sum / Double(indices.count)
                    }
                    results.append(TemperatureReading(key: item.key, name: item.name, celsius: temp, group: item.group))
                }
                planLock.unlock()
                return results
            }
        }
        planLock.unlock()

        let indexed = rawReadings.enumerated().map { ($0.offset, $0.element.0, $0.element.1) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        // Split PMU tdie sensors into Performance / Super style labels on Apple Silicon.
        let tdie = indexed.compactMap { item -> (Int, String, Double)? in
            guard item.1.hasPrefix("PMU tdie") else { return nil }
            return item
        }

        var planItems: [PlanItem] = []
        var consumed = Set<String>()

        if !tdie.isEmpty {
            let sortedDie = tdie.sorted { lhs, rhs in
                dieIndex(lhs.1) < dieIndex(rhs.1)
            }
            // Heuristic for M-series Pro/Max: first N → Performance, next → Super/Efficiency.
            let performanceCount = min(12, sortedDie.count)
            var cpuIndices: [Int] = []
            for (index, item) in sortedDie.enumerated() {
                consumed.insert(item.1)
                cpuIndices.append(item.0)
                if index < performanceCount {
                    let n = index + 1
                    planItems.append(
                        PlanItem(
                            key: "hid.cpu.perf.\(n)",
                            name: "CPU Performance Core \(n)",
                            group: .cpu,
                            kind: .single(rawIndex: item.0)
                        )
                    )
                } else {
                    let n = index - performanceCount + 1
                    planItems.append(
                        PlanItem(
                            key: "hid.cpu.super.\(n)",
                            name: "CPU Super Core \(n)",
                            group: .cpu,
                            kind: .single(rawIndex: item.0)
                        )
                    )
                }
            }

            if !cpuIndices.isEmpty {
                planItems.append(
                    PlanItem(
                        key: "hid.cpu.avg",
                        name: "CPU Core Average",
                        group: .cpu,
                        kind: .average(rawIndices: cpuIndices)
                    )
                )
            }
        }

        for (rawIndex, raw, value) in indexed where !consumed.contains(raw) {
            let lower = raw.lowercased()
            if !tdie.isEmpty && (lower.contains("pacc") || lower.contains("eacc") || lower.contains("performance") || lower.contains("efficiency") || lower.contains("super")) {
                continue
            }
            let mapped = friendly(raw: raw, value: value)
            planItems.append(
                PlanItem(
                    key: mapped.key,
                    name: mapped.name,
                    group: mapped.group,
                    kind: .single(rawIndex: rawIndex)
                )
            )
        }

        // Synthetic GPU average if we have GPU cluster-like sensors.
        let gpuItems = planItems.filter { $0.group == .gpu }
        if gpuItems.count >= 2, !planItems.contains(where: { $0.key == "hid.gpu.avg" }) {
            var gpuRawIndices: [Int] = []
            for item in gpuItems {
                if case .single(let rawIndex) = item.kind {
                    gpuRawIndices.append(rawIndex)
                }
            }
            planItems.append(
                PlanItem(
                    key: "hid.gpu.avg",
                    name: "GPU Cluster Average",
                    group: .gpu,
                    kind: .average(rawIndices: gpuRawIndices)
                )
            )
        }

        var unique: [String: PlanItem] = [:]
        for item in planItems {
            unique[item.key] = item
        }
        let sortedPlan = unique.values.sorted { lhs, rhs in
            if lhs.group.sortOrder != rhs.group.sortOrder {
                return lhs.group.sortOrder < rhs.group.sortOrder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let signature = rawReadings.map(\.0)
        planLock.lock()
        cachedPlan = CachedPlan(signature: signature, items: sortedPlan)
        planLock.unlock()

        return sortedPlan.compactMap { item -> TemperatureReading? in
            let temp: Double
            switch item.kind {
            case .single(let rawIndex):
                temp = rawReadings[rawIndex].1
            case .average(let indices):
                guard !indices.isEmpty else { return nil }
                var sum = 0.0
                for idx in indices { sum += rawReadings[idx].1 }
                temp = sum / Double(indices.count)
            }
            return TemperatureReading(key: item.key, name: item.name, celsius: temp, group: item.group)
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
