import SwiftUI

public enum CoolDownTheme {
    public static let accent = Color(red: 0.15, green: 0.62, blue: 0.72)
    public static let warning = Color(red: 0.92, green: 0.55, blue: 0.18)
    public static let danger = Color(red: 0.86, green: 0.28, blue: 0.24)
    public static let calm = Color(red: 0.22, green: 0.70, blue: 0.48)

    public static func temperatureColor(_ celsius: Double?) -> Color {
        guard let celsius, celsius.isFinite else { return .secondary }
        switch celsius {
        case ..<60: return calm
        case ..<75: return accent
        case ..<85: return warning
        default: return danger
        }
    }
}

/// A lightweight material treatment that keeps the interface feeling native on
/// macOS while giving related controls a clear, glass-like hierarchy.
public struct GlassCard<Content: View>: View {
    private let content: Content
    private let contentPadding: CGFloat

    public init(contentPadding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.contentPadding = contentPadding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(contentPadding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

public struct GlassBackdrop: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [
                CoolDownTheme.accent.opacity(0.12),
                Color(nsColor: .windowBackgroundColor).opacity(0.86),
                CoolDownTheme.calm.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
