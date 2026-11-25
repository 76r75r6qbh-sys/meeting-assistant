import Foundation

/// Accumulates the live transcript out of the segments WhisperKit discovers.
///
/// WhisperKit fires `segmentDiscoveryCallback` once per 30 s decode window, and
/// with VAD chunking up to 16 chunks decode concurrently, so windows arrive
/// interleaved and out of order. Keying the reported segments by their window
/// means a window that reports again replaces only its own segments, while
/// everything already on screen stays put — publishing the reported segments
/// directly instead drops the text of every other chunk on every callback.
struct TranscriptSegmentMerger {
    /// Identifies the reporting decode window. The caller derives it from the
    /// `seek` of the first reported WhisperKit segment: WhisperKit offsets
    /// `seek` by the VAD chunk's start before reporting, which makes it unique
    /// across the chunks decoding concurrently.
    typealias ChunkKey = Int

    private var segmentsByChunk: [ChunkKey: [TranscriptSegment]] = [:]

    /// Replaces everything the given window contributed with `chunkSegments`.
    /// An empty report clears that window's contribution and leaves the rest.
    mutating func merge(chunkSegments: [TranscriptSegment], chunkKey: ChunkKey) {
        segmentsByChunk[chunkKey] = chunkSegments
    }

    /// The union of every window's segments in audio order: by chunk key, then
    /// by `startTime` within the window, then by the position the window
    /// reported them in.
    ///
    /// The chunk key leads rather than `startTime` because under VAD chunking a
    /// live report's `start`/`end` arrive relative to its own chunk — the
    /// batched segment callback offsets only `seek` (WhisperKit.swift,
    /// `batchedSegmentCallback`), and the timings are globalised only once every
    /// chunk has returned (`AudioChunking.updateSeekOffsetsForResults` →
    /// `TranscriptionUtilities.updateSegmentTimings`). The caller shifts them
    /// onto the absolute clock with `absoluteLiveTimes` before merging, but that
    /// shift is approximate, so the chunk key — which is monotone in audio
    /// position and exact — stays the primary order. Under sequential chunking
    /// (`chunkingStrategy: .none`) the reported times are already absolute and
    /// pass through untouched; the two orders then agree.
    ///
    /// The order also has to be total: dictionary iteration order is arbitrary,
    /// and a list that reshuffles between callbacks flickers just as badly as
    /// one that gets replaced.
    var orderedSegments: [TranscriptSegment] {
        segmentsByChunk
            .flatMap { chunkKey, segments in
                segments.enumerated().map { (chunkKey: chunkKey, position: $0.offset, segment: $0.element) }
            }
            .sorted { lhs, rhs in
                if lhs.chunkKey != rhs.chunkKey {
                    return lhs.chunkKey < rhs.chunkKey
                }
                if lhs.segment.startTime != rhs.segment.startTime {
                    return lhs.segment.startTime < rhs.segment.startTime
                }
                return lhs.position < rhs.position
            }
            .map(\.segment)
    }
}

extension TranscriptSegmentMerger {
    /// The sample rate WhisperKit counts `seek` in.
    private static let whisperSampleRate: Double = 16_000

    /// Puts one live-reported segment back on the recording's clock.
    ///
    /// Under VAD chunking each chunk is transcribed as its own audio array, so
    /// its `seek` restarts at zero and `SegmentSeeker` builds `start`/`end`
    /// relative to the chunk. WhisperKit's live callback offsets only `seek`
    /// (`start`/`end` are globalised much later, once every chunk has returned
    /// via `AudioChunking.updateSeekOffsetsForResults`), so the live list showed
    /// `[00:00]` again halfway through a meeting. `seek` is that window's
    /// absolute position in samples, so shifting the report onto it, relative to
    /// its own earliest segment, recovers absolute times to within the second or
    /// two a live view can live with.
    ///
    /// - Parameters:
    ///   - seek: the reporting window's `seek`, in 16 kHz samples.
    ///   - reportMinStart: the smallest `start` in the same report — every
    ///     segment of the report shifts by the same amount, so their order and
    ///     durations are preserved.
    ///   - timesAreAbsolute: `true` for `chunkingStrategy: .none`, where
    ///     WhisperKit seeks through the whole file itself and
    ///     `findSeekPointAndSegments` already adds `Float(seek) / sampleRate`
    ///     into `start`/`end` (`SegmentSeeker.swift`). Shifting those again
    ///     would land every segment early by its window's leading silence, so
    ///     they are returned untouched.
    static func absoluteLiveTimes(
        seek: Int,
        start: TimeInterval,
        end: TimeInterval,
        reportMinStart: TimeInterval,
        timesAreAbsolute: Bool
    ) -> (startTime: TimeInterval, endTime: TimeInterval) {
        guard !timesAreAbsolute else {
            return (startTime: start, endTime: end)
        }
        let windowStart = Double(seek) / whisperSampleRate
        return (
            startTime: windowStart + (start - reportMinStart),
            endTime: windowStart + (end - reportMinStart)
        )
    }
}
