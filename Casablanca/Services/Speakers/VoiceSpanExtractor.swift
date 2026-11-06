import AVFoundation
import FluidAudio
import Foundation

/// Reads only the given time ranges of a track, in memory: each range is read
/// with `AVAudioFile` (seek + read), resampled to 16 kHz mono, and the ranges
/// are joined with a short silence so the diarizer sees separate turns. No
/// audio is written to disk. "Remember voice…" embeds exactly this buffer, so
/// nothing outside the consented speaker's segments reaches the model.
enum VoiceSpanExtractor {
    static let sampleRate = 16_000.0
    static let gapSeconds = 0.5

    enum ExtractionError: Error {
        case bufferAllocationFailed
    }

    /// 16 kHz mono samples of `ranges` (seconds) in time order, with
    /// `gapSeconds` of silence between them. Ranges are clamped to the file;
    /// empty ranges are skipped. Checks for cancellation between ranges.
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
            try Task.checkCancellation()
            let start = max(0, min(file.length, AVAudioFramePosition((range.lowerBound * rate).rounded(.down))))
            let end = max(0, min(file.length, AVAudioFramePosition((range.upperBound * rate).rounded(.up))))
            guard end > start else { continue }
            let count = AVAudioFrameCount(end - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw ExtractionError.bufferAllocationFailed
            }
            file.framePosition = start
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { continue }
            let mono = try converter.resampleBuffer(buffer)
            guard !mono.isEmpty else { continue }
            if !output.isEmpty { output.append(contentsOf: gap) }
            output.append(contentsOf: mono)
        }
        return output
    }
}
