import XCTest
@testable import Casablanca

final class TranscriptChunkerTests: XCTestCase {

    // MARK: - Helpers

    /// `count` unique `[mm:ss] Speaker: …` lines, one every 7 seconds.
    private func timestampedLines(_ count: Int) -> [String] {
        (0..<count).map { i in
            let seconds = i * 7
            let label = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return "[\(label)] Speaker \(i % 3): this is statement number \(i) of the meeting."
        }
    }

    private func lines(of chunk: TranscriptChunk) -> [String] {
        chunk.text.components(separatedBy: "\n")
    }

    /// Length of the overlap prefix: the longest prefix of `current` that is a
    /// suffix of `previous`. Unambiguous because the test lines are unique.
    private func overlapCount(previous: [String], current: [String]) -> Int {
        var best = 0
        for n in 1...min(previous.count, current.count) where Array(previous.suffix(n)) == Array(current.prefix(n)) {
            best = n
        }
        return best
    }

    /// Every chunk's lines minus its overlap prefix, concatenated in order.
    private func reconstructed(_ chunks: [TranscriptChunk]) -> [String] {
        var out: [String] = []
        var previous: [String] = []
        for chunk in chunks {
            let current = lines(of: chunk)
            let skip = previous.isEmpty ? 0 : overlapCount(previous: previous, current: current)
            out += current.dropFirst(skip)
            previous = current
        }
        return out
    }

    // MARK: - Trivial inputs

    func testEmptyAndWhitespaceOnlyInputGiveNoChunks() {
        XCTAssertEqual(TranscriptChunker.chunks(of: "", chunkTokens: 100, overlapTokens: 10), [])
        XCTAssertEqual(TranscriptChunker.chunks(of: "  \n\n\t \n", chunkTokens: 100, overlapTokens: 10), [])
    }

    func testInputWithinBudgetIsOneTrimmedChunk() {
        let chunks = TranscriptChunker.chunks(of: "\n  [00:01] Hello\n[00:05] World  \n\n", chunkTokens: 100, overlapTokens: 10)
        XCTAssertEqual(chunks, [TranscriptChunk(index: 0, text: "[00:01] Hello\n[00:05] World", startLabel: "00:01", endLabel: "00:05")])
    }

    // MARK: - Line-boundary split and overlap

