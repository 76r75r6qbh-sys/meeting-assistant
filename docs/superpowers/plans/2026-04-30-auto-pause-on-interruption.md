# Auto-Pause Recording On System Interruption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Treat system interruptions (screen lock, sleep, audio device disconnect, SCStream stop-with-error) as graceful auto-pauses that finalize the current segment, persist a resumable session, transition the meeting to `.pausedRecording`, and either auto-resume after short interruptions (< 30s; lock/sleep only) or wait for a manual Resume tap.

**Architecture:** Three units. `AudioRecordingService` becomes a testable pause/resume state machine (no system-event awareness). `RecordingInterruptionMonitor` observes `NSWorkspace`, Core Audio device-list changes, and forwarded SCStream errors, emitting structured `interruptionStarted` / `interruptionEnded` events. `RecordingInterruptionCoordinator` is the only piece touching both — it pauses on start events, schedules a 30-second auto-resume window, and resumes on end events when the window has not expired and every active reason allows auto-resume. UI gets explicit Pause / Resume / Stop buttons plus a quiet inline auto-pause indicator and macOS notifications.

**Tech Stack:** Swift, SwiftUI, SwiftData, AVFoundation, ScreenCaptureKit, Core Audio, UserNotifications, XCTest, `xcodebuild`.

**Supersedes:** `docs/superpowers/plans/2026-04-24-pause-resume-recording.md` Tasks 3, 4, 5. The pause/resume state-machine work originally scoped there is folded into Task 1 and Task 2 of this plan with the additional empty-segment and system-interrupt entry points required by `docs/superpowers/specs/2026-04-30-auto-pause-on-interruption-design.md`. Tasks 1 and 2 of the older plan (paused workspace state and resumable session store) are already shipped and unchanged.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Casablanca/Services/AudioRecordingService.swift` | Add testable seams (`RecordingSessionControlling`, factory, merge closure), implement `pauseRecording()`, `resumeRecording(for:)`, `stopRecording(for:)` (segment-aware), `handleSystemInterrupt(reason:)` (empty-segment-tolerant pause), `forwardStreamFailure(_:)`. Hold a weak monitor reference for stream-failure forwarding and active-device tracking. |
| `Casablanca/Services/RecordingInterruptionMonitor.swift` | New. Subscribe to `NSWorkspace` notifications, register a Core Audio property listener for device-list changes, accept forwarded stream failures, and emit `RecordingInterruption` start/end events on the main actor. |
| `Casablanca/Services/RecordingInterruptionCoordinator.swift` | New. Subscribe to monitor events; call `service.handleSystemInterrupt(reason:)` on start; manage a 30-second auto-resume window; call `service.resumeRecording(for:)` on end when conditions met; post `UNUserNotificationCenter` notifications via an injected notifier; expose recent-events ring buffer for the UI. |
| `Casablanca/ViewModels/MeetingListViewModel.swift` | On `deleteMeeting`, also delete the meeting's resumable recording session folder via an injected closure. |
| `Casablanca/Views/NotesEditorView.swift` | Replace the start/stop button cluster with explicit Pause / Resume / Stop buttons. Add paused-state task validation that recovers a stale paused meeting. Render an inline auto-pause indicator above the recording header when the coordinator has a recent event for the active meeting. |
| `Casablanca/Views/ContentView.swift` | Instantiate the monitor, coordinator, and notifier alongside `recordingService`; pass the coordinator into `NotesEditorView`. |
| `CasablancaTests/MeetingStartFlowTests.swift` | Service pause/resume/stop tests, paused workspace presentation tests, deletion cleanup test. |
| `CasablancaTests/PermissionsBehaviorTests.swift` | `RecordingSegmentMerger` and empty-segment helper tests. |
| `CasablancaTests/RecordingInterruptionMonitorTests.swift` | New. Map system events and forwarded stream failures to `RecordingInterruption` start/end events. |
| `CasablancaTests/RecordingInterruptionCoordinatorTests.swift` | New. Cover short-lock auto-resume, long-lock manual-only, device-disconnect never auto-resumes, stream-failure never auto-resumes, overlapping reasons coalesce, manual stop cancels pending resume, resume failure stays paused with notification. |

## Test Commands

- Service & state-machine tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-service -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests -only-testing:CasablancaTests/MeetingDeletionTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Helper tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-helpers -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingResumeSessionStoreTests -only-testing:CasablancaTests/RecordingSegmentMergerTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Monitor tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-monitor -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingInterruptionMonitorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Coordinator tests: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-coordinator -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingInterruptionCoordinatorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`
- Full regression: `xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-full -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`

---

### Task 1: Refactor `AudioRecordingService` Into A Pause/Resume State Machine

Adds testable seams plus `pauseRecording()`, `resumeRecording(for:)`, segment-aware `stopRecording(for:)`, empty-segment-tolerant `handleSystemInterrupt(reason:)`, and a `RecordingSegmentMerger` helper. Tasks 3–5 of the older plan are folded in and extended here.

**Files:**
- Modify: `Casablanca/Services/AudioRecordingService.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`
- Modify: `CasablancaTests/PermissionsBehaviorTests.swift`

- [ ] **Step 1: Write the failing service tests for pause/resume/stop**

Append to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing helper tests for `RecordingSegmentMerger`**

Append to `CasablancaTests/PermissionsBehaviorTests.swift`:

```swift
final class RecordingSegmentMergerTests: XCTestCase {
    func testMergeConcatenatesExistingWavFilesInOrder() throws {
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

    func testMergeWithSingleSegmentProducesEquivalentOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let only = directory.appendingPathComponent("segment-001.wav")
        let output = directory.appendingPathComponent("final.wav")

        try writeMonoWAV(samples: [100, 200, 300], to: only)

        let duration = try RecordingSegmentMerger.merge(segmentURLs: [only], into: output)

        XCTAssertEqual(duration, 3.0 / 16_000.0, accuracy: 0.0001)
        let outputData = try Data(contentsOf: output)
        XCTAssertEqual(outputData.count, 44 + 3 * MemoryLayout<Int16>.size)
    }

    private func writeMonoWAV(samples: [Int16], to url: URL) throws {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let header = RecordingSegmentMerger.header(dataByteCount: payload.count)
        try (header + payload).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 3: Run the new tests and verify they fail**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task1-red -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/RecordingSegmentMergerTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL — `RecordingSessionControlling`, `pauseRecording`, `resumeRecording(for:)`, `stopRecording(for:)`, `handleSystemInterrupt(reason:)`, `hasResumableSession(for:)`, and `RecordingSegmentMerger` do not exist.

- [ ] **Step 4: Add the protocol, factory typealias, and `InterruptionReason` placeholder**

In `Casablanca/Services/AudioRecordingService.swift`, add these declarations near the top of the file, after `enum RecordingError`:

```swift
protocol RecordingSessionControlling: AnyObject {
    var outputURL: URL { get }
    var startedAt: Date { get }
    var hasCapturedFrames: Bool { get }
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

enum RecordingInterruptionReason: Hashable, Sendable {
    case screenLock
    case systemSleep
    case audioDeviceLost(deviceID: String)
    case streamFailure(underlyingDescription: String)

