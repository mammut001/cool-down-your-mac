import Foundation

enum SMCKnownNames {
    static func isTemperatureKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        return first == "T" || first == "t"
    }

    static let fallbackKeys: [(key: String, name: String)] = [
        // Intel CPU keys
        ("TC0P", "CPU Proximity"),
        ("TC0D", "CPU Die"),
        ("TC0E", "CPU Die"),
        ("TC0F", "CPU Die"),
        ("TC1C", "CPU Core 1"),
        ("TC2C", "CPU Core 2"),
        ("TC3C", "CPU Core 3"),
        ("TC4C", "CPU Core 4"),
        ("TC5C", "CPU Core 5"),
        ("TC6C", "CPU Core 6"),
        ("TC7C", "CPU Core 7"),
        ("TC8C", "CPU Core 8"),
        ("TCPG", "CPU Package"),
        ("TCSC", "CPU System Agent"),
        ("TCXC", "CPU PECI"),
        ("TC0H", "CPU Heatsink"),
        // Intel GPU keys
        ("TG0P", "GPU Proximity"),
        ("TG0D", "GPU Die"),
        ("TG0H", "GPU Heatsink"),
        ("TG1D", "GPU 2 Die"),
        // Platform / Memory / Ambient / Heatsink
        ("TM0P", "Memory Proximity"),
        ("TM0S", "Memory Slot"),
        ("TN0P", "Platform Controller Hub"),
        ("TN0D", "PCH Die"),
        ("TA0P", "Ambient Airflow"),
        ("TA1P", "Ambient 2"),
        ("Th0H", "Heatsink"),
        ("Th1H", "Heatsink 2"),
        // Universal / Apple Silicon fallback keys
        ("TB0T", "Battery"),
        ("TB1T", "Battery 2"),
        ("TB2T", "Battery 3"),
        ("TW0P", "Airport Proximity"),
        ("Ts0P", "Trackpad"),
        ("Ts1P", "Trackpad Actuator"),
        ("TPMP", "Power Manager Die Average"),
        ("TPSP", "Power Supply Proximity"),
        ("TCHP", "Power Supply Proximity"),
        ("TH0x", "Heatpipe"),
        ("TCMb", "CPU Max")
    ]

    static func name(for key: String) -> String {
        switch key {
        // CPU
        case "TC0P": return "CPU Proximity"
        case "TC0D": return "CPU Die"
        case "TC0E", "TC0F": return "CPU Die"
        case "TC1C": return "CPU Core 1"
        case "TC2C": return "CPU Core 2"
        case "TC3C": return "CPU Core 3"
        case "TC4C": return "CPU Core 4"
        case "TC5C": return "CPU Core 5"
        case "TC6C": return "CPU Core 6"
        case "TC7C": return "CPU Core 7"
        case "TC8C": return "CPU Core 8"
        case "TCPG": return "CPU Package"
        case "TCSC": return "CPU System Agent"
        case "TCXC": return "CPU PECI"
        case "TC0H": return "CPU Heatsink"
        // GPU
        case "TG0P": return "GPU Proximity"
        case "TG0D": return "GPU Die"
        case "TG0H": return "GPU Heatsink"
        case "TG1D": return "GPU 2 Die"
        // Memory / Platform / Ambient
        case "TM0P": return "Memory Proximity"
        case "TM0S": return "Memory Slot"
        case "TN0P": return "Platform Controller Hub"
        case "TN0D": return "PCH Die"
        case "TA0P": return "Ambient Airflow"
        case "TA1P": return "Ambient 2"
        case "Th0H": return "Heatsink"
        case "Th1H": return "Heatsink 2"
        // Battery / Input / PMU
        case "TB0T", "TB2T": return "Battery"
        case "TB1T": return "Battery 2"
        case "TW0P": return "Airport Proximity"
        case "Ts0P": return "Trackpad"
        case "Ts1P": return "Trackpad Actuator"
        case "TPMP": return "Power Manager Die Average"
        case "TPSP", "TCHP": return "Power Supply Proximity"
        case "TH0x", "TH0a", "TH0b": return "Heatpipe"
        case "TCMb": return "CPU Max"
        case "TN00", "TN01": return "APPLE SSD"
        default:
            if key.hasPrefix("TC") && key.hasSuffix("C") && key.count == 4 {
                let coreChar = key[key.index(key.startIndex, offsetBy: 2)]
                if let coreNum = Int(String(coreChar)) {
                    return "CPU Core \(coreNum)"
                }
            }
            return key
        }
    }
}
