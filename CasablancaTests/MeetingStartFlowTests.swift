import SwiftData
import XCTest
@testable import Casablanca

@MainActor
final class MeetingStartFlowTests: XCTestCase {
    func testRecordingStatusUsesWorkspacePresentation() {
        XCTAssertEqual(MeetingStatus.recording.detailPresentation, .workspace)
        XCTAssertEqual(MeetingStatus.notesOnly.detailPresentation, .workspace)
        XCTAssertEqual(MeetingStatus.processing.detailPresentation, .processing)
        XCTAssertEqual(MeetingStatus.completed.detailPresentation, .completed)
    }

    func testPausedRecordingStatusUsesWorkspacePresentation() {
        XCTAssertEqual(MeetingStatus.pausedRecording.detailPresentation, .workspace)
    }

    func testUpcomingMeetingsShowRecordingAndNotesButtons() {
        let layout = MeetingEntryActionLayout(isPast: false)

        XCTAssertEqual(layout.visibleActions, [.startRecording, .takeNotes])
        XCTAssertEqual(layout.contextMenuActions, [.startRecording, .takeNotes, .viewDetails])
    }

    func testPastMeetingsKeepDetailsPrimary() {
        let layout = MeetingEntryActionLayout(isPast: true)

        XCTAssertEqual(layout.visibleActions, [.viewDetails])
        XCTAssertEqual(layout.contextMenuActions, [.takeNotes, .viewDetails])
    }

    func testBeginManualMeetingCreatesNotesOnlyMeeting() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        viewModel.beginManualMeeting(title: "Weekly Sync")

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings[0].title, "Weekly Sync")
        XCTAssertEqual(meetings[0].status, .notesOnly)
        XCTAssertEqual(viewModel.selectedMeeting?.id, meetings[0].id)
    }

    func testBeginRecordingPreservesExistingUserNotes() {
        let meeting = Meeting(title: "Design Review", date: .now, status: .notesOnly)
        meeting.userNotes = "Already typed before recording"

        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.beginRecording(for: meeting)

        XCTAssertEqual(meeting.status, .recording)
        XCTAssertEqual(meeting.userNotes, "Already typed before recording")
    }

    func testFutureMeetingWithPrepMovesToUpcomingSidebarSection() {
        let futureMeeting = Meeting(
            title: "Prepared Refinement",
            date: Date().addingTimeInterval(3600),
            status: .notesOnly
        )
        let meetings = [futureMeeting]
        let viewModel = MeetingListViewModel(
            calendarService: CalendarService(),
            meetingHasPrep: { meeting in
                meeting.id == futureMeeting.id
            }
        )

        XCTAssertEqual(viewModel.filteredUpcomingMeetings(from: meetings), [futureMeeting])
        XCTAssertTrue(viewModel.filteredRecentMeetings(from: meetings).isEmpty)
    }

    func testFutureMeetingWithoutPrepStaysInRecentSidebarSection() {
        let futureMeeting = Meeting(
            title: "Unprepared Refinement",
            date: Date().addingTimeInterval(3600),
            status: .notesOnly
        )
        let meetings = [futureMeeting]
        let viewModel = MeetingListViewModel(
            calendarService: CalendarService(),
            meetingHasPrep: { _ in false }
        )

        XCTAssertTrue(viewModel.filteredUpcomingMeetings(from: meetings).isEmpty)
        XCTAssertEqual(viewModel.filteredRecentMeetings(from: meetings), [futureMeeting])
    }

}

@MainActor
final class MeetingWorkspacePresentationTests: XCTestCase {
    func testMeetingNotesModeDefaultsToFreeform() {
        XCTAssertEqual(MeetingNotesMode.defaultForWorkspaceEntry, .freeform)
    }

