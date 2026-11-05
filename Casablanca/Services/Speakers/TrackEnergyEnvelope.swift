import AVFoundation
import Foundation

/// A track's loudness over time: one RMS value per 50 ms frame of 16 kHz mono
/// audio (800 samples). A trailing partial frame counts as a frame.
struct EnergyEnvelope: Equatable, Sendable {
    static let frameDuration = 0.05
    static let samplesPerFrame = 800

    var rms: [Float]

    /// Mean of `rms²` over the frames covering `[from, to]` seconds. Frames past
    /// the end of the track count as silence; an empty range covers one frame.
    func meanSquare(from: Double, to: Double) -> Float {
        let range = Self.frameRange(from: from, to: to)
        guard !range.isEmpty else { return 0 }
        var sum: Double = 0
        for index in range where index < rms.count {
            let value = Double(rms[index])
            sum += value * value
        }
        return Float(sum / Double(range.count))
    }

    /// The frame value at `index`, or 0 past either end.
    func value(at index: Int) -> Float {
        index >= 0 && index < rms.count ? rms[index] : 0
    }

    /// The frames covering `[from, to]` seconds: `floor(from)…ceil(to)` in frames,
    /// at least one frame, never negative. A tiny epsilon keeps `1.0 / 0.05`
    /// (= 20.000000000000004) from reaching into the next frame.
    static func frameRange(from: Double, to: Double) -> Range<Int> {
        guard from.isFinite, to.isFinite else { return 0..<0 }
        let epsilon = 1e-9
        let lower = max(0, Int((from / frameDuration + epsilon).rounded(.down)))
        let upper = max(lower + 1, Int((to / frameDuration - epsilon).rounded(.up)))
        return lower..<upper
    }
}

/// Builds `EnergyEnvelope`s from samples or from a track file on disk.
enum TrackEnergyEnvelope {
    static let sampleRate = 16_000.0
    /// Frames read per chunk; the file is streamed, never loaded whole.
    static let chunkFrames: AVAudioFrameCount = 65_536

    enum ReadError: LocalizedError {
        case cannotCreateFormat
        case cannotCreateConverter
        case cannotCreateBuffer
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateFormat: return "Could not create the 16 kHz analysis format."
            case .cannotCreateConverter: return "Could not convert the track to 16 kHz mono."
            case .cannotCreateBuffer: return "Could not allocate an audio buffer."
            case .conversionFailed(let reason): return "Track conversion failed: \(reason)"
            }
        }
    }

    /// The envelope of 16 kHz mono float samples.
    static func envelope(samples: [Float]) -> EnergyEnvelope {
        var accumulator = Accumulator()
        samples.withUnsafeBufferPointer { accumulator.append($0) }
        return accumulator.finish()
    }

    /// Reads a track (WAV or m4a, any rate and channel count) through
    /// `AVAudioConverter` to 16 kHz mono float, in chunks, and returns its envelope.
    static func read(url: URL) throws -> EnergyEnvelope {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw ReadError.cannotCreateFormat }

        let source = file.processingFormat
        var accumulator = Accumulator()

        if source.sampleRate == target.sampleRate, source.channelCount == 1,
           source.commonFormat == .pcmFormatFloat32 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunkFrames) else {
                throw ReadError.cannotCreateBuffer
            }
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                accumulator.append(buffer)
            }
            return accumulator.finish()
        }

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw ReadError.cannotCreateConverter
        }
        let ratio = target.sampleRate / source.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up)) + 1_024
        let feeder = ChunkFeeder(file: file, format: source, chunkFrames: chunkFrames)

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
                throw ReadError.cannotCreateBuffer
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                feeder.next(inputStatus)
            }
            if let readError = feeder.error { throw readError }
            if status == .error {
                throw ReadError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
            }
            accumulator.append(output)
            if status == .endOfStream || (status == .inputRanDry && feeder.finished) { break }
        }
        return accumulator.finish()
    }

    // MARK: - Streaming pieces

    /// Hands `AVAudioConverter` one freshly read chunk per request.
    private final class ChunkFeeder {
        let file: AVAudioFile
        let format: AVAudioFormat
        let chunkFrames: AVAudioFrameCount
        private(set) var finished = false
        private(set) var error: Error?

        init(file: AVAudioFile, format: AVAudioFormat, chunkFrames: AVAudioFrameCount) {
            self.file = file
            self.format = format
            self.chunkFrames = chunkFrames
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !finished, file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                self.error = error
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            guard buffer.frameLength > 0 else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }

    /// Sums squares across chunk boundaries and closes a frame every 800 samples.
    private struct Accumulator {
        private var rms: [Float] = []
        private var sumOfSquares: Double = 0
        private var count = 0

        mutating func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        mutating func append(_ samples: UnsafeBufferPointer<Float>) {
            for sample in samples {
                let value = Double(sample)
                sumOfSquares += value * value
                count += 1
                if count == EnergyEnvelope.samplesPerFrame { closeFrame() }
            }
        }

        mutating func finish() -> EnergyEnvelope {
            if count > 0 { closeFrame() }
            return EnergyEnvelope(rms: rms)
        }

        private mutating func closeFrame() {
            rms.append(Float((sumOfSquares / Double(count)).squareRoot()))
            sumOfSquares = 0
            count = 0
        }
    }
}
