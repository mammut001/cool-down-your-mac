import SwiftUI

public enum CoolDownTheme {
    public static let accent = Color(red: 0.15, green: 0.62, blue: 0.72)
    public static let warning = Color(red: 0.92, green: 0.55, blue: 0.18)
    public static let danger = Color(red: 0.86, green: 0.28, blue: 0.24)
    public static let calm = Color(red: 0.22, green: 0.70, blue: 0.48)

    public static func temperatureColor(_ celsius: Double) -> Color {
        switch celsius {
        case ..<60: return calm
        case ..<75: return accent
        case ..<85: return warning
        default: return danger
        }
    }
}
