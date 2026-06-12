import Foundation

/// Builds canonical 16 kHz, mono, 16-bit little-endian PCM WAV headers.
///
/// Phase 1c unified the two byte-identical header builders that previously
/// lived in `RecordingSession.wavHeader(dataByteCount:)` and
/// `RecordingSegmentMerger.header(dataByteCount:)`. Both call sites now route
/// through `WAVCodec.header(dataByteCount:)`; the emitted bytes are unchanged
/// (the golden header pins in `RecordingSegmentMergerGoldenTests` lock this).
enum WAVCodec {
    static func header(dataByteCount: Int) -> Data {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let riffChunkSize = UInt32(36 + dataByteCount)
        let dataSize = UInt32(dataByteCount)

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: riffChunkSize.littleEndian, Array.init))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)

        let fmtChunkSize: UInt32 = 16
        let audioFormat: UInt16 = 1
        header.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: channelCount.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        return header
    }
}
