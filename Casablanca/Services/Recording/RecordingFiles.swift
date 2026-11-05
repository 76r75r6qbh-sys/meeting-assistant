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

    /// Where the renderer keeps a fully mixed temp track for the speaker-track
    /// merge: `segment-007.mic.pcm` becomes `segment-007.mic.kept.pcm`. The
    /// name deliberately does not end in `.mic.pcm` / `.system.pcm`, so launch
    /// recovery never re-renders it or reports it as stranded, while
    /// `hasRecoverableAudio` still counts it (extension `pcm`).
    static func keptTrackURL(for pcmURL: URL) -> URL {
        pcmURL
            .deletingPathExtension()
            .appendingPathExtension("kept")
            .appendingPathExtension("pcm")
    }

    /// The per-source speaker track (always a WAV) beside a merged recording:
    /// `<name>.wav` becomes `<name>.mic.wav` or `<name>.system.wav`, which
    /// `RecordingCompressor.compress` later turns into `<name>.mic.m4a` /
    /// `<name>.system.m4a`.
    static func speakerTrackURL(forRecording recordingURL: URL, kind: RecordingTrackKind) -> URL {
        recordingURL
            .deletingPathExtension()
            .appendingPathExtension(trackSuffix(for: kind))
            .appendingPathExtension("wav")
    }

    /// The suffix `RecordingSession` gives each source's temp PCM
    /// (`segment-007.mic.pcm`, `segment-007.system.pcm`).
    static func trackSuffix(for kind: RecordingTrackKind) -> String {
        switch kind {
        case .microphone: return "mic"
        case .systemAudio: return "system"
        }
    }
}
