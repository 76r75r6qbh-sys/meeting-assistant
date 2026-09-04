import XCTest
@testable import Casablanca

/// WhisperKit reports discovered segments one decode window at a time, and with
/// VAD chunking up to 16 chunks decode concurrently, so windows arrive
/// interleaved. These tests pin the accumulation rules the live transcript list
/// depends on.
final class TranscriptSegmentMergeTests: XCTestCase {
    // Chunk keys are the reporting window's `seek` in samples at 16 kHz, so
    // 480_000 is the window that starts 30 s into the recording.
    private let chunkA = 0
    private let chunkB = 480_000

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, text: text)
    }

    // MARK: - Out-of-order arrival

    func testChunkReportedOutOfOrderYieldsSortedUnion() {
        var merger = TranscriptSegmentMerger()

        merger.merge(
            chunkSegments: [segment(30, 33, "world"), segment(33, 36, "again")],
            chunkKey: chunkB
        )
        merger.merge(
            chunkSegments: [segment(0, 3, "hello"), segment(3, 6, "there")],
            chunkKey: chunkA
        )

        XCTAssertEqual(merger.orderedSegments.map(\.text), ["hello", "there", "world", "again"])
        XCTAssertEqual(merger.orderedSegments.map(\.startTime), [0, 3, 30, 33])
    }

    func testChunkRelativeStartTimesStillOrderByChunk() {
        var merger = TranscriptSegmentMerger()

        // A live report's start/end are relative to its own VAD chunk —
        // WhisperKit offsets only `seek` until every chunk has returned — so
        // ordering on those timings alone would interleave the two chunks.
        merger.merge(
            chunkSegments: [segment(1, 3, "world"), segment(4, 6, "again")],
            chunkKey: chunkB
        )
        merger.merge(
            chunkSegments: [segment(0, 3, "hello"), segment(10, 13, "there")],
            chunkKey: chunkA
        )

        XCTAssertEqual(merger.orderedSegments.map(\.text), ["hello", "there", "world", "again"])
    }

    // MARK: - Re-report replaces only its own chunk

    func testReReportOfAChunkReplacesOnlyThatChunksSegments() {
        var merger = TranscriptSegmentMerger()
        merger.merge(
            chunkSegments: [segment(0, 3, "hello"), segment(3, 6, "there")],
            chunkKey: chunkA
        )
        merger.merge(
            chunkSegments: [segment(30, 33, "world"), segment(33, 36, "again")],
            chunkKey: chunkB
        )

        merger.merge(chunkSegments: [segment(0, 6, "hello there")], chunkKey: chunkA)

        XCTAssertEqual(merger.orderedSegments.map(\.text), ["hello there", "world", "again"])
    }

    // MARK: - Empty reports

    func testEmptyReportClearsOnlyItsOwnChunk() {
        var merger = TranscriptSegmentMerger()
        merger.merge(chunkSegments: [segment(0, 3, "hello")], chunkKey: chunkA)
        merger.merge(chunkSegments: [segment(30, 33, "world")], chunkKey: chunkB)

        merger.merge(chunkSegments: [], chunkKey: chunkB)

        XCTAssertEqual(merger.orderedSegments.map(\.text), ["hello"])
    }

    func testEmptyReportForAnUnseenChunkContributesNothing() {
        var merger = TranscriptSegmentMerger()

        merger.merge(chunkSegments: [], chunkKey: chunkA)

        XCTAssertTrue(merger.orderedSegments.isEmpty)
    }

    // MARK: - Ties

    func testIdenticalStartTimesOrderDeterministicallyByChunk() {
        var merger = TranscriptSegmentMerger()

        // A later window can carry the same `start` as an earlier one because
        // WhisperKit only globalises the segment timings after every chunk is
        // done; the chunk key is what still separates them.
        merger.merge(chunkSegments: [segment(5, 8, "later")], chunkKey: chunkB)
        merger.merge(chunkSegments: [segment(5, 8, "earlier")], chunkKey: chunkA)

        XCTAssertEqual(merger.orderedSegments.map(\.text), ["earlier", "later"])

        // The arrival order must not decide it: the live list would reshuffle
        // between callbacks if the sort were not total.
        var reversed = TranscriptSegmentMerger()
        reversed.merge(chunkSegments: [segment(5, 8, "earlier")], chunkKey: chunkA)
        reversed.merge(chunkSegments: [segment(5, 8, "later")], chunkKey: chunkB)

        XCTAssertEqual(reversed.orderedSegments.map(\.text), merger.orderedSegments.map(\.text))
    }

    func testSegmentOrderWithinOneChunkIsPreservedForIdenticalStartTimes() {
        var merger = TranscriptSegmentMerger()

        merger.merge(
            chunkSegments: [segment(5, 8, "first"), segment(5, 8, "second")],
            chunkKey: chunkA
        )

        XCTAssertEqual(merger.orderedSegments.map(\.text), ["first", "second"])
    }

    // MARK: - Absolute live timestamps

    /// WhisperKit's live callback offsets only `seek`, so a report's own
    /// `start`/`end` restart near zero for every decode window — the live list
    /// showed `[00:00]` again halfway through a meeting. `seek` is the window's
    /// absolute position in 16 kHz samples, which is what puts them back on the
    /// recording's clock.
    func testLiveTimesAreOffsetByTheWindowsSeek() {
        let times = TranscriptSegmentMerger.absoluteLiveTimes(
            seek: 480_000,
            start: 0,
            end: 3,
            reportMinStart: 0
        )

        XCTAssertEqual(times.startTime, 30, accuracy: 0.001)
        XCTAssertEqual(times.endTime, 33, accuracy: 0.001)
    }

    func testFirstWindowKeepsItsOwnTimes() {
        let times = TranscriptSegmentMerger.absoluteLiveTimes(
            seek: 0,
            start: 2,
            end: 5,
            reportMinStart: 2
        )

        XCTAssertEqual(times.startTime, 0, accuracy: 0.001)
        XCTAssertEqual(times.endTime, 3, accuracy: 0.001)
    }

    /// The report's own segments stay in their relative order and keep their
    /// durations: only the whole window moves onto the absolute clock.
    func testLaterSegmentsInAWindowKeepTheirOffsetFromTheWindowStart() {
        let reportMinStart: TimeInterval = 1
        let first = TranscriptSegmentMerger.absoluteLiveTimes(
            seek: 160_000,
            start: 1,
            end: 4,
            reportMinStart: reportMinStart
        )
        let second = TranscriptSegmentMerger.absoluteLiveTimes(
            seek: 160_000,
            start: 4,
            end: 9,
            reportMinStart: reportMinStart
        )

        XCTAssertEqual(first.startTime, 10, accuracy: 0.001)
        XCTAssertEqual(first.endTime, 13, accuracy: 0.001)
        XCTAssertEqual(second.startTime, 13, accuracy: 0.001)
        XCTAssertEqual(second.endTime, 18, accuracy: 0.001)
    }
}
