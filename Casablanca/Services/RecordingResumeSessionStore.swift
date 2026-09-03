import Foundation
import OSLog

enum RecordingResumeSessionStoreError: Error, Equatable {
    case sessionNotFound(UUID)
}

struct PersistedRecordingSegment: Codable, Equatable {
    let index: Int
    let filePath: String
    let duration: TimeInterval
    let createdAt: Date
}

struct PersistedRecordingSession: Codable, Equatable {
    let meetingID: UUID
    let createdAt: Date
    var updatedAt: Date
    var nextSegmentNumber: Int
    var systemAudioEnabled: Bool
    var selectedInputDeviceID: String?
    var segments: [PersistedRecordingSegment]
}

struct RecordingResumeSessionStore {
    private let fileManager: FileManager
    private let baseDirectoryProvider: () throws -> URL

    init(
        fileManager: FileManager = .default,
        baseDirectoryProvider: @escaping () throws -> URL = {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return appSupport
                .appendingPathComponent("Casablanca", isDirectory: true)
                .appendingPathComponent("RecordingSessions", isDirectory: true)
        }
    ) {
        self.fileManager = fileManager
        self.baseDirectoryProvider = baseDirectoryProvider
    }

    func loadSession(for meetingID: UUID) throws -> PersistedRecordingSession? {
        let manifestURL = try manifestURL(for: meetingID)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(PersistedRecordingSession.self, from: data)
    }

    @discardableResult
    func createSession(
        for meetingID: UUID,
        systemAudioEnabled: Bool,
        selectedInputDeviceID: String?
    ) throws -> PersistedRecordingSession {
        let now = Date()
        let session = PersistedRecordingSession(
            meetingID: meetingID,
            createdAt: now,
            updatedAt: now,
            nextSegmentNumber: 1,
            systemAudioEnabled: systemAudioEnabled,
            selectedInputDeviceID: selectedInputDeviceID,
            segments: []
        )
        try persist(session)
        return session
    }

    func nextSegmentURL(for meetingID: UUID, segmentNumber: Int) throws -> URL {
        try sessionDirectory(for: meetingID)
            .appendingPathComponent(String(format: "segment-%03d.wav", segmentNumber))
    }

    /// Reserves the first segment number whose WAV *and* raw PCM slots are all
    /// free, persists it in the manifest and returns the WAV URL to record to.
    ///
    /// Recording used to trust the manifest counter alone, which silently
    /// overwrote `segment-001.wav` (and its in-flight `.mic.pcm` /
    /// `.system.pcm` siblings) whenever the counter had been reset — real
    /// audio was lost that way. Probing the directory makes that impossible.
    func reserveNextSegmentURL(for meetingID: UUID) throws -> URL {
        guard var session = try loadSession(for: meetingID) else {
            throw RecordingResumeSessionStoreError.sessionNotFound(meetingID)
        }

        let directory = try sessionDirectory(for: meetingID)
        var segmentNumber = max(1, session.nextSegmentNumber)
        while segmentNumberIsTaken(segmentNumber, in: directory) {
            segmentNumber += 1
        }

        session.nextSegmentNumber = segmentNumber
        session.updatedAt = Date()
        try persist(session)

        return directory.appendingPathComponent(String(format: "segment-%03d.wav", segmentNumber))
    }

    @discardableResult
    func appendSegment(
        for meetingID: UUID,
        segmentURL: URL,
        duration: TimeInterval
    ) throws -> PersistedRecordingSession {
        guard var session = try loadSession(for: meetingID) else {
            throw RecordingResumeSessionStoreError.sessionNotFound(meetingID)
        }
        // The filename is the authority: a segment recorded as `segment-007.wav`
        // must be stored as index 7 even when the manifest counter drifted.
        let index = Self.segmentNumber(inFileName: segmentURL.lastPathComponent) ?? session.nextSegmentNumber
        let segment = PersistedRecordingSegment(
            index: index,
            filePath: segmentURL.path,
            duration: duration,
            createdAt: Date()
        )
        session.segments.append(segment)
        session.nextSegmentNumber = max(session.nextSegmentNumber, index + 1)
        session.updatedAt = Date()
        try persist(session)
        return session
    }