    func testLongTranscriptChunksFitBudgetAndReconstructAllLinesInOrder() {
        let all = timestampedLines(300)
        let chunkTokens = 200
        let overlapTokens = 40
        let chunks = TranscriptChunker.chunks(of: all.joined(separator: "\n"), chunkTokens: chunkTokens, overlapTokens: overlapTokens)

        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        for chunk in chunks {
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(chunk.text), chunkTokens)
            // Never split inside a line: every chunk line is a whole input line.
            XCTAssertTrue(lines(of: chunk).allSatisfy(all.contains))
        }
        XCTAssertEqual(reconstructed(chunks), all)
    }

    func testEachLaterChunkStartsWithOverlapWithinOverlapBudget() {
        let chunks = TranscriptChunker.chunks(of: timestampedLines(200).joined(separator: "\n"), chunkTokens: 200, overlapTokens: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        for k in 1..<chunks.count {
            let previous = lines(of: chunks[k - 1])
            let current = lines(of: chunks[k])
            let n = overlapCount(previous: previous, current: current)
            XCTAssertGreaterThan(n, 0, "chunk \(k) has no overlap")
            let overlap = current.prefix(n).joined(separator: "\n")
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(overlap), 40)
            // It is the *longest* trailing run within budget: one more line would exceed it.
            if n < previous.count {
                let longer = previous.suffix(n + 1).joined(separator: "\n")
                XCTAssertGreaterThan(LLMPromptSupport.budgetTokens(longer), 40)
            }
        }
    }

    func testZeroOverlapWhenLastLineAloneExceedsOverlapBudget() {
        // Each line is ~60 chars (20 tokens); a 5-token overlap fits no whole line.
        let all = timestampedLines(40)
        let chunks = TranscriptChunker.chunks(of: all.joined(separator: "\n"), chunkTokens: 100, overlapTokens: 5)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap { lines(of: $0) }, all)
    }

    func testOverlapNotSmallerThanChunkStillTerminatesAndCoversEverything() {
        let all = timestampedLines(50)
        let chunks = TranscriptChunker.chunks(of: all.joined(separator: "\n"), chunkTokens: 60, overlapTokens: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(chunk.text), 60)
        }
        XCTAssertEqual(reconstructed(chunks), all)
        XCTAssertEqual(lines(of: chunks.last!).last, all.last)
    }

    // MARK: - Oversized single line

    func testOversizedLineIsSplitAtWhitespace() {
        let words = (0..<400).map { "word\($0)" }
        let line = words.joined(separator: " ")
        let chunks = TranscriptChunker.chunks(of: "[00:00] Intro\n" + line + "\n[09:59] Outro", chunkTokens: 50, overlapTokens: 0)

        XCTAssertGreaterThan(chunks.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(chunk.text), 50)
        }
        let pieces = chunks.flatMap { lines(of: $0) }
        XCTAssertEqual(pieces.first, "[00:00] Intro")
        XCTAssertEqual(pieces.last, "[09:59] Outro")
        // Cut only at spaces (each dropped once): the pieces re-join to the line,
        // and no word was cut in half.
        let middle = pieces.dropFirst().dropLast()
        XCTAssertEqual(middle.joined(separator: " "), line)
        XCTAssertTrue(middle.allSatisfy { $0.split(separator: " ").allSatisfy { words.contains(String($0)) } })
    }

    func testOversizedLineWithoutWhitespaceIsCutAtTheLimit() {
        let line = String(repeating: "x", count: 1_000)
        let chunks = TranscriptChunker.chunks(of: line, chunkTokens: 50, overlapTokens: 0)
        // 50 tokens × 3 chars/token = 150 chars per piece.
        XCTAssertEqual(chunks.map { $0.text.count }, [150, 150, 150, 150, 150, 150, 100])
        XCTAssertEqual(chunks.map(\.text).joined(), line)
    }

    // MARK: - Timestamp labels

    func testLabelsAreFirstAndLastTimestampInChunkIncludingHours() {
        let text = [
            "[59:58] Before the hour",
            "Continuation without a label",
            "[1:00:05] Just past the hour",
            "[1:02:03] Later",
            "trailing text [9:99:99] not at line start",
        ].joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(of: text, chunkTokens: 1_000, overlapTokens: 0)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].startLabel, "59:58")
        XCTAssertEqual(chunks[0].endLabel, "1:02:03")
    }

    func testLabelsTrackEachChunkOfALongTranscript() {
        let all = timestampedLines(120)
        let chunks = TranscriptChunker.chunks(of: all.joined(separator: "\n"), chunkTokens: 150, overlapTokens: 30)
        for chunk in chunks {
            let chunkLines = lines(of: chunk)
            XCTAssertEqual(chunk.startLabel, TranscriptChunker.label(of: chunkLines.first!))
            XCTAssertEqual(chunk.endLabel, TranscriptChunker.label(of: chunkLines.last!))
        }
        XCTAssertEqual(chunks.first?.startLabel, "00:00")
        XCTAssertEqual(chunks.last?.endLabel, "13:53") // line 119 × 7 s = 833 s
    }

    func testLabelParsing() {
        XCTAssertEqual(TranscriptChunker.label(of: "[01:02] a"), "01:02")
        XCTAssertEqual(TranscriptChunker.label(of: "[1:02] a"), "1:02")
        XCTAssertEqual(TranscriptChunker.label(of: "[1:02:03] a"), "1:02:03")
        XCTAssertEqual(TranscriptChunker.label(of: "[12:02:03]"), "12:02:03")
        XCTAssertNil(TranscriptChunker.label(of: " [01:02] leading space"))
        XCTAssertNil(TranscriptChunker.label(of: "[1:2] one-digit seconds"))
        XCTAssertNil(TranscriptChunker.label(of: "[123:02] three-digit minutes"))
        XCTAssertNil(TranscriptChunker.label(of: "[1:02:03:04] too many fields"))
        XCTAssertNil(TranscriptChunker.label(of: "[Speaker] hello"))
        XCTAssertNil(TranscriptChunker.label(of: "no label"))
    }

    func testTranscriptWithoutTimestampsHasNilLabels() {
        let all = (0..<100).map { "Plain line \($0) without any timestamp at all." }
        let chunks = TranscriptChunker.chunks(of: all.joined(separator: "\n"), chunkTokens: 120, overlapTokens: 20)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.startLabel == nil && $0.endLabel == nil })
        XCTAssertEqual(reconstructed(chunks), all)
    }

    // MARK: - Determinism

    func testChunkingIsDeterministic() {
        let text = timestampedLines(150).joined(separator: "\n")
        let first = TranscriptChunker.chunks(of: text, chunkTokens: 180, overlapTokens: 40)
        let second = TranscriptChunker.chunks(of: text, chunkTokens: 180, overlapTokens: 40)
        XCTAssertEqual(first, second)
    }
}
