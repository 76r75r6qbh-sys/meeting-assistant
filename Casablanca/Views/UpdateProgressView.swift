// Casablanca/Views/UpdateProgressView.swift
import SwiftUI

struct UpdateProgressView: View {
    let release: ReleaseInfo
    let progress: Double
    let phase: Phase
    let onCancel: () -> Void

    enum Phase { case downloading, staged }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installing Casablanca \(release.version.description)")
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if phase == .downloading {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var label: String {
        switch phase {
        case .downloading: return "Downloading… \(Int(progress * 100))%"
        case .staged: return "Preparing to install. Casablanca will restart."
        }
    }
}
