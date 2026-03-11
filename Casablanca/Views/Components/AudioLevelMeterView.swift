import SwiftUI

struct AudioLevelMeterView: View {
    private static let barCount = 7
    private static let barSpacing: CGFloat = 3
    private static let barWidth = CasaSpace.xs
    private static let containerHeight: CGFloat = 28
    private static let inactiveBarHeight: CGFloat = 6
    private static let minActiveBarHeight: CGFloat = 8
    private static let maxActiveBarHeight: CGFloat = 24
    private static let minimumVisibleLevel = 0.02

    let level: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(barColor(for: index))
                    .frame(width: Self.barWidth, height: barHeight(for: index))
                    .animation(reduceMotion ? nil : CasaAnimation.micro, value: level)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: Self.containerHeight, alignment: .bottom)
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isActive(index) else { return Self.inactiveBarHeight }

        let progress = CGFloat(index) / CGFloat(max(Self.barCount - 1, 1))
        return Self.minActiveBarHeight + ((Self.maxActiveBarHeight - Self.minActiveBarHeight) * progress)
    }

    private func barColor(for index: Int) -> Color {
        guard isActive(index) else { return .backgroundActive }
        return index >= Self.barCount - 2 ? .accentWarning.opacity(0.85) : .textSecondary
    }

    private func isActive(_ index: Int) -> Bool {
        level >= threshold(for: index)
    }

    private func threshold(for index: Int) -> Double {
        if index == 0 {
            return Self.minimumVisibleLevel
        }

        return Double(index + 1) / Double(Self.barCount)
    }
}
