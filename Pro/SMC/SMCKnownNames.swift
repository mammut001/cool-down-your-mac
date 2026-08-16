import Foundation

enum SMCKnownNames {
    static let fallbackKeys: [(key: String, name: String)] = [
        ("TB0T", "Battery"),
        ("TB1T", "Battery 2"),
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
        default: return key
        }
    }
}