    var allowsAutoResume: Bool {
        switch self {
        case .screenLock, .systemSleep: return true
        case .audioDeviceLost, .streamFailure: return false
        }
    }
}
```

- [ ] **Step 5: Make `RecordingSession` conform to `RecordingSessionControlling` and split callbacks**

The existing `RecordingSession` has a single `onFailure` callback shared by transient buffer errors and the stream delegate's fatal `didStopWithError`. The new design splits them: per-buffer/conversion errors stay in `onFailure` (visibility only), while the stream delegate calls a new `onStreamFatal` callback that the service uses to forward to the interruption monitor. This preserves the spec's "a single dropped buffer is not an interruption" rule.

In `Casablanca/Services/AudioRecordingService.swift`, **replace the entire existing `RecordingSession` class declaration through its `init` body** (currently `private final class RecordingSession: NSObject, @unchecked Sendable {` at ~line 425 through the closing `}` of `init` at ~line 483). The replacement also removes `Self.makeOutputURL(for:)` (deleted) and `outputURL` is now passed in by the service.

The new declaration:

```swift
private final class RecordingSession: NSObject, RecordingSessionControlling, @unchecked Sendable {
    let outputURL: URL
    let startedAt = Date()
    private let microphoneTempURL: URL
    private let systemAudioTempURL: URL
    private let pipeline = DeferredRecordingPipeline.captureFirst
    private var selectedInputDeviceID: AudioDeviceID?
    private var systemAudioEnabled: Bool

    private let onLevelUpdate: (Double) -> Void
    private let onFailure: (Error) -> Void
    private let onStreamFatal: (Error) -> Void

    // ... existing private storage unchanged ...

    init(
        outputURL: URL,
        meeting: Meeting,
        inputDeviceID: AudioDeviceID?,
        systemAudioEnabled: Bool,
        onLevelUpdate: @escaping (Double) -> Void,
        onFailure: @escaping (Error) -> Void,
        onStreamFatal: @escaping (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.microphoneTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "mic")
        self.systemAudioTempURL = Self.makeTemporaryURL(for: outputURL, suffix: "system")
        self.selectedInputDeviceID = inputDeviceID
        self.systemAudioEnabled = systemAudioEnabled
        self.onLevelUpdate = onLevelUpdate
        self.onFailure = onFailure
        self.onStreamFatal = onStreamFatal
        super.init()
        streamDelegate.onStop = { [weak self] error in
            self?.onStreamFatal(error)
        }
    }

    var hasCapturedFrames: Bool {
        capturedMicrophoneFrames > 0 || capturedSystemAudioFrames > 0
    }
}
```

Delete the existing `static func makeOutputURL(for:)` from `RecordingSession`. Output URL allocation moves to the service.

Update `RecordingSessionFactory` to take the second callback. Replace the typealias added in Step 4:

```swift
typealias RecordingSessionFactory = (
    _ outputURL: URL,
    _ meeting: Meeting,
    _ inputDeviceID: AudioDeviceID?,
    _ systemAudioEnabled: Bool,
    _ onLevelUpdate: @escaping (Double) -> Void,
    _ onFailure: @escaping (Error) -> Void,
    _ onStreamFatal: @escaping (Error) -> Void
) throws -> RecordingSessionControlling
```

The fake-session test in Step 1 already uses six positional arguments to mean "ignore all callbacks"; switch the closure signatures from `_, _, _, _, _, _` to `_, _, _, _, _, _, _` (seven underscores) wherever a fake factory appears.

- [ ] **Step 6: Add the segment-aware service surface**

Replace the existing `AudioRecordingService` body in `Casablanca/Services/AudioRecordingService.swift` with the following. Properties remain the same; new initializer adds injected seams; new public methods are added; the legacy zero-arg `stopRecording()` is preserved for transitional callers.

```swift
@MainActor
@Observable
final class AudioRecordingService {
    static let systemDefaultDevicePreferenceID = AppPreferenceValue.systemDefaultRecordingInputDevice

    private(set) var isRecording = false
    private(set) var isPreparing = false
    private(set) var activeMeetingID: UUID?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var audioLevel: Double = 0
    private(set) var outputURL: URL?
    private(set) var errorMessage: String?
    private(set) var availableInputDevices: [AudioInputDevice] = []
    private(set) var selectedInputDeviceID = ""
    private(set) var isSystemAudioEnabled = true

    private var session: RecordingSessionControlling?
    private var timerTask: Task<Void, Never>?

    private let sessionStore: RecordingResumeSessionStore
    private let makeRecordingSession: RecordingSessionFactory
    private let makeFinalOutputURL: (Meeting) throws -> URL
    private let mergeSegments: ([URL], URL) throws -> TimeInterval

    weak var interruptionMonitor: RecordingInterruptionMonitor?

    init(
        sessionStore: RecordingResumeSessionStore = RecordingResumeSessionStore(),
        makeRecordingSession: @escaping RecordingSessionFactory = AudioRecordingService.defaultSessionFactory,
        makeFinalOutputURL: @escaping (Meeting) throws -> URL = AudioRecordingService.defaultFinalOutputURL,
        mergeSegments: @escaping ([URL], URL) throws -> TimeInterval = RecordingSegmentMerger.merge
    ) {
        self.sessionStore = sessionStore
        self.makeRecordingSession = makeRecordingSession
        self.makeFinalOutputURL = makeFinalOutputURL
        self.mergeSegments = mergeSegments
        refreshInputDevices(forcePreferredSelection: true)
    }

    // MARK: - Lifecycle

    func startRecording(for meeting: Meeting) async throws {
        guard session == nil else {
            throw RecordingError.activeRecordingExists
        }

        isPreparing = true
        errorMessage = nil
        audioLevel = 0
        elapsedTime = 0

        do {
            refreshInputDevices()
            _ = try sessionStore.loadSession(for: meeting.id) ?? sessionStore.createSession(
                for: meeting.id,
                systemAudioEnabled: isSystemAudioEnabled,
                selectedInputDeviceID: selectedInputDeviceID
            )

            let segmentURL = try sessionStore.nextSegmentURL(for: meeting.id, segmentNumber: 1)
            try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let session = try buildSession(
                outputURL: segmentURL,
                meeting: meeting,
                selectedInputDeviceID: selectedInputDeviceID,
                systemAudioEnabled: isSystemAudioEnabled
            )
            try await session.start()

            self.session = session
            activeMeetingID = meeting.id
            outputURL = session.outputURL
            isRecording = true
            isPreparing = false
            startTimer(from: session.startedAt)
            interruptionMonitor?.setActiveInputDevice(selectedInputDeviceID)
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            session = nil
            activeMeetingID = nil
            outputURL = nil
            throw error
        }
    }

