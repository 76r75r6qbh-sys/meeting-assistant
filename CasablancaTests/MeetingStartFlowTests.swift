import CoreAudio
import EventKit
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
        XCTAssertEqual(layout.contextMenuActions, [.prepare, .startRecording, .takeNotes, .viewDetails])
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

    func testNotesOnlyWorkspaceShowsMeetingHeader() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertTrue(presentation.showsNotesHeader)
    }

    func testRecordingWorkspaceHidesMeetingHeader() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: true,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertFalse(presentation.showsNotesHeader)
    }

    func testPausedRecordingWorkspaceHidesMeetingHeader() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: false
        )

        XCTAssertFalse(presentation.showsNotesHeader)
    }

    func testFocusModeHidesMeetingHeaderEvenOutsideRecording() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .notesOnly)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: nil,
            isRecording: false,
            isPreparing: false,
            isFinalizing: false,
            prefersRecordingFocusMode: true
        )

        XCTAssertTrue(presentation.isFocusModeActive)
        XCTAssertFalse(presentation.showsNotesHeader)
    }

    func testFinalizingHidesMeetingHeader() {
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let presentation = MeetingWorkspacePresentation(
            meeting: meeting,
            activeMeetingID: meeting.id,
            isRecording: false,
            isPreparing: false,
            isFinalizing: true,
            prefersRecordingFocusMode: false
        )

        XCTAssertFalse(presentation.showsNotesHeader)
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

    @MainActor
    func testDeleteMeetingAlsoRemovesResumableRecordingSession() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        context.insert(meeting)
        try context.save()

        var removedSessionMeetingID: UUID?
        let viewModel = MeetingListViewModel(
            calendarService: CalendarService(),
            removeResumableRecordingSession: { meetingID in
                removedSessionMeetingID = meetingID
            }
        )
        viewModel.setModelContext(context)

        try viewModel.deleteMeeting(meeting)

        XCTAssertEqual(removedSessionMeetingID, meeting.id)
    }
}

@MainActor
final class DashboardHeroPresentationTests: XCTestCase {
    private func makeEvent(start: Date, end: Date, title: String) -> EKEvent {
        let event = EKEvent(eventStore: EKEventStore())
        event.title = title
        event.startDate = start
        event.endDate = end
        return event
    }

    func testLiveMeetingShowsLiveNowEyebrow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let event = makeEvent(start: now.addingTimeInterval(-300),
                              end: now.addingTimeInterval(600),
                              title: "Daily standup")
        let presentation = DashboardHeroPresentation(event: event, referenceDate: now)

        XCTAssertTrue(presentation.isLive)
        XCTAssertEqual(presentation.eyebrow, "Live now")
        XCTAssertNil(presentation.minutesUntilStart)
    }

    func testUpcomingMeetingShowsCountdownEyebrow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let event = makeEvent(start: now.addingTimeInterval(25 * 60),
                              end: now.addingTimeInterval(40 * 60),
                              title: "PM-PM")
        let presentation = DashboardHeroPresentation(event: event, referenceDate: now)

        XCTAssertFalse(presentation.isLive)
        XCTAssertEqual(presentation.minutesUntilStart, 25)
        XCTAssertEqual(presentation.eyebrow, "Up next · in 25 min")
    }

    func testImminentMeetingShowsStartingSoonEyebrow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let event = makeEvent(start: now.addingTimeInterval(30),
                              end: now.addingTimeInterval(900),
                              title: "Refinement")
        let presentation = DashboardHeroPresentation(event: event, referenceDate: now)

        XCTAssertEqual(presentation.minutesUntilStart, 0)
        XCTAssertEqual(presentation.eyebrow, "Starting soon")
    }

    func testDetailLineFallsBackToTimeRangeWithoutParticipants() {
        let now = Date(timeIntervalSince1970: 10_000)
        let event = makeEvent(start: now, end: now.addingTimeInterval(900), title: "Sync")
        let presentation = DashboardHeroPresentation(event: event, referenceDate: now)

        XCTAssertEqual(presentation.detailLine, presentation.timeRange)
        XCTAssertEqual(presentation.participantCount, 0)
    }
}

final class SidebarMeetingRowActionTests: XCTestCase {
    func testRecentMeetingRowsExposeDeleteAction() {
        let actions = SidebarMeetingRowActions(section: .recent)

        XCTAssertEqual(actions.contextMenuActions, [.deleteMeeting])
    }

