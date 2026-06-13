# Pause And Resume Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persisted pause/resume recording so a meeting can be paused, reopened later, resumed as another segment, and finally exported as one stitched recording.

**Architecture:** Keep the existing workspace route and recorder entry point, but split resumable-state persistence into a dedicated sidecar store and refactor `AudioRecordingService` into a testable state machine with injected live-session and merge seams. The meeting model stores only user-facing recording state and final output metadata, while segment manifests and segment files live in app-managed session storage until the user finishes recording.

**Tech Stack:** Swift, SwiftUI, SwiftData, AVFoundation, ScreenCaptureKit, XCTest, `xcodebuild`

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Casablanca/Models/Meeting.swift` | Add paused recording status and keep workspace routing aligned with the new state |
| `Casablanca/Services/RecordingResumeSessionStore.swift` | Persist resumable recording manifests and segment file paths under Application Support |
| `Casablanca/Services/AudioRecordingService.swift` | Add pause/resume state machine, inject fakeable session/merge seams, and stitch segments into one final output |
| `Casablanca/ViewModels/MeetingListViewModel.swift` | Extend meeting deletion so resumable recording session folders are cleaned up too |
| `Casablanca/Views/NotesEditorView.swift` | Render `Pause Recording`, `Resume Recording`, and paused-state recovery/error behavior |
| `Casablanca/Views/SidebarView.swift` | Show paused meetings distinctly in the sidebar status icon/label |
| `CasablancaTests/MeetingStartFlowTests.swift` | Cover paused workspace presentation, service pause/resume flows, and deletion cleanup |
| `CasablancaTests/PermissionsBehaviorTests.swift` | Cover resumable session-store and segment-merge helpers with temporary files |

## Test Commands

- Presentation/state tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-presentation -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Store/helper tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-store -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingResumeSessionStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Service/deletion tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-service -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/MeetingDeletionTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Full regression suite: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-full -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`

### Task 1: Add The Paused Recording Workspace State

**Files:**
- Modify: `Casablanca/Models/Meeting.swift`
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `Casablanca/Views/SidebarView.swift`
- Test: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing workspace presentation tests**

