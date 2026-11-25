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

/// The free-space guard for the per-source speaker tracks. Kept float32 PCM
/// grows for the whole meeting (about 920 MB per two hours for both sources)
/// and the track WAVs add more at Stop; the live recording must never run out
/// of disk because of them. Below the threshold the tracks are dropped, never
/// the mix.
enum RecordingDiskSpace {
    /// Bytes available on the volume that holds `url`, or `nil` when unknown.
    typealias CapacityProvider = @Sendable (URL) -> Int64?

    static let minimumFreeBytesForSpeakerTracks: Int64 = 2_000_000_000

    /// The volume's capacity for important usage, falling back to its plain
    /// available capacity. Asks about the file's directory, which exists.
    static let systemCapacity: CapacityProvider = { url in
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        ) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Whether there is room to keep speaker tracks beside `url`. An unknown
    /// capacity counts as low: the recording comes first.
    static func allowsSpeakerTracks(at url: URL, capacity: CapacityProvider) -> Bool {
        guard let available = capacity(url) else { return false }
        return available >= minimumFreeBytesForSpeakerTracks
    }

    /// Logs the low-space decision at most once per session directory (or
    /// recording folder). Privacy-safe: no paths, names or meeting IDs.
    static func noteLowSpace(for directory: URL, capacity: CapacityProvider) {
        guard claimLowSpaceLog(for: directory) else { return }
        let available = capacity(directory).map { String($0 / 1_000_000) } ?? "unknown"
        Log.recording.notice(
            "Low disk space (\(available, privacy: .public) MB available, need \(minimumFreeBytesForSpeakerTracks / 1_000_000, privacy: .public) MB); not keeping speaker tracks for this recording"
        )
    }

    /// `true` the first time it is asked about `directory`. `internal` so the
    /// once-per-session rule can be tested.
    static func claimLowSpaceLog(for directory: URL) -> Bool {
        let key = directory.standardizedFileURL.path
        return loggedDirectories.withLock { $0.insert(key).inserted }
    }

    private static let loggedDirectories = LockedSet()
}

/// A tiny lock-protected set; the renderer runs on whichever queue finalises
/// the segment.
private final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []

    func withLock<T>(_ body: (inout Set<String>) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&values)
    }
}
