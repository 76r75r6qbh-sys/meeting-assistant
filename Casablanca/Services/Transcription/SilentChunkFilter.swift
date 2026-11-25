import Foundation
import WhisperKit

/// Drops the VAD chunks that hold no speech, before they are decoded.
///
/// `VADAudioChunker` splits on silence but never removes anything, so a meeting
/// that opens with five minutes of "can you hear me" dead air still pays for
/// ten padded 30-second decode windows — and Whisper answers silence with
/// hallucinated boilerplate ("Ondertiteld door...") that then has to be cleaned
/// out of the transcript. Deciding *not* to decode a chunk is cheaper and more
/// accurate than deciding what its output meant.
///
/// The judgement is the VAD's: this only counts the frames it marked voiced.
/// Opt-in behind `whisperDropSilentChunks` until Task 21's A/B says it is safe
/// to make the default.
struct SilentChunkFilter {
    struct Outcome {
        /// The chunks to decode, in their original order and with their
        /// `seekOffsetIndex` untouched — both are what places the resulting text
        /// at the right point in the meeting.
        let kept: [AudioChunk]
        let droppedCount: Int
        /// Audio not decoded, in seconds. The saving, for the log.
        let droppedSeconds: Double
    }

    /// - Parameters:
    ///   - chunks: The chunker's output, in order.
    ///   - vad: The detector whose `energyThreshold` decides what counts as
    ///     speech. Frames are its frames (0.1 s for `EnergyVAD`).
    ///   - minVoicedFrames: How many voiced frames a chunk needs to be worth
    ///     decoding. One is deliberately generous: a single 100 ms frame above
    ///     the threshold could be one clipped word, and dropping a real word
    ///     costs more than decoding 30 s of near-silence.
    static func partition(
        _ chunks: [AudioChunk],
        vad: VoiceActivityDetector,
        minVoicedFrames: Int = 1
    ) -> Outcome {
        var kept = [AudioChunk]()
        var droppedSamples = 0

        for chunk in chunks {
            let voicedFrames = vad.voiceActivity(in: chunk.audioSamples).filter { $0 }.count
            if voicedFrames >= minVoicedFrames {
                kept.append(chunk)
            } else {
                droppedSamples += chunk.audioSamples.count
            }
        }

        return Outcome(
            kept: kept,
            droppedCount: chunks.count - kept.count,
            droppedSeconds: Double(droppedSamples) / Double(vad.sampleRate)
        )
    }
}
