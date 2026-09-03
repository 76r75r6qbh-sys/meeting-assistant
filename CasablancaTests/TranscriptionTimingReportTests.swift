import Foundation
import WhisperKit
import XCTest
@testable import Casablanca

/// Covers the timing report that answers "where did the 25 minutes go?" for a
/// transcription run: the per-chunk sums, the fallback histogram rebuilt from
/// the progress callback, and the single log line they are reported on.
final class TranscriptionTimingReportTests: XCTestCase {

    func testSumsPerResultTimingsAcrossResults() {
        // Each VAD chunk is its own `TranscribeTask` with its own timings, so
        // the decode phases only mean anything once summed across results.
        let firstChunk = TranscriptionTimings(
            logmels: 1,
            encoding: 10,
            decodingLoop: 100,
            decodingPredictions: 90,
            decodingFallback: 5,
            decodingKvCaching: 2,
            totalDecodingLoops: 1_000,
            totalDecodingWindows: 4
        )
        let secondChunk = TranscriptionTimings(
            logmels: 2,
            encoding: 20,
            decodingLoop: 200,
            decodingPredictions: 180,
            decodingFallback: 7,
            decodingKvCaching: 3,
            totalDecodingLoops: 2_000,
            totalDecodingWindows: 6
        )

        let report = TranscriptionTimingReport(
            audioSeconds: 600,
            modelLoadWall: .seconds(30),
            transcribeWall: .seconds(300),
            pipelineTimings: TranscriptionTimings(),
            chunkTimings: [firstChunk, secondChunk],
            maxTemperatureByWindow: [:]
        )

        XCTAssertEqual(report.logmels, 3, accuracy: 0.0001)
        XCTAssertEqual(report.encoding, 30, accuracy: 0.0001)
        XCTAssertEqual(report.decodingLoop, 300, accuracy: 0.0001)
        XCTAssertEqual(report.decodingPredictions, 270, accuracy: 0.0001)
        XCTAssertEqual(report.decodingFallback, 12, accuracy: 0.0001)
        XCTAssertEqual(report.decodingKvCaching, 5, accuracy: 0.0001)
        XCTAssertEqual(report.totalWindows, 10)
        XCTAssertEqual(report.totalTokens, 3_000)
    }

    func testFallbackHistogramFromMaxTemperaturePerWindow() {
        // Temperature climbs by 0.2 per fallback: 0 means the window decoded on
        // the first attempt, 0.6 means it took three fallbacks.
        let report = TranscriptionTimingReport(
            audioSeconds: 100,
            modelLoadWall: .zero,
            transcribeWall: .seconds(50),
            pipelineTimings: TranscriptionTimings(),
            chunkTimings: [TranscriptionTimings(totalDecodingWindows: 3)],
            maxTemperatureByWindow: [0: 0, 1: 0.2, 2: 0.6]
        )

        XCTAssertEqual(report.fallbackHistogram, [0: 1, 1: 1, 3: 1])
        XCTAssertEqual(report.fallbackWindows, 2)
    }

    func testSummaryLineIsSingleLineKeyValue() {
        let report = TranscriptionTimingReport(
            audioSeconds: 2_650,
            modelLoadWall: .seconds(42),
            transcribeWall: .seconds(1_478),
            pipelineTimings: TranscriptionTimings(
                modelLoading: 40,
                prewarmLoadTime: 18,
                encoderSpecializationTime: 6,
                decoderSpecializationTime: 4,
                audioLoading: 3
            ),
            chunkTimings: [
                TranscriptionTimings(
                    logmels: 8,
                    encoding: 310,
                    decodingLoop: 980,
                    decodingPredictions: 940,
                    decodingFallback: 120,
                    decodingKvCaching: 30,
                    totalDecodingLoops: 48_213,
                    totalDecodingWindows: 112
                ),
            ],
            maxTemperatureByWindow: [0: 0, 1: 0.2]
        )

        let line = report.summaryLine

        XCTAssertFalse(line.contains("\n"), "the report has to fit one log line")
        for field in line.split(separator: " ") {
            XCTAssertEqual(
                field.filter { $0 == "=" }.count,
                1,
                "every field must be a single key=value pair, got '\(field)'"
            )
        }
        XCTAssertTrue(line.hasPrefix("audio=2650s"), line)
        XCTAssertTrue(line.contains("wall=1520s"), line)
        XCTAssertTrue(line.contains("speed=1.74x"), line)
        XCTAssertTrue(line.contains("load=42s"), line)
        XCTAssertTrue(line.contains("enc=310s"), line)
        XCTAssertTrue(line.contains("dec=980s"), line)
        XCTAssertTrue(line.contains("fb=120s"), line)
        XCTAssertTrue(line.contains("fbWindows=1/112"), line)
        XCTAssertTrue(line.contains("tokens=48213"), line)
    }
}
