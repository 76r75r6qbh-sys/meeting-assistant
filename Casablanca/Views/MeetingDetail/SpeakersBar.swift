import SwiftUI

/// The meeting's speakers above the transcript: one chip per speaker with its
/// name, its share of the talk time, a ▶ sample from its speaker track, and a
/// rename popover with participant names and the LLM's suggestions.
///
/// "Suggest names" asks the LLM on demand (whatever the automatic setting);
/// suggestions that arrive later (the pipeline's opt-in step) show up through
/// the store's change notification. Nothing is applied without a tap.
///
/// With voice profiles on (Settings → Privacy), a named speaker whose track is
/// still on disk gets "Remember voice…" in its context menu (A7); voice
/// matches arrive as suggestions like the LLM's.
///
/// Renames rewrite only the transcript's line prefixes (`SpeakerRenamer`).
/// `onSpeakersChanged` runs after every rename, merge or "this is me" change,
/// so the owner can save and (Phase 2) offer to regenerate the summary.
struct SpeakersBar: View {
    let meeting: Meeting
    let store: SpeakerAnalysisStore
    var onSpeakersChanged: ((Meeting) -> Void)? = nil
    private let proposer: SpeakerNameProposer
    private let voiceProfiles: VoiceProfileStore
    private let diarizer: SpeakerDiarizing

    @AppStorage(AppPreferenceKey.voiceProfilesEnabled) private var voiceProfilesEnabled = false
    @ObservedObject private var player = AudioClipPlayer.shared
    @State private var record: SpeakerAnalysisRecord?
    /// The speaker whose clip was started last, so only its chip shows ■
    /// when several speakers share one track.
    @State private var playingSpeakerID: String?
    /// Speakers whose clip failed to play.
    @State private var unavailableClips: Set<String> = []
    @State private var renamingSpeakerID: String?
    @State private var isSuggesting = false
    /// Shown after "Suggest names" found nothing.
    @State private var suggestionNote: String?
    /// The speaker whose "Remember voice…" sheet is open.
    @State private var rememberingSpeaker: SpeakerInfo?

    init(
        meeting: Meeting,
        store: SpeakerAnalysisStore,
        proposer: SpeakerNameProposer = SpeakerNameProposer(),
        voiceProfiles: VoiceProfileStore = VoiceProfileStore(),
        diarizer: SpeakerDiarizing = FluidAudioDiarizer.shared,
        onSpeakersChanged: ((Meeting) -> Void)? = nil
    ) {
        self.meeting = meeting
        self.store = store
        self.proposer = proposer
        self.voiceProfiles = voiceProfiles
        self.diarizer = diarizer
        self.onSpeakersChanged = onSpeakersChanged
    }

