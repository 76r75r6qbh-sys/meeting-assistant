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

    // MARK: - No export after delete

    /// A coalescer with a long delay, so a scheduled export only runs on flush.
    private func makeCoalescer() -> MeetingExportCoalescer {
        MeetingExportCoalescer(delay: .seconds(60))
    }

    private func makeStoredMeeting(in context: ModelContext) throws -> Meeting {
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        context.insert(meeting)
        try context.save()
        return meeting
    }

    /// Positive control: a live meeting's scheduled export runs on flush.
    func testScheduledExportOfALiveMeetingRuns() throws {
        let context = ModelContext(try makeContainer())
        let meeting = try makeStoredMeeting(in: context)
        let coalescer = makeCoalescer()
        var exported: [UUID] = []

        coalescer.scheduleAutomaticExport(of: meeting, reporter: nil) { meeting, _, _ in exported.append(meeting.id) }
        coalescer.flushAndWait(timeout: 5)

        XCTAssertEqual(exported, [meeting.id])
    }

    /// Edit, then delete within the debounce: the pending export is cancelled,
    /// so the deleted meeting's note or file is never rewritten or recreated.
    func testDeletingAMeetingCancelsItsScheduledExport() throws {
        let context = ModelContext(try makeContainer())
        let coalescer = makeCoalescer()
        let vm = MeetingListViewModel(
            calendarService: CalendarService(),
            removeItemAtURL: { _ in },
            exportCoalescer: coalescer
        )
        vm.setModelContext(context)
        let meeting = try makeStoredMeeting(in: context)
        var exported = 0

        coalescer.scheduleAutomaticExport(of: meeting, reporter: nil) { _, _, _ in exported += 1 }
        vm.beginSoftDelete(meeting.id)
        try vm.commitSoftDelete(meeting)
        XCTAssertTrue(coalescer.isIdle, "The delete cancels the pending export")
        coalescer.flushAndWait(timeout: 5)

        XCTAssertEqual(exported, 0)
        XCTAssertTrue(coalescer.isIdle)
    }

    /// A delete that bypasses the cancel (or races it) is still caught when
    /// the run starts: a deleted model is never exported (or touched).
    func testAScheduledExportSkipsAMeetingDeletedElsewhere() throws {
        let context = ModelContext(try makeContainer())
        let meeting = try makeStoredMeeting(in: context)
        let coalescer = makeCoalescer()
        var exported = 0

        coalescer.scheduleAutomaticExport(of: meeting, reporter: nil) { _, _, _ in exported += 1 }
        context.delete(meeting)
        try context.save()
        coalescer.flushAndWait(timeout: 5)

        XCTAssertEqual(exported, 0)
    }

    /// During the undo grace period the meeting is soft-deleted: no export.
    func testAScheduledExportSkipsAMeetingPendingDeletion() throws {
        let context = ModelContext(try makeContainer())
        let meeting = try makeStoredMeeting(in: context)
        let coalescer = makeCoalescer()
        coalescer.isPendingDeletion = { $0 == meeting.id }
        var exported = 0

        coalescer.scheduleAutomaticExport(of: meeting, reporter: nil) { _, _, _ in exported += 1 }
        coalescer.flushAndWait(timeout: 5)

        XCTAssertEqual(exported, 0)
    }

    /// The awaited export (transcription pipeline) has the same guard.
    func testAnAwaitedExportSkipsADeletedMeeting() async throws {
        let context = ModelContext(try makeContainer())
        let meeting = try makeStoredMeeting(in: context)
        let coalescer = makeCoalescer()
        var exported = 0
        context.delete(meeting)
        try context.save()

        await coalescer.runAutomaticExport(of: meeting, defaults: .standard, reporter: nil) { _, _, _ in exported += 1 }

        XCTAssertEqual(exported, 0)
    }

    // MARK: - Leftover files and the decision log

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingSoftDeleteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A view model whose side stores all live in `directory`.
    private func makeIsolatedViewModel(in directory: URL, log: TodoDecisionLog) -> MeetingListViewModel {
        MeetingListViewModel(
            calendarService: CalendarService(),
            removeResumableRecordingSession: { _ in },
            speakerAnalysisStore: SpeakerAnalysisStore(directory: directory.appendingPathComponent("Speakers", isDirectory: true)),
            exportCoalescer: makeCoalescer(),
            todoDecisionLog: log
        )
    }

    /// Stop failed, so the meeting references only its mix: the per-source
    /// track WAVs (and any m4a of them) next to it still go with the meeting.
    func testDeleteRemovesUnreferencedTrackFilesNextToTheRecording() throws {
        let directory = try makeTemporaryDirectory()
        let context = ModelContext(try makeContainer())
        let vm = makeIsolatedViewModel(in: directory, log: TodoDecisionLog(fileURL: directory.appendingPathComponent("log.jsonl")))
        vm.setModelContext(context)
        let mix = directory.appendingPathComponent("meeting.m4a")
        let leftovers = ["meeting.mic.wav", "meeting.system.wav", "meeting.mic.m4a", "meeting.system.m4a"]
            .map { directory.appendingPathComponent($0) }
        let unrelated = directory.appendingPathComponent("other.mic.wav")
        for url in [mix, unrelated] + leftovers { try Data("x".utf8).write(to: url) }
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        meeting.recordingFileURL = mix.path
        context.insert(meeting)
        try context.save()

        try vm.deleteMeeting(meeting)

        for url in [mix] + leftovers {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is removed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "another recording's track is left alone")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Meeting>()), 0)
    }

    /// Only some leftovers exist (or none): a missing file is not an error.
    func testDeleteWithMissingTrackFilesStillDeletesTheMeeting() throws {
        let directory = try makeTemporaryDirectory()
        let context = ModelContext(try makeContainer())
        let vm = makeIsolatedViewModel(in: directory, log: TodoDecisionLog(fileURL: directory.appendingPathComponent("log.jsonl")))
        vm.setModelContext(context)
        let mix = directory.appendingPathComponent("meeting.wav")
        let mic = directory.appendingPathComponent("meeting.mic.wav")
        try Data("x".utf8).write(to: mix)
        try Data("x".utf8).write(to: mic)
        let meeting = Meeting(title: "Standup", date: .now, status: .completed)
        meeting.recordingFileURL = mix.path
        meeting.systemTrackFileURL = directory.appendingPathComponent("meeting.system.wav").path
        context.insert(meeting)
        try context.save()

        XCTAssertNoThrow(try vm.deleteMeeting(meeting))

        XCTAssertFalse(FileManager.default.fileExists(atPath: mic.path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Meeting>()), 0)
    }

    /// The deleted meeting's to-do text and quotes leave the decision log;
    /// other meetings' lines stay.
    func testDeleteRemovesTheMeetingsDecisionLogEntries() throws {
        let directory = try makeTemporaryDirectory()
        let log = TodoDecisionLog(fileURL: directory.appendingPathComponent("todo-decisions.jsonl"))
        let context = ModelContext(try makeContainer())
        let vm = makeIsolatedViewModel(in: directory, log: log)
        vm.setModelContext(context)
        let meeting = try makeStoredMeeting(in: context)
        let other = UUID()
        for (task, meetingID) in [("Stuur offerte", meeting.id), ("Plan demo", other)] {
            log.append(TodoDecisionEntry(
                date: Date(timeIntervalSince1970: 1_793_000_000), meetingID: meetingID, todoID: UUID(), action: .accept,
                item: .init(task: task, owner: nil, due: nil, timestamp: nil, quote: "quote \(task)"),
                edit: nil, verification: nil, verificationReason: nil
            ))
        }

        try vm.deleteMeeting(meeting)

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("Stuur offerte"))
        XCTAssertFalse(text.contains(meeting.id.uuidString))
        XCTAssertTrue(text.contains("Plan demo"))
        XCTAssertTrue(text.contains(other.uuidString))
    }
}