Append these tests to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
func testPausedRecordingStatusUsesWorkspacePresentation() {
    XCTAssertEqual(MeetingStatus.pausedRecording.detailPresentation, .workspace)
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
```

- [ ] **Step 2: Run the focused workspace tests and verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-presentation-red -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL because `MeetingStatus.pausedRecording` does not exist and `MeetingWorkspacePresentation` does not yet expose paused-state action flags.

- [ ] **Step 3: Implement the paused meeting state and presentation**

In `Casablanca/Models/Meeting.swift`, extend the status enum and routing:

```swift
enum MeetingStatus: String, Codable {
    case upcoming
    case notesOnly
    case recording
    case pausedRecording
    case processing
    case completed
}

extension MeetingStatus {
    var detailPresentation: MeetingDetailPresentation {
        switch self {
        case .upcoming, .notesOnly, .recording, .pausedRecording:
            return .workspace
        case .processing:
            return .processing
        case .completed:
            return .completed
        }
    }
}
```

In `Casablanca/Views/NotesEditorView.swift`, expand `MeetingWorkspacePresentation` with explicit paused-state action flags:

```swift
struct MeetingWorkspacePresentation {
    let meeting: Meeting
    let activeMeetingID: UUID?
    let isRecording: Bool
    let isPreparing: Bool
    let isFinalizing: Bool
    let prefersRecordingFocusMode: Bool

    var isActiveMeeting: Bool { activeMeetingID == meeting.id }
    var isPausedRecording: Bool { meeting.status == .pausedRecording }
    var showsRecordingChrome: Bool { meeting.status == .recording || meeting.status == .pausedRecording }
    var showsTimestampedTools: Bool { meeting.status == .recording && isActiveMeeting && isRecording }
    var showsStartRecordingButton: Bool { meeting.status == .notesOnly }
    var showsPauseRecordingButton: Bool { meeting.status == .recording && isActiveMeeting && isRecording && !isFinalizing }
    var showsResumeRecordingButton: Bool { meeting.status == .pausedRecording && !isFinalizing }
    var showsStopRecordingButton: Bool { showsRecordingChrome && !isFinalizing }
    var backButtonDisabled: Bool { isFinalizing || (meeting.status == .recording && isActiveMeeting && isRecording) }

    var stateLabel: String {
        if isFinalizing { return "Finalizing" }
        if isPreparing { return "Preparing" }
        if meeting.status == .pausedRecording { return "Paused" }
        return "Recording"
    }
}
```

In `Casablanca/Views/SidebarView.swift`, add paused-state iconography:

```swift
case .pausedRecording:
    Image(systemName: "pause.circle")
        .symbolRenderingMode(.hierarchical)
        .imageScale(.medium)
        .foregroundStyle(Color.stateIdle)
```

and:

```swift
case .pausedRecording: return "Paused recording"
```

- [ ] **Step 4: Re-run the workspace tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-presentation-green -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS with the new paused-state presentation tests green.

- [ ] **Step 5: Commit the paused workspace state**

```bash
git add Casablanca/Models/Meeting.swift Casablanca/Views/NotesEditorView.swift Casablanca/Views/SidebarView.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: add paused recording workspace state"
```

### Task 2: Persist Resumable Recording Sessions Outside The Meeting Model

**Files:**
- Create: `Casablanca/Services/RecordingResumeSessionStore.swift`
- Test: `CasablancaTests/PermissionsBehaviorTests.swift`

- [ ] **Step 1: Write the failing session-store tests**

Append these tests to `CasablancaTests/PermissionsBehaviorTests.swift`:

```swift
final class RecordingResumeSessionStoreTests: XCTestCase {
    func testSessionStoreRoundTripsManifestAndSegments() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meetingID = UUID()
        let segmentURL = try store.nextSegmentURL(for: meetingID, segmentNumber: 1)

        _ = try store.createSession(
            for: meetingID,
            systemAudioEnabled: true,
            selectedInputDeviceID: "BuiltInMic"
        )

        let updated = try store.appendSegment(
            for: meetingID,
            segmentURL: segmentURL,
            duration: 12.5
        )

        let reloaded = try XCTUnwrap(store.loadSession(for: meetingID))
        XCTAssertEqual(updated, reloaded)
        XCTAssertEqual(reloaded.nextSegmentNumber, 2)
        XCTAssertEqual(reloaded.segments.count, 1)
        XCTAssertEqual(reloaded.segments[0].filePath, segmentURL.path)
    }

    func testDeleteSessionRemovesMeetingFolder() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let meetingID = UUID()

        _ = try store.createSession(for: meetingID, systemAudioEnabled: false, selectedInputDeviceID: nil)
        let sessionDirectory = try store.sessionDirectory(for: meetingID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try store.deleteSession(for: meetingID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }
}
```

- [ ] **Step 2: Run the store tests and verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-store-red -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingResumeSessionStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL because `RecordingResumeSessionStore` and its manifest types do not exist yet.

- [ ] **Step 3: Implement the resumable session store**

Create `Casablanca/Services/RecordingResumeSessionStore.swift`:

```swift
import Foundation

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
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
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
        var session = try loadSession(for: meetingID) ?? createSession(
            for: meetingID,
            systemAudioEnabled: true,
            selectedInputDeviceID: nil
        )
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
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func sessionDirectory(for meetingID: UUID) throws -> URL {
        let directory = try baseDirectoryProvider().appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifestURL(for meetingID: UUID) throws -> URL {
        try sessionDirectory(for: meetingID).appendingPathComponent("session.json")
    }

    private func persist(_ session: PersistedRecordingSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: manifestURL(for: session.meetingID), options: .atomic)
    }
}
```

- [ ] **Step 4: Re-run the store tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-store-green -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingResumeSessionStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS with both manifest persistence tests green.

- [ ] **Step 5: Commit the session-store layer**

```bash
git add Casablanca/Services/RecordingResumeSessionStore.swift CasablancaTests/PermissionsBehaviorTests.swift
git commit -m "feat: persist resumable recording sessions"
```

### Task 3: Refactor AudioRecordingService Into A Testable Pause/Resume State Machine

**Files:**
- Modify: `Casablanca/Services/AudioRecordingService.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Test: `CasablancaTests/PermissionsBehaviorTests.swift`

