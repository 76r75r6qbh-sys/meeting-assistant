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
