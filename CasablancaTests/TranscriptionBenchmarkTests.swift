import XCTest
@testable import Casablanca

final class TranscriptionBenchmarkTests: XCTestCase {
    // MARK: - Argument parsing

    func testParsesArguments() {
        let request = TranscriptionBenchmark.requestedRun(from: [
            "/Applications/Casablanca.app/Contents/MacOS/Casablanca",
            "--benchmark-transcription", "/tmp/vzvz-44min.m4a",
            "--benchmark-variant", "baseline",
        ])
        XCTAssertEqual(request?.fileURL, URL(fileURLWithPath: "/tmp/vzvz-44min.m4a"))
        XCTAssertEqual(request?.variant, "baseline")

        // No flag at all: a normal launch, so no benchmark run.
        XCTAssertNil(TranscriptionBenchmark.requestedRun(from: ["/Applications/Casablanca.app"]))
        XCTAssertNil(TranscriptionBenchmark.requestedRun(from: []))

        // Variant is optional and defaults to "default".
        let defaulted = TranscriptionBenchmark.requestedRun(from: [
            "Casablanca", "--benchmark-transcription", "/tmp/a.wav",
        ])
        XCTAssertEqual(defaulted?.variant, "default")

        // Paths with spaces arrive as a single argument and must survive intact.
        let spaced = TranscriptionBenchmark.requestedRun(from: [
            "Casablanca",
            "--benchmark-transcription", "/Users/me/Application Support/Casablanca/Benchmarks/vzvz 44min.m4a",
            "--benchmark-variant", "workers 8",
        ])
        XCTAssertEqual(
            spaced?.fileURL.path,
            "/Users/me/Application Support/Casablanca/Benchmarks/vzvz 44min.m4a"
        )
        XCTAssertEqual(spaced?.variant, "workers 8")

        // A dangling flag has no file to transcribe, so it is not a run.
        XCTAssertNil(TranscriptionBenchmark.requestedRun(from: ["Casablanca", "--benchmark-transcription"]))
        // Other tuning arguments in between must not confuse the parser.
        let mixed = TranscriptionBenchmark.requestedRun(from: [
            "Casablanca", "-whisperWorkers", "8",
            "--benchmark-transcription", "/tmp/a.wav",
            "-whisperFallbackCount", "2",
            "--benchmark-variant", "fb2",
        ])
        XCTAssertEqual(mixed?.fileURL.path, "/tmp/a.wav")
        XCTAssertEqual(mixed?.variant, "fb2")
    }

    // MARK: - Output naming

    func testReportFileNameUsesTimestampAndVariant() {
        // 2026-03-03 14:05:01 UTC
        let date = Date(timeIntervalSince1970: 1_772_546_701)
        let baseName = TranscriptionBenchmark.reportBaseName(
            variant: "baseline",
            at: date,
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(baseName, "20260303-140501-baseline")

        // A variant with spaces or slashes must not create a nested path.
        let sanitised = TranscriptionBenchmark.reportBaseName(
            variant: "workers 8/gpu",
            at: date,
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(sanitised, "20260303-140501-workers-8-gpu")
    }

    // MARK: - Transcript file format

    func testTranscriptContentsMatchTheSavedTranscriptFormat() {
        let result = TranscriptionResult(
            segments: [
                TranscriptSegment(startTime: 0, endTime: 3, text: "Goedemorgen."),
                TranscriptSegment(startTime: 3661, endTime: 3665, text: "Tot zover."),
            ],
            fullText: "Goedemorgen. Tot zover.",
            duration: 3665
        )
        let contents = TranscriptionService.transcriptFileContents(
            title: "vzvz-44min",
            date: "2026-09-03 14:05:01",
            duration: 3665,
            result: result
        )
        XCTAssertEqual(contents, """
        Transcription: vzvz-44min
        Date: 2026-09-03 14:05:01
        Duration: 61m 5s
        ---

        [00:00] Goedemorgen.
        [1:01:01] Tot zover.
        """)
    }
}