- [ ] **Step 1: Write the failing pause/resume service tests**

Append these tests to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
@MainActor
final class AudioRecordingServicePauseResumeTests: XCTestCase {
    func testPauseRecordingPersistsSegmentAndLeavesMeetingResumable() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RecordingResumeSessionStore(baseDirectoryProvider: { rootURL })
        let segmentURL = rootURL.appendingPathComponent("segment-001.wav")
        let fakeSession = FakeRecordingSession(
            outputURL: segmentURL,
            stopResult: RecordingResult(outputURL: segmentURL, duration: 8)
        )
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        let service = AudioRecordingService(
            sessionStore: store,
            makeRecordingSession: { _, _, _, _, _, _ in fakeSession },
            mergeSegments: { _, outputURL in
                try Data("merged".utf8).write(to: outputURL)
                return 8
            }
        )

        try await service.startRecording(for: meeting)
        let pause = try await service.pauseRecording()

        XCTAssertEqual(pause.duration, 8)
        XCTAssertFalse(service.isRecording)
        XCTAssertNil(service.activeMeetingID)

        let session = try XCTUnwrap(store.loadSession(for: meeting.id))
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.segments[0].filePath, segmentURL.path)
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
            makeRecordingSession: { _, _, _, _, _, _ in
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
}

private final class FakeRecordingSession: RecordingSessionControlling {
    let outputURL: URL
    let startedAt = Date()
    let stopResult: RecordingResult

    init(outputURL: URL, stopResult: RecordingResult) {
        self.outputURL = outputURL
        self.stopResult = stopResult
    }

    func start() async throws {}
    func stop() async throws -> RecordingResult { stopResult }
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {}
    func setSystemAudioEnabled(_ enabled: Bool) {}
}
```

Also append this helper test to `CasablancaTests/PermissionsBehaviorTests.swift`:

```swift
func testMergeSegmentsConcatenatesExistingWavFilesInOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appendingPathComponent("segment-001.wav")
    let second = directory.appendingPathComponent("segment-002.wav")
    let output = directory.appendingPathComponent("final.wav")

    try writeMonoWAV(samples: [0, 1000], to: first)
    try writeMonoWAV(samples: [2000, 3000], to: second)

    let duration = try RecordingSegmentMerger.merge(segmentURLs: [first, second], into: output)

    XCTAssertEqual(duration, 4.0 / 16_000.0, accuracy: 0.0001)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
}

private func writeMonoWAV(samples: [Int16], to url: URL) throws {
    let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let header = RecordingSegmentMerger.header(dataByteCount: payload.count)
    try (header + payload).write(to: url, options: .atomic)
}
```

- [ ] **Step 2: Run the service/helper tests and verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-service-red -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/RecordingResumeSessionStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL because `AudioRecordingService` has no injected session factory, no `pauseRecording()`, no `stopRecording(for:)`, and no segment merger helper.

- [ ] **Step 3: Add the injected seams and pause/resume methods**

In `Casablanca/Services/AudioRecordingService.swift`, introduce a fakeable live-session protocol and service injections:

```swift
protocol RecordingSessionControlling: AnyObject {
    var outputURL: URL { get }
    var startedAt: Date { get }
    func start() async throws
    func stop() async throws -> RecordingResult
    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws
    func setSystemAudioEnabled(_ enabled: Bool)
}

