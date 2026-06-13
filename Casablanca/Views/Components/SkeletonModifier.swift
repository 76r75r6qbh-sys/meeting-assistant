import SwiftUI

/// A loading-skeleton modifier: redacts the content as a placeholder and, when
/// loading, lays a subtle animated shimmer over it. Honors Reduce Motion — the
/// shimmer becomes a static placeholder when motion is reduced.
///
/// Usage:
///   Text("Some content")
///       .casaSkeleton(isLoading)
struct SkeletonModifier: ViewModifier {
    let isLoading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if isLoading {
            content
                .redacted(reason: .placeholder)
                .overlay {
                    if reduceMotion {
                        // Static placeholder under Reduce Motion — no sweeping motion.
                        EmptyView()
                    } else {
                        shimmer
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Loading")
        } else {
            content
        }
    }

    private var shimmer: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.35),
                    Color.white.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * 0.6)
            .offset(x: phase * width)
            .blendMode(.plusLighter)
            .onAppear {
                phase = -1
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
        }
        .mask(Rectangle())
    }
}

extension View {
    /// Applies a loading skeleton (placeholder redaction + shimmer) while
    /// `isLoading` is true. Reduce-Motion-aware.
    func casaSkeleton(_ isLoading: Bool) -> some View {
        modifier(SkeletonModifier(isLoading: isLoading))
    }
}
