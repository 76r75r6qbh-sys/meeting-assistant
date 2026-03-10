import SwiftUI

struct AudioLevelMeterView: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: CasaSpace.xs) {
            ForEach(0..<12, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(barColor(for: index))
                    .frame(width: 6, height: barHeight(for: index))
                    .animation(.easeOut(duration: CasaDuration.fast), value: level)
            }
        }
        .frame(height: 44, alignment: .bottom)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Double(index + 1) / 12.0
        let activeHeight = CGFloat(14 + index * 2)
        return level >= threshold ? activeHeight : 10
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / 12.0
        if level >= threshold {
            return index > 8 ? .accentWarning : .stateRecording
        }
        return .backgroundActive
    }
}
