import SwiftUI

/// The transcript tab's small transport: play/pause for the meeting's mixed
/// recording and the current time. It shows the shared `AudioClipPlayer`'s
/// state only while that player holds this recording; a speaker sample or
/// another meeting's audio reads as "not playing" here.
///
/// Only this view observes the player, so its 0.25 s ticks do not re-render
/// the transcript.
struct TranscriptTransportBar: View {
    let recordingURL: URL
    /// `false` while the meeting is (re)transcribing: the button is disabled.
    let canPlay: Bool
    /// The last attempt to play failed: ▶ shows as unavailable.
    let isUnavailable: Bool
    /// Length shown before the file is loaded (the meeting's stored duration).
    let knownDuration: Double?
    /// Starts the recording from the given seconds (the owner handles errors).
    let onPlay: (Double) -> Void
    @ObservedObject var player: AudioClipPlayer

    private var isLoaded: Bool {
        player.playingURL?.standardizedFileURL == recordingURL.standardizedFileURL
    }

    private var isPlaying: Bool { isLoaded && player.isPlaying }

    var body: some View {
        HStack(spacing: CasaSpace.sm) {
            if isUnavailable {
                Image(systemName: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 16, height: 16)
                    .help("The recording could not be played")
                    .accessibilityLabel("Recording unavailable")
            } else {
                Button {
                    toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption)
                        .foregroundStyle(canPlay ? Color.textPrimary : Color.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .help(canPlay
                    ? (isPlaying ? "Pause the recording" : "Play the recording")
                    : "Playback is available once transcription has finished")
                .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")
            }

            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .accessibilityLabel("Playback position \(timeText)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, CasaSpace.sm)
        .padding(.vertical, CasaSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: CasaRadius.md))
    }

    /// `current / total`; `current` alone when the length is unknown.
    var timeText: String {
        let current = isLoaded ? player.currentTime : 0
        let total = isLoaded && player.duration > 0 ? player.duration : knownDuration
        let currentLabel = TranscriptLineFormat.timestampLabel(seconds: current)
        guard let total, total > 0 else { return currentLabel }
        return "\(currentLabel) / \(TranscriptLineFormat.timestampLabel(seconds: total))"
    }

    private func toggle() {
        if isPlaying {
            player.pause()
        } else if isLoaded {
            player.resume()
        } else {
            onPlay(0)
        }
    }
}

/// Starts the mixed recording for transcript jumps and the transport's ▶,
/// and remembers which meeting's recording failed to play (R2: ▶ shows as
/// unavailable). Shared by the transcript tab and the pinned transport, so
/// both agree; playback itself is the shared `AudioClipPlayer`'s, and keeps
/// going across tab switches.
@MainActor
@Observable
final class TranscriptPlayback {
    static let shared = TranscriptPlayback()

    let player: AudioClipPlayer
    /// The meeting whose recording last failed to play.
    private(set) var failedMeetingID: UUID?

    init(player: AudioClipPlayer = .shared) {
        self.player = player
    }

    func isUnavailable(for meeting: Meeting) -> Bool {
        failedMeetingID == meeting.id
    }

    /// The mixed recording when its file is on disk.
    static func recordingURL(of meeting: Meeting) -> URL? {
        TimestampJumpPlan.recordingURL(path: meeting.recordingFileURL)
    }

    static func canPlay(_ meeting: Meeting, isTranscribing: Bool) -> Bool {
        TimestampJumpPlan.shouldPlay(
            status: meeting.status,
            isTranscribing: isTranscribing,
            hasRecordingFile: recordingURL(of: meeting) != nil
        )
    }

    /// Plays `meeting`'s recording from `seconds` when it may play; a failure
    /// is logged and marks the meeting's ▶ unavailable.
    func play(_ meeting: Meeting, isTranscribing: Bool, from seconds: Double) {
        guard Self.canPlay(meeting, isTranscribing: isTranscribing),
              let url = Self.recordingURL(of: meeting) else { return }
        do {
            try player.play(url: url, from: seconds)
            if failedMeetingID == meeting.id { failedMeetingID = nil }
        } catch {
            Log.recording.error("Recording playback failed: \(error.localizedDescription, privacy: .public)")
            failedMeetingID = meeting.id
        }
    }
}

/// The transport pinned above the transcript tab's scroll content (placed
/// with `safeAreaInset(edge: .top)` on the detail scroll view), aligned with
/// the reading column. Shown when the meeting has a transcript and its
/// recording file exists.
struct TranscriptTransportInset: View {
    let meeting: Meeting
    let isTranscribing: Bool
    let playback: TranscriptPlayback

    private var hasTranscript: Bool {
        meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        if hasTranscript, let url = TranscriptPlayback.recordingURL(of: meeting) {
            TranscriptTransportBar(
                recordingURL: url,
                canPlay: TranscriptPlayback.canPlay(meeting, isTranscribing: isTranscribing),
                isUnavailable: playback.isUnavailable(for: meeting),
                knownDuration: meeting.recordingDuration,
                onPlay: { playback.play(meeting, isTranscribing: isTranscribing, from: $0) },
                player: playback.player
            )
            .padding(.horizontal, CasaSpace.xl)
            .padding(.vertical, CasaSpace.sm)
            .frame(maxWidth: CasaLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            // Opaque, so the transcript scrolls underneath it.
            .background(Color.backgroundPrimary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.borderSubtle)
                    .frame(height: 1)
            }
        }
    }
}
