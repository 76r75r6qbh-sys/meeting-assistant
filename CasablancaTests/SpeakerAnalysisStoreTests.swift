import XCTest
@testable import Casablanca

final class SpeakerAnalysisStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        let store = SpeakerAnalysisStore(directory: directory)
        let record = SpeakerAnalysisRecord(
            meetingID: UUID(),
            diarization: .succeeded(clusterCount: 2),
            suggestions: [
                SpeakerNameSuggestion(speakerID: "S1", name: "Kim", evidence: "\"Thanks, Kim\" [03:12]", source: .transcript, score: nil),
                SpeakerNameSuggestion(speakerID: "S2", name: "Jeroen", evidence: "voice profile", source: .voiceProfile, score: 0.82),
            ]
        )

        try store.save(record)

        XCTAssertEqual(store.load(record.meetingID), record)
        let json = try String(contentsOf: store.fileURL(record.meetingID), encoding: .utf8)
        XCTAssertFalse(json.contains("embedding"), "The sidecar holds no biometric data")
    }

    func testFailedOutcomeRoundTrips() throws {
        let store = SpeakerAnalysisStore(directory: directory)
        let record = SpeakerAnalysisRecord(meetingID: UUID(), diarization: .failed(reason: "offline"), suggestions: [])

        try store.save(record)

        XCTAssertEqual(store.load(record.meetingID)?.diarization, .failed(reason: "offline"))
    }

    func testLoadMissingIsNil() {
        let store = SpeakerAnalysisStore(directory: directory)
        XCTAssertNil(store.load(UUID()))
    }

    func testDeleteRemovesFile() throws {
        let store = SpeakerAnalysisStore(directory: directory)
        let record = SpeakerAnalysisRecord(meetingID: UUID(), diarization: .notRun, suggestions: [])
        try store.save(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(record.meetingID).path))

        store.delete(record.meetingID)
        store.delete(record.meetingID) // a missing sidecar is fine

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(record.meetingID).path))
        XCTAssertNil(store.load(record.meetingID))
    }
}