    func testNotesOnlyWorkspaceShowsStartRecordingButton() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertFalse(presentation.showsRecordingChrome)
        XCTAssertTrue(presentation.showsStartRecordingButton)
        XCTAssertFalse(presentation.showsTimestampedTools)
        XCTAssertFalse(presentation.backButtonDisabled)
    }

    func testUpcomingWorkspaceShowsStartRecordingButton() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .upcoming)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertFalse(presentation.showsRecordingChrome)
        XCTAssertTrue(presentation.showsStartRecordingButton)
        XCTAssertFalse(presentation.showsPauseRecordingButton)
        XCTAssertFalse(presentation.showsResumeRecordingButton)
        XCTAssertFalse(presentation.showsStopRecordingButton)
    }

    func testActiveRecordingWorkspaceShowsRecordingChrome() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: true,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertTrue(presentation.showsRecordingChrome)
        XCTAssertTrue(presentation.showsExpandedRecordingChrome)
        XCTAssertFalse(presentation.showsCompactRecordingControls)
        XCTAssertFalse(presentation.showsStartRecordingButton)
        XCTAssertTrue(presentation.showsTimestampedTools)
        XCTAssertTrue(presentation.backButtonDisabled)
    }

    func testFocusedRecordingWorkspaceHidesExpandedRecordingChrome() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: true,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: true
        )

        XCTAssertTrue(presentation.showsRecordingChrome)
        XCTAssertFalse(presentation.showsExpandedRecordingChrome)
        XCTAssertTrue(presentation.showsCompactRecordingControls)
    }

    func testPreparingWorkspaceKeepsUserInSameScreen() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: false,
            isPreparing: true,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertTrue(presentation.showsRecordingChrome)
        XCTAssertTrue(presentation.showsExpandedRecordingChrome)
        XCTAssertFalse(presentation.showsTimestampedTools)
        XCTAssertFalse(presentation.showsStartRecordingButton)
    }

    func testPausedWorkspaceShowsResumeAndStopActions() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertTrue(presentation.showsRecordingChrome)
        XCTAssertFalse(presentation.showsTimestampedTools)
        XCTAssertFalse(presentation.showsStartRecordingButton)
        XCTAssertFalse(presentation.showsPauseRecordingButton)
        XCTAssertTrue(presentation.showsResumeRecordingButton)
        XCTAssertTrue(presentation.showsStopRecordingButton)
        XCTAssertFalse(presentation.backButtonDisabled)
        XCTAssertEqual(presentation.stateLabel, "Paused")
    }

    func testRecordingWorkspaceStillPrefersPauseDuringLiveCapture() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: true,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertTrue(presentation.showsPauseRecordingButton)
        XCTAssertFalse(presentation.showsResumeRecordingButton)
        XCTAssertTrue(presentation.showsStopRecordingButton)
        XCTAssertEqual(presentation.stateLabel, "Recording")
    }

    func testNotesOnlyWorkspaceIgnoresFocusedRecordingPreference() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: true
        )

        XCTAssertFalse(presentation.showsRecordingChrome)
        XCTAssertFalse(presentation.showsExpandedRecordingChrome)
        XCTAssertFalse(presentation.showsCompactRecordingControls)
        XCTAssertTrue(presentation.showsStartRecordingButton)
    }

    func testFinalizingWorkspaceShowsBlockingOverlay() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: false,
            isPreparing: false,
            isFinalizing: true,
            prefersRecordingFocusMode: false
        )

        XCTAssertTrue(presentation.showsBlockingOverlay)
        XCTAssertEqual(presentation.blockingOverlayTitle, "Recording finaliseren...")
        XCTAssertTrue(presentation.backButtonDisabled)
    }

    func testFinalizingWorkspaceStillShowsBlockingOverlayWhenFocusModeEnabled() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: false,
            isPreparing: false,
            isFinalizing: true,
            prefersRecordingFocusMode: true
        )

        XCTAssertTrue(presentation.showsBlockingOverlay)
        XCTAssertFalse(presentation.showsExpandedRecordingChrome)
        XCTAssertTrue(presentation.showsCompactRecordingControls)
        XCTAssertTrue(presentation.backButtonDisabled)
    }

    func testFreeformWorkspaceKeepsTodosVisibleOutsideRecording() {
        let presentation = FreeformWorkspacePresentation(
            showsRecordingChrome: false
        )

        XCTAssertTrue(presentation.showsTodosArea)
    }

    func testFreeformWorkspaceKeepsTodosVisibleDuringRecording() {
        let presentation = FreeformWorkspacePresentation(
            showsRecordingChrome: true
        )

        XCTAssertTrue(presentation.showsTodosArea)
    }
}

@MainActor
final class MeetingPrepPresentationTests: XCTestCase {
    func testPrepPaneShowsWhenMarkdownExistsAndExpanded() {
        let presentation = MeetingPrepPresentation(
            markdown: "# Prep",
            isExpanded: true
        )

        XCTAssertTrue(presentation.hasPrep)
        XCTAssertTrue(presentation.showsPrepPane)
        XCTAssertFalse(presentation.showsShowPrepButton)
    }

    func testPrepPaneCollapseShowsRevealButton() {
        let presentation = MeetingPrepPresentation(
            markdown: "# Prep",
            isExpanded: false
        )

        XCTAssertTrue(presentation.hasPrep)
        XCTAssertFalse(presentation.showsPrepPane)
        XCTAssertTrue(presentation.showsShowPrepButton)
    }

    func testEmptyMarkdownBehavesLikeNoPrep() {
        let presentation = MeetingPrepPresentation(
            markdown: "   \n",
            isExpanded: true
        )

        XCTAssertFalse(presentation.hasPrep)
        XCTAssertFalse(presentation.showsPrepPane)
        XCTAssertFalse(presentation.showsShowPrepButton)
    }
}