typealias RecordingSessionFactory = (
    _ outputURL: URL,
    _ meeting: Meeting,
    _ inputDeviceID: AudioDeviceID?,
    _ systemAudioEnabled: Bool,
    _ onLevelUpdate: @escaping (Double) -> Void,
    _ onFailure: @escaping (Error) -> Void
) throws -> RecordingSessionControlling
```

Make `RecordingSession` conform by changing its initializer to accept `outputURL` directly:

```swift
private final class RecordingSession: NSObject, RecordingSessionControlling, @unchecked Sendable {
    init(
        outputURL: URL,
        meeting: Meeting,
        inputDeviceID: AudioDeviceID?,
        systemAudioEnabled: Bool,
        onLevelUpdate: @escaping (Double) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.microphoneTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "mic")
        self.systemAudioTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "system")
        self.selectedInputDeviceID = inputDeviceID
        self.systemAudioEnabled = systemAudioEnabled
        self.onLevelUpdate = onLevelUpdate
        self.onFailure = onFailure
        super.init()
    }
}
```

Extend `AudioRecordingService` with injected seams and resumable APIs:

```swift
@MainActor
@Observable
final class AudioRecordingService {
    private let sessionStore: RecordingResumeSessionStore
    private let makeRecordingSession: RecordingSessionFactory
    private let makeFinalOutputURL: (Meeting) throws -> URL
    private let mergeSegments: ([URL], URL) throws -> TimeInterval

    init(
        sessionStore: RecordingResumeSessionStore = RecordingResumeSessionStore(),
        makeRecordingSession: @escaping RecordingSessionFactory = { outputURL, meeting, inputDeviceID, systemAudioEnabled, onLevelUpdate, onFailure in
            try RecordingSession(
                outputURL: outputURL,
                meeting: meeting,
                inputDeviceID: inputDeviceID,
                systemAudioEnabled: systemAudioEnabled,
                onLevelUpdate: onLevelUpdate,
                onFailure: onFailure
            )
        },
        makeFinalOutputURL: @escaping (Meeting) throws -> URL = AudioRecordingService.defaultFinalOutputURL,
        mergeSegments: @escaping ([URL], URL) throws -> TimeInterval = RecordingSegmentMerger.merge
    ) {
        self.sessionStore = sessionStore
        self.makeRecordingSession = makeRecordingSession
        self.makeFinalOutputURL = makeFinalOutputURL
        self.mergeSegments = mergeSegments
        refreshInputDevices(forcePreferredSelection: true)
    }

    func pauseRecording() async throws -> RecordingResult {
        guard let session, let activeMeetingID else {
            throw RecordingError.noActiveRecording
        }

        let segmentResult = try await finalizeActiveSegment(session: session, meetingID: activeMeetingID)
        clearActiveSessionState()
        elapsedTime = segmentResult.duration
        return segmentResult
    }

    func resumeRecording(for meeting: Meeting) async throws {
        guard let persisted = try sessionStore.loadSession(for: meeting.id) else {
            throw RecordingError.noActiveRecording
        }

        isPreparing = true
        let segmentURL = try sessionStore.nextSegmentURL(
            for: meeting.id,
            segmentNumber: persisted.nextSegmentNumber
        )
        let session = try buildSession(
            outputURL: segmentURL,
            meeting: meeting,
            selectedInputDeviceID: persisted.selectedInputDeviceID,
            systemAudioEnabled: persisted.systemAudioEnabled
        )
        try await session.start()

        self.session = session
        activeMeetingID = meeting.id
        outputURL = segmentURL
        isRecording = true
        isPreparing = false
        startTimer(from: session.startedAt)
    }

