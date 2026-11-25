import SwiftUI

/// A modal, blurred-background progress overlay with a spinner, title, and
/// supporting message. Used for blocking operations such as finalizing a
/// recording before transcription.
struct BlockingProgressOverlay: View {
    let title: String
    let message: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: CasaSpace.md) {
                ProgressView()
                    .controlSize(.regular)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                Text(message)
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(CasaSpace.xxl)
            .frame(width: 360)
            .background(Color.backgroundPrimary.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))
            .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
        .transition(.opacity)
    }
}