@MainActor
final class MeetingDeletionTests: XCTestCase {
    func testDeleteMeetingRemovesItFromPersistenceAndClearsSelection() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Delete Me", date: .now, status: .completed)
        context.insert(meeting)
        try context.save()

        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)
        viewModel.selectedMeeting = meeting

        try viewModel.deleteMeeting(meeting)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(meetings.isEmpty)
        XCTAssertEqual(viewModel.sidebarSelection, .dashboard)
        XCTAssertNil(viewModel.selectedMeeting)
    }

    func testDeleteMeetingWithoutRecordingFileSucceeds() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Notes Only", date: .now, status: .notesOnly)
        context.insert(meeting)
        try context.save()

        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        try viewModel.deleteMeeting(meeting)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(meetings.isEmpty)
    }

    func testDeleteMeetingIgnoresMissingRecordingFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Missing File", date: .now, status: .completed)
        meeting.recordingFileURL = "/tmp/does-not-exist-\(UUID().uuidString).m4a"
        context.insert(meeting)
        try context.save()

        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        try viewModel.deleteMeeting(meeting)

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertTrue(meetings.isEmpty)
    }

    func testDeleteMeetingRemovesRecordingFileFromDisk() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Recorded", date: .now, status: .completed)
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data("audio".utf8).write(to: recordingURL)
        meeting.recordingFileURL = recordingURL.path
        context.insert(meeting)
        try context.save()

        let viewModel = MeetingListViewModel(calendarService: CalendarService())
        viewModel.setModelContext(context)

        try viewModel.deleteMeeting(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
    }

    func testDeleteMeetingPropagatesFileDeletionErrorAndKeepsMeeting() throws {
        struct TestError: Error {}

        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Protected", date: .now, status: .completed)
        meeting.recordingFileURL = "/tmp/\(UUID().uuidString).m4a"
        context.insert(meeting)
        try context.save()

        let viewModel = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { _ in throw TestError() }
        )
        viewModel.setModelContext(context)

        XCTAssertThrowsError(try viewModel.deleteMeeting(meeting))

        let meetings = try context.fetch(FetchDescriptor<Meeting>())
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.id, meeting.id)
    }
}

final class SidebarMeetingRowActionTests: XCTestCase {
    func testRecentMeetingRowsExposeDeleteAction() {
        let actions = SidebarMeetingRowActions(section: .recent)

        XCTAssertEqual(actions.contextMenuActions, [.deleteMeeting])
    }

    func testUpcomingSectionRowsDoNotExposeDeleteAction() {
        let actions = SidebarMeetingRowActions(section: .upcoming)

        XCTAssertTrue(actions.contextMenuActions.isEmpty)
    }
}

final class AudioRecordingPipelineTests: XCTestCase {
    func testCaptureFirstPipelineDefersRealtimeConversionForBothTracks() {
        let pipeline = DeferredRecordingPipeline.captureFirst

        XCTAssertTrue(pipeline.microphone.writesRawCaptureBuffers)
        XCTAssertFalse(pipeline.microphone.requiresRealtimeConversion)
        XCTAssertTrue(pipeline.systemAudio.writesRawCaptureBuffers)
        XCTAssertFalse(pipeline.systemAudio.requiresRealtimeConversion)
    }

    func testCaptureFirstPipelineDoesNotRequireScreenFrames() {
        XCTAssertFalse(DeferredRecordingPipeline.captureFirst.requiresScreenStreamOutput)
    }

    func testDeferredPipelineUsesLongestTrackForOutputFrameCount() {
        let pipeline = DeferredRecordingPipeline.captureFirst

        XCTAssertEqual(
            pipeline.expectedOutputFrameCount(microphoneFrames: 1_600, systemAudioFrames: 3_200),
            3_200
        )
        XCTAssertEqual(
            pipeline.expectedOutputFrameCount(microphoneFrames: 4_800, systemAudioFrames: 0),
            4_800
        )
    }
}

@MainActor
final class TodoRowPresentationTests: XCTestCase {
    func testGenericTodoRowDoesNotNavigateToMeeting() {
        let todo = TodoItem(text: "Inbox zero")

        let presentation = TodoRowPresentation(todo: todo)

        XCTAssertFalse(presentation.canNavigateToMeeting)
        XCTAssertNil(presentation.meetingSubtitle)
    }

    func testMeetingLinkedTodoRowShowsMeetingSubtitleAndNavigates() {
        let meeting = Meeting(title: "Weekly Sync", date: .now)
        let todo = TodoItem(text: "Send notes", meeting: meeting)

        let presentation = TodoRowPresentation(todo: todo)

        XCTAssertTrue(presentation.canNavigateToMeeting)
        XCTAssertNotNil(presentation.meetingSubtitle)
    }
}

private func makeContainer() throws -> ModelContainer {
    let schema = Schema([Meeting.self, TodoItem.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