    func stopRecording(for meeting: Meeting) async throws -> RecordingResult {
        if let liveSession = session, activeMeetingID == meeting.id {
            _ = try await finalizeActiveSegment(session: liveSession, meetingID: meeting.id)
            clearActiveSessionState()
        }

        guard let persisted = try sessionStore.loadSession(for: meeting.id),
              !persisted.segments.isEmpty
        else {
            throw RecordingError.noActiveRecording
        }

        let finalURL = try makeFinalOutputURL(meeting)
        let segmentURLs = persisted.segments.map { URL(fileURLWithPath: $0.filePath) }
        let duration = try mergeSegments(segmentURLs, finalURL)
        try sessionStore.deleteSession(for: meeting.id)

        outputURL = finalURL
        elapsedTime = duration
        return RecordingResult(outputURL: finalURL, duration: duration)
    }

    func hasResumableSession(for meetingID: UUID) -> Bool { (try? sessionStore.loadSession(for: meetingID)) != nil }
    func setErrorMessage(_ message: String) { errorMessage = message }

    static func defaultFinalOutputURL(for meeting: Meeting) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directory = appSupport
            .appendingPathComponent("Casablanca", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let timestamp = formatter.string(from: Date())
        return directory.appendingPathComponent("\(meeting.sanitizedTitle) \(timestamp).wav")
    }

    private func buildSession(
        outputURL: URL,
        meeting: Meeting,
        selectedInputDeviceID: String?,
        systemAudioEnabled: Bool
    ) throws -> RecordingSessionControlling {
        let effectiveInputDeviceID = selectedInputDeviceID ?? self.selectedInputDeviceID
        let audioDeviceID = availableInputDevices.first(where: { $0.id == effectiveInputDeviceID })?.deviceID
        return try makeRecordingSession(
            outputURL,
            meeting,
            audioDeviceID,
            systemAudioEnabled,
            { [weak self] level in self?.audioLevel = level },
            { [weak self] error in self?.errorMessage = error.localizedDescription }
        )
    }

    private func finalizeActiveSegment(
        session: RecordingSessionControlling,
        meetingID: UUID
    ) async throws -> RecordingResult {
        let result = try await session.stop()
        _ = try sessionStore.appendSegment(
            for: meetingID,
            segmentURL: result.outputURL,
            duration: result.duration
        )
        return result
    }

    private func clearActiveSessionState() {
        self.session = nil
        isRecording = false
        isPreparing = false
        activeMeetingID = nil
        timerTask?.cancel()
        timerTask = nil
        audioLevel = 0
    }
}
```

Add a deterministic WAV merger helper in the same file:

```swift
enum RecordingSegmentMerger {
    static func merge(segmentURLs: [URL], into outputURL: URL) throws -> TimeInterval {
        let sampleRate = 16_000.0
        var renderedSamples = [Int16]()

        for url in segmentURLs {
            let data = try Data(contentsOf: url)
            let body = data.dropFirst(44)
            renderedSamples += body.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
        }

        let payload = renderedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        try (header(dataByteCount: payload.count) + payload).write(to: outputURL, options: .atomic)

        return Double(renderedSamples.count) / sampleRate
    }