    func pauseRecording() async throws -> RecordingResult {
        guard let session, let activeMeetingID else {
            throw RecordingError.noActiveRecording
        }

        let result = try await finalizeActiveSegment(session: session, meetingID: activeMeetingID, dropIfEmpty: false)
        clearActiveSessionState()
        elapsedTime = result.duration
        return result
    }

    func resumeRecording(for meeting: Meeting) async throws {
        guard session == nil else {
            throw RecordingError.activeRecordingExists
        }
        guard let persisted = try sessionStore.loadSession(for: meeting.id) else {
            throw RecordingError.noActiveRecording
        }

        isPreparing = true
        errorMessage = nil

        do {
            let segmentURL = try sessionStore.nextSegmentURL(
                for: meeting.id,
                segmentNumber: persisted.nextSegmentNumber
            )
            try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

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
            interruptionMonitor?.setActiveInputDevice(persisted.selectedInputDeviceID ?? selectedInputDeviceID)
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            session = nil
            activeMeetingID = nil
            outputURL = nil
            throw error
        }
    }

    func stopRecording(for meeting: Meeting) async throws -> RecordingResult {
        if let liveSession = session, activeMeetingID == meeting.id {
            _ = try await finalizeActiveSegment(session: liveSession, meetingID: meeting.id, dropIfEmpty: true)
            clearActiveSessionState()
        }

        guard let persisted = try sessionStore.loadSession(for: meeting.id) else {
            throw RecordingError.noActiveRecording
        }

        let segmentURLs = persisted.segments.map { URL(fileURLWithPath: $0.filePath) }
        guard !segmentURLs.isEmpty else {
            try? sessionStore.deleteSession(for: meeting.id)
            throw RecordingError.noCapturedAudio
        }

        let finalURL = try makeFinalOutputURL(meeting)
        let duration = try mergeSegments(segmentURLs, finalURL)
        try sessionStore.deleteSession(for: meeting.id)

        outputURL = finalURL
        elapsedTime = duration
        interruptionMonitor?.setActiveInputDevice(nil)
        return RecordingResult(outputURL: finalURL, duration: duration)
    }

    func handleSystemInterrupt(reason: RecordingInterruptionReason) async {
        guard let session, let activeMeetingID else { return }

        do {
            _ = try await finalizeActiveSegment(session: session, meetingID: activeMeetingID, dropIfEmpty: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        clearActiveSessionState()
    }

    // Transitional. Existing call site in `NotesEditorView` is migrated to `stopRecording(for:)`
    // in Task 2 Step 4; this method is deleted in Task 2 Step 4 immediately after migration.
    @discardableResult
    func stopRecording() async throws -> RecordingResult {
        guard let session else { throw RecordingError.noActiveRecording }

        defer {
            self.session = nil
            isRecording = false
            isPreparing = false
            activeMeetingID = nil
            timerTask?.cancel()
            timerTask = nil
            audioLevel = 0
        }

        do {
            let result = try await session.stop()
            outputURL = result.outputURL
            elapsedTime = result.duration
            return result
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func clearError() { errorMessage = nil }

    func setErrorMessage(_ message: String) { errorMessage = message }

    func hasResumableSession(for meetingID: UUID) -> Bool {
        (try? sessionStore.loadSession(for: meetingID)) != nil
    }

    func forwardStreamFailure(_ error: Error) {
        interruptionMonitor?.reportStreamFailure(error)
    }

    // MARK: - Existing input-device APIs (unchanged behavior)

    func refreshInputDevices(forcePreferredSelection: Bool = false) {
        let devices = Self.fetchInputDevices()
        availableInputDevices = devices

        if forcePreferredSelection {
            selectedInputDeviceID = Self.preferredInputDeviceID(in: devices) ?? devices.first?.id ?? ""
            return
        }

        if let selected = devices.first(where: { $0.id == selectedInputDeviceID }) {
            selectedInputDeviceID = selected.id
            return
        }

        selectedInputDeviceID = Self.preferredInputDeviceID(in: devices) ?? devices.first?.id ?? ""
    }

    func selectInputDevice(_ deviceID: String) async {
        guard let device = availableInputDevices.first(where: { $0.id == deviceID }) else { return }
        do {
            try session?.setMicrophoneDevice(device.deviceID)
            selectedInputDeviceID = device.id
            interruptionMonitor?.setActiveInputDevice(device.id)
        } catch {
            errorMessage = error.localizedDescription
            refreshInputDevices()
        }
    }

    func toggleSystemAudioEnabled() {
        isSystemAudioEnabled.toggle()
        session?.setSystemAudioEnabled(isSystemAudioEnabled)
    }

    static func availableRecordingInputDevices() -> [AudioInputDevice] {
        fetchInputDevices()
    }

    static func systemDefaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return deviceName(deviceID)
    }

    // MARK: - Defaults & helpers

    static func defaultSessionFactory(
        outputURL: URL,
        meeting: Meeting,
        inputDeviceID: AudioDeviceID?,
        systemAudioEnabled: Bool,
        onLevelUpdate: @escaping (Double) -> Void,
        onFailure: @escaping (Error) -> Void,
        onStreamFatal: @escaping (Error) -> Void
    ) throws -> RecordingSessionControlling {
        try RecordingSession(
            outputURL: outputURL,
            meeting: meeting,
            inputDeviceID: inputDeviceID,
            systemAudioEnabled: systemAudioEnabled,
            onLevelUpdate: onLevelUpdate,
            onFailure: onFailure,
            onStreamFatal: onStreamFatal
        )
    }

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
            { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.audioLevel = level
                }
            },
            { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            },
            { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.forwardStreamFailure(error)
                }
            }
        )
    }

