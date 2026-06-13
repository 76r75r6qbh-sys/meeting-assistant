import SwiftUI

struct MeetingDetailInspector: View {
    let meeting: Meeting
    let canExport: Bool

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CasaSpace.xl) {
                recordingInspectorSection

                if !meeting.participants.isEmpty {
                    participantsInspectorSection
                }

                exportInspectorSection
            }
            .padding(CasaSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundSecondary)
    }

    @ViewBuilder
    private var recordingInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Recording")

            if recordingURL != nil {
                HStack(spacing: CasaSpace.sm) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved locally")
                            .font(.subheadline)
                            .foregroundStyle(Color.textPrimary)
                        if let duration = meeting.recordingDuration {
                            Text(duration.formattedRecordingDuration)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(CasaSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))

                // NOTE: A full inline audio player (waveform + scrubber) is deferred
                // to a later polish pass; "Show in Finder" is available in the ⋯ menu.
            } else {
                Text("No recording saved for this meeting.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var participantsInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Participants")

            ForEach(Array(meeting.participants.enumerated()), id: \.offset) { _, name in
                HStack(spacing: CasaSpace.sm) {
                    Text(initials(for: name))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.backgroundTertiary, in: Circle())
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var exportInspectorSection: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            inspectorLabel("Export")

            if meeting.appleNotesSummaryNoteID != nil || meeting.appleNotesRawNotesNoteID != nil {
                Label("Exported to Apple Notes", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentSuccess)
                    .symbolRenderingMode(.hierarchical)
            } else if canExport {
                Text("Not exported yet. Use the Export action to save to your configured destination.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            } else {
                Text("Generate a summary or transcript to enable export.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func inspectorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Color.textTertiary)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
