import Foundation

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

    @discardableResult
    func appendSegment(
        for meetingID: UUID,
        segmentURL: URL,
        duration: TimeInterval
    ) throws -> PersistedRecordingSession {
        guard var session = try loadSession(for: meetingID) else {
            throw RecordingResumeSessionStoreError.sessionNotFound(meetingID)
        }
        let segment = PersistedRecordingSegment(
            index: session.nextSegmentNumber,
            filePath: segmentURL.path,
            duration: duration,
            createdAt: Date()
        )
        session.segments.append(segment)
        session.nextSegmentNumber += 1
        session.updatedAt = Date()
        try persist(session)
        return session
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
        try sessionDirectory(for: meetingID).appendingPathComponent("session.json")
    }

    private func persist(_ session: PersistedRecordingSession) throws {
        let directory = try sessionDirectory(for: session.meetingID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}