    private func finalizeActiveSegment(
        session: RecordingSessionControlling,
        meetingID: UUID,
        dropIfEmpty: Bool
    ) async throws -> RecordingResult {
        let result = try await session.stop()

        if dropIfEmpty && !session.hasCapturedFrames {
            try? FileManager.default.removeItem(at: result.outputURL)
            return RecordingResult(outputURL: result.outputURL, duration: 0)
        }

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

    private func startTimer(from startDate: Date) {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                elapsedTime = Date().timeIntervalSince(startDate)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var currentInputDevice: AudioInputDevice? {
        if let selected = availableInputDevices.first(where: { $0.id == selectedInputDeviceID }) {
            return selected
        }
        return availableInputDevices.first
    }
}
```

Update existing callers of `session?.outputURL` (none outside the service) and the existing `startRecording` body — already replaced above. Existing private extensions on `AudioRecordingService` (`fetchInputDevices`, `defaultInputDeviceID`, `deviceName`, `hasInputChannels`, `preferredInputDeviceID`) remain unchanged.

- [ ] **Step 7: Add the `RecordingSegmentMerger` helper**

Append to `Casablanca/Services/AudioRecordingService.swift`:

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

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: channelCount.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian, Array.init))
        return data
    }
}
```

- [ ] **Step 8: Run the new tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task1-green -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/RecordingSegmentMergerTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS — six service tests and two merger tests green.

- [ ] **Step 9: Add a stub `RecordingInterruptionMonitor` so the `weak` reference compiles**

The full monitor lands in Task 3, but the service now references `RecordingInterruptionMonitor`. Create the placeholder file `Casablanca/Services/RecordingInterruptionMonitor.swift`:

```swift
import Foundation

@MainActor
final class RecordingInterruptionMonitor {
    func setActiveInputDevice(_ deviceID: String?) {}
    func reportStreamFailure(_ error: Error) {}
}
```

Build only (no test) to confirm the project compiles:

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task1-build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 10: Commit Task 1**

```bash
git add Casablanca/Services/AudioRecordingService.swift Casablanca/Services/RecordingInterruptionMonitor.swift CasablancaTests/MeetingStartFlowTests.swift CasablancaTests/PermissionsBehaviorTests.swift
git commit -m "feat: add pause/resume/stop state machine to AudioRecordingService"
```

---

### Task 2: Wire Pause / Resume / Stop Buttons And Cleanup Paths

Replaces the legacy Start/Stop button cluster with explicit Pause / Resume / Stop, recovers stale paused meetings on workspace entry, and cleans up resumable session folders on meeting deletion.

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `Casablanca/ViewModels/MeetingListViewModel.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing UI presentation and deletion tests**

Append to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
final class MeetingDeletionTests: XCTestCase {
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
final class MeetingWorkspacePresentationTests: XCTestCase {
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
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task2-red -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingDeletionTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL — `MeetingListViewModel` has no `removeResumableRecordingSession` parameter and the existing `MeetingWorkspacePresentation` already passes the rest, but the deletion test fails because the cleanup seam is missing.

- [ ] **Step 3: Add the cleanup seam in `MeetingListViewModel`**

In `Casablanca/ViewModels/MeetingListViewModel.swift`, change the property list and initializer:

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

In the existing `func deleteMeeting(_ meeting: Meeting) throws`, add immediately before `modelContext.delete(meeting)`:

```swift
try? removeResumableRecordingSession(meeting.id)
```

- [ ] **Step 4: Wire Pause / Resume / Stop into the workspace footer**

In `Casablanca/Views/NotesEditorView.swift`, update the `RecordingActionPhase` enum:

```swift
private enum RecordingActionPhase { case start, pause, resume, stop }
```

Replace the existing footer recording button block (the `if presentation.showsStartRecordingButton { ... } else { Button { ... stop } }` chunk) with:

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
        .disabled(recordingService.isPreparing)
    }

    if presentation.showsResumeRecordingButton {
        Button {
            Task { await resumeRecording() }
        } label: {
            Label("Resume Recording", systemImage: "record.circle")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(recordingService.isPreparing)
    }

    if presentation.showsStopRecordingButton {
        Button {
            Task { await stopRecording() }
        } label: {
            Label("Stop Recording", systemImage: "stop.circle")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(recordingService.isPreparing && presentation.showsResumeRecordingButton)
    }
}
```

Add the new handlers next to `requestRecordingStart`:

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
```

Replace the existing `stopRecording()` body in `NotesEditorView` with the segment-aware variant:

```swift
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

After this migration, **delete the transitional zero-arg `func stopRecording() async throws -> RecordingResult` from `AudioRecordingService.swift`** (the method added in Task 1 Step 6 with the comment "Transitional. Existing call site in `NotesEditorView` is migrated..."). It now has no callers.

In the existing `task(id: meeting.id)` block, append a paused-state recovery check. Replace:

```swift
.task(id: meeting.id) {
    try? ObsidianTodoSyncService.refreshTodos(for: meeting, in: modelContext)
    loadPrepMarkdown()
}
```

with:

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

- [ ] **Step 5: Run Task 2 tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task2-green -destination 'platform=macOS' -only-testing:CasablancaTests/MeetingDeletionTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS — deletion cleanup and paused presentation tests green.

- [ ] **Step 6: Commit Task 2**

```bash
git add Casablanca/Views/NotesEditorView.swift Casablanca/ViewModels/MeetingListViewModel.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: wire pause and resume buttons into recording workspace"
```

---

### Task 3: Implement `RecordingInterruptionMonitor`

Replaces the Task 1 stub with the real monitor. Subscribes to `NSWorkspace`, registers a Core Audio property listener, accepts forwarded stream failures, and emits `RecordingInterruption` start/end events on the main actor.

**Files:**
- Modify: `Casablanca/Services/RecordingInterruptionMonitor.swift`
- Create: `CasablancaTests/RecordingInterruptionMonitorTests.swift`

- [ ] **Step 1: Write the failing monitor tests**

Create `CasablancaTests/RecordingInterruptionMonitorTests.swift`:

```swift
import XCTest
@testable import Casablanca

@MainActor
final class RecordingInterruptionMonitorTests: XCTestCase {
    func testScreenSleepProducesInterruptionStartedScreenLock() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .started)
        XCTAssertEqual(events.first?.reason, .screenLock)
    }

    func testScreenWakeProducesInterruptionEndedScreenLock() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.kind, .ended)
        XCTAssertEqual(events.last?.reason, .screenLock)
    }

    func testSleepAndWakeProduceSystemSleepEvents() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(events.map(\.reason), [.systemSleep, .systemSleep])
        XCTAssertEqual(events.map(\.kind), [.started, .ended])
    }

    func testActiveDeviceRemovedProducesAudioDeviceLost() async {
        let center = NotificationCenter()
        var devices: [String] = ["BuiltInMic", "USBMic"]
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { devices },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("USBMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        devices = ["BuiltInMic"]
        monitor.deviceListChanged()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .audioDeviceLost(deviceID: "USBMic"))
    }

    func testDeviceRemovedThatIsNotActiveProducesNoEvent() async {
        let center = NotificationCenter()
        var devices: [String] = ["BuiltInMic", "USBMic"]
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { devices },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        monitor.setActiveInputDevice("BuiltInMic")

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        devices = ["BuiltInMic"]
        monitor.deviceListChanged()

        XCTAssertTrue(events.isEmpty)
    }

    func testStreamFailureWhileSystemReasonActiveIsSwallowed() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        monitor.reportStreamFailure(NSError(domain: "test", code: 1))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .systemSleep)
    }

    func testStreamFailureWithoutActiveSystemReasonProducesStreamFailureEvent() async {
        let center = NotificationCenter()
        let monitor = RecordingInterruptionMonitor(
            workspaceNotificationCenter: center,
            deviceListProvider: { [] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        var events: [RecordingInterruptionEvent] = []
        monitor.onEvent = { events.append($0) }

        let error = NSError(domain: "SCStreamErrorDomain", code: -3812, userInfo: [NSLocalizedDescriptionKey: "Stream not found"])
        monitor.reportStreamFailure(error)

        XCTAssertEqual(events.count, 1)
        if case .streamFailure(let description) = events.first?.reason {
            XCTAssertTrue(description.contains("Stream not found"))
        } else {
            XCTFail("Expected streamFailure event, got \(String(describing: events.first?.reason))")
        }
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task3-red -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingInterruptionMonitorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL — the monitor stub has no `init(workspaceNotificationCenter:...)`, no `RecordingInterruptionEvent`, no `onEvent` callback, no `deviceListChanged()`.

- [ ] **Step 3: Replace the stub with the real monitor**

Replace the contents of `Casablanca/Services/RecordingInterruptionMonitor.swift` with:

```swift
import AppKit
import CoreAudio
import Foundation

struct RecordingInterruptionEvent: Equatable {
    enum Kind: Equatable { case started, ended }

    let kind: Kind
    let reason: RecordingInterruptionReason
    let at: Date
}

@MainActor
final class RecordingInterruptionMonitor {
    var onEvent: ((RecordingInterruptionEvent) -> Void)?

    private let workspaceNotificationCenter: NotificationCenter
    private let deviceListProvider: () -> [String]
    private let now: () -> Date

    private var activeReasons: Set<RecordingInterruptionReason> = []
    private var activeInputDeviceID: String?
    private var observers: [NSObjectProtocol] = []
    private var coreAudioListenerInstalled = false

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        deviceListProvider: @escaping () -> [String] = RecordingInterruptionMonitor.defaultDeviceListProvider,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.deviceListProvider = deviceListProvider
        self.now = now
        installWorkspaceObservers()
    }

    deinit {
        for observer in observers {
            workspaceNotificationCenter.removeObserver(observer)
        }
    }

    func setActiveInputDevice(_ deviceID: String?) {
        activeInputDeviceID = deviceID
        if deviceID != nil && !coreAudioListenerInstalled {
            installCoreAudioListener()
        }
    }

    func reportStreamFailure(_ error: Error) {
        guard activeReasons.isEmpty else { return }
        let description = (error as NSError).localizedDescription
        emit(.started, reason: .streamFailure(underlyingDescription: description))
    }

    func deviceListChanged() {
        guard let activeID = activeInputDeviceID else { return }
        let currentIDs = Set(deviceListProvider())
        if !currentIDs.contains(activeID) {
            emit(.started, reason: .audioDeviceLost(deviceID: activeID))
        }
    }

    private func installWorkspaceObservers() {
        let pairs: [(Notification.Name, RecordingInterruptionEvent.Kind, RecordingInterruptionReason)] = [
            (NSWorkspace.screensDidSleepNotification, .started, .screenLock),
            (NSWorkspace.screensDidWakeNotification, .ended, .screenLock),
            (NSWorkspace.willSleepNotification, .started, .systemSleep),
            (NSWorkspace.didWakeNotification, .ended, .systemSleep)
        ]

        for (name, kind, reason) in pairs {
            let observer = workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.emit(kind, reason: reason)
                }
            }
            observers.append(observer)
        }
    }

    private func installCoreAudioListener() {
        coreAudioListenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.deviceListChanged()
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func emit(_ kind: RecordingInterruptionEvent.Kind, reason: RecordingInterruptionReason) {
        switch kind {
        case .started:
            guard !activeReasons.contains(reason) else { return }
            activeReasons.insert(reason)
        case .ended:
            guard activeReasons.contains(reason) else { return }
            activeReasons.remove(reason)
        }
        onEvent?(RecordingInterruptionEvent(kind: kind, reason: reason, at: now()))
    }

    static func defaultDeviceListProvider() -> [String] {
        AudioRecordingService.availableRecordingInputDevices().map(\.id)
    }
}
```

- [ ] **Step 4: Run the monitor tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task3-green -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingInterruptionMonitorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS — seven monitor tests green.

- [ ] **Step 5: Commit Task 3**

```bash
git add Casablanca/Services/RecordingInterruptionMonitor.swift CasablancaTests/RecordingInterruptionMonitorTests.swift
git commit -m "feat: add RecordingInterruptionMonitor"
```

---

### Task 4: Implement `RecordingInterruptionCoordinator`

The decision layer: pauses on `started`, schedules a 30-second auto-resume window, resumes on `ended` when the window has not expired and every reason in the recent set allows auto-resume.

**Files:**
- Create: `Casablanca/Services/RecordingInterruptionCoordinator.swift`
- Create: `CasablancaTests/RecordingInterruptionCoordinatorTests.swift`

- [ ] **Step 1: Write the failing coordinator tests**

Create `CasablancaTests/RecordingInterruptionCoordinatorTests.swift`:

```swift
import XCTest
@testable import Casablanca

