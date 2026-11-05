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
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 260
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
    /// Constant minimum width of the detail column. Sidebar minimum plus this
    /// equals the window minimum, so the window can still be dragged below the
    /// sidebar breakpoint (where the sidebar collapses) while content-heavy
    /// screens are never squeezed to nothing by the sidebar or an inspector.
    static let detailColumnMinWidth: CGFloat = windowMinWidth - sidebarMinWidth
    /// Below this window width the sidebar collapses to a controlled detail-only
    /// layout instead of being silently dropped by NavigationSplitView.
    static let layoutSidebarBreakpoint: CGFloat = 600
    /// At/above this window width the meeting-detail trailing inspector is shown
    /// by default; below it the inspector hides so the sidebar stays visible.
    static let layoutInspectorBreakpoint: CGFloat = 880
    /// Width limits of the trailing inspector panel (`widthGatedInspector`:
    /// notes workspace Prep/To-Dos, recorded-meeting details).
    static let inspectorColumnMinWidth: CGFloat = 260
    static let inspectorColumnMaxWidth: CGFloat = 560
    /// Narrowest window in which an open inspector fits beside a full-width
    /// sidebar and the detail column's minimum. `layoutInspectorBreakpoint`
    /// must not be below this (enforced by a test); the panel additionally caps
    /// its width so the column beside it keeps `detailColumnMinWidth`.
    static let inspectorMinimumWindowWidth: CGFloat = sidebarMaxWidth + detailColumnMinWidth + inspectorColumnMinWidth
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

    /// Whether a trailing inspector may be open at this width. Only `.expanded`
    /// is wide enough (see `CasaLayout.inspectorMinimumWindowWidth`).
    var allowsInspector: Bool { self == .expanded }
}

private struct LayoutWidthClassKey: EnvironmentKey {
    static let defaultValue: LayoutWidthClass = .expanded
}

extension EnvironmentValues {
    /// The main window's responsive width tier, published by ContentView to its
    /// detail column. Defaults to `.expanded` outside the split (previews, tests).
    var layoutWidthClass: LayoutWidthClass {
        get { self[LayoutWidthClassKey.self] }
        set { self[LayoutWidthClassKey.self] = newValue }
    }
}

// MARK: - Width-Gated Inspector

extension View {
    /// A trailing inspector panel beside this view, shown only while the window
    /// is wide enough to hold it (`LayoutWidthClass.allowsInspector`).
    ///
    /// Deliberately not SwiftUI's `.inspector`: inside the NavigationSplitView's
    /// detail column that is a nested `NSSplitView` whose Auto Layout minimums
    /// (content column + inspector column) are hard constraints SwiftUI does not
    /// report through the detail column's (constant) minimum size. Whenever the
    /// window offers the detail column less than that -- shrinking toward the
    /// window minimum, the sidebar collapsing or expanding at the compact
    /// breakpoint -- the two split views fight over the width and re-dirty the
    /// constraint pass until AppKit aborts ("more Update Constraints in Window
    /// passes than there are views"). A width gate alone does not prevent that:
    /// it follows the window width a run-loop turn late, and the attached
    /// nested split re-dirties the pass even while collapsed. This panel is
    /// plain SwiftUI layout inside the detail column, so the only split view
    /// left is the sidebar's, whose column minimums are constant.
    ///
    /// `isPresented` is the user's intent: it is never cleared by the gate, so
    /// an inspector opened (or auto-opened) while the window is too narrow
    /// shows once the window is wide enough again.
    func widthGatedInspector<Inspector: View>(
        isPresented: Binding<Bool>,
        idealWidth: CGFloat,
        @ViewBuilder content: @escaping () -> Inspector
    ) -> some View {
        modifier(InspectorPanelModifier(
            isPresented: isPresented,
            idealWidth: idealWidth,
            respectsWidthClass: true,
            inspector: content
        ))
    }

    /// The same trailing panel without the width gate. Only for tests that
    /// prove the panel itself keeps the split stable at every window width.
    func ungatedInspectorPanel<Inspector: View>(
        isPresented: Binding<Bool>,
        idealWidth: CGFloat,
        @ViewBuilder content: @escaping () -> Inspector
    ) -> some View {
        modifier(InspectorPanelModifier(
            isPresented: isPresented,
            idealWidth: idealWidth,
            respectsWidthClass: false,
            inspector: content
        ))
    }
}

private struct InspectorPanelModifier<Inspector: View>: ViewModifier {
    @Binding var isPresented: Bool
    let idealWidth: CGFloat
    let respectsWidthClass: Bool
    let inspector: () -> Inspector
    @Environment(\.layoutWidthClass) private var widthClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The user's dragged width; nil until the first drag (then `idealWidth`).
    @State private var draggedWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringHandle = false
    /// Width the detail column gives content + panel together.
    @State private var availableWidth: CGFloat?

    private var isShown: Bool {
        isPresented && (!respectsWidthClass || widthClass.allowsInspector)
    }

    /// The ideal or dragged width, within the inspector limits, and never so
    /// wide that the content beside it gets less than `detailColumnMinWidth`.
    private var panelWidth: CGFloat {
        let width = Self.clamped(draggedWidth ?? idealWidth)
        guard let availableWidth else { return width }
        let roomLeft = availableWidth - CasaLayout.detailColumnMinWidth - 1
        return min(width, max(CasaLayout.inspectorColumnMinWidth, roomLeft))
    }

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            // Constant minimum, so neither the notes editor nor the panel can
            // push a content-derived minimum into the split's constraint pass.
            content
                .stableSplitColumnMinimumSize()
            if isShown {
                resizeHandle
                    // Above the panel, so its full hit area reaches the handle.
                    .zIndex(1)
                inspector()
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : CasaAnimation.fast, value: isShown)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    availableWidth = width
                }
            }
        }
    }

    /// A hairline divider with a wider invisible hit area that drags the
    /// panel's width between the inspector limits.
    private var resizeHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != isHoveringHandle else { return }
                        isHoveringHandle = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .onDisappear {
                        // Hidden while hovered (window narrowed, toggle): no exit event comes.
                        if isHoveringHandle { NSCursor.pop() }
                        isHoveringHandle = false
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? panelWidth
                                dragStartWidth = start
                                draggedWidth = Self.clamped(start - value.translation.width)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
            .accessibilityHidden(true)
    }

    private static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, CasaLayout.inspectorColumnMinWidth), CasaLayout.inspectorColumnMaxWidth)
    }
}

// MARK: - Split-Column Minimum Size

extension View {
    /// Makes a NavigationSplitView column (or an inspector column) report a
    /// constant minimum size instead of one derived from its content.
    ///
    /// The column's hosting view publishes its content's minimum size to the
    /// split view during AppKit's Update Constraints pass. When that minimum
    /// depends on the content -- text that wraps with the column's width, a
    /// card that appears when the calendar refreshes -- each change re-dirties
    /// the pass it is computed in. Enough of those and AppKit aborts the app
    /// ("more Update Constraints in Window passes than there are views"), which
    /// is how 0.16.0 crashed shortly after launch and while shrinking the
    /// window. A flexible frame with both a minimum and a maximum sizes itself
    /// to the proposal, clamped, independent of its content, so the published
    /// minimum never changes. The window's own minimum still applies.
    func stableSplitColumnMinimumSize(minWidth: CGFloat = 0) -> some View {
        frame(minWidth: minWidth, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
