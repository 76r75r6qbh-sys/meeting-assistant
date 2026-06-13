@preconcurrency import AVFoundation
import Foundation

/// Re-encodes a finished recording's 16 kHz mono WAV mixdown to AAC inside an
/// m4a container, to keep long-term disk usage down (uncompressed 16 kHz mono
/// 16-bit WAV is ~115 MB/hr; AAC at 32 kbps mono is ~14 MB/hr — roughly an 8x
/// reduction with no meaningful quality loss for speech).
///
/// This is a purely additive, downstream post-processing step. It runs only
/// AFTER transcription has read the WAV (WhisperKit needs the lossless PCM),
/// and it never touches the WAV-production code paths
/// (`RecordingMixdownRenderer` / `RecordingSegmentMerger` / `WAVCodec`), whose
/// byte output is golden-pinned.
///
/// Uses `AVAssetReader` + `AVAssetWriter` rather than `AVAssetExportSession`
/// for explicit control of the output format (mono, 16 kHz, AAC) and so a
/// failure surfaces as a concrete error we can log and recover from.
enum RecordingCompressor {
    enum CompressionError: LocalizedError {
        case noAudioTrack
        case cannotCreateReader(String)
        case cannotCreateWriter(String)
        case readerSetupFailed
        case writerSetupFailed
        case exportFailed(String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "The recording had no audio track to compress."
            case .cannotCreateReader(let reason):
                return "Could not read the recording for compression: \(reason)"
            case .cannotCreateWriter(let reason):
                return "Could not create the compressed file: \(reason)"
            case .readerSetupFailed:
                return "Could not configure the audio reader for compression."
            case .writerSetupFailed:
                return "Could not configure the audio writer for compression."
            case .exportFailed(let reason):
                return "Compression failed: \(reason)"
            case .outputMissing:
                return "Compression produced no output file."
            }
        }
    }

    /// Target AAC bitrate. 32 kbps mono is comfortably above transparency for
    /// 16 kHz speech while staying tiny on disk.
    static let targetBitrate = 32_000
    static let sampleRate = 16_000.0
    static let channelCount = 1

    /// Re-encodes `wavURL` to an AAC/m4a file alongside it (same basename, `.m4a`
    /// extension) and returns the output URL.
    ///
    /// On any failure the partial output is removed and an error is thrown; the
    /// input WAV is left untouched so the recording is never lost. Callers are
    /// responsible for deleting the WAV only once this returns successfully.
    static func compress(wavURL: URL) async throws -> URL {
        let outputURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")

        // A stale output from a previous failed attempt would make the writer
        // refuse to start; clear it first.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: wavURL)
        // `loadTracks(withMediaType:)` is available from macOS 12; our deployment
        // target is macOS 14, so the deprecated synchronous `tracks(_:)` fallback
        // is unnecessary and we can use the async loader unconditionally.
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw CompressionError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw CompressionError.cannotCreateReader(error.localizedDescription)
        }

        // Decode to 16-bit signed-integer PCM; the writer's AAC encoder consumes this.
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(readerOutput) else {
            throw CompressionError.readerSetupFailed
        }
        reader.add(readerOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw CompressionError.cannotCreateWriter(error.localizedDescription)
        }

        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: targetBitrate,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw CompressionError.writerSetupFailed
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "reader did not start")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "nl.medicore.casablanca.recording.compress")
        // The reader/writer/output are not Sendable, but all access happens
        // exclusively inside the `requestMediaDataWhenReady` block, which runs
        // serially on `queue`; the continuation is resumed exactly once. Boxing
        // them in an `@unchecked Sendable` holder confines the capture and
        // silences the closure's Sendable diagnostics without weakening safety.
        let pipeline = CompressionPipeline(reader: reader, writerInput: writerInput, readerOutput: readerOutput)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while pipeline.writerInput.isReadyForMoreMediaData {
                    guard pipeline.reader.status == .reading,
                          let sampleBuffer = pipeline.readerOutput.copyNextSampleBuffer() else {
                        pipeline.writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !pipeline.writerInput.append(sampleBuffer) {
                        // Append failure: stop pulling; finish handling below
                        // inspects writer/reader status and reports the error.
                        pipeline.reader.cancelReading()
                        pipeline.writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: outputURL)
            throw CompressionError.exportFailed(reader.error?.localizedDescription ?? "read failed")
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw CompressionError.exportFailed(writer.error?.localizedDescription ?? "write did not complete")
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CompressionError.outputMissing
        }

        return outputURL
    }
}

/// Holds the non-Sendable AVFoundation reader/writer objects so they can be
/// captured in the `@Sendable` `requestMediaDataWhenReady` closure.
/// `@unchecked Sendable`: every access is confined to the dedicated serial
/// compression queue that drives that closure, so the objects are never touched
/// concurrently.
private final class CompressionPipeline: @unchecked Sendable {
    let reader: AVAssetReader
    let writerInput: AVAssetWriterInput
    let readerOutput: AVAssetReaderTrackOutput

    init(reader: AVAssetReader, writerInput: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.writerInput = writerInput
        self.readerOutput = readerOutput
    }
}
