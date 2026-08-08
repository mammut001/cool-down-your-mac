import Foundation

public enum SensorFormatting {
    public static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.0f°C", celsius)
    }

    public static func rpm(_ value: Double) -> String {
        String(format: "%.0f RPM", value)
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    public static func menuBarTitle(temp: Double?, mode: ControlMode, showTemp: Bool) -> String {
        if showTemp, let temp {
            return String(format: "%.0f°", temp)
        }
        switch mode {
        case .systemAuto: return "Auto"
        case .smartCurve: return "Smart"
        case .manual: return "Manual"
        }
    }
}
