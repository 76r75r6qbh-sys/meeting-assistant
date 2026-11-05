import Foundation

/// The on-disk naming and sizing rules the recording store, launch recovery,
/// the session and the mixdown all have to agree on. Kept in one place so they
/// cannot drift apart.
enum RecordingFiles {
    static let segmentFileNamePrefix = "segment-"

    /// Parses the number out of `segment-007.wav`, `segment-007.mic.pcm`, …
    static func segmentNumber(inFileName fileName: String) -> Int? {
        guard fileName.hasPrefix(segmentFileNamePrefix) else { return nil }
        let digits = fileName
            .dropFirst(segmentFileNamePrefix.count)
            .prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// The file's size in bytes, or `nil` when it cannot be determined. Never
    /// collapse that `nil` into 0 where the answer decides a deletion: an
    /// unknown size must not read as "empty".
    static func byteCount(of url: URL, fileManager: FileManager = .default) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.size] as? Int
    }

    /// Bytes currently on disk for a temp track, or 0 when the file is
    /// missing. Only for measuring captured audio, never for deciding a delete.
    static func trackByteCount(at url: URL) -> Int64 {
        Int64(byteCount(of: url) ?? 0)
    }
}
