import AppKit

/// Formats and applies the Dock-tile badge for the open-approvals count.
/// Kept tiny and side-effect-free (except `apply`) so the formatter is unit
/// testable without touching `NSApp`.
enum DockBadge {
    /// The dock-tile label for a pending count: the number, or nil at 0.
    static func label(for count: Int) -> String? { count > 0 ? "\(count)" : nil }

    /// Apply the label to the dock tile. Main-thread only.
    @MainActor static func apply(count: Int) {
        NSApp.dockTile.badgeLabel = label(for: count)
    }
}
