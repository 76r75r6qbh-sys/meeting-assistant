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
    /// Plays the recording for jumps (the pinned transport uses the same one).
    var playback: TranscriptPlayback = .shared

    /// The line the last jump landed on (expanded, highlighted), with the
    /// jump's token so a repeat jump to the same line still expands it.
    @State private var focus: TranscriptFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            if !meeting.speakers.isEmpty {
                SpeakersBar(meeting: meeting, store: speakerAnalysisStore) { changed in
                    onSave()
                    onSpeakersChanged?(changed)
                }
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
        // One handler for meeting changes and jumps, so a reset for a new
        // meeting can never undo the jump that brought us to it.
        .onChange(of: TranscriptJumpKey(meetingID: meeting.id, token: jump?.token), initial: true) { old, new in
            if old.meetingID != new.meetingID, jump?.meetingID != meeting.id {
                focus = nil
            }
            carryOutJump()
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
            focus = TranscriptFocus(token: jump.token, meetingID: meeting.id, index: index)
            // First attempt on the next run-loop turn, after this update's
            // layout. A chapter that had to expand retries once when the
            // line appears (`onFocusedLineAppear`).
            DispatchQueue.main.async { scroll(to: index) }
        }

        playback.play(meeting, isTranscribing: isTranscribing, from: jump.seconds)
    }

    private func scroll(to index: Int) {
        guard let scrollProxy else { return }
        withAnimation(reduceMotion ? nil : CasaAnimation.standard) {
            scrollProxy.scrollTo(TranscriptLineAnchor(index: index), anchor: .top)
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
                        // Never another meeting's focus (this tab is reused).
                        focus: TranscriptFocus.scoped(focus, to: meeting.id),
                        meetingID: meeting.id,
                        onFocusedLineAppear: { scroll(to: $0) }
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

/// The line a jump landed on. The token differs per jump, so jumping to the
/// same line again (after collapsing its chapter) is still a change.
struct TranscriptFocus: Equatable {
    let token: UUID
    /// The meeting the jump was for. The tab is reused across meetings, so a
    /// focus only counts for its own meeting (see ``scoped(_:to:)``).
    let meetingID: UUID
    let index: Int

    /// `focus` when it belongs to `meetingID`, else `nil`: another meeting's
    /// focus never expands, highlights or scrolls this one.
    static func scoped(_ focus: TranscriptFocus?, to meetingID: UUID) -> TranscriptFocus? {
        focus?.meetingID == meetingID ? focus : nil
    }

    /// Whether a chapter of `meetingID` should start expanded (and wait for
    /// the line to appear) for `focus` when it is first built.
    static func initialTarget(_ focus: TranscriptFocus?, meetingID: UUID, chapterLines lines: Range<Int>) -> TranscriptFocus? {
        guard let focus = scoped(focus, to: meetingID), focus.expands(chapterLines: lines) else { return nil }
        return focus
    }

    /// Whether a chapter holding lines `lines` must expand for this focus.
    func expands(chapterLines lines: Range<Int>) -> Bool {
        lines.contains(index)
    }

    /// What a chapter does when the focus changes: the focus it must expand
    /// for (and whose line it then waits to appear), or `nil` when the line
    /// is elsewhere or the chapter is already open.
    static func expansionTarget(
        _ focus: TranscriptFocus?,
        meetingID: UUID,
        chapterLines lines: Range<Int>,
        isExpanded: Bool
    ) -> TranscriptFocus? {
        guard let focus = scoped(focus, to: meetingID), !isExpanded, focus.expands(chapterLines: lines) else { return nil }
        return focus
    }
}

private struct TranscriptJumpKey: Equatable {
    let meetingID: UUID
    let token: UUID?
}

/// One collapsible transcript chapter with a monospaced timestamp gutter on each
/// segment. The first chapter starts expanded; the rest collapsed. A chapter
/// holding the focused line (a timestamp jump) expands and highlights it.
/// The gutter time is a timestamp link: it jumps (and plays) from that line.
private struct ChapterDisclosure: View {
    let chapter: TranscriptPresentation.Chapter
    let startsExpanded: Bool
    let firstLineIndex: Int
    let focus: TranscriptFocus?
    let meetingID: UUID
    /// Called when the focused line appears because this chapter expanded
    /// for the focus (the scroll's retry).
    let onFocusedLineAppear: (Int) -> Void
    @State private var isExpanded: Bool
    /// The focus this chapter expanded for, until its line has appeared.
    @State private var awaitingAppear: TranscriptFocus?

    init(
        chapter: TranscriptPresentation.Chapter,
        startsExpanded: Bool,
        firstLineIndex: Int,
        focus: TranscriptFocus?,
        meetingID: UUID,
        onFocusedLineAppear: @escaping (Int) -> Void
    ) {
        self.chapter = chapter
        self.startsExpanded = startsExpanded
        self.firstLineIndex = firstLineIndex
        self.focus = focus
        self.meetingID = meetingID
        self.onFocusedLineAppear = onFocusedLineAppear
        let lines = firstLineIndex..<(firstLineIndex + chapter.segments.count)
        let target = TranscriptFocus.initialTarget(focus, meetingID: meetingID, chapterLines: lines)
        _isExpanded = State(initialValue: startsExpanded || target != nil)
        _awaitingAppear = State(initialValue: startsExpanded ? nil : target)
    }

    private var lines: Range<Int> { firstLineIndex..<(firstLineIndex + chapter.segments.count) }

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
                        lineIndex == TranscriptFocus.scoped(focus, to: meetingID)?.index ? Color.accentPrimary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CasaRadius.sm)
                    )
                    .id(TranscriptLineAnchor(index: lineIndex))
                    .onAppear {
                        guard let awaiting = TranscriptFocus.scoped(awaitingAppear, to: meetingID),
                              awaiting.index == lineIndex else { return }
                        awaitingAppear = nil
                        onFocusedLineAppear(lineIndex)
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
        // Keyed on the whole focus (token included): a repeat jump to a line
        // whose chapter the user collapsed expands it again.
        .onChange(of: focus) { _, newFocus in
            guard let target = TranscriptFocus.expansionTarget(
                newFocus, meetingID: meetingID, chapterLines: lines, isExpanded: isExpanded
            ) else { return }
            awaitingAppear = target
            isExpanded = true
        }
        // Collapsed before the focused line appeared: drop the pending retry,
        // so a later manual expand does not scroll.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { awaitingAppear = nil }
        }
    }

    /// The line's time as a timestamp link to itself.
    private func gutter(_ start: TimeInterval) -> some View {
        var label = AttributedString(TranscriptPresentation.formatClock(start))
        label.link = TimestampLinks.url(meetingID: meetingID, seconds: start)
        // Still a link, in the gutter's quiet tertiary colour.
        return Text(label)
            .font(.caption.monospaced())
            .foregroundStyle(Color.textTertiary)
            .tint(Color.textTertiary)
            .help("Play from here")
    }
}