    func testUpcomingSectionRowsExposePrepareNotDelete() {
        let actions = SidebarMeetingRowActions(section: .upcoming)

        XCTAssertEqual(actions.contextMenuActions, [.prepare])
        XCTAssertFalse(actions.contextMenuActions.contains(.deleteMeeting))
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

@MainActor
final class AudioRecordingServicePauseResumeTests: XCTestCase {
    func testPauseRecordingPersistsSegmentAndLeavesMeetingResumable() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let segmentURL = rootURL.appendingPathComponent("segment-001.wav")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("segment".utf8).write(to: segmentURL)

        let fakeSession = FakeRecordingSession(
            outputURL: segmentURL,
            stopResult: RecordingResult(outputURL: segmentURL, duration: 8),
            capturedFrames: 1
        )
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in fakeSession },
            makeFinalOutputURL: { _ in rootURL.appendingPathComponent("final.wav") },
            mergeSegments: { _, outputURL in
                try Data("merged".utf8).write(to: outputURL)
                return 8
            }
        )

        try await service.startRecording(for: meeting)
        let pauseResult = try await service.pauseRecording()

        XCTAssertEqual(pauseResult.duration, 8)
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.activeMeetingID)

        let session = try XCTUnwrap(store.loadSession(for: meeting.id))
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.segments[0].filePath, segmentURL.path)
        XCTAssertEqual(session.nextSegmentNumber, 2)
    }

    func testHandleSystemInterruptWithZeroFramesDoesNotAppendSegment() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let segmentURL = rootURL.appendingPathComponent("segment-001.wav")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data().write(to: segmentURL)

        let fakeSession = FakeRecordingSession(
            outputURL: segmentURL,
            stopResult: RecordingResult(outputURL: segmentURL, duration: 0),
            capturedFrames: 0
        )
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in fakeSession }
        )

        try await service.startRecording(for: meeting)
        await service.handleSystemInterrupt(reason: .screenLock)

        XCTAssertFalse(service.isRecording)
        let session = try XCTUnwrap(store.loadSession(for: meeting.id))
        XCTAssertTrue(session.segments.isEmpty, "Empty segment must not be persisted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentURL.path), "Empty segment file must be deleted")
    }

    func testResumeRecordingOpensNewSegmentForExistingSession() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 12)

        var capturedURLs: [URL] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                capturedURLs.append(outputURL)
                return FakeRecordingSession(
                    outputURL: outputURL,
                    stopResult: RecordingResult(outputURL: outputURL, duration: 5),
                    capturedFrames: 1
                )
            }
        )

        try await service.resumeRecording(for: meeting)

        XCTAssertEqual(capturedURLs.count, 1)
        XCTAssertEqual(capturedURLs.first?.lastPathComponent, "segment-002.wav")
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(service.activeMeetingID, meeting.id)
    }

    func testStopRecordingFromPausedMeetingMergesSegmentsAndDeletesSession() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let segmentURL = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("segment".utf8).write(to: segmentURL)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: segmentURL, duration: 12)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in
                XCTFail("Paused stop should not create a live session")
                throw RecordingError.noActiveRecording
            },
            makeFinalOutputURL: { _ in outputURL },
            mergeSegments: { urls, destination in
                XCTAssertEqual(urls, [segmentURL])
                try Data("merged".utf8).write(to: destination)
                return 12
            }
        )

        let result = try await service.stopRecording(for: meeting)

        XCTAssertEqual(result.outputURL.path, outputURL.path)
        XCTAssertEqual(result.duration, 12)
        XCTAssertNil(try store.loadSession(for: meeting.id))
    }

    func testStopRecordingFromLiveMeetingFinalizesSegmentBeforeMerge() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let liveSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: liveSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("live".utf8).write(to: liveSegment)

        let fakeSession = FakeRecordingSession(
            outputURL: liveSegment,
            stopResult: RecordingResult(outputURL: liveSegment, duration: 7),
            capturedFrames: 1
        )

        let outputURL = rootURL.appendingPathComponent("final.wav")
        var mergedURLs: [URL] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in fakeSession },
            makeFinalOutputURL: { _ in outputURL },
            mergeSegments: { urls, destination in
                mergedURLs = urls
                try Data("merged".utf8).write(to: destination)
                return 7
            }
        )

        try await service.startRecording(for: meeting)
        let result = try await service.stopRecording(for: meeting)

        XCTAssertEqual(result.duration, 7)
        XCTAssertEqual(mergedURLs, [liveSegment])
        XCTAssertNil(try store.loadSession(for: meeting.id))
    }

    func testHasResumableSessionReturnsTrueForPersistedSession() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)

        let service = AudioRecordingService(sessionStore: store)

        XCTAssertTrue(service.hasResumableSession(for: meeting.id))
        XCTAssertFalse(service.hasResumableSession(for: UUID()))
    }

    func testStopRecordingClearsActiveStateEvenWhenFinalizeThrows() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let segmentURL = rootURL.appendingPathComponent("segment-001.wav")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("live".utf8).write(to: segmentURL)

        let fakeSession = ThrowingFakeRecordingSession(outputURL: segmentURL)
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in fakeSession }
        )

        try await service.startRecording(for: meeting)
        XCTAssertTrue(service.isRecording)

        do {
            _ = try await service.stopRecording(for: meeting)
            XCTFail("Expected stopRecording to throw")
        } catch {
            // Expected
        }

        XCTAssertFalse(service.isRecording, "Service must not be stuck recording after a failed stop")
        XCTAssertNil(service.activeMeetingID, "Active meeting must be cleared")
    }
}

