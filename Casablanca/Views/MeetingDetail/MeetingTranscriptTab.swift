import AppKit
import SwiftUI

struct MeetingTranscriptTab: View {
    @Bindable var meeting: Meeting
    let terminologyService: TerminologyService
    let onTranscribe: () -> Void
    let onSave: () -> Void
    var speakerAnalysisStore = SpeakerAnalysisStore()
    /// Runs after the speakers bar renamed or merged a speaker, once the
    /// meeting is saved (Phase 2: the "regenerate summary with names" offer).
    var onSpeakersChanged: ((Meeting) -> Void)? = nil
    /// A timestamp-link jump for this meeting to carry out (scroll, play).
    var jump: TimestampJump? = nil
    /// The detail column's scroll view, for scrolling to the jump's line.
    var scrollProxy: ScrollViewProxy? = nil
    /// The meeting is being (re)transcribed: jumps scroll but do not play.
    var isTranscribing: Bool = false
    /// Runs once `jump` is carried out, so it is not replayed.
    var onJumpHandled: () -> Void = {}
    var player: AudioClipPlayer = .shared

    /// The transcript line the last jump landed on (expanded, highlighted).
    @State private var focusedLineIndex: Int?
    /// Playing the recording failed; the transport shows it unavailable.
    @State private var playbackFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recordingURL: URL? {
        guard let path = meeting.recordingFileURL else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The mixed recording when its file is on disk (the transport's source).
    private var playableRecordingURL: URL? {
        TimestampJumpPlan.recordingURL(path: meeting.recordingFileURL)
    }

    private var canPlay: Bool {
        TimestampJumpPlan.shouldPlay(
            status: meeting.status,
            isTranscribing: isTranscribing,
            hasRecordingFile: playableRecordingURL != nil
        )
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

            if !meeting.speakers.isEmpty {
                SpeakersBar(meeting: meeting, store: speakerAnalysisStore) { changed in
                    onSave()
                    onSpeakersChanged?(changed)
                }
            }

            if let transcript = meeting.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let playableRecordingURL {
                    TranscriptTransportBar(
                        recordingURL: playableRecordingURL,
                        canPlay: canPlay,
                        isUnavailable: playbackFailed,
                        knownDuration: meeting.recordingDuration,
                        onPlay: { startPlayback(at: $0) },
                        player: player
                    )
                }
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
        .onChange(of: jump?.token, initial: true) { _, _ in
            carryOutJump()
        }
        .onChange(of: meeting.id) { _, _ in
            focusedLineIndex = nil
            playbackFailed = false
        }
    }

    // MARK: - Timestamp jumps

    /// Expands and highlights the nearest line at or before the jump's time,
    /// scrolls it to the top, and plays the recording from the jump's time
    /// when the meeting allows it. A meeting without a recording file only
    /// scrolls; a transcript without timestamps only shows the tab.
    private func carryOutJump() {
        guard let jump, jump.meetingID == meeting.id else { return }
        defer { onJumpHandled() }

        if case .chapters(let chapters) = TranscriptPresentation.parse(meeting.transcript ?? ""),
           let index = TimestampJumpPlan.lineIndex(
               atOrBefore: jump.seconds,
               starts: chapters.flatMap { $0.segments.map(\.start) }
           ) {
            focusedLineIndex = index
            if let scrollProxy {
                // Let the chapter expand and lay out before scrolling to it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(reduceMotion ? nil : CasaAnimation.standard) {
                        scrollProxy.scrollTo(TranscriptLineAnchor(index: index), anchor: .top)
                    }
                }
            }
        }

        if canPlay {
            startPlayback(at: jump.seconds)
        }
    }

    /// Plays the mixed recording from `seconds`; a failure is logged and
    /// shown as an unavailable ▶ (R2).
    private func startPlayback(at seconds: Double) {
        guard canPlay, let url = playableRecordingURL else { return }
        do {
            try player.play(url: url, from: seconds)
            playbackFailed = false
        } catch {
            Log.recording.error("Recording playback failed: \(error.localizedDescription, privacy: .public)")
            playbackFailed = true
        }
    }

