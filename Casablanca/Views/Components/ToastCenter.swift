import SwiftUI

/// A single transient toast: a short message, an optional action button, and a
/// stable id so the overlay can animate replacements.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let actionLabel: String?
    let action: (() -> Void)?

    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

/// App-wide, MainActor toast queue. Holds at most one visible toast at a time
/// (the latest wins) and auto-dismisses it after a duration. Installed on
/// `AppModel` and rendered once in `ContentView` via `.toastOverlay(_:)`.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    /// Shows a toast. Replaces any visible toast (latest wins). Pass an
    /// `actionLabel`+`action` to surface a button (e.g. "Undo"). Auto-dismisses
    /// after `duration` seconds.
    func show(
        message: String,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil,
        duration: TimeInterval = 4
    ) {
        let toast = Toast(message: message, actionLabel: actionLabel, action: action)
        current = toast
        scheduleDismiss(of: toast.id, after: duration)
    }

    /// Dismisses the current toast immediately (e.g. after the action fires).
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    private func scheduleDismiss(of id: UUID, after duration: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // Only dismiss if this toast is still the visible one (a newer toast
            // may have replaced it).
            if self?.current?.id == id {
                self?.current = nil
            }
        }
    }
}

// MARK: - Overlay view

/// Bottom-center capsule overlay that renders the current toast. Slide-in from
/// the bottom (Reduce-Motion-aware), with an optional trailing action button.
struct ToastView: View {
    let toast: Toast
    let onAction: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: CasaSpace.md) {
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            if let label = toast.actionLabel, toast.action != nil {
                Divider()
                    .frame(height: 16)
                Button(label, action: onAction)
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, CasaSpace.lg)
        .padding(.vertical, CasaSpace.md)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }
}

// MARK: - Overlay modifier

extension View {
    /// Renders the toast center's current toast as a bottom-center overlay over
    /// the whole window. Install once near the app root (ContentView).
    func toastOverlay(_ toastCenter: ToastCenter) -> some View {
        modifier(ToastOverlayModifier(toastCenter: toastCenter))
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @Bindable var toastCenter: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = toastCenter.current {
                    ToastView(toast: toast) {
                        toast.action?()
                        toastCenter.dismiss()
                    }
                    .padding(.bottom, CasaSpace.xxl)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    .id(toast.id)
                }
            }
            .animation(reduceMotion ? nil : CasaAnimation.standard, value: toastCenter.current)
    }
}
