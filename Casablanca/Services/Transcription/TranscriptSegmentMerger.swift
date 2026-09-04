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
    /// The chunk key leads rather than `startTime` because a live report's
    /// `start`/`end` are relative to its own VAD chunk — the batched segment
    /// callback offsets only `seek` (WhisperKit.swift, `batchedSegmentCallback`),
    /// and the timings are globalised only once every chunk has returned
    /// (`AudioChunking.updateSeekOffsetsForResults` →
    /// `TranscriptionUtilities.updateSegmentTimings`). Sorting the union on
    /// those relative timings would interleave the text of concurrent chunks;
    /// the chunk key is monotone in audio position, so leading with it keeps the
    /// live list readable. For timings that are already global the two orders
    /// agree.
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