@MainActor
final class StopRecordingErrorPathTests: XCTestCase {
    func testStopRecordingFailureDoesNotSilentlyClobberMeetingStatus() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let segmentURL = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("segment".utf8).write(to: segmentURL)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)
        _ = try store.appendSegment(for: meeting.id, segmentURL: segmentURL, duration: 5)

        let service = AudioRecordingService(
            sessionStore: store,
            mergeSegments: { _, _ in
                throw NSError(domain: "test.merge", code: 1)
            }
        )

        do {
            _ = try await service.stopRecording(for: meeting)
            XCTFail("Expected stopRecording to throw on merge failure")
        } catch {
            // Expected
        }

        // Service should still report the resumable session exists so the View can recover.
        XCTAssertTrue(service.hasResumableSession(for: meeting.id),
                      "Resumable session must NOT be deleted when merge fails — user needs to retry stop later")
    }
}

private final class FakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let capturedFrames: Int
    private let stopResult: RecordingResult

    init(outputURL: URL, stopResult: RecordingResult, capturedFrames: Int) {
        self.outputURL = outputURL
        self.stopResult = stopResult
        self.capturedFrames = capturedFrames
    }

    func start() async throws {}
    func stop() async throws -> RecordingResult { stopResult }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
    var hasCapturedFrames: Bool { capturedFrames > 0 }
}

private final class ThrowingFakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true

    init(outputURL: URL) { self.outputURL = outputURL }

    func start() async throws {}
    func stop() async throws -> RecordingResult {
        throw NSError(domain: "test.disk-write", code: 42)
    }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}

private func makeContainer() throws -> ModelContainer {
    let schema = Schema([Meeting.self, TodoItem.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

@MainActor
final class AutoPauseIndicatorPresentationTests: XCTestCase {
    func testIndicatorShowsLatestRecordWithEndedAt() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = Date(timeIntervalSince1970: 1_012)
        let record = RecordingInterruptionCoordinator.InterruptionRecord(
            reason: .screenLock,
            startedAt: started,
            endedAt: ended,
            resumedAutomatically: true
        )
        let presentation = AutoPauseIndicatorPresentation(records: [record], referenceDate: ended.addingTimeInterval(60))

        XCTAssertTrue(presentation.shouldShow)
        XCTAssertEqual(presentation.summary, "Auto-paused at \(presentation.formattedTime(started)) for 12s — recording resumed.")
    }

    func testIndicatorHidesAfterFiveMinutes() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = Date(timeIntervalSince1970: 1_012)
        let record = RecordingInterruptionCoordinator.InterruptionRecord(
            reason: .screenLock,
            startedAt: started,
            endedAt: ended,
            resumedAutomatically: true
        )
        let presentation = AutoPauseIndicatorPresentation(records: [record], referenceDate: ended.addingTimeInterval(301))

        XCTAssertFalse(presentation.shouldShow)
    }

    func testIndicatorMessageForLongPauseStillVisible() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = Date(timeIntervalSince1970: 1_120)
        let record = RecordingInterruptionCoordinator.InterruptionRecord(
            reason: .audioDeviceLost(deviceID: "USBMic"),
            startedAt: started,
            endedAt: ended,
            resumedAutomatically: false
        )
        let presentation = AutoPauseIndicatorPresentation(records: [record], referenceDate: ended.addingTimeInterval(30))

        XCTAssertTrue(presentation.shouldShow)
        XCTAssertTrue(presentation.summary.contains("microphone"))
        XCTAssertTrue(presentation.summary.contains("Resume"))
    }
}
