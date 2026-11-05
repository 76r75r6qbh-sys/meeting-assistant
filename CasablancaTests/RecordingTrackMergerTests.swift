import Foundation
import XCTest
@testable import Casablanca

/// Pins the per-source speaker-track merge: each kept track is laid out on the
/// merged mix's timeline, segment by segment, so sample *n* of a track is
/// sample *n* of the mix — across pauses, recovered segments and uneven track
/// lengths.
final class RecordingTrackMergerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTrackMergerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: directory.appendingPathComponent(file).path
                )
            }
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Naming

    func testSpeakerTrackNamesDeriveFromTheRecording() {
        let recording = directory.appendingPathComponent("Weekly Sync.wav")
        XCTAssertEqual(
            RecordingFiles.speakerTrackURL(forRecording: recording, kind: .microphone).lastPathComponent,
            "Weekly Sync.mic.wav"
        )
        XCTAssertEqual(
            RecordingFiles.speakerTrackURL(forRecording: recording, kind: .systemAudio).lastPathComponent,
            "Weekly Sync.system.wav"
        )
        XCTAssertEqual(
            RecordingFiles.keptTrackURL(for: directory.appendingPathComponent("segment-007.mic.pcm")).lastPathComponent,
            "segment-007.mic.kept.pcm"
        )
    }

    // MARK: - Alignment

    func testPadsEachSegmentToMixLengthAcrossPauses() throws {
        let m: [Float] = [0.1, 0.2, 0.3]
        let s: [Float] = [-0.1, -0.2, -0.3, -0.4, -0.5]
        let n: [Float] = [0.5, 0.6, 0.7, 0.8]
        let segment1 = try makeSegment(number: 1, wavFrames: 5, mic: m, system: s)
        let segment2 = try makeSegment(number: 2, wavFrames: 4, mic: n, system: [])
        let recording = directory.appendingPathComponent("final.wav")
        _ = try RecordingSegmentMerger.merge(segmentURLs: [segment1, segment2], into: recording)

        // A tiny chunk size forces reads to straddle segment and chunk edges.
        let result = try RecordingTrackMerger.merge(
            segmentWAVs: [segment1, segment2],
            recordingURL: recording,
            chunkFrames: 2
        )

        let micURL = try XCTUnwrap(result.microphone)
        let systemURL = try XCTUnwrap(result.system)
        XCTAssertEqual(micURL, RecordingFiles.speakerTrackURL(forRecording: recording, kind: .microphone))
        XCTAssertEqual(systemURL, RecordingFiles.speakerTrackURL(forRecording: recording, kind: .systemAudio))

        let int16 = RecordingTrackMerger.int16Samples(fromFloat:)
        XCTAssertEqual(try samples(in: micURL), int16(m) + [0, 0] + int16(n))
        XCTAssertEqual(try samples(in: systemURL), int16(s) + [0, 0, 0, 0])

        let mixDataBytes = try dataByteCount(of: recording)
        XCTAssertEqual(mixDataBytes, 9 * 2)
        XCTAssertEqual(try dataByteCount(of: micURL), mixDataBytes)
        XCTAssertEqual(try dataByteCount(of: systemURL), mixDataBytes)
        XCTAssertEqual(try Data(contentsOf: micURL).prefix(44), WAVCodec.header(dataByteCount: mixDataBytes))
    }

    func testMissingKeptFileForASegmentIsSilence() throws {
        // Segment 1 is an adopted legacy WAV: it never had kept PCM.
        let segment1 = try makeSegment(number: 1, wavFrames: 3, mic: nil, system: nil)
        let n: [Float] = [0.25, -0.25]
        let segment2 = try makeSegment(number: 2, wavFrames: 2, mic: n, system: nil)
        let recording = directory.appendingPathComponent("final.wav")

        let result = try RecordingTrackMerger.merge(segmentWAVs: [segment1, segment2], recordingURL: recording)

        let micURL = try XCTUnwrap(result.microphone)
        XCTAssertEqual(try samples(in: micURL), [0, 0, 0] + RecordingTrackMerger.int16Samples(fromFloat: n))
        XCTAssertNil(result.system)
    }

    func testTrackLongerThanMixIsTruncated() throws {
        let m: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let segment = try makeSegment(number: 1, wavFrames: 2, mic: m, system: nil)
        let recording = directory.appendingPathComponent("final.wav")

        let result = try RecordingTrackMerger.merge(segmentWAVs: [segment], recordingURL: recording)

        XCTAssertEqual(
            try samples(in: try XCTUnwrap(result.microphone)),
            RecordingTrackMerger.int16Samples(fromFloat: Array(m.prefix(2)))
        )
    }

    func testMicOnlySessionWritesNoSystemTrack() throws {
        let segment = try makeSegment(number: 1, wavFrames: 3, mic: [0.1, 0.2, 0.3], system: nil)
        let recording = directory.appendingPathComponent("final.wav")

        let result = try RecordingTrackMerger.merge(segmentWAVs: [segment], recordingURL: recording)

        XCTAssertNotNil(result.microphone)
        XCTAssertNil(result.system)
        let systemPath = RecordingFiles.speakerTrackURL(forRecording: recording, kind: .systemAudio).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemPath))
    }

    func testFloatConversionClampsAndRounds() {
        XCTAssertEqual(RecordingTrackMerger.int16Samples(fromFloat: [1.5, -1.5, 0.5]), [32767, -32767, 16384])
    }

    func testFailedMergeLeavesNoPartialAndReturnsEmpty() async throws {
        let segment = try makeSegment(number: 1, wavFrames: 3, mic: [0.1, 0.2, 0.3], system: [0.1, 0.2, 0.3])
        // The microphone track merges first and succeeds; the system track
        // cannot be read, so the whole merge is abandoned.
        let unreadable = keptURL(segment: 1, kind: "system")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        let recording = directory.appendingPathComponent("final.wav")

        let result = await RecordingTrackMerger.mergeInBackground(segmentWAVs: [segment], recordingURL: recording)

        XCTAssertEqual(result, SpeakerTrackFiles())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".partial") }, "leftovers: \(leftovers)")
        XCTAssertFalse(leftovers.contains("final.mic.wav"), "a half-finished merge leaves no track behind")
        XCTAssertFalse(leftovers.contains("final.system.wav"))
        // The captured audio itself is untouched.
        XCTAssertTrue(leftovers.contains("segment-001.mic.kept.pcm"))
        XCTAssertTrue(leftovers.contains("segment-001.system.kept.pcm"))
    }

    // MARK: - Helpers

    /// Writes `segment-NNN.wav` with `wavFrames` Int16 frames plus, when given,
    /// the kept float32 PCM of each source.
    private func makeSegment(number: Int, wavFrames: Int, mic: [Float]?, system: [Float]?) throws -> URL {
        let wav = directory.appendingPathComponent(String(format: "segment-%03d.wav", number))
        var data = WAVCodec.header(dataByteCount: wavFrames * 2)
        data.append(Data(repeating: 0x11, count: wavFrames * 2))
        try data.write(to: wav)
        if let mic {
            try floats(mic).write(to: keptURL(segment: number, kind: "mic"))
        }
        if let system {
            try floats(system).write(to: keptURL(segment: number, kind: "system"))
        }
        return wav
    }

    private func keptURL(segment: Int, kind: String) -> URL {
        RecordingFiles.keptTrackURL(
            for: directory.appendingPathComponent(String(format: "segment-%03d.%@.pcm", segment, kind))
        )
    }

    private func floats(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func samples(in url: URL) throws -> [Int16] {
        let body = try Data(contentsOf: url).dropFirst(WAVCodec.headerByteCount)
        return Data(body).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// The `data` chunk size recorded in the header.
    private func dataByteCount(of url: URL) throws -> Int {
        let header = try Data(contentsOf: url).prefix(WAVCodec.headerByteCount)
        let bytes = Array(header.suffix(4))
        return Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    }
}
