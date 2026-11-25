import AVFoundation
import XCTest
@testable import Casablanca

/// Concurrency + flush tests for `PCMTrackWriter` (Phase 1c).
///
/// The writer owns a serial queue, a `FileHandle`, and a lock-guarded frame
/// counter. These tests pin that:
///  - concurrent `enqueue` from two queues converges to the correct total frame
///    count and on-disk byte count (no lost or torn writes);
///  - `drainAndClose` flushes all pending work before returning.
///
/// Buffers are already in the writer's target format (16 kHz mono float32), so
/// `convert` short-circuits and the bytes written are the raw float samples.
final class PCMTrackWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCMTrackWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func targetFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    private func makeBuffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let format = targetFormat()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData!.pointee
        for index in 0..<Int(frames) {
            channel[index] = value
        }
        return buffer
    }

    private func makeWriter(named name: String) throws -> (PCMTrackWriter, URL) {
        let url = directory.appendingPathComponent("\(name).pcm")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let writer = PCMTrackWriter(
            label: "test",
            queueLabel: "com.casablanca.tests.\(name)",
            targetFormat: targetFormat(),
            fileHandle: handle,
            onFailure: { XCTFail("unexpected failure: \($0)") }
        )
        return (writer, url)
    }

    func testConcurrentEnqueueFromTwoQueuesProducesCorrectFrameAndByteCounts() throws {
        let (writer, url) = try makeWriter(named: "concurrent")

        let framesPerBuffer: AVAudioFrameCount = 64
        let buffersPerQueue = 200
        let queueA = DispatchQueue(label: "test.producer.a")
        let queueB = DispatchQueue(label: "test.producer.b")

        // Pre-build all buffers on this thread. `AVAudioPCMBuffer` allocation
        // touches AVFoundation globals that are not thread-safe to call
        // concurrently, so building inside the producer closures would race in
        // the test harness (not in `PCMTrackWriter`). The concurrency under test
        // is the concurrent `enqueue` itself.
        let buffers = (0..<(buffersPerQueue * 2)).map { _ in
            makeBuffer(frames: framesPerBuffer, value: 0.25)
        }

        let group = DispatchGroup()
        for (offset, queue) in [queueA, queueB].enumerated() {
            for index in 0..<buffersPerQueue {
                let buffer = buffers[offset * buffersPerQueue + index]
                group.enter()
                queue.async {
                    writer.enqueue(buffer: buffer)
                    group.leave()
                }
            }
        }
        group.wait()

        writer.drainAndClose()

        let expectedFrames = AVAudioFramePosition(framesPerBuffer) * AVAudioFramePosition(buffersPerQueue * 2)
        XCTAssertEqual(writer.frames, expectedFrames)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, Int(expectedFrames) * MemoryLayout<Float>.size)
    }

    func testDrainAndCloseFlushesPendingWork() throws {
        let (writer, url) = try makeWriter(named: "flush")

        // Enqueue work, then immediately drain. drainAndClose must block until
        // every queued conversion+write has completed.
        for _ in 0..<50 {
            writer.enqueue(buffer: makeBuffer(frames: 100, value: 0.5))
        }
        writer.drainAndClose()

        XCTAssertEqual(writer.frames, 5_000)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 5_000 * MemoryLayout<Float>.size)

        // The flushed bytes are the raw float samples (no conversion needed).
        let samples = TemporaryRecordingPCMStorage.samples(from: data)
        XCTAssertEqual(samples.count, 5_000)
        XCTAssertTrue(samples.allSatisfy { $0 == 0.5 })
    }

    func testFramesReadableConcurrentlyWithEnqueue() throws {
        let (writer, _) = try makeWriter(named: "reads")

        let buffers = (0..<300).map { _ in makeBuffer(frames: 32, value: 0.1) }

        let group = DispatchGroup()
        // Writer thread.
        group.enter()
        DispatchQueue.global().async {
            for buffer in buffers {
                writer.enqueue(buffer: buffer)
            }
            group.leave()
        }
        // Concurrent reader thread: lock-read must never crash or tear.
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<1_000 {
                _ = writer.frames
            }
            group.leave()
        }
        group.wait()

        writer.drainAndClose()
        XCTAssertEqual(writer.frames, 32 * 300)
    }
}
