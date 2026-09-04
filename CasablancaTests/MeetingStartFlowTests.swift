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

    func testUpcomingMeetingsShowPrepareNotesAndRecordingButtons() {
        let layout = MeetingEntryActionLayout(isPast: false)

        XCTAssertEqual(layout.visibleActions, [.prepare, .takeNotes, .startRecording])
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
        XCTAssertEqual(presentation.blockingOverlayTitle, "Finalizing recording…")
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

    func testStartRecordingSurfacesMicrophoneOnlyFallbackWithoutFailing() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let segmentURL = rootURL.appendingPathComponent("segment-001.wav")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("segment".utf8).write(to: segmentURL)

        // A session that started but couldn't capture system audio (lid closed,
        // no display) and fell back to microphone-only.
        let fakeSession = FakeRecordingSession(
            outputURL: segmentURL,
            stopResult: RecordingResult(outputURL: segmentURL, duration: 0),
            capturedFrames: 1,
            systemAudioUnavailableError: NSError(domain: "test.nodisplay", code: 1)
        )
        let meeting = Meeting(title: "Lid Closed", date: .now, status: .recording)

        var notices: [String] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in fakeSession }
        )
        service.onSystemAudioUnavailable = { notices.append($0) }

        try await service.startRecording(for: meeting)

        XCTAssertTrue(service.isRecording, "Recording must continue despite the system-audio fallback")
        XCTAssertNil(service.errorMessage, "Fallback must NOT set errorMessage — that drives a modal that derails recording")
        XCTAssertEqual(notices.count, 1, "A non-fatal microphone-only notice should be surfaced exactly once")
    }

    /// Starting a recording for a meeting that already has segments must never
    /// hand out segment 1 again — that overwrote a 75-minute recording. It
    /// continues the existing session instead.
    func testStartRecordingWithExistingSegmentsOpensNextSegmentInsteadOfSegmentOne() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        let firstSegmentBytes = Data("first-segment-audio".utf8)
        try firstSegmentBytes.write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 30)

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

        try await service.startRecording(for: meeting)

        XCTAssertEqual(capturedURLs.map(\.lastPathComponent), ["segment-002.wav"])
        XCTAssertEqual(
            try Data(contentsOf: firstSegment), firstSegmentBytes,
            "The existing segment must be byte-for-byte untouched"
        )
        XCTAssertGreaterThanOrEqual(
            service.elapsedTime, 30,
            "Starting into an existing session must continue the timer from the recorded total"
        )
        XCTAssertLessThan(service.elapsedTime, 32)

        _ = try await service.pauseRecording()

        let session = try XCTUnwrap(store.loadSession(for: meeting.id))
        XCTAssertEqual(session.segments.map(\.index), [1, 2])
        XCTAssertEqual(Set(session.segments.map(\.filePath)).count, 2, "Segments must have distinct paths")
    }

    /// A raw `.mic.pcm` left behind by a crash owns its segment number even
    /// though the manifest never got the finalized WAV: recording into it would
    /// clobber recoverable audio.
    func testStartRecordingWithOrphanedPCMDoesNotReuseThatSegmentNumber() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let orphanedPCM = try store.sessionDirectory(for: meeting.id).appendingPathComponent("segment-001.mic.pcm")
        try Data(repeating: 7, count: 4_000).write(to: orphanedPCM)

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

        try await service.startRecording(for: meeting)

        XCTAssertEqual(capturedURLs.map(\.lastPathComponent), ["segment-002.wav"])
        XCTAssertEqual(try Data(contentsOf: orphanedPCM).count, 4_000, "The orphaned PCM must survive untouched")
    }

    /// The manifest listing no segments is not proof that nothing was
    /// captured — raw PCM in the directory is audio, and deleting the session
    /// directory over it is how a whole recording was lost.
    func testStopRecordingWithZeroSegmentsButOrphanedPCMKeepsSessionDirectory() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)

        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)
        let sessionDirectory = try store.sessionDirectory(for: meeting.id)
        let orphanedPCM = sessionDirectory.appendingPathComponent("segment-001.mic.pcm")
        try Data(repeating: 3, count: 4_000).write(to: orphanedPCM)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _, _ in
                XCTFail("Stopping a paused meeting must not create a live session")
                throw RecordingError.noActiveRecording
            },
            mergeSegments: { _, _ in
                XCTFail("There is nothing to merge when the manifest lists no segments")
                return 0
            }
        )

        do {
            _ = try await service.stopRecording(for: meeting)
            XCTFail("Expected stopRecording to throw .noCapturedAudio")
        } catch RecordingError.noCapturedAudio {
            // Expected
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sessionDirectory.path),
            "Session directory must survive: it still holds raw audio"
        )
        XCTAssertEqual(try Data(contentsOf: orphanedPCM).count, 4_000, "Raw PCM must survive untouched")
    }

    /// A finalize that fails on I/O must leave every byte on disk and still
    /// release the service, so the user can resume (and later recover) instead
    /// of being wedged behind `.activeRecordingExists`.
    func testHandleSystemInterruptWhenFinalizeThrowsLeavesFilesAndClearsSession() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let capturedBytes = Data("captured-audio".utf8)
        var capturedURLs: [URL] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                capturedURLs.append(outputURL)
                try capturedBytes.write(to: outputURL)
                return ThrowingFakeRecordingSession(outputURL: outputURL)
            }
        )

        try await service.startRecording(for: meeting)
        _ = await service.handleSystemInterrupt(reason: .systemSleep)

        XCTAssertFalse(service.isRecording, "The service must not stay wedged in recording after a failed finalize")
        XCTAssertNil(service.activeMeetingID)
        XCTAssertNotNil(service.errorMessage, "A real finalize failure must be surfaced")
        let interruptedSegment = try XCTUnwrap(capturedURLs.first)
        XCTAssertEqual(try Data(contentsOf: interruptedSegment), capturedBytes, "The segment must be left on disk untouched")

        try await service.resumeRecording(for: meeting)

        XCTAssertTrue(service.isRecording, "Resuming after a failed finalize must not be blocked")
        XCTAssertEqual(
            capturedURLs.map(\.lastPathComponent), ["segment-001.wav", "segment-002.wav"],
            "The resumed segment must not overwrite the interrupted one"
        )
        XCTAssertEqual(try Data(contentsOf: interruptedSegment), capturedBytes)
    }

    /// The service must never delete a segment itself. Deletion is the
    /// session's call, and only when the capture is *provably* empty — 0 frames
    /// counted AND 0 bytes on disk — which the fake models by removing its own
    /// file and throwing `.noCapturedAudio`, exactly like `RecordingSession`.
    func testHandleSystemInterruptWithZeroFramesDoesNotAppendSegment() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        var capturedURLs: [URL] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                capturedURLs.append(outputURL)
                try Data().write(to: outputURL)
                return FakeRecordingSession(
                    outputURL: outputURL,
                    stopResult: RecordingResult(outputURL: outputURL, duration: 0),
                    capturedFrames: 0,
                    deletesProvablyEmptyOutputOnStop: true
                )
            }
        )

        try await service.startRecording(for: meeting)
        _ = await service.handleSystemInterrupt(reason: .screenLock)

        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.errorMessage, "A provably empty segment is not a user-facing failure")
        let session = try XCTUnwrap(store.loadSession(for: meeting.id))
        XCTAssertTrue(session.segments.isEmpty, "Empty segment must not be persisted")
        let segmentURL = try XCTUnwrap(capturedURLs.first)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: segmentURL.path),
            "Only the session deletes, and only with 0 frames AND 0 bytes"
        )
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

    func testResumeContinuesElapsedTimeFromPriorSegments() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 42)

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                FakeRecordingSession(
                    outputURL: outputURL,
                    stopResult: RecordingResult(outputURL: outputURL, duration: 5),
                    capturedFrames: 1
                )
            }
        )

        try await service.resumeRecording(for: meeting)

        XCTAssertGreaterThanOrEqual(
            service.elapsedTime, 42,
            "Timer must continue from the accumulated prior-segment duration, not restart at 0"
        )
        XCTAssertLessThan(
            service.elapsedTime, 44,
            "Timer should be ~42 plus a sliver — not doubled or reset"
        )
    }

    // MARK: - Retrying the audio engine start after wake

    /// After the Mac wakes, CoreAudio is often not ready yet and the first
    /// `AVAudioEngine.start()` throws — the auto-resume then failed once and left
    /// the meeting paused. Resuming retries with backoff instead.
    func testResumeRetriesSessionStartWithBackoff() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Woke Up", date: .now, status: .pausedRecording)
        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 12)

        let flaky = FlakyEngineStart(failuresBeforeSuccess: 2)
        let sleeps = SleepSpy()
        var builtURLs: [URL] = []

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                builtURLs.append(outputURL)
                return flaky.session(outputURL: outputURL)
            },
            startRetryDelays: [.zero, .zero, .zero],
            sleep: { [sleeps] in sleeps.record($0) }
        )

        try await service.resumeRecording(for: meeting)

        XCTAssertEqual(flaky.startAttempts, 3, "The resume must retry the engine start, not fail on the first throw")
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(service.activeMeetingID, meeting.id)
        XCTAssertNil(service.errorMessage, "A resume that eventually started must not leave an error on screen")
        XCTAssertEqual(sleeps.delays, [.zero, .zero], "One backoff wait between attempts, taken from the configured delays")
        // Each attempt rebuilds through the factory: `RecordingSession.startedAt`
        // is fixed at init (a reused session would bill the backoff as recorded
        // audio) and its `configure()` is not idempotent.
        XCTAssertEqual(builtURLs.count, 3, "Every attempt builds a fresh session")
        XCTAssertEqual(
            Set(builtURLs.map(\.lastPathComponent)), ["segment-002.wav"],
            "The retries reuse the reserved segment number — they must not burn a number per attempt"
        )
    }

    /// The retry is bounded: after the configured attempts the resume fails, and
    /// it fails cleanly — the last error surfaces, no session is left half-built
    /// for a concurrent Stop to find, and the idle-sleep assertion is not held.
    func testResumeGivesUpAfterRetriesAndSurfacesLastError() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Dead CoreAudio", date: .now, status: .pausedRecording)
        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 12)

        let flaky = FlakyEngineStart(failuresBeforeSuccess: .max)
        let sleeps = SleepSpy()
        let sleepPreventer = SleepPreventerSpy()

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in flaky.session(outputURL: outputURL) },
            sleepPreventer: sleepPreventer,
            startRetryDelays: [.milliseconds(1), .milliseconds(2), .milliseconds(3)],
            sleep: { [sleeps] in sleeps.record($0) }
        )

        do {
            try await service.resumeRecording(for: meeting)
            XCTFail("A resume whose every attempt fails must throw")
        } catch {
            XCTAssertEqual(
                (error as NSError).code, 4,
                "The error from the LAST attempt must surface, not the first one"
            )
        }

        XCTAssertEqual(flaky.startAttempts, 4, "One attempt plus one per configured delay")
        XCTAssertEqual(
            sleeps.delays, [.milliseconds(1), .milliseconds(2), .milliseconds(3)],
            "The backoff must walk the configured delays in order"
        )
        XCTAssertNotNil(service.errorMessage, "The user has to see why the resume failed")
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.isPreparing)
        XCTAssertNil(service.activeMeetingID, "No half-built session may be left behind for a concurrent Stop")
        XCTAssertEqual(sleepPreventer.activeCount, 0, "A failed resume must not leave the Mac awake")
        XCTAssertEqual(sleepPreventer.beginCount, 0, "The assertion belongs to a session that actually started")
    }

    /// A Stop cancels the coordinator's resume task
    /// (`clearInterruptionBookkeeping`), and it can land while the retry is
    /// sitting in a backoff wait. The default `sleep` swallows cancellation, so
    /// without an explicit check the remaining attempts ran back-to-back and one
    /// of them published a live session — timer, idle-sleep assertion and all —
    /// for a meeting the user had already stopped and whose manifest was gone.
    func testCancelledResumeStopsRetryingAndPublishesNothing() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Stopped Mid-Retry", date: .now, status: .pausedRecording)
        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: "BuiltInMic")
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 12)

        // Attempt 1 throws; attempt 2 would succeed — so if the cancellation is
        // ignored, the resume publishes instead of failing.
        let flaky = FlakyEngineStart(failuresBeforeSuccess: 1)
        let sleeps = SleepSpy()
        let sleepPreventer = SleepPreventerSpy()
        let resume = ResumeTaskBox()

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in flaky.session(outputURL: outputURL) },
            sleepPreventer: sleepPreventer,
            startRetryDelays: [.zero, .zero, .zero],
            sleep: { [sleeps, resume] delay in
                sleeps.record(delay)
                // The Stop arrives while the retry is waiting.
                resume.cancel()
            }
        )

        resume.run { try await service.resumeRecording(for: meeting) }

        do {
            try await resume.value
            XCTFail("A cancelled resume must throw, not publish a session")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertEqual(flaky.startAttempts, 1, "Cancellation must end the retry, not just skip the wait")
        XCTAssertEqual(sleeps.delays.count, 1)
        XCTAssertFalse(service.isRecording, "Nothing may be published for a meeting the user stopped")
        XCTAssertFalse(service.isPreparing)
        XCTAssertNil(service.activeMeetingID)
        XCTAssertEqual(sleepPreventer.beginCount, 0, "A cancelled resume must not hold the Mac awake")
        XCTAssertNil(
            service.errorMessage,
            "Stop is not a failure — an error modal after the user's own Stop would be nonsense"
        )
    }

    /// The retry is for the wake path only. A manual start must fail fast so the
    /// user sees the error instead of staring at a spinner for seven seconds.
    func testStartRecordingDoesNotRetry() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "No Microphone", date: .now, status: .recording)

        let flaky = FlakyEngineStart(failuresBeforeSuccess: .max)
        let sleeps = SleepSpy()

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in flaky.session(outputURL: outputURL) },
            startRetryDelays: [.zero, .zero, .zero],
            sleep: { [sleeps] in sleeps.record($0) }
        )

        do {
            try await service.startRecording(for: meeting)
            XCTFail("A session whose start() throws must fail the start")
        } catch {
            XCTAssertEqual((error as NSError).code, 1)
        }

        XCTAssertEqual(flaky.startAttempts, 1, "A manual start must fail fast — no retry, no backoff")
        XCTAssertTrue(sleeps.delays.isEmpty)
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.activeMeetingID)
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

    /// The race that lost audio: an interrupt suspended inside `session.stop()`
    /// while the user presses Stop. Stop used to get `.sessionAlreadyStopped`
    /// back and run straight on to merge (without the in-flight segment) and
    /// then delete the directory holding it. Finalization is serialized now, so
    /// Stop waits for that finalize, merges both segments, and only then deletes.
    func testStopWhileInterruptFinalizeIsInFlightMergesEverySegmentBeforeDeleting() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        // The part of the meeting recorded before the interruption.
        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 10)

        let sessionDirectory = try store.sessionDirectory(for: meeting.id)
        let finalURL = rootURL.appendingPathComponent("final.wav")
        let gate = FinalizeGate()
        var capturedURLs: [URL] = []
        var mergedURLs: [URL] = []

        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                capturedURLs.append(outputURL)
                try Data("second".utf8).write(to: outputURL)
                return GatedFakeRecordingSession(outputURL: outputURL, duration: 20, gate: gate)
            },
            makeFinalOutputURL: { _ in finalURL },
            mergeSegments: { urls, destination in
                mergedURLs = urls
                for url in urls {
                    XCTAssertTrue(
                        FileManager.default.fileExists(atPath: url.path),
                        "Every merged segment must still be on disk when the merge runs"
                    )
                }
                try Data("merged".utf8).write(to: destination)
                return 30
            }
        )

        try await service.startRecording(for: meeting)
        let liveSegment = try XCTUnwrap(capturedURLs.first)

        let interrupt = Task { await service.handleSystemInterrupt(reason: .systemSleep) }
        // Wait until the interrupt is suspended *inside* `session.stop()`.
        while await gate.stopCalls == 0 {
            await Task.yield()
        }

        let stop = Task { try await service.stopRecording(for: meeting) }
        // Give Stop the main actor so it reaches the finalize it has to join.
        for _ in 0..<20 {
            await Task.yield()
        }

        await gate.open()
        let result = try await stop.value
        _ = await interrupt.value

        let stopCalls = await gate.stopCalls
        XCTAssertEqual(stopCalls, 1, "The segment must be finalized exactly once")
        XCTAssertEqual(
            mergedURLs, [firstSegment, liveSegment],
            "The merge must include the segment the interrupt was still finalizing"
        )
        XCTAssertEqual(result.outputURL.path, finalURL.path)
        XCTAssertEqual(result.duration, 30)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.path),
            "The session directory is deleted only after the merge that included every segment"
        )
    }

    /// `.sessionAlreadyStopped` from a finalize this service does not own must
    /// abort the stop: merging would omit that segment and the delete would
    /// then destroy it.
    func testStopRecordingRefusesToMergeWhenTheSegmentIsFinalizedElsewhere() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let firstSegment = try store.nextSegmentURL(for: meeting.id, segmentNumber: 1)
        try FileManager.default.createDirectory(at: firstSegment.deletingLastPathComponent(), withIntermediateDirectories: true)
        let firstSegmentBytes = Data("first".utf8)
        try firstSegmentBytes.write(to: firstSegment)
        _ = try store.createSession(for: meeting.id, systemAudioEnabled: true, selectedInputDeviceID: nil)
        _ = try store.appendSegment(for: meeting.id, segmentURL: firstSegment, duration: 10)

        let sessionDirectory = try store.sessionDirectory(for: meeting.id)
        let finalURL = rootURL.appendingPathComponent("final.wav")
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                try Data("second".utf8).write(to: outputURL)
                return ThrowingFakeRecordingSession(outputURL: outputURL, stopError: RecordingError.sessionAlreadyStopped)
            },
            makeFinalOutputURL: { _ in finalURL },
            mergeSegments: { _, _ in
                XCTFail("Nothing may be merged while another finalize may still append a segment")
                return 0
            }
        )

        try await service.startRecording(for: meeting)

        do {
            _ = try await service.stopRecording(for: meeting)
            XCTFail("Expected stopRecording to refuse a segment finalized elsewhere")
        } catch RecordingError.sessionAlreadyStopped {
            // Expected
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path), "The session must survive")
        XCTAssertEqual(try Data(contentsOf: firstSegment), firstSegmentBytes)
        XCTAssertNotNil(try store.loadSession(for: meeting.id), "The manifest must survive so the stop can be retried")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path), "Nothing may be merged")
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.activeMeetingID)
    }

    /// The same report during an interrupt is benign: leave every file where it
    /// is, append nothing, and release the service.
    func testHandleSystemInterruptWhenSegmentIsFinalizedElsewhereLeavesFilesAndClearsSession() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        let capturedBytes = Data("captured-audio".utf8)
        var capturedURLs: [URL] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                capturedURLs.append(outputURL)
                try capturedBytes.write(to: outputURL)
                return ThrowingFakeRecordingSession(outputURL: outputURL, stopError: RecordingError.sessionAlreadyStopped)
            }
        )

        try await service.startRecording(for: meeting)
        _ = await service.handleSystemInterrupt(reason: .screenLock)

        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.activeMeetingID)
        XCTAssertNil(service.errorMessage, "Another finalize owning the segment is not a user-facing failure")
        let segmentURL = try XCTUnwrap(capturedURLs.first)
        XCTAssertEqual(try Data(contentsOf: segmentURL), capturedBytes, "The segment must be left exactly as it was")
        let session = try XCTUnwrap(store.loadSession(for: meeting.id))
        XCTAssertTrue(session.segments.isEmpty, "The owning finalize appends it, not this one")
    }

    /// A live session that captured nothing at all: the failure reaches the
    /// caller and the leftover (empty) directory is cleaned through
    /// `deleteSessionIfEmpty`, never an unconditional delete.
    func testStopRecordingWithLiveSessionThatCapturedNothingSurfacesNoCapturedAudio() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)

        var capturedURLs: [URL] = []
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { outputURL, _, _, _, _, _, _ in
                capturedURLs.append(outputURL)
                try Data().write(to: outputURL)
                return FakeRecordingSession(
                    outputURL: outputURL,
                    stopResult: RecordingResult(outputURL: outputURL, duration: 0),
                    capturedFrames: 0,
                    deletesProvablyEmptyOutputOnStop: true
                )
            },
            mergeSegments: { _, _ in
                XCTFail("There is nothing to merge")
                return 0
            }
        )

        try await service.startRecording(for: meeting)
        let sessionDirectory = try store.sessionDirectory(for: meeting.id)

        do {
            _ = try await service.stopRecording(for: meeting)
            XCTFail("Expected stopRecording to throw .noCapturedAudio")
        } catch RecordingError.noCapturedAudio {
            // Expected
        }

        XCTAssertFalse(service.isRecording)
        let segmentURL = try XCTUnwrap(capturedURLs.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentURL.path), "The session removed its provably empty file")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.path),
            "A directory with no recoverable audio is cleaned up by deleteSessionIfEmpty"
        )
        XCTAssertNil(try store.loadSession(for: meeting.id))
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
    var systemAudioUnavailableError: Error?
    private let stopResult: RecordingResult
    /// Mirrors `RecordingSession.stop()`: when the capture is provably empty
    /// (0 frames AND 0 bytes on disk) the session — never the facade — removes
    /// its own files and reports `.noCapturedAudio`.
    private let deletesProvablyEmptyOutputOnStop: Bool

    init(
        outputURL: URL,
        stopResult: RecordingResult,
        capturedFrames: Int,
        systemAudioUnavailableError: Error? = nil,
        deletesProvablyEmptyOutputOnStop: Bool = false
    ) {
        self.outputURL = outputURL
        self.stopResult = stopResult
        self.capturedFrames = capturedFrames
        self.systemAudioUnavailableError = systemAudioUnavailableError
        self.deletesProvablyEmptyOutputOnStop = deletesProvablyEmptyOutputOnStop
    }

    func start() async throws {}
    func stop() async throws -> RecordingResult {
        if deletesProvablyEmptyOutputOnStop, capturedFrames == 0, isProvablyEmptyOnDisk {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingError.noCapturedAudio
        }
        return stopResult
    }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
    var hasCapturedFrames: Bool { capturedFrames > 0 }

    private var isProvablyEmptyOnDisk: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attributes?[.size] as? Int) == 0
    }
}

