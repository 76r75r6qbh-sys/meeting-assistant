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

    static func header(dataByteCount: Int) -> Data {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let chunkSize = UInt32(36 + dataByteCount)
        let subchunk2Size = UInt32(dataByteCount)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: channelCount.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian, Array.init))
        return data
    }
}
