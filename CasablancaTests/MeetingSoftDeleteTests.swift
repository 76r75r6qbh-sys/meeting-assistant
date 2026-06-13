import EventKit
import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class MeetingSoftDeleteTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testBeginSoftDeleteHidesMeetingFromVisibleLists() {
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        let other = Meeting(title: "Retro", date: .now, status: .completed)
        let vm = MeetingListViewModel(calendarService: CalendarService())

        XCTAssertEqual(vm.visibleMeetings(from: [meeting, other]).count, 2)

        vm.beginSoftDelete(meeting.id)

        XCTAssertTrue(vm.isPendingDeletion(meeting.id))
        let visible = vm.visibleMeetings(from: [meeting, other])
        XCTAssertEqual(visible.map(\.id), [other.id])
    }

    func testBeginSoftDeleteDeselectsSelectedMeeting() {
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        let vm = MeetingListViewModel(calendarService: CalendarService())
        vm.sidebarSelection = .meeting(meeting.id)

        vm.beginSoftDelete(meeting.id)

        XCTAssertEqual(vm.sidebarSelection, .dashboard)
    }

    func testUndoSoftDeleteUnhidesMeeting() {
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        let vm = MeetingListViewModel(calendarService: CalendarService())

        vm.beginSoftDelete(meeting.id)
        let undid = vm.undoSoftDelete(meeting.id)

        XCTAssertTrue(undid)
        XCTAssertFalse(vm.isPendingDeletion(meeting.id))
        XCTAssertEqual(vm.visibleMeetings(from: [meeting]).map(\.id), [meeting.id])
    }

    func testUndoNonPendingReturnsFalse() {
        let vm = MeetingListViewModel(calendarService: CalendarService())
        XCTAssertFalse(vm.undoSoftDelete(UUID()))
    }

    func testCommitSoftDeletePerformsRealDelete() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var removedURLs: [URL] = []
        let vm = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { removedURLs.append($0) }
        )
        vm.setModelContext(context)

        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        meeting.recordingFileURL = "/tmp/casablanca-test-recording.wav"
        context.insert(meeting)
        try context.save()

        vm.beginSoftDelete(meeting.id)
        let didDelete = try vm.commitSoftDelete(meeting)

        XCTAssertTrue(didDelete)
        XCTAssertFalse(vm.isPendingDeletion(meeting.id))
        XCTAssertEqual(removedURLs.map(\.path), ["/tmp/casablanca-test-recording.wav"])

        let remaining = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCommitAfterUndoIsNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var removedURLs: [URL] = []
        let vm = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { removedURLs.append($0) }
        )
        vm.setModelContext(context)

        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        meeting.recordingFileURL = "/tmp/casablanca-test-recording.wav"
        context.insert(meeting)
        try context.save()

        vm.beginSoftDelete(meeting.id)
        vm.undoSoftDelete(meeting.id)
        let didDelete = try vm.commitSoftDelete(meeting)

        XCTAssertFalse(didDelete)
        XCTAssertTrue(removedURLs.isEmpty)
        let remaining = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(remaining.count, 1)
    }
}