    static func header(dataByteCount: Int) -> Data {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let chunkSize = UInt32(36 + dataByteCount)
        let subchunk2Size = UInt32(dataByteCount)
        var mutableChunkSize = chunkSize
        var mutableSubchunk1Size: UInt32 = 16
        var mutableAudioFormat: UInt16 = 1
        var mutableChannelCount = channelCount
        var mutableSampleRate = sampleRate
        var mutableByteRate = byteRate
        var mutableBlockAlign = blockAlign
        var mutableBitsPerSample = bitsPerSample
        var mutableSubchunk2Size = subchunk2Size

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(Data(bytes: &mutableChunkSize, count: MemoryLayout<UInt32>.size))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(Data(bytes: &mutableSubchunk1Size, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &mutableAudioFormat, count: MemoryLayout<UInt16>.size))
        data.append(Data(bytes: &mutableChannelCount, count: MemoryLayout<UInt16>.size))
        data.append(Data(bytes: &mutableSampleRate, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &mutableByteRate, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &mutableBlockAlign, count: MemoryLayout<UInt16>.size))
        data.append(Data(bytes: &mutableBitsPerSample, count: MemoryLayout<UInt16>.size))
        data.append("data".data(using: .ascii)!)
        data.append(Data(bytes: &mutableSubchunk2Size, count: MemoryLayout<UInt32>.size))
        return data
    }
}
```

- [ ] **Step 4: Re-run the service/helper tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-service-green -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/RecordingResumeSessionStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS with the fake-session pause/resume flow and WAV merge helper covered.

- [ ] **Step 5: Commit the service state machine**

```bash
git add Casablanca/Services/AudioRecordingService.swift CasablancaTests/MeetingStartFlowTests.swift CasablancaTests/PermissionsBehaviorTests.swift
git commit -m "feat: add pause and resume recording state machine"
```

### Task 4: Wire Pause/Resume Into The Workspace And Cleanup Paths

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `Casablanca/ViewModels/MeetingListViewModel.swift`
- Modify: `Casablanca/Views/SidebarView.swift`
- Test: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing workspace/deletion tests**

Append these tests to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
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
```

Also add this presentation regression:

```swift
func testPausedWorkspaceStillShowsCompactControlsWhenFocusModeEnabled() {
    let meeting = Meeting(title: "Weekly Sync", date: .now, status: .pausedRecording)
    let presentation = MeetingWorkspacePresentation(
        meeting: meeting,
        activeMeetingID: nil,
        isRecording: false,
        isPreparing: false,
        isFinalizing: false,
        prefersRecordingFocusMode: true
    )

    XCTAssertFalse(presentation.showsExpandedRecordingChrome)
    XCTAssertTrue(presentation.showsCompactRecordingControls)
    XCTAssertTrue(presentation.showsResumeRecordingButton)
}
```

- [ ] **Step 2: Run the workspace/deletion tests and verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-ui-red -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests -only-testing:CasablancaTests/MeetingDeletionTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL because the view model does not clean up resumable sessions and the workspace footer/header still only understands start vs stop.

- [ ] **Step 3: Implement the workspace actions and deletion cleanup**

In `Casablanca/ViewModels/MeetingListViewModel.swift`, add an injectable resumable-session cleanup seam:

```swift
private let removeResumableRecordingSession: (UUID) throws -> Void

init(
    calendarService: CalendarService,
    meetingHasPrep: @escaping (Meeting) -> Bool = { meeting in
        MeetingPrepService.hasPrep(for: meeting)
    },
    removeItemAtURL: @escaping (URL) throws -> Void = { url in
        try FileManager.default.removeItem(at: url)
    },
    removeResumableRecordingSession: @escaping (UUID) throws -> Void = { meetingID in
        try RecordingResumeSessionStore().deleteSession(for: meetingID)
    }
) {
    self.calendarService = calendarService
    self.meetingHasPrep = meetingHasPrep
    self.removeItemAtURL = removeItemAtURL
    self.removeResumableRecordingSession = removeResumableRecordingSession
}
```

and inside `deleteMeeting(_:)`:

```swift
try? removeResumableRecordingSession(meeting.id)
```

In `Casablanca/Views/NotesEditorView.swift`, expand the action phase and footer actions:

```swift
private enum RecordingActionPhase {
    case start
    case pause
    case resume
    case stop
}
```

Replace the footer recording buttons with explicit actions:

```swift
if presentation.showsStartRecordingButton {
    Button(action: requestRecordingStart) {
        Label("Start Recording", systemImage: "record.circle")
    }
    .buttonStyle(PrimaryButtonStyle())
} else {
    if presentation.showsPauseRecordingButton {
        Button {
            Task { await pauseRecording() }
        } label: {
            Label("Pause Recording", systemImage: "pause.circle")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    if presentation.showsResumeRecordingButton {
        Button {
            Task { await resumeRecording() }
        } label: {
            Label("Resume Recording", systemImage: "record.circle")
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    if presentation.showsStopRecordingButton {
        Button {
            Task { await stopRecording() }
        } label: {
            Label("Stop Recording", systemImage: "stop.circle")
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}
```