@MainActor
final class RecordingInterruptionCoordinatorTests: XCTestCase {
    func testShortLockTriggersPauseAndAutoResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        XCTAssertEqual(env.meeting.status, .pausedRecording)

        env.advance(by: 10)
        env.fireEnd(.screenLock, atOffset: 10)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.notifier.posted.count, 2)
        XCTAssertEqual(env.meeting.status, .recording)
        XCTAssertGreaterThanOrEqual(env.saveCount, 2)
    }

    func testLongLockSkipsAutoResumeAndStaysPaused() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 31)
        env.fireEnd(.screenLock, atOffset: 31)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])
        XCTAssertEqual(env.notifier.posted.count, 1)
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    func testAudioDeviceLostNeverAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.audioDeviceLost(deviceID: "USBMic"), atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.audioDeviceLost(deviceID: "USBMic"), atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.audioDeviceLost(deviceID: "USBMic"))])
    }

    func testStreamFailureNeverAutoResumes() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.streamFailure(underlyingDescription: "stream not found"), atOffset: 0)
        await env.flush()
        env.advance(by: 1)
        env.fireEnd(.streamFailure(underlyingDescription: "stream not found"), atOffset: 1)
        await env.flush()

        XCTAssertEqual(env.service.calls.count, 1)
        XCTAssertEqual(env.service.calls.first, .handleSystemInterrupt(.streamFailure(underlyingDescription: "stream not found")))
    }

    func testOverlappingReasonsCoalescePauseAndDelayAutoResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        env.fireStart(.systemSleep, atOffset: 1)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])

        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])

        env.advance(by: 2)
        env.fireEnd(.systemSleep, atOffset: 7)
        await env.flush()
        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
    }

    func testManualStopDuringAutoResumeWindowCancelsResume() async {
        let env = makeEnv()
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.coordinator.notifyMeetingTransitioned(to: .processing)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock)])
    }

    func testResumeFailureLeavesMeetingPausedAndPostsNotification() async {
        let env = makeEnv()
        env.service.resumeError = NSError(domain: "test", code: 7)
        env.coordinator.bind(meeting: env.meeting)

        env.fireStart(.screenLock, atOffset: 0)
        await env.flush()
        env.advance(by: 5)
        env.fireEnd(.screenLock, atOffset: 5)
        await env.flush()

        XCTAssertEqual(env.service.calls, [.handleSystemInterrupt(.screenLock), .resume])
        XCTAssertEqual(env.notifier.posted.last?.title, "Could not resume recording")
        XCTAssertEqual(env.meeting.status, .pausedRecording)
    }

    private func makeEnv() -> CoordinatorEnv {
        CoordinatorEnv()
    }

    private final class CoordinatorEnv {
        let service = FakeRecordingService()
        let notifier = FakeNotifier()
        let monitor = FakeMonitor()
        var clock: TimeInterval = 0
        let meeting = Meeting(title: "Weekly Sync", date: .now, status: .recording)
        var saveCount = 0
        let coordinator: RecordingInterruptionCoordinator

        init() {
            let env = self
            coordinator = RecordingInterruptionCoordinator(
                service: service,
                monitor: monitor,
                notifier: notifier,
                autoResumeWindow: 30,
                now: { Date(timeIntervalSince1970: env.clock) },
                save: { env.saveCount += 1 }
            )
        }

        func bind(meeting: Meeting) { coordinator.bind(meeting: meeting) }

        func advance(by seconds: TimeInterval) { clock += seconds }

        func fireStart(_ reason: RecordingInterruptionReason, atOffset offset: TimeInterval) {
            clock = offset
            monitor.fire(.init(kind: .started, reason: reason, at: Date(timeIntervalSince1970: offset)))
        }

        func fireEnd(_ reason: RecordingInterruptionReason, atOffset offset: TimeInterval) {
            clock = offset
            monitor.fire(.init(kind: .ended, reason: reason, at: Date(timeIntervalSince1970: offset)))
        }

        func flush() async {
            for _ in 0..<10 {
                await Task.yield()
            }
        }
    }

    private final class FakeRecordingService: RecordingInterruptionServicing {
        enum Call: Equatable {
            case handleSystemInterrupt(RecordingInterruptionReason)
            case resume
        }
        var calls: [Call] = []
        var resumeError: Error?

        func handleSystemInterrupt(reason: RecordingInterruptionReason) async {
            calls.append(.handleSystemInterrupt(reason))
        }

        func resumeRecording(for meeting: Meeting) async throws {
            calls.append(.resume)
            if let error = resumeError { throw error }
        }
    }

    private final class FakeNotifier: RecordingInterruptionNotifying {
        struct Post: Equatable {
            let title: String
            let body: String
        }
        var posted: [Post] = []
        func post(title: String, body: String) {
            posted.append(.init(title: title, body: body))
        }
    }

    private final class FakeMonitor: RecordingInterruptionEmitting {
        var onEvent: ((RecordingInterruptionEvent) -> Void)?
        func fire(_ event: RecordingInterruptionEvent) { onEvent?(event) }
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task4-red -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingInterruptionCoordinatorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL — `RecordingInterruptionCoordinator`, `RecordingInterruptionServicing`, `RecordingInterruptionNotifying`, `RecordingInterruptionEmitting`, and `RecordingInterruptionMonitor.onEvent` integration do not exist.

- [ ] **Step 3: Implement the coordinator and protocols**

Create `Casablanca/Services/RecordingInterruptionCoordinator.swift`:

```swift
import Foundation

protocol RecordingInterruptionServicing: AnyObject {
    func handleSystemInterrupt(reason: RecordingInterruptionReason) async
    func resumeRecording(for meeting: Meeting) async throws
}

protocol RecordingInterruptionNotifying: AnyObject {
    func post(title: String, body: String)
}

protocol RecordingInterruptionEmitting: AnyObject {
    var onEvent: ((RecordingInterruptionEvent) -> Void)? { get set }
}

extension AudioRecordingService: RecordingInterruptionServicing {}
extension RecordingInterruptionMonitor: RecordingInterruptionEmitting {}

@MainActor
final class RecordingInterruptionCoordinator {
    struct InterruptionRecord: Equatable {
        let reason: RecordingInterruptionReason
        let startedAt: Date
        var endedAt: Date?
        var resumedAutomatically: Bool
    }

    private(set) var recentEvents: [InterruptionRecord] = []

    private weak var service: RecordingInterruptionServicing?
    private weak var monitor: RecordingInterruptionEmitting?
    private weak var notifier: RecordingInterruptionNotifying?
    private let autoResumeWindow: TimeInterval
    private let now: () -> Date
    private let save: () -> Void

    private var meeting: Meeting?
    private var activeReasons: Set<RecordingInterruptionReason> = []
    private var startedAt: Date?
    private var resumeAllowedForActiveWindow = true
    private var deadlineTask: Task<Void, Never>?

    init(
        service: RecordingInterruptionServicing,
        monitor: RecordingInterruptionEmitting,
        notifier: RecordingInterruptionNotifying,
        autoResumeWindow: TimeInterval = 30,
        now: @escaping () -> Date = Date.init,
        save: @escaping () -> Void = {}
    ) {
        self.service = service
        self.monitor = monitor
        self.notifier = notifier
        self.autoResumeWindow = autoResumeWindow
        self.now = now
        self.save = save
        monitor.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
    }

    func bind(meeting: Meeting?) {
        self.meeting = meeting
        cancelPendingDeadline()
        activeReasons.removeAll()
        startedAt = nil
    }

    func notifyMeetingTransitioned(to status: MeetingStatus) {
        guard status != .pausedRecording else { return }
        cancelPendingDeadline()
        activeReasons.removeAll()
        startedAt = nil
    }

    private func handle(event: RecordingInterruptionEvent) {
        switch event.kind {
        case .started: handleStart(event)
        case .ended: handleEnd(event)
        }
    }

    private func handleStart(_ event: RecordingInterruptionEvent) {
        let isFirst = activeReasons.isEmpty
        activeReasons.insert(event.reason)
        if !event.reason.allowsAutoResume {
            resumeAllowedForActiveWindow = false
        }

        guard isFirst else {
            appendRecentEvent(InterruptionRecord(reason: event.reason, startedAt: event.at, endedAt: nil, resumedAutomatically: false))
            return
        }

        resumeAllowedForActiveWindow = event.reason.allowsAutoResume
        startedAt = event.at
        appendRecentEvent(InterruptionRecord(reason: event.reason, startedAt: event.at, endedAt: nil, resumedAutomatically: false))
        Task { @MainActor [service] in
            await service?.handleSystemInterrupt(reason: event.reason)
        }
        meeting?.status = .pausedRecording
        save()
        notifier?.post(title: "Recording paused", body: bodyForPause(event.reason))
        scheduleDeadline()
    }

    private func handleEnd(_ event: RecordingInterruptionEvent) {
        activeReasons.remove(event.reason)
        if let lastIdx = recentEvents.lastIndex(where: { $0.reason == event.reason && $0.endedAt == nil }) {
            recentEvents[lastIdx].endedAt = event.at
        }
        guard activeReasons.isEmpty else { return }

        defer { startedAt = nil; resumeAllowedForActiveWindow = true }
        cancelPendingDeadline()

        guard let meeting else { return }
        guard resumeAllowedForActiveWindow else { return }
        guard let startedAt else { return }
        guard event.at.timeIntervalSince(startedAt) < autoResumeWindow else { return }
        guard now().timeIntervalSince(startedAt) < autoResumeWindow else { return }

        let reasonForBody = event.reason
        Task { @MainActor [weak self, service, notifier] in
            do {
                try await service?.resumeRecording(for: meeting)
                if let self {
                    if let lastIdx = self.recentEvents.indices.last {
                        self.recentEvents[lastIdx].resumedAutomatically = true
                    }
                    self.meeting?.status = .recording
                    self.save()
                    notifier?.post(
                        title: "Recording resumed",
                        body: "Continued after \(self.bodyForResume(reasonForBody))"
                    )
                } else {
                    notifier?.post(title: "Recording resumed", body: "")
                }
            } catch {
                notifier?.post(title: "Could not resume recording", body: error.localizedDescription)
            }
        }
    }

    private func appendRecentEvent(_ record: InterruptionRecord) {
        recentEvents.append(record)
        if recentEvents.count > 5 {
            recentEvents.removeFirst(recentEvents.count - 5)
        }
    }

    private func scheduleDeadline() {
        cancelPendingDeadline()
        let window = autoResumeWindow
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            self?.resumeAllowedForActiveWindow = false
        }
    }

    private func cancelPendingDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func bodyForPause(_ reason: RecordingInterruptionReason) -> String {
        switch reason {
        case .screenLock: return "Screen locked."
        case .systemSleep: return "System went to sleep."
        case .audioDeviceLost(let id): return "Microphone disconnected (\(id))."
        case .streamFailure(let description): return description
        }
    }

    private func bodyForResume(_ reason: RecordingInterruptionReason) -> String {
        switch reason {
        case .screenLock: return "screen unlock."
        case .systemSleep: return "system wake."
        case .audioDeviceLost: return "microphone reconnect."
        case .streamFailure: return "stream recovery."
        }
    }
}
```

- [ ] **Step 4: Run the coordinator tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task4-green -destination 'platform=macOS' -only-testing:CasablancaTests/RecordingInterruptionCoordinatorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS — seven coordinator tests green.

- [ ] **Step 5: Commit Task 4**

```bash
git add Casablanca/Services/RecordingInterruptionCoordinator.swift CasablancaTests/RecordingInterruptionCoordinatorTests.swift
git commit -m "feat: add RecordingInterruptionCoordinator"
```

---

### Task 5: Add The macOS User-Notification Adapter

A thin `UNUserNotificationCenter` wrapper conforming to `RecordingInterruptionNotifying`. Production posts notifications; on first use it requests authorization once. If the user declines, posts become no-ops.

**Files:**
- Create: `Casablanca/Services/RecordingNotificationCenter.swift`

- [ ] **Step 1: Implement the notifier**

Create `Casablanca/Services/RecordingNotificationCenter.swift`:

```swift
import Foundation
import UserNotifications

@MainActor
final class RecordingNotificationCenter: RecordingInterruptionNotifying {
    private let center: UNUserNotificationCenter
    private var didRequestAuthorization = false
    private var isAuthorized = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(title: String, body: String) {
        Task { @MainActor in
            await ensureAuthorization()
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func ensureAuthorization() async {
        if didRequestAuthorization { return }
        didRequestAuthorization = true
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run:

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task5-build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit Task 5**

```bash
git add Casablanca/Services/RecordingNotificationCenter.swift
git commit -m "feat: add UserNotifications-based interruption notifier"
```

---

### Task 6: Add The Inline Auto-Pause Indicator In `NotesEditorView`

Renders a single quiet line above the recording chrome when the coordinator's `recentEvents` has at least one record for the active meeting in the last 5 minutes. Reads from the coordinator passed in via `ContentView`.

**Files:**
- Modify: `Casablanca/Views/NotesEditorView.swift`
- Modify: `CasablancaTests/MeetingStartFlowTests.swift`

- [ ] **Step 1: Write the failing presentation test**

Append to `CasablancaTests/MeetingStartFlowTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task6-red -destination 'platform=macOS' -only-testing:CasablancaTests/AutoPauseIndicatorPresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: FAIL — `AutoPauseIndicatorPresentation` does not exist.

- [ ] **Step 3: Add the presentation struct and inline view**

In `Casablanca/Views/NotesEditorView.swift`, add this struct above `NotesEditorView`:

```swift
struct AutoPauseIndicatorPresentation {
    let records: [RecordingInterruptionCoordinator.InterruptionRecord]
    let referenceDate: Date

    private static let visibilityWindow: TimeInterval = 300

    var shouldShow: Bool {
        guard let latest = records.last, let endedAt = latest.endedAt else { return false }
        return referenceDate.timeIntervalSince(endedAt) < Self.visibilityWindow
    }

    var summary: String {
        guard let latest = records.last, let endedAt = latest.endedAt else { return "" }
        let duration = Int(endedAt.timeIntervalSince(latest.startedAt).rounded())
        let timeOfDay = formattedTime(latest.startedAt)
        let suffix = latest.resumedAutomatically ? "recording resumed." : "tap Resume to continue."
        let cause: String
        switch latest.reason {
        case .screenLock: cause = "Auto-paused at \(timeOfDay) for \(duration)s"
        case .systemSleep: cause = "Auto-paused at \(timeOfDay) (sleep, \(duration)s)"
        case .audioDeviceLost: cause = "Auto-paused at \(timeOfDay) — microphone disconnected"
        case .streamFailure: cause = "Auto-paused at \(timeOfDay) — recording stream stopped"
        }
        return "\(cause) — \(suffix)"
    }

    func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
```

Add a `coordinator: RecordingInterruptionCoordinator?` argument to `NotesEditorView` and store it as `@Bindable` — declare just below the existing `@Bindable var recordingService: AudioRecordingService`:

```swift
var interruptionCoordinator: RecordingInterruptionCoordinator?
```

In the `header` property, immediately above the existing `HStack(alignment: .center)` block, insert:

```swift
if let presentation = autoPauseIndicatorPresentation, presentation.shouldShow {
    Text(presentation.summary)
        .font(.caption)
        .foregroundStyle(Color.textSecondary)
        .padding(.bottom, CasaSpace.xs)
}
```

Add a computed property at the bottom of `NotesEditorView` (next to `presentation`):

```swift
private var autoPauseIndicatorPresentation: AutoPauseIndicatorPresentation? {
    guard let interruptionCoordinator else { return nil }
    return AutoPauseIndicatorPresentation(
        records: interruptionCoordinator.recentEvents.suffix(5).map { $0 },
        referenceDate: Date()
    )
}
```

- [ ] **Step 4: Run the indicator tests and verify they pass**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task6-green -destination 'platform=macOS' -only-testing:CasablancaTests/AutoPauseIndicatorPresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: PASS — three indicator tests green.

- [ ] **Step 5: Commit Task 6**

```bash
git add Casablanca/Views/NotesEditorView.swift CasablancaTests/MeetingStartFlowTests.swift
git commit -m "feat: render inline auto-pause indicator in notes editor"
```

---

### Task 7: Wire The Coordinator Into The App

Instantiate the monitor, coordinator, and notifier in `ContentView`. Pass the coordinator down to `NotesEditorView`. Bind/unbind the active meeting as the user navigates so the coordinator only auto-resumes for the meeting currently in the workspace.

**Files:**
- Modify: `Casablanca/Views/ContentView.swift`
- Modify: `Casablanca/Views/NotesEditorView.swift`

- [ ] **Step 1: Wire the new objects in `ContentView`**

In `Casablanca/Views/ContentView.swift`, add `@State` properties next to `recordingService`:

```swift
@State private var interruptionMonitor = RecordingInterruptionMonitor()
@State private var interruptionNotifier = RecordingNotificationCenter()
@State private var interruptionCoordinator: RecordingInterruptionCoordinator?
```

Replace the existing `recordingService` initialization wiring by adding a `.task` modifier on the outer `NavigationSplitView` (next to the existing `.task` block) that ties the components together exactly once:

```swift
.task {
    if interruptionCoordinator == nil {
        recordingService.interruptionMonitor = interruptionMonitor
        let context = modelContext
        interruptionCoordinator = RecordingInterruptionCoordinator(
            service: recordingService,
            monitor: interruptionMonitor,
            notifier: interruptionNotifier,
            save: { try? context.save() }
        )
    }
}
```

Update the `NotesEditorView` call site in `detailView` to pass the coordinator:

```swift
NotesEditorView(
    meeting: meeting,
    recordingService: recordingService,
    interruptionCoordinator: interruptionCoordinator,
    autoStartRecording: meeting.status == .recording,
    onBack: {
        viewModel.selectedMeeting = nil
    }
)
```

- [ ] **Step 2: Bind the active meeting in `NotesEditorView`**

In `Casablanca/Views/NotesEditorView.swift`, accept the coordinator as a non-optional argument when present. Update the existing `task(id: meeting.id)` block (the one we already touched in Task 2) so binding happens on appear:

```swift
.task(id: meeting.id) {
    interruptionCoordinator?.bind(meeting: meeting)
    try? ObsidianTodoSyncService.refreshTodos(for: meeting, in: modelContext)
    loadPrepMarkdown()

    if meeting.status == .pausedRecording && !recordingService.hasResumableSession(for: meeting.id) {
        recordingActionPhase = .resume
        recordingService.setErrorMessage("This paused recording can no longer be resumed.")
        meeting.status = .notesOnly
        save()
    }
}
.onDisappear {
    interruptionCoordinator?.bind(meeting: nil)
}
```

In `pauseRecording()` (added in Task 2), after `meeting.status = .pausedRecording`, add `interruptionCoordinator?.notifyMeetingTransitioned(to: .pausedRecording)` (no-op for the coordinator's reset path but explicit for future hooks). In `resumeRecording()` after the success branch's `meeting.status = .recording`, add `interruptionCoordinator?.notifyMeetingTransitioned(to: .recording)`. In `stopRecording()` after `meeting.status = .processing`, add `interruptionCoordinator?.notifyMeetingTransitioned(to: .processing)`.

- [ ] **Step 3: Build and verify the app still compiles**

Run:

```bash
xcodebuild build -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-task7-build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit Task 7**

```bash
git add Casablanca/Views/ContentView.swift Casablanca/Views/NotesEditorView.swift
git commit -m "feat: instantiate interruption coordinator in app shell"
```

---

### Task 8: Full Regression And Manual Sanity Pass

**Files:**
- Test: `CasablancaTests/*`
- Manual: app smoke test

- [ ] **Step 1: Run the focused regression suite**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-regression -destination 'platform=macOS' -only-testing:CasablancaTests/AudioRecordingServicePauseResumeTests -only-testing:CasablancaTests/RecordingSegmentMergerTests -only-testing:CasablancaTests/MeetingDeletionTests -only-testing:CasablancaTests/MeetingWorkspacePresentationTests -only-testing:CasablancaTests/RecordingInterruptionMonitorTests -only-testing:CasablancaTests/RecordingInterruptionCoordinatorTests -only-testing:CasablancaTests/AutoPauseIndicatorPresentationTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Run the full suite**

Run:

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -derivedDataPath .build/xcode-auto-pause-full -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: full suite passes with `0 failures`.

- [ ] **Step 3: Manual sanity pass**

Build and run the app locally. Verify each scenario:

```text
1. Start a recording on a meeting. Lock the laptop for ~10 seconds, unlock.
   - Recording continues. Header shows: "Auto-paused at HH:MM for ~10s — recording resumed."
   - macOS shows two notifications: "Recording paused" then "Recording resumed".
2. Start a recording. Lock for ~60 seconds, unlock.
   - Meeting status is "Paused". Resume Recording button visible.
   - macOS shows only "Recording paused" notification.
   - Tap Resume → recording continues, then Stop. Final WAV plays back as one continuous file.
3. Start a recording with a USB microphone. Unplug the mic.
   - Meeting goes to Paused with notification "Recording paused — Microphone disconnected (...)".
   - Replug the mic. Meeting STAYS paused (no auto-resume).
   - Tap Resume → recording continues with the same mic.
4. Force-quit Casablanca during a paused recording.
   - Reopen the app. Open the same meeting.
   - Resume Recording button is visible. Tap Resume → record more → Stop.
   - Final WAV contains both segments.
5. Start a fresh recording on a meeting where mic permission has already been denied (revoke in System Settings before opening the workspace, then tap Start Recording).
   - The pre-existing "Recording Error" alert flow appears with Retry / Open Privacy Settings / Back to Notes (NOT the new pause path). Mid-recording mic revocation by contrast will surface as a stream-failure auto-pause and is acceptable; the manual-resume button will then prompt for permission again.
```

Expected: every step matches. Any deviation goes back to the failing-test phase of the relevant task.

- [ ] **Step 4: Commit the verified implementation**

```bash
git add -A
git commit -m "feat: auto-pause recording on system interruption"
```

(If `git status` reports nothing to commit at this step, skip.)
