import Foundation

enum RecordingSegmentMerger {
    static func merge(segmentURLs: [URL], into outputURL: URL) throws -> TimeInterval {
        let sampleRate = 16_000.0
        var renderedSamples = [Int16]()

        for url in segmentURLs {
            let data = try Data(contentsOf: url)
            let body = data.dropFirst(44)
            renderedSamples += body.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
        }

        let payload = renderedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        try (header(dataByteCount: payload.count) + payload).write(to: outputURL, options: .atomic)

        return Double(renderedSamples.count) / sampleRate
    }

    /// Thin alias over the shared `WAVCodec` header builder. Kept as a static on
    /// the merger so the golden pins (`RecordingSegmentMergerGoldenTests`) and
    /// the test helper that hand-crafts WAV fixtures continue to compile against
    /// `RecordingSegmentMerger.header(dataByteCount:)`.
    static func header(dataByteCount: Int) -> Data {
        WAVCodec.header(dataByteCount: dataByteCount)
    }
}
