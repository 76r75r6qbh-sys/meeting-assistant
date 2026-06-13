@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Mixes the two temporary float32 PCM tracks into the final 16 kHz mono 16-bit
/// WAV. Phase 1c extraction from `RecordingSession.mixTemporaryRecordings()`:
/// hardware-free and unit-testable. The chunked read/mix/write loop, the WAV
/// header write, and the gain constants are unchanged (the golden pins in
/// `RecordingMixdownTests` lock the mix arithmetic).
struct RecordingMixdownRenderer {
    let microphoneURL: URL
    let systemAudioURL: URL
    let microphoneFrames: AVAudioFramePosition
    let systemAudioFrames: AVAudioFramePosition
    let outputURL: URL
    let expectedOutputFrames: AVAudioFramePosition

    func render() throws {
        let microphoneBytes = Self.fileSize(at: microphoneURL)
        let systemAudioBytes = Self.fileSize(at: systemAudioURL)

        Log.recording.debug(
            "Finalizing recording: micFrames=\(self.microphoneFrames) micBytes=\(microphoneBytes) systemFrames=\(self.systemAudioFrames) systemBytes=\(systemAudioBytes)"
        )

        let microphoneHandle = microphoneFrames > 0
            ? try? FileHandle(forReadingFrom: microphoneURL)
            : nil
        let systemAudioHandle = systemAudioFrames > 0
            ? try? FileHandle(forReadingFrom: systemAudioURL)
            : nil

        guard microphoneHandle != nil || systemAudioHandle != nil else {
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not reopen its temporary recordings. micFrames=\(microphoneFrames), micBytes=\(microphoneBytes), systemFrames=\(systemAudioFrames), systemBytes=\(systemAudioBytes)."
            )
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            bestEffort("remove existing output file", Log.recording) {
                try FileManager.default.removeItem(at: outputURL)
            }
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL)
        else {
            throw RecordingError.failedToFinalizeRecording("Casablanca could not create the final WAV file.")
        }

        let chunkFrames = 4_096
        let chunkBytes = chunkFrames * MemoryLayout<Float>.size
        var mixedAudioByteCount = 0

        do {
            try outputHandle.write(contentsOf: Data(repeating: 0, count: 44))
        } catch {
            bestEffort("close output handle", Log.recording) { try outputHandle.close() }
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not initialize the final WAV file: \(Self.describeFinalizationError(error))."
            )
        }

        do {
            while true {
                let microphoneData = try microphoneHandle?.read(upToCount: chunkBytes) ?? Data()
                let systemAudioData = try systemAudioHandle?.read(upToCount: chunkBytes) ?? Data()

                let microphoneSamples = TemporaryRecordingPCMStorage.samples(from: microphoneData)
                let systemAudioSamples = TemporaryRecordingPCMStorage.samples(from: systemAudioData)
                let frameCount = max(microphoneSamples.count, systemAudioSamples.count)

                guard frameCount > 0 else { break }

                let mixedSamples = Self.mixFrames(
                    microphoneSamples: microphoneSamples,
                    systemAudioSamples: systemAudioSamples
                )

                let mixedData = mixedSamples.withUnsafeBufferPointer { buffer in
                    Data(buffer: buffer)
                }
                try outputHandle.write(contentsOf: mixedData)
                mixedAudioByteCount += mixedData.count
            }
        } catch {
            bestEffort("close output handle", Log.recording) { try outputHandle.close() }
            bestEffort("close microphone handle", Log.recording) { try microphoneHandle?.close() }
            bestEffort("close system audio handle", Log.recording) { try systemAudioHandle?.close() }
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not read one of the temporary recordings: \(Self.describeFinalizationError(error))."
            )
        }

        do {
            try outputHandle.seek(toOffset: 0)
            try outputHandle.write(contentsOf: WAVCodec.header(dataByteCount: mixedAudioByteCount))
            try outputHandle.close()
            bestEffort("close microphone handle", Log.recording) { try microphoneHandle?.close() }
            bestEffort("close system audio handle", Log.recording) { try systemAudioHandle?.close() }
        } catch {
            bestEffort("close output handle", Log.recording) { try outputHandle.close() }
            bestEffort("close microphone handle", Log.recording) { try microphoneHandle?.close() }
            bestEffort("close system audio handle", Log.recording) { try systemAudioHandle?.close() }
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not finalize the final WAV file: \(Self.describeFinalizationError(error))."
            )
        }

        let renderedFrameCount = mixedAudioByteCount / MemoryLayout<Int16>.size
        if expectedOutputFrames > 0, renderedFrameCount == 0 {
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca produced an empty final mix despite capturing audio. expectedFrames=\(expectedOutputFrames)."
            )
        }

        bestEffort("remove microphone temp file", Log.recording) { try FileManager.default.removeItem(at: microphoneURL) }
        bestEffort("remove system audio temp file", Log.recording) { try FileManager.default.removeItem(at: systemAudioURL) }
    }

    // Test seam (Phase 1b golden-fixture pinning): the per-frame mixing
    // arithmetic was lifted verbatim out of the chunk loop so it can be
    // exercised headlessly. The formula is unchanged:
    // clamp(mic*1.35 + system*0.8, -1, 1) scaled to Int16. `internal` so tests
    // can pin it; the production call site is byte-identical.
    static func mixFrames(microphoneSamples: [Float], systemAudioSamples: [Float]) -> [Int16] {
        let frameCount = max(microphoneSamples.count, systemAudioSamples.count)
        var mixedSamples = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            var sample: Float = 0

            if index < microphoneSamples.count {
                sample += microphoneSamples[index] * 1.35
            }

            if index < systemAudioSamples.count {
                sample += systemAudioSamples[index] * 0.8
            }

            let clamped = min(max(sample, -1), 1)
            mixedSamples[index] = Int16((clamped * Float(Int16.max)).rounded())
        }
        return mixedSamples
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func describeFinalizationError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
