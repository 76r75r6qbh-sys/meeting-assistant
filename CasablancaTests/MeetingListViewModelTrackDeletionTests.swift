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
}
