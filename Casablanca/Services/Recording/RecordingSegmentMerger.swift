import Foundation

enum RecordingSegmentMerger {
    /// The merge `AudioRecordingService` runs by default. `nonisolated async`,
    /// so it executes on the global executor rather than on the main actor that
    /// awaits it: a two-hour meeting is ~230 MB of segments, and merging them
    /// on the main actor froze the UI for the whole copy.
    static func mergeInBackground(segmentURLs: [URL], into outputURL: URL) async throws -> TimeInterval {
        try merge(segmentURLs: segmentURLs, into: outputURL)
    }

    /// Concatenates the PCM bodies of `segmentURLs` (16 kHz mono 16-bit WAVs)
    /// into one WAV at `outputURL` and returns its duration.
    ///
    /// Streams: each segment's body is copied in `chunkByteCount` pieces and the
    /// RIFF/data sizes are patched in at the end, so memory stays flat however
    /// long the meeting. Loading everything up front used to hold the audio in
    /// memory three to four times over (~1 GB peak for two hours). The output
    /// is byte-identical to that implementation: the canonical 44-byte header
    /// is skipped per segment and a trailing odd byte is dropped, as binding the
    /// body to `Int16` did. The file is written beside the target and moved
    /// into place, so a failed merge never leaves a half-written WAV behind.
    static func merge(
        segmentURLs: [URL],
        into outputURL: URL,
        chunkByteCount: Int = 1 << 20
    ) throws -> TimeInterval {
        let fileManager = FileManager.default
        let partialURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).partial")
        guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partialURL.path])
        }

        var dataByteCount = 0
        do {
            let output = try FileHandle(forWritingTo: partialURL)
            defer { try? output.close() }

            try output.write(contentsOf: header(dataByteCount: 0))
            for url in segmentURLs {
                dataByteCount += try appendBody(of: url, to: output, chunkByteCount: chunkByteCount)
            }
            try output.seek(toOffset: 0)
            try output.write(contentsOf: header(dataByteCount: dataByteCount))
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }

        do {
            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: partialURL)
            } else {
                try fileManager.moveItem(at: partialURL, to: outputURL)
            }
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }

        return Double(dataByteCount / MemoryLayout<Int16>.size) / sampleRate
    }

    /// Copies one segment's whole samples behind the header. Returns the bytes
    /// written.
    private static func appendBody(of url: URL, to output: FileHandle, chunkByteCount: Int) throws -> Int {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        let fileByteCount = Int(try input.seekToEnd())
        let bodyByteCount = max(0, fileByteCount - WAVCodec.headerByteCount)
        var remaining = bodyByteCount - bodyByteCount % MemoryLayout<Int16>.size
        guard remaining > 0 else { return 0 }

        try input.seek(toOffset: UInt64(WAVCodec.headerByteCount))
        var written = 0
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: min(chunkByteCount, remaining)), !chunk.isEmpty else {
                break
            }
            try output.write(contentsOf: chunk)
            written += chunk.count
            remaining -= chunk.count
        }
        return written
    }

    private static let sampleRate = 16_000.0

    /// Thin alias over the shared `WAVCodec` header builder. Kept as a static on
    /// the merger so the golden pins (`RecordingSegmentMergerGoldenTests`) and
    /// the test helper that hand-crafts WAV fixtures continue to compile against
    /// `RecordingSegmentMerger.header(dataByteCount:)`.
    static func header(dataByteCount: Int) -> Data {
        WAVCodec.header(dataByteCount: dataByteCount)
    }
}
