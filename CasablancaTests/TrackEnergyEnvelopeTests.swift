import AVFoundation
import XCTest
@testable import Casablanca

/// Deterministic test signals for the speaker-attribution tests: a seeded LCG,
/// 16 kHz, built in memory. Never real recordings.
enum SyntheticSignal {
    static let sampleRate = 16_000

    /// Uniform noise in `[-amplitude, amplitude]` from a 64-bit LCG seeded with `seed`.
    static func noise(seed: UInt64, count: Int, amplitude: Float) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            // Top 24 bits → [0, 1).
            let unit = Float(state >> 40) / Float(1 << 24)
            samples[index] = (unit * 2 - 1) * amplitude
        }
        return samples
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: samples(seconds))
    }

    static func samples(_ seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }

    /// `signal` with everything outside `[from, to)` seconds set to zero.
    static func gated(_ signal: [Float], keep ranges: [(Double, Double)]) -> [Float] {
        var out = [Float](repeating: 0, count: signal.count)
        for (from, to) in ranges {
            let lo = max(0, samples(from))
            let hi = min(signal.count, samples(to))
            if lo < hi { for index in lo..<hi { out[index] = signal[index] } }
        }
        return out
    }

    /// Writes 16 kHz mono Int16 PCM as a WAV (same header the app writes).
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = WAVCodec.header(dataByteCount: samples.count * 2)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            pcm[index] = Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded())
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}

final class TrackEnergyEnvelopeTests: XCTestCase {

    func testFrameRMSOfConstantSignal() {
        let envelope = TrackEnergyEnvelope.envelope(samples: [Float](repeating: 0.5, count: 16_000))

        XCTAssertEqual(EnergyEnvelope.frameDuration, 0.05)
        XCTAssertEqual(envelope.rms.count, 20)
        for value in envelope.rms {
            XCTAssertEqual(value, 0.5, accuracy: 1e-6)
        }
        XCTAssertEqual(envelope.meanSquare(from: 0, to: 1), 0.25, accuracy: 1e-6)
    }

    func testReadsWAVMatchesInMemoryEnvelope() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = SyntheticSignal.noise(seed: 7, count: 16_000 * 2 + 300, amplitude: 0.4)
        let url = directory.appendingPathComponent("meeting.mic.wav")
        try SyntheticSignal.writeWAV(samples, to: url)

        let read = try TrackEnergyEnvelope.read(url: url)
        // The WAV holds Int16: compare against the same quantised samples.
        let quantised = samples.map { Float(Int16((max(-1, min(1, $0)) * Float(Int16.max)).rounded())) / 32_768 }
        let expected = TrackEnergyEnvelope.envelope(samples: quantised)

        XCTAssertEqual(read.rms.count, expected.rms.count)
        XCTAssertEqual(read.rms.count, 41, "A trailing partial frame counts as a frame")
        for (lhs, rhs) in zip(read.rms, expected.rms) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-4)
        }
    }

    func testReadsCompressedM4ATrack() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = SyntheticSignal.noise(seed: 11, count: 16_000 * 3, amplitude: 0.3)
        let wavURL = directory.appendingPathComponent("meeting.system.wav")
        try SyntheticSignal.writeWAV(samples, to: wavURL)

        let m4aURL = try await RecordingCompressor.compress(wavURL: wavURL)
        XCTAssertEqual(m4aURL.lastPathComponent, "meeting.system.m4a")

        let wav = try TrackEnergyEnvelope.read(url: wavURL)
        let m4a = try TrackEnergyEnvelope.read(url: m4aURL)

        XCTAssertEqual(Double(m4a.rms.count), Double(wav.rms.count), accuracy: 1)
        let wavMean = wav.rms.reduce(0, +) / Float(wav.rms.count)
        let m4aMean = m4a.rms.reduce(0, +) / Float(m4a.rms.count)
        XCTAssertEqual(m4aMean, wavMean, accuracy: wavMean * 0.10)
    }

    func testMeanSquareOutsideTheEnvelopeIsZero() {
        let envelope = TrackEnergyEnvelope.envelope(samples: [Float](repeating: 0.5, count: 16_000))
        XCTAssertEqual(envelope.meanSquare(from: 5, to: 6), 0)
        XCTAssertEqual(EnergyEnvelope(rms: []).meanSquare(from: 0, to: 1), 0)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("energy-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