    /// Renders the transcript: timestamped transcripts become collapsible
    /// ~5-minute chapters (first expanded); untimestamped transcripts fall back
    /// to plain selectable text. Uses the full reading column (no inner scroll).
    @ViewBuilder
    private func transcriptBody(_ transcript: String) -> some View {
        switch TranscriptPresentation.parse(transcript) {
        case .chapters(let chapters):
            VStack(alignment: .leading, spacing: CasaSpace.xs) {
                // Chapters are identified by their window, not by the parse's
                // fresh UUIDs, so a re-render keeps each one's expansion.
                let firstIndices = Self.firstLineIndices(chapters)
                ForEach(Array(chapters.enumerated()), id: \.element.startSeconds) { index, chapter in
                    ChapterDisclosure(
                        chapter: chapter,
                        startsExpanded: index == 0,
                        firstLineIndex: firstIndices[index],
                        focusedLineIndex: focusedLineIndex,
                        meetingID: meeting.id
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // This view is reused across meetings; another meeting starts
            // with fresh chapter expansion.
            .id(meeting.id)
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

    /// Index of each chapter's first line in the whole transcript.
    static func firstLineIndices(_ chapters: [TranscriptPresentation.Chapter]) -> [Int] {
        var indices: [Int] = []
        var next = 0
        for chapter in chapters {
            indices.append(next)
            next += chapter.segments.count
        }
        return indices
    }

    private func reapplyTerminology() async {
        guard let raw = meeting.rawTranscript else { return }
        let entries = TerminologyService.parse(
            UserDefaults.standard.string(forKey: AppPreferenceKey.terminologyList) ?? ""
        )
        guard !entries.isEmpty else { return }

        // A labelled transcript keeps its speaker prefixes through the correction.
        let knownSpeakers = Set(
            meeting.speakers.map { TranscriptLineFormat.sanitizedSpeakerName($0.displayName) }.filter { !$0.isEmpty }
        )
        let corrected = await terminologyService.correct(raw, entries: entries, knownSpeakers: knownSpeakers)
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

/// Scroll anchor of one transcript line (index in the whole transcript).
struct TranscriptLineAnchor: Hashable {
    let index: Int
}

/// One collapsible transcript chapter with a monospaced timestamp gutter on each
/// segment. The first chapter starts expanded; the rest collapsed. A chapter
/// holding the focused line (a timestamp jump) expands and highlights it.
/// The gutter time is a timestamp link: it jumps (and plays) from that line.
private struct ChapterDisclosure: View {
    let chapter: TranscriptPresentation.Chapter
    let startsExpanded: Bool
    let firstLineIndex: Int
    let focusedLineIndex: Int?
    let meetingID: UUID
    @State private var isExpanded: Bool

    init(
        chapter: TranscriptPresentation.Chapter,
        startsExpanded: Bool,
        firstLineIndex: Int,
        focusedLineIndex: Int?,
        meetingID: UUID
    ) {
        self.chapter = chapter
        self.startsExpanded = startsExpanded
        self.firstLineIndex = firstLineIndex
        self.focusedLineIndex = focusedLineIndex
        self.meetingID = meetingID
        _isExpanded = State(initialValue: startsExpanded || Self.contains(focusedLineIndex, chapter: chapter, first: firstLineIndex))
    }

    private static func contains(_ index: Int?, chapter: TranscriptPresentation.Chapter, first: Int) -> Bool {
        guard let index else { return false }
        return index >= first && index < first + chapter.segments.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: CasaSpace.sm) {
                ForEach(Array(chapter.segments.enumerated()), id: \.offset) { offset, segment in
                    let lineIndex = firstLineIndex + offset
                    HStack(alignment: .firstTextBaseline, spacing: CasaSpace.md) {
                        gutter(segment.start)
                            .frame(width: 56, alignment: .trailing)
                        Text(segment.text)
                            .font(.body)
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(4)
                    }
                    .padding(.vertical, CasaSpace.xxs)
                    .background(
                        lineIndex == focusedLineIndex ? Color.accentPrimary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CasaRadius.sm)
                    )
                    .id(TranscriptLineAnchor(index: lineIndex))
                }
            }
            .padding(.top, CasaSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(chapter.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
        }
        .onChange(of: focusedLineIndex) { _, index in
            if Self.contains(index, chapter: chapter, first: firstLineIndex) {
                isExpanded = true
            }
        }
    }

    /// The line's time as a timestamp link to itself.
    private func gutter(_ start: TimeInterval) -> some View {
        var label = AttributedString(TranscriptPresentation.formatClock(start))
        label.link = TimestampLinks.url(meetingID: meetingID, seconds: start)
        return Text(label)
            .font(.caption.monospaced())
            .help("Play from here")
    }
}
