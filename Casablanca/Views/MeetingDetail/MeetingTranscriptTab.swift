import AppKit
import SwiftUI

struct MeetingTranscriptTab: View {
    @Bindable var meeting: Meeting
    let terminologyService: TerminologyService
    let onTranscribe: () -> Void
    let onSave: () -> Void

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var canReapplyTerminology: Bool {
        guard meeting.rawTranscript != nil else { return false }
        guard UserDefaults.standard.bool(forKey: AppPreferenceKey.terminologyCorrectionEnabled) else { return false }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        return !TerminologyService.parse(raw).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CasaSpace.md) {
            HStack {
                Label("Transcript", systemImage: "doc.text")
                    .font(.headline)
                    .symbolRenderingMode(.hierarchical)

                Spacer()

                if let transcript = meeting.transcript, !transcript.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("Copy transcript to clipboard")
                    .accessibilityLabel("Copy transcript")
                }

                if canReapplyTerminology {
                    Button {
                        Task { await reapplyTerminology() }
                    } label: {
                        Label("Re-apply terminology", systemImage: "wand.and.sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(terminologyService.isCorrecting)
                }

                if meeting.rawTranscript != nil {
                    Button {
                        restoreOriginalTranscript()
                    } label: {
                        Label("Restore original", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(terminologyService.isCorrecting)
                    .help("Replace the displayed transcript with the unmodified text from the recording, discarding any terminology corrections.")
                }
            }

            if let warning = terminologyService.warningMessage {
                HStack(alignment: .top, spacing: CasaSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.accentWarning)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        terminologyService.clearWarning()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss warning")
                    .accessibilityLabel("Dismiss warning")
                }
                .padding(CasaSpace.sm)
                .background(Color.accentWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if let transcript = meeting.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcriptBody(transcript)
            } else {
                ContentUnavailableView {
                    Label("No Transcript Yet", systemImage: "waveform")
                } description: {
                    Text("Transcribe the saved recording to review searchable text.")
                } actions: {
                    if recordingURL != nil {
                        Button("Transcribe") {
                            onTranscribe()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders the transcript: timestamped transcripts become collapsible
    /// ~5-minute chapters (first expanded); untimestamped transcripts fall back
    /// to plain selectable text. Uses the full reading column (no inner scroll).
    @ViewBuilder
    private func transcriptBody(_ transcript: String) -> some View {
        switch TranscriptPresentation.parse(transcript) {
        case .chapters(let chapters):
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    ChapterDisclosure(chapter: chapter, startsExpanded: index == 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .plain(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(4)
        case .empty:
            EmptyView()
        }
    }

    private func reapplyTerminology() async {
        guard let raw = meeting.rawTranscript else { return }
        let entries = TerminologyService.parse(
            UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )
        guard !entries.isEmpty else { return }

        let corrected = await terminologyService.correct(raw, entries: entries)
        guard meeting.modelContext != nil else { return }
        meeting.transcript = corrected
        onSave()
    }

    private func restoreOriginalTranscript() {
        guard let raw = meeting.rawTranscript else { return }
        meeting.transcript = raw
        terminologyService.clearWarning()
        onSave()
    }
}

/// One collapsible transcript chapter with a monospaced timestamp gutter on each
/// segment. The first chapter starts expanded; the rest collapsed.
private struct ChapterDisclosure: View {
    let chapter: TranscriptPresentation.Chapter
    let startsExpanded: Bool
    @State private var isExpanded: Bool

    init(chapter: TranscriptPresentation.Chapter, startsExpanded: Bool) {
        self.chapter = chapter
        self.startsExpanded = startsExpanded
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                ForEach(chapter.segments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: CasaSpace.md) {
                        Text(TranscriptPresentation.formatClock(segment.start))
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.textTertiary)
                            .frame(width: 56, alignment: .trailing)
                        Text(segment.text)
                            .font(.body)
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(4)
                    }
                }
            }
            .padding(.top, CasaSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(chapter.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
        }
    }
}
