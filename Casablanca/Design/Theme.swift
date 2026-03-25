import AppKit
import SwiftUI

// MARK: - Adaptive Color Helper

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Color Tokens

extension Color {
    // Background
    static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
    static let backgroundTertiary = Color(light: .init(red: 0.937, green: 0.937, blue: 0.941),
                                          dark: .init(red: 0.110, green: 0.110, blue: 0.118))
    static let backgroundHover = Color(light: .init(red: 0.910, green: 0.910, blue: 0.918),
                                       dark: .init(red: 0.137, green: 0.137, blue: 0.149))
    static let backgroundActive = Color(light: .init(red: 0.875, green: 0.875, blue: 0.882),
                                        dark: .init(red: 0.173, green: 0.173, blue: 0.180))

    // Text
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // Border
    static let borderSubtle = Color(nsColor: .separatorColor)
    static let borderDefault = Color(nsColor: .tertiaryLabelColor).opacity(0.3)
    static let borderFocus = Color.accentColor

    // Accent
    static let accentPrimary = Color(red: 0.357, green: 0.431, blue: 0.961)     // #5B6EF5
    static let accentPrimaryHover = Color(red: 0.290, green: 0.361, blue: 0.902) // #4A5CE6
    static let accentSecondary = Color(red: 0.545, green: 0.361, blue: 0.965)    // #8B5CF6
    static let accentSuccess = Color(red: 0.204, green: 0.827, blue: 0.600)      // #34D399
    static let accentWarning = Color(red: 0.984, green: 0.749, blue: 0.141)      // #FBBF24
    static let accentDanger = Color(red: 0.937, green: 0.267, blue: 0.267)       // #EF4444

    // State
    static let stateRecording = accentDanger
    static let stateProcessing = accentSecondary
    static let stateLive = accentSuccess
    static let stateIdle = Color(nsColor: .tertiaryLabelColor)
    static let stateAIGenerated = accentSecondary.opacity(0.15)
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    var isHighlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(CasaSpace.md)
            .background(Color.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))
            .overlay(alignment: .leading) {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, CasaSpace.xs)
                }
            }
    }
}

extension View {
    func cardStyle(isHighlighted: Bool = false) -> some View {
        modifier(CardStyle(isHighlighted: isHighlighted))
    }
}

// MARK: - Native macOS Button Style Wrappers
// These wrap native styles to respect system accent color, focus rings,
// Increased Contrast, and standard macOS press feedback (no scale effect).

struct PrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: nil, action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
}

struct GhostButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: nil, action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(.borderless)
    }
}

struct SecondaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: nil, action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
