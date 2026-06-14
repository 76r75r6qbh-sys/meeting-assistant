import SwiftUI

// MARK: - Spacing (4pt base grid)

enum CasaSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let standard: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

// MARK: - Corner Radius

enum CasaRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

// MARK: - Animation Durations (legacy — prefer CasaAnimation springs)

enum CasaDuration {
    static let micro: Double = 0.1
    static let fast: Double = 0.15
    static let standard: Double = 0.2
    static let emphasis: Double = 0.3
    static let slow: Double = 0.4
}

// MARK: - Spring Animations (Apple HIG recommended)

enum CasaAnimation {
    static let micro = Animation.spring(response: 0.15, dampingFraction: 0.9)
    static let fast = Animation.spring(response: 0.2, dampingFraction: 0.85)
    static let standard = Animation.smooth
    static let emphasis = Animation.spring(response: 0.4, dampingFraction: 0.75)
    static let slow = Animation.spring(response: 0.5, dampingFraction: 0.8)
}

// MARK: - Layout Constants

enum CasaLayout {
    static let sidebarWidth: CGFloat = 220
    static let sidebarCollapsedWidth: CGFloat = 60
    static let sidebarItemHeight: CGFloat = 28
    static let toolbarHeight: CGFloat = 52
    static let contentMaxWidth: CGFloat = 720
    static let inspectorWidth: CGFloat = 280
    static let prepInspectorMin: CGFloat = 220
    static let prepInspectorMaxFraction: CGFloat = 0.5   // 50% of window width
    static let prepInspectorDefault: CGFloat = 300
    static let windowDefaultWidth: CGFloat = 1080
    static let windowDefaultHeight: CGFloat = 720
    static let windowMinWidth: CGFloat = 480
    static let windowMinHeight: CGFloat = 500
    /// Below this window width the sidebar collapses to a controlled detail-only
    /// layout instead of being silently dropped by NavigationSplitView.
    static let layoutSidebarBreakpoint: CGFloat = 600
    /// At/above this window width the meeting-detail trailing inspector is shown
    /// by default; below it the inspector hides so the sidebar stays visible.
    static let layoutInspectorBreakpoint: CGFloat = 880
    static let popoverWidth: CGFloat = 288

    // Modal / sheet widths — standard tiers so sheets don't carry magic numbers.
    static let modalWidthSmall: CGFloat = 460
    static let modalWidthMedium: CGFloat = 520
    static let modalWidthLarge: CGFloat = 560
    static let modalWidthXL: CGFloat = 600
}

/// Responsive width tier for the main window, derived from its measured width.
/// Drives both the sidebar column visibility and the meeting-detail inspector so
/// that a narrow window hides the inspector (keeping the sidebar) and a very
/// small window gracefully collapses the sidebar rather than dropping it.
enum LayoutWidthClass {
    case compact   // sidebar collapsed, inspector hidden
    case regular   // sidebar shown, inspector hidden
    case expanded  // sidebar shown, inspector shown

    static func from(width: CGFloat) -> LayoutWidthClass {
        if width < CasaLayout.layoutSidebarBreakpoint { return .compact }
        if width < CasaLayout.layoutInspectorBreakpoint { return .regular }
        return .expanded
    }
}

// MARK: - Reduce-Motion-Aware Animation

extension View {
    /// Applies `animation` to changes of `value`, but honors Reduce Motion: when
    /// the system "Reduce Motion" accessibility setting is on, the animation is
    /// dropped (`nil`) so the change is instantaneous. Use this instead of a bare
    /// `.animation(_:value:)` for any non-essential motion.
    func casaAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(CasaAnimationModifier(animation: animation, value: value))
    }
}

private struct CasaAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