private final class ThrowingFakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true
    let systemAudioUnavailableError: Error? = nil
    private let stopError: Error

    init(outputURL: URL, stopError: Error = NSError(domain: "test.disk-write", code: 42)) {
        self.outputURL = outputURL
        self.stopError = stopError
    }

    func start() async throws {}
    func stop() async throws -> RecordingResult {
        throw stopError
    }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}

/// Holds a `stop()` open so a test can interleave a second finalize with one
/// that is already in flight — the race that merged a truncated recording and
/// then deleted the segment it left out.
private actor FinalizeGate {
    private(set) var stopCalls = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the fake's `stop()`: counts the call and, for the
    /// first one, suspends until `open()`. Returns false for any later call —
    /// `RecordingSession.stop()` is one-shot and rejects a second entry
    /// immediately, even while the first is still finalizing.
    func enterStop() async -> Bool {
        stopCalls += 1
        guard stopCalls == 1 else { return false }
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return true
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class GatedFakeRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true
    let systemAudioUnavailableError: Error? = nil
    private let duration: TimeInterval
    private let gate: FinalizeGate

    init(outputURL: URL, duration: TimeInterval, gate: FinalizeGate) {
        self.outputURL = outputURL
        self.duration = duration
        self.gate = gate
    }

    func start() async throws {}
    func stop() async throws -> RecordingResult {
        guard await gate.enterStop() else {
            throw RecordingError.sessionAlreadyStopped
        }
        return RecordingResult(outputURL: outputURL, duration: duration)
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

/// Vends recording sessions whose `start()` throws for the first
/// `failuresBeforeSuccess` attempts — CoreAudio right after a wake, which is not
/// ready yet and then is. The attempt counter lives here, not in the session,
/// because the retry rebuilds the session per attempt. Each failure carries a
/// distinct error code (the attempt number) so a test can prove *which*
/// attempt's error surfaced. `.max` never succeeds.
private final class FlakyEngineStart: @unchecked Sendable {
    private(set) var startAttempts = 0
    private let failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func session(outputURL: URL) -> RecordingSessionControlling {
        CountingStartRecordingSession(outputURL: outputURL) { [unowned self] in
            startAttempts += 1
            if startAttempts <= failuresBeforeSuccess {
                throw NSError(domain: "test.audio-engine", code: startAttempts)
            }
        }
    }
}

private final class CountingStartRecordingSession: RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    let hasCapturedFrames = true
    let systemAudioUnavailableError: Error? = nil
    private let onStart: () throws -> Void

    init(outputURL: URL, onStart: @escaping () throws -> Void) {
        self.outputURL = outputURL
        self.onStart = onStart
    }

    func start() async throws { try onStart() }
    func stop() async throws -> RecordingResult { RecordingResult(outputURL: outputURL, duration: 0) }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}

/// Records the backoff waits the retry asked for without taking any of them, so
/// the retry tests are deterministic instead of seven seconds long.
private final class SleepSpy: @unchecked Sendable {
    private(set) var delays: [Duration] = []

    func record(_ delay: Duration) {
        delays.append(delay)
    }
}

/// Mirrors `RecordingPowerAssertionTests`' fake, kept local because that one is
/// file-private. Used here to pin that a resume which never started takes no
/// idle-sleep assertion.
private final class SleepPreventerSpy: SleepPreventing {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    var activeCount: Int { beginCount - endCount }

    func begin(reason: String) -> SleepPreventionToken {
        beginCount += 1
        return SleepPreventionToken { [weak self] in
            self?.endCount += 1
        }
    }
}

/// Runs `resumeRecording` in a child task the test can cancel from inside the
/// injected `sleep` — the real shape of the bug, where a Stop cancels the
/// coordinator's `resumeTask` while the retry is mid-backoff. The task is
/// created here rather than in the test body so the non-Sendable `Meeting`
/// never crosses a `@Sendable` closure boundary.
private final class ResumeTaskBox: @unchecked Sendable {
    /// Written on the MainActor before the child task can reach the injected
    /// `sleep` and read from that `sleep`, which runs off the MainActor —
    /// ordered by the await in between, never concurrent.
    private var task: Task<Void, Error>?

    @MainActor
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        task = Task { try await operation() }
    }

    func cancel() {
        task?.cancel()
    }

    var value: Void {
        get async throws { try await task?.value }
    }
}