    /// Every file in the session directory except the manifest: the WAV
    /// segments plus any raw `.mic.pcm` / `.system.pcm` still on disk.
    /// Empty when the directory does not exist.
    func sessionFiles(for meetingID: UUID) throws -> [URL] {
        let directory = try sessionDirectory(for: meetingID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        // No `.skipsHiddenFiles`: the deletion guard must see every byte on
        // disk, including anything hidden that could still hold audio.
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.lastPathComponent != Self.manifestFileName }
    }

    /// True when the session directory still holds audio worth keeping: any
    /// raw PCM with a single byte in it, or any WAV larger than its 44-byte
    /// header. Conservative by design — a directory we cannot inspect counts
    /// as holding audio, because guessing wrong destroys a recording.
    func hasRecoverableAudio(for meetingID: UUID) -> Bool {
        let files: [URL]
        do {
            files = try sessionFiles(for: meetingID)
        } catch {
            Log.recording.notice(
                "hasRecoverableAudio could not list session files for meeting \(meetingID.uuidString, privacy: .public); assuming audio is present"
            )
            return true
        }

        return files.contains { file in
            switch file.pathExtension.lowercased() {
            case "pcm":
                return fileSize(of: file) > 0
            case "wav":
                return fileSize(of: file) > Self.wavHeaderByteCount
            default:
                return false
            }
        }
    }

    /// Deletes the session directory only when it holds no recoverable audio.
    /// Returns whether the directory was removed.
    @discardableResult
    func deleteSessionIfEmpty(for meetingID: UUID) throws -> Bool {
        let directory = try sessionDirectory(for: meetingID)

        if hasRecoverableAudio(for: meetingID) {
            Log.recording.notice(
                "Keeping recording session for meeting \(meetingID.uuidString, privacy: .public) at \(directory.path, privacy: .public): recoverable audio present"
            )
            return false
        }

        Log.recording.notice(
            "Deleting empty recording session for meeting \(meetingID.uuidString, privacy: .public) at \(directory.path, privacy: .public)"
        )
        try deleteSession(for: meetingID)
        return true
    }

    func deleteSession(for meetingID: UUID) throws {
        let directory = try sessionDirectory(for: meetingID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        try fileManager.removeItem(at: directory)
    }

    func sessionDirectory(for meetingID: UUID) throws -> URL {
        try baseDirectoryProvider().appendingPathComponent(meetingID.uuidString, isDirectory: true)
    }

    private func manifestURL(for meetingID: UUID) throws -> URL {
        try sessionDirectory(for: meetingID).appendingPathComponent(Self.manifestFileName)
    }

    private func persist(_ session: PersistedRecordingSession) throws {
        let directory = try sessionDirectory(for: session.meetingID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: directory.appendingPathComponent(Self.manifestFileName), options: .atomic)
    }

    /// True when `segment-%03d` already owns a WAV or either raw PCM track.
    private func segmentNumberIsTaken(_ segmentNumber: Int, in directory: URL) -> Bool {
        let stem = String(format: "segment-%03d", segmentNumber)
        return ["\(stem).wav", "\(stem).mic.pcm", "\(stem).system.pcm"].contains { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    private func fileSize(of url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else {
            return 0
        }
        return size
    }

    /// Parses the number out of `segment-007.wav`, `segment-007.mic.pcm`, …
    private static func segmentNumber(inFileName fileName: String) -> Int? {
        guard fileName.hasPrefix(segmentFileNamePrefix) else {
            return nil
        }
        let digits = fileName
            .dropFirst(segmentFileNamePrefix.count)
            .prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else {
            return nil
        }
        return Int(digits)
    }

    private static let manifestFileName = "session.json"
    private static let segmentFileNamePrefix = "segment-"
    /// Byte count of the canonical 44-byte RIFF/WAVE header we write; a file
    /// at or below it carries no samples.
    private static let wavHeaderByteCount = 44
}
