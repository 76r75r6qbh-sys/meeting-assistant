import SwiftData
import XCTest
@testable import Casablanca

/// Deleting a meeting removes its per-source speaker tracks along with the
/// recording, tolerating track files that are already gone.
@MainActor
final class MeetingListViewModelTrackDeletionTests: XCTestCase {
    func testDeleteMeetingRemovesTrackFiles() throws {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let recordingPath = "/tmp/casablanca-track-test/final.m4a"
        let micPath = "/tmp/casablanca-track-test/final.mic.m4a"
        let systemPath = "/tmp/casablanca-track-test/final.system.m4a"

        var removedPaths: [String] = []
        let vm = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { url in
                removedPaths.append(url.path)
                if url.path == systemPath {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
                }
            },
            removeResumableRecordingSession: { _ in }
        )
        vm.setModelContext(context)

        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        meeting.recordingFileURL = recordingPath
        meeting.micTrackFileURL = micPath
        meeting.systemTrackFileURL = systemPath
        context.insert(meeting)
        try context.save()

        XCTAssertNoThrow(try vm.deleteMeeting(meeting))

        XCTAssertEqual(removedPaths, [recordingPath, micPath, systemPath])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
    }

    /// A track file that cannot be removed (not merely missing) must not abort
    /// the meeting delete after the recording is already gone.
    func testTrackRemovalFailureDoesNotAbortTheDelete() throws {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let recordingPath = "/tmp/casablanca-track-test/final.m4a"
        let micPath = "/tmp/casablanca-track-test/final.mic.m4a"
        let systemPath = "/tmp/casablanca-track-test/final.system.m4a"

        var removedPaths: [String] = []
        let vm = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { url in
                removedPaths.append(url.path)
                if url.path == micPath {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                }
            },
            removeResumableRecordingSession: { _ in }
        )
        vm.setModelContext(context)

        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        meeting.recordingFileURL = recordingPath
        meeting.micTrackFileURL = micPath
        meeting.systemTrackFileURL = systemPath
        context.insert(meeting)
        try context.save()

        XCTAssertNoThrow(try vm.deleteMeeting(meeting))

        XCTAssertEqual(removedPaths, [recordingPath, micPath, systemPath])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
    }

    func testDeleteMeetingRemovesSpeakerSidecar() throws {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SpeakerAnalysisStore(directory: directory)
        let vm = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { _ in },
            removeResumableRecordingSession: { _ in },
            speakerAnalysisStore: store
        )
        vm.setModelContext(context)
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        context.insert(meeting)
        try context.save()
        try store.save(SpeakerAnalysisRecord(meetingID: meeting.id, diarization: .succeeded(clusterCount: 2), suggestions: []))
        let sidecar = store.fileURL(meeting.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        try vm.deleteMeeting(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }
}
