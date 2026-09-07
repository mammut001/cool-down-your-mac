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
///
/// On macOS 26.0+, this adopts Apple's official Liquid Glass material
/// (`.glassEffect(_:in:)`) with hardware-concentric continuous curves.
public struct GlassCard<Content: View>: View {
    private let content: Content
    private let contentPadding: CGFloat

    public init(contentPadding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.contentPadding = contentPadding
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            content
                .padding(contentPadding)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        } else {
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
}

/// A sheer ambient background that introduces subtle atmospheric cool tones
/// while remaining translucent to allow macOS native window and popover
/// Liquid Glass materials to shine through naturally without occlusion.
public struct GlassBackdrop: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [
                CoolDownTheme.accent.opacity(0.07),
                Color.clear,
                CoolDownTheme.calm.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

public extension View {
    /// Applies Apple's official `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`
    /// on macOS 26.0+, falling back gracefully to standard bordered styles on earlier releases.
    @ViewBuilder
    func liquidGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    /// Groups child Liquid Glass components within a `GlassEffectContainer` on
    /// macOS 26.0+ to optimize composite rendering performance and enable
    /// seamless fluid morphing transitions.
    @ViewBuilder
    func glassContainerIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                self
            }
        } else {
            self
        }
    }
}
