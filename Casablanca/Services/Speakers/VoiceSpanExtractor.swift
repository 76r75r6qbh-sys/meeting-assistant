import AVFoundation
import FluidAudio
import Foundation

/// Reads only the given time ranges of a track, in memory: each range is read
/// with `AVAudioFile` (seek + chunked read), averaged to mono, resampled to
/// 16 kHz, and the ranges are joined with a short silence so the diarizer sees
/// separate turns. No audio is written to disk. "Remember voice…" embeds
/// exactly this buffer, so nothing outside the consented speaker's segments
/// reaches the model.
enum VoiceSpanExtractor {
    static let sampleRate = 16_000.0
    static let gapSeconds = 0.5
    /// Frames per read: one second at 48 kHz.
    static let chunkFrames = 48_000
    /// Smaller reads tried, in order, after a read throws (AAC's tail).
    static let backoffFrames = [4_096, 512]

    enum ExtractionError: Error {
        case bufferAllocationFailed
    }

    /// 16 kHz mono samples of `ranges` (seconds) in time order, with
    /// `gapSeconds` of silence between them. Ranges are clamped to the file;
    /// empty ranges are skipped. Checks for cancellation between chunks.
    static func samples(
        url: URL,
        ranges: [ClosedRange<Double>],
        gapSeconds: Double = gapSeconds
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let converter = AudioConverter()
        let gap = [Float](repeating: 0, count: Int((gapSeconds * sampleRate).rounded()))

        var output: [Float] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(0, min(file.length, AVAudioFramePosition((range.lowerBound * rate).rounded(.down))))
            let end = max(0, min(file.length, AVAudioFramePosition((range.upperBound * rate).rounded(.up))))
            guard end > start else { continue }
            let read = try readFrames(total: Int(end - start), chunk: chunkFrames) { offset, count in
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                    throw ExtractionError.bufferAllocationFailed
                }
                file.framePosition = start + AVAudioFramePosition(offset)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
                return downmixed(buffer)
            }
            if let failure = read.failure, read.samples.isEmpty,
               !isEndOfFile(rangeStart: start, fileLength: file.length, rate: rate, producedAudio: !output.isEmpty) {
                throw failure
            }
            let mono = read.samples
            guard !mono.isEmpty else { continue }
            let resampled = try converter.resample(mono, from: rate)
            guard !resampled.isEmpty else { continue }
            if !output.isEmpty { output.append(contentsOf: gap) }
            output.append(contentsOf: resampled)
        }
        return output
    }

    /// Up to `total` frames from `read(offset, count)` (offset from the
    /// range start; the reader seeks there), `chunk` at a time. A short or
    /// empty read is the end of the file. When a read throws, it is retried
    /// at the same offset with smaller reads (`backoffFrames`), and what those
    /// return is kept: for AAC, `AVAudioFile.length` is an estimate and any
    /// read crossing its phantom tail throws. When even the smallest read
    /// throws, reading stops and the error is returned beside the samples
    /// read so far; the caller decides whether it is the end of the file
    /// (`isEndOfFile`). A cancellation is always thrown.
    static func readFrames(
        total: Int,
        chunk: Int,
        read: (_ offset: Int, _ count: Int) throws -> [Float]
    ) throws -> (samples: [Float], failure: Error?) {
        var samples: [Float] = []
        samples.reserveCapacity(total)
        var sizes = ([chunk] + backoffFrames.filter { $0 < chunk })[...]
        while samples.count < total, let size = sizes.first {
            let wanted = min(size, total - samples.count)
            let got: [Float]
            do {
                got = try read(samples.count, wanted)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ExtractionError {
                // Our own failures (no buffer) are not end-of-file.
                throw error
            } catch {
                sizes = sizes.dropFirst()
                if sizes.isEmpty { return (samples, error) }
                continue
            }
            samples.append(contentsOf: got)
            if got.count < wanted { break }
        }
        return (samples, nil)
    }

    /// Whether a range whose reads all threw is just past the real end of
    /// the file: earlier ranges already produced audio, or the range starts
    /// within the last second of the (estimated) length.
    static func isEndOfFile(
        rangeStart: AVAudioFramePosition,
        fileLength: AVAudioFramePosition,
        rate: Double,
        producedAudio: Bool
    ) -> Bool {
        producedAudio || rangeStart >= fileLength - AVAudioFramePosition(rate.rounded())
    }

    /// The channel average of a deinterleaved float buffer (what
    /// `AVAudioFile.processingFormat` always is). FluidAudio's converter
    /// would keep only the left channel of a stereo file.
    static func downmixed(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, !buffer.format.isInterleaved, let data = buffer.floatChannelData else { return [] }
        var mono = Array(UnsafeBufferPointer(start: data[0], count: frames))
        guard channels > 1 else { return mono }
        for channel in 1..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { mono[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        return mono.map { $0 * scale }
    }
}