Add the new handlers:

```swift
private func pauseRecording() async {
    recordingActionPhase = .pause
    do {
        let result = try await recordingService.pauseRecording()
        meeting.recordingDuration = (meeting.recordingDuration ?? 0) + result.duration
        meeting.status = .pausedRecording
        save()
    } catch {
        save()
    }
}

private func resumeRecording() async {
    recordingActionPhase = .resume
    do {
        try await recordingService.resumeRecording(for: meeting)
        meeting.status = .recording
        save()
    } catch {
        meeting.status = .pausedRecording
        save()
    }
}

private func stopRecording() async {
    guard !isFinalizingRecording else { return }

    recordingActionPhase = .stop
    isFinalizingRecording = true

    do {
        let result = try await recordingService.stopRecording(for: meeting)
        meeting.recordingFileURL = result.outputURL.path
        meeting.recordingDuration = result.duration
        meeting.status = .processing
        save()
    } catch {
        isFinalizingRecording = false
        meeting.status = recordingService.hasResumableSession(for: meeting.id) ? .pausedRecording : .notesOnly
        save()
    }
}
```

On workspace entry, validate paused sessions before pretending they are resumable:

```swift
.task(id: meeting.id) {
    try? ObsidianTodoSyncService.refreshTodos(for: meeting, in: modelContext)
    loadPrepMarkdown()

    if meeting.status == .pausedRecording && !recordingService.hasResumableSession(for: meeting.id) {
        recordingActionPhase = .resume
        recordingService.setErrorMessage("This paused recording can no longer be resumed.")
        meeting.status = .notesOnly
        save()
    }
}
```

- [ ] **Step 4: Re-run the workspace/deletion tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-ui-green -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests -only-testing:CasablancaTests/MeetingDeletionTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS with paused workspace and deletion cleanup behavior covered.

- [ ] **Step 5: Commit the UI and cleanup wiring**

```bash
git add Casablanca/Views/NotesEditorView.swift Casablanca/ViewModels/MeetingListViewModel.swift Casablanca/Views/SidebarView.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: wire pause and resume recording into workspace"
```

### Task 5: Run Full Regression Verification

**Files:**
- Test: `CasablancaTests/MeetingStartFlowTests.swift`
- Test: `CasablancaTests/PermissionsBehaviorTests.swift`
- Test: full project

- [ ] **Step 1: Run the focused regression suite**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-regression -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingWorkspacePresentationTests -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/MeetingDeletionTests -only-testing:CasablancaTests/RecordingResumeSessionStoreTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Run the full suite**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-pause-resume-full -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: full suite passes with `0 failures`.

- [ ] **Step 3: Sanity-check the manual flow**

Run the app locally and verify:

```text
1. Start a meeting recording.
2. Pause it.
3. Quit Casablanca.
4. Reopen Casablanca and open the same meeting manually.
5. Confirm the workspace shows Resume Recording.
6. Resume, then Stop Recording.
7. Confirm the meeting transitions to Processing with one final recording file.
```

Expected: no auto-open on launch, resume available only when the meeting is opened manually, and the final recording appears once with the stitched duration.

- [ ] **Step 4: Commit the verified implementation**

```bash
git add Casablanca/Models/Meeting.swift Casablanca/Services/RecordingResumeSessionStore.swift Casablanca/Services/AudioRecordingService.swift Casablanca/ViewModels/MeetingListViewModel.swift Casablanca/Views/NotesEditorView.swift Casablanca/Views/SidebarView.swift CasablancaTests/MeetingStartFlowTests.swift CasablancaTests/PermissionsBehaviorTests.swift
git commit -m "feat: add persisted pause and resume recording"
```