    var body: some View {
        let speakers = meeting.speakers
        let percentages = SpeakerClipSelector.talkTimePercentages(meeting.speakerSegments)

        VStack(alignment: .leading, spacing: CasaSpace.xs) {
            FlowLayout(spacing: CasaSpace.xs) {
                ForEach(speakers) { speaker in
                    chip(for: speaker, percentage: percentages[speaker.id])
                }
                if canSuggestNames {
                    suggestButton
                }
            }
            if let suggestionNote {
                Text(suggestionNote)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            if let caption = Self.failureCaption(record?.diarization) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: meeting.id) {
            record = store.load(meeting.id)
            unavailableClips = []
            suggestionNote = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SpeakerAnalysisStore.recordDidChange)) { note in
            guard note.userInfo?[SpeakerAnalysisStore.meetingIDKey] as? UUID == meeting.id else { return }
            record = store.load(meeting.id)
        }
        .sheet(item: $rememberingSpeaker) { speaker in
            SaveVoiceProfileSheet(speakerName: speaker.displayName) { consentGiven in
                try await rememberVoice(of: speaker, consentGiven: consentGiven)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers")
    }

    /// Longest a name is shown in a chip before it truncates, so one chip
    /// always fits the narrowest detail column.
    static let maxNameWidth: CGFloat = 150

    /// "Speaker recognition unavailable: …" for a failed diarization; nil otherwise.
    static func failureCaption(_ outcome: DiarizationOutcome?) -> String? {
        guard case .failed(let reason) = outcome else { return nil }
        return "Speaker recognition unavailable: \(reason)"
    }

    // MARK: - Chip

    @ViewBuilder
    private func chip(for speaker: SpeakerInfo, percentage: Int?) -> some View {
        let suggestions = suggestions(for: speaker.id)
        HStack(spacing: CasaSpace.xs) {
            Button {
                renamingSpeakerID = speaker.id
            } label: {
                HStack(spacing: CasaSpace.xxs) {
                    if speaker.isUser {
                        Image(systemName: "person.fill")
                            .font(.system(size: 9))
                    }
                    Text(speaker.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Self.maxNameWidth, alignment: .leading)
                    if !suggestions.isEmpty {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Name suggested")
                    }
                }
                .foregroundStyle(Color.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Rename speaker")
            .accessibilityLabel("Rename \(speaker.displayName)")
            .popover(isPresented: renameBinding(for: speaker.id), arrowEdge: .bottom) {
                SpeakerRenamePopover(
                    speaker: speaker,
                    participants: availableParticipants(for: speaker),
                    namesInUse: meeting.speakers
                        .filter { $0.id != speaker.id && !$0.nameConfirmed && !$0.isUser }
                        .map(\.displayName),
                    suggestions: suggestions,
                    onRename: { rename(speaker.id, to: $0) },
                    onAcceptSuggestion: { rename(speaker.id, to: $0.name) },
                    onSetIsUser: { setIsUser($0, speakerID: speaker.id) },
                    onDone: { renamingSpeakerID = nil }
                )
            }

            if let percentage {
                Text("\(percentage)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityLabel("\(percentage) percent of talk time")
            }

            clipButton(for: speaker)
        }
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xxs + 1)
        .background(Color.backgroundTertiary, in: Capsule())
        .contextMenu {
            if canRememberVoice(of: speaker) {
                Button("Remember voice\u{2026}") { rememberingSpeaker = speaker }
            }
        }
    }

    @ViewBuilder
    private func clipButton(for speaker: SpeakerInfo) -> some View {
        if unavailableClips.contains(speaker.id) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 10))
                .foregroundStyle(Color.textTertiary)
                .help("Sample unavailable")
                .accessibilityLabel("Sample unavailable")
        } else if let clip = SpeakerClipSelector.clip(
            for: speaker.id,
            meeting: meeting,
            sourceOverrides: record?.segmentSources ?? [:]
        ) {
            let isPlaying = player.isPlaying && player.playingURL == clip.url && playingSpeakerID == speaker.id
            Button {
                if isPlaying {
                    player.stop()
                } else {
                    play(clip, speakerID: speaker.id)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop sample" : "Play a sample of this speaker")
            .accessibilityLabel(isPlaying ? "Stop sample of \(speaker.displayName)" : "Play sample of \(speaker.displayName)")
        }
    }

    // MARK: - Actions

    private func play(_ clip: SpeakerClip, speakerID: String) {
        do {
            try player.play(url: clip.url, from: clip.start, duration: clip.duration)
            playingSpeakerID = speakerID
        } catch {
            Log.recording.error("Speaker sample could not play: \(error.localizedDescription, privacy: .public)")
            unavailableClips.insert(speakerID)
            playingSpeakerID = nil
        }
    }

    /// Renames and drops that speaker's suggestions from the sidecar (the
    /// name is confirmed now). Returns an error message, or nil on success.
    private func rename(_ speakerID: String, to name: String) -> String? {
        do {
            try SpeakerRenamer.rename(speakerID: speakerID, to: name, in: meeting, store: store)
        } catch SpeakerRenamer.RenameError.emptyName {
            return "Enter a name."
        } catch SpeakerRenamer.RenameError.nameInUse {
            return SpeakerRenamePopover.nameInUseWarning
        } catch {
            return "This speaker no longer exists."
        }
        removeSuggestions(for: speakerID)
        onSpeakersChanged?(meeting)
        return nil
    }

    /// Whether "Suggest names" has something to work on.
    private var canSuggestNames: Bool {
        !SpeakerNameProposer.candidates(meeting.speakers).isEmpty
            && !(meeting.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestButton: some View {
        Button {
            Task { await suggestNames() }
        } label: {
            HStack(spacing: CasaSpace.xxs) {
                if isSuggesting {
                    ProgressView().controlSize(.mini)
                    Text("Suggesting\u{2026}")
                } else {
                    Image(systemName: "sparkles")
                    Text("Suggest names")
                }
            }
            .font(.caption)
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(isSuggesting)
        .help("Ask the AI provider who the unnamed speakers are, from the participants and the first 10 minutes. Nothing changes until you pick a name.")
    }

    private func suggestNames() async {
        guard !isSuggesting else { return }
        isSuggesting = true
        suggestionNote = nil
        let suggestions = await SpeakerAnalysis.suggestNamesNow(for: meeting, store: store, proposer: proposer)
        isSuggesting = false
        record = store.load(meeting.id)
        suggestionNote = suggestions.isEmpty ? "No names found in the transcript." : nil
    }

    // MARK: - Voice profiles (A7)

    /// Voice profiles are on, the speaker has a confirmed name, its track is
    /// still on disk, and the diarizer can run here.
    private func canRememberVoice(of speaker: SpeakerInfo) -> Bool {
        voiceProfilesEnabled
            && speaker.nameConfirmed
            && diarizer.isAvailable
            && SpeakerClipSelector.voiceSample(
                for: speaker.id,
                meeting: meeting,
                sourceOverrides: record?.segmentSources ?? [:]
            ) != nil
    }

    /// One embedding from up to 30 s of the speaker's longest segments on its
    /// track, saved under its name. Consent is checked before any voice is
    /// analysed.
    private func rememberVoice(of speaker: SpeakerInfo, consentGiven: Bool) async throws {
        guard consentGiven else { throw VoiceProfileStore.StoreError.consentRequired }
        guard let sample = SpeakerClipSelector.voiceSample(
            for: speaker.id,
            meeting: meeting,
            sourceOverrides: record?.segmentSources ?? [:]
        ) else { throw RememberVoiceError.trackMissing }
        let embedding = try await diarizer.embedding(trackURL: sample.url, ranges: sample.ranges)
        try voiceProfiles.save(name: speaker.displayName, embedding: embedding, consentGiven: consentGiven)
    }

    private enum RememberVoiceError: LocalizedError {
        case trackMissing
        var errorDescription: String? { "This speaker\u{2019}s track is no longer on this Mac." }
    }

    private func setIsUser(_ isUser: Bool, speakerID: String) {
        do {
            try SpeakerRenamer.setIsUser(isUser, speakerID: speakerID, in: meeting)
        } catch {
            return
        }
        onSpeakersChanged?(meeting)
    }

    private func removeSuggestions(for speakerID: String) {
        guard var updated = record else { return }
        let before = updated.suggestions.count
        updated.suggestions.removeAll { $0.speakerID == speakerID }
        guard updated.suggestions.count != before else { return }
        record = updated
        do {
            try store.save(updated)
        } catch {
            Log.transcription.error(
                "Could not update the speaker suggestions: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Helpers

    private func suggestions(for speakerID: String) -> [SpeakerNameSuggestion] {
        guard let speaker = meeting.speakers.first(where: { $0.id == speakerID }), !speaker.nameConfirmed else { return [] }
        return record?.suggestions.filter { $0.speakerID == speakerID } ?? []
    }

    /// Participants not already the name of another speaker.
    private func availableParticipants(for speaker: SpeakerInfo) -> [String] {
        let taken = Set(meeting.speakers.filter { $0.id != speaker.id }.map { $0.displayName.lowercased() })
        return meeting.participants.filter { !taken.contains(SpeakerRenamer.sanitize($0).lowercased()) }
    }

    private func renameBinding(for speakerID: String) -> Binding<Bool> {
        Binding(
            get: { renamingSpeakerID == speakerID },
            set: { if !$0, renamingSpeakerID == speakerID { renamingSpeakerID = nil } }
        )
    }
}
