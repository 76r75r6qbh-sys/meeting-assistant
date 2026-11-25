import XCTest
import AVFoundation
@testable import Casablanca

/// Regression coverage for the frame-accounting contract that the recording
/// facade depends on.
///
/// Context: `AudioRecordingService.finalizeActiveSegment` calls `session.stop()`
/// and *then* reads `session.hasCapturedFrames` to decide whether to keep the
/// segment. A Phase-1c regression moved the per-track frame counters into the
/// `PCMTrackWriter`s, which `stop()` releases — so `hasCapturedFrames` read the
/// now-nil writers and always returned `false` after stopping, causing every
/// finalized recording to be dropped as "no audio samples were captured."
///
/// The fix caches the captured-frame total in `stop()` before the writers are
/// released, so `hasCapturedFrames` stays accurate when the facade checks it.
/// These tests exercise the real `RecordingSession.stop()` teardown path
/// (the empty case, which needs no audio hardware); the non-empty capture path
/// is hardware-bound and is verified by recording in the app.
@MainActor
final class RecordingSessionFrameAccountingTests: XCTestCase {

    private func makeSession(systemAudioEnabled: Bool) throws -> RecordingSession {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let meeting = Meeting(title: "Frame Accounting", date: .now, status: .recording)
        return try RecordingSession(
            outputURL: outputURL,
            meeting: meeting,
            inputDeviceID: nil,
            systemAudioEnabled: systemAudioEnabled,
            onLevelUpdate: { _ in },
            onFailure: { _ in },
            onStreamFatal: { _ in }
        )
    }

    func testFreshSessionReportsNoCapturedFrames() throws {
        let session = try makeSession(systemAudioEnabled: false)
        XCTAssertFalse(session.hasCapturedFrames)
    }

    /// One second of 16 kHz mono float32 audio matching the recorder's target
    /// format, so the writer stores it verbatim (no conversion) and counts frames.
    private func oneSecondMonoBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let frames: AVAudioFrameCount = 16_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = 0.1
        }
        return buffer
    }

    /// Appends raw float32 PCM straight to a temp track file, bypassing the
    /// `PCMTrackWriter` so its frame counter stays at 0 — the on-disk shape left
    /// behind when a segment is finalized twice. `trailingByteCount` simulates a
    /// torn final frame (a write cut short mid-sample).
    private func writeRawFloatPCM(sampleCount: Int, trailingByteCount: Int = 0, to url: URL) throws {
        let samples = [Float](repeating: 0.1, count: sampleCount)
        var data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        if trailingByteCount > 0 {
            data.append(Data(repeating: 0, count: trailingByteCount))
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    func testStopWithoutCaptureThrowsNoCapturedAudioAndStaysEmpty() async throws {
        let session = try makeSession(systemAudioEnabled: false)

        do {
            _ = try await session.stop()
            XCTFail("Expected stop() to throw noCapturedAudio when nothing was captured")
        } catch let error as RecordingError {
            guard case .noCapturedAudio = error else {
                return XCTFail("Expected .noCapturedAudio, got \(error)")
            }
        }

        // The contract the facade relies on: after stop(), hasCapturedFrames must
        // still reflect what was captured (here: nothing). This is the property
        // the regression broke — it must remain false, not throw or change.
        XCTAssertFalse(session.hasCapturedFrames)
    }

    /// `stop()` must be one-shot. An interrupt-driven finalize and the user's
    /// Stop can interleave; the second entry used to re-read the (now released)
    /// frame counters as 0, take the "empty" branch, and delete the finished WAV
    /// along with the raw PCM — losing the whole recording.
    func testSecondStopDoesNotDeleteOutputAndThrowsAlreadyStopped() async throws {
        let session = try makeSession(systemAudioEnabled: false)
        let microphoneWriter = try session.configureForTeardownTesting(systemAudioUnit: nil)
        microphoneWriter.enqueue(buffer: oneSecondMonoBuffer())

        let result = try await session.stop()
        let renderedSize = try fileSize(at: result.outputURL)
        XCTAssertGreaterThan(renderedSize, 44, "First stop must render a WAV with audio beyond the header")

        do {
            _ = try await session.stop()
            XCTFail("Expected the second stop() to throw sessionAlreadyStopped")
        } catch let error as RecordingError {
            guard case .sessionAlreadyStopped = error else {
                return XCTFail("Expected .sessionAlreadyStopped, got \(error)")
            }
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.outputURL.path),
            "The second stop() must not delete the finished recording"
        )
        XCTAssertEqual(try fileSize(at: result.outputURL), renderedSize, "The finished WAV must be byte-identical")
        XCTAssertTrue(session.hasCapturedFrames, "The finalized frame count must survive a rejected second stop")

        try? FileManager.default.removeItem(at: result.outputURL)
    }

    /// The "is this segment empty?" decision must come from the bytes on disk,
    /// never from a counter that may have been reset. Here 16,000 frames are on
    /// disk while the writer's counter reads 0 — the old code deleted them.
    func testStopRendersFromPCMBytesWhenWriterCounterIsZero() async throws {
        let session = try makeSession(systemAudioEnabled: false)
        let microphoneWriter = try session.configureForTeardownTesting(systemAudioUnit: nil)
        let trackURLs = session.temporaryTrackURLs

        try writeRawFloatPCM(sampleCount: 16_000, to: trackURLs.microphone)
        XCTAssertEqual(microphoneWriter.frames, 0, "The writer counter must stay 0 for this to test the byte path")

        let result = try await session.stop()

        XCTAssertEqual(
            try fileSize(at: result.outputURL),
            44 + 16_000 * 2,
            "The WAV must carry every frame that was on disk (44-byte header + 16-bit mono frames)"
        )
        XCTAssertTrue(session.hasCapturedFrames, "Bytes on disk count as captured frames")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: trackURLs.microphone.path),
            "The microphone PCM is removed only by the successful render"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: trackURLs.systemAudio.path))

        try? FileManager.default.removeItem(at: result.outputURL)
    }

    /// A torn final write leaves a partial frame on disk. The byte-derived frame
    /// count truncates it rather than reading a phantom frame.
    func testStopIgnoresTrailingPartialFrameInPCMBytes() async throws {
        let session = try makeSession(systemAudioEnabled: false)
        try session.configureForTeardownTesting(systemAudioUnit: nil)
        let trackURLs = session.temporaryTrackURLs

        try writeRawFloatPCM(sampleCount: 16_000, trailingByteCount: 2, to: trackURLs.microphone)

        let result = try await session.stop()

        XCTAssertEqual(try fileSize(at: result.outputURL), 44 + 16_000 * 2)

        try? FileManager.default.removeItem(at: result.outputURL)
    }

    /// The only case that may delete: both counters at 0 *and* both temp files
    /// empty. Then there is provably nothing to lose.
    func testStopWithTrulyEmptyTracksRemovesTempFilesAndThrows() async throws {
        let session = try makeSession(systemAudioEnabled: false)
        try session.configureForTeardownTesting(systemAudioUnit: nil)
        let trackURLs = session.temporaryTrackURLs
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackURLs.microphone.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackURLs.systemAudio.path))

        do {
            _ = try await session.stop()
            XCTFail("Expected stop() to throw noCapturedAudio for two provably empty tracks")
        } catch let error as RecordingError {
            guard case .noCapturedAudio = error else {
                return XCTFail("Expected .noCapturedAudio, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: trackURLs.microphone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trackURLs.systemAudio.path))
        XCTAssertFalse(session.hasCapturedFrames)
    }
}
