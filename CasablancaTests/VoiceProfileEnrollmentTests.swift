import XCTest
@testable import Casablanca

/// A diarizer whose `embedding` records the ranges it was asked for and runs
/// a hook first (to suspend, flip the setting, or wait for cancellation).
private final class RecordingEmbeddingDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(url: URL, ranges: [ClosedRange<Double>])] = []
    private var _sawCancellation = false
    let result: [Float]
    let hook: @Sendable () async throws -> Void

    init(result: [Float] = [1, 0], hook: @escaping @Sendable () async throws -> Void = {}) {
        self.result = result
        self.hook = hook
    }

    var requests: [(url: URL, ranges: [ClosedRange<Double>])] { lock.withLock { _requests } }
    var sawCancellation: Bool { lock.withLock { _sawCancellation } }

    func prepareModels(progress: @escaping @Sendable (Double?) -> Void) async throws {}

    func diarize(trackURL: URL) async throws -> DiarizationOutput {
        XCTFail("Remember voice must never diarize a whole track")
        return DiarizationOutput(turns: [], embeddings: [:])
    }

    func embedding(trackURL: URL, ranges: [ClosedRange<Double>]) async throws -> [Float] {
        lock.withLock { _requests.append((trackURL, ranges)) }
        do {
            try await hook()
        } catch {
            if error is CancellationError { lock.withLock { _sawCancellation = true } }
            throw error
        }
        return result
    }
}

@MainActor
final class VoiceProfileEnrollmentTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProfileEnrollmentTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("VoiceProfiles/profiles.sealed")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeStore(enabled: LockedFlag = LockedFlag(true)) -> VoiceProfileStore {
        VoiceProfileStore(fileURL: fileURL, keyStore: InMemoryKeyStore(), isEnabled: { enabled.value })
    }

    private let track = URL(fileURLWithPath: "/tmp/system.m4a")

    /// Only the consented speaker's selected ranges are analysed.
    func testOnlyTheSelectedRangesAreAnalysed() async throws {
        let trackFile = directory.appendingPathComponent("system.m4a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: trackFile)
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.systemTrackFileURL = trackFile.path
        meeting.speakers = [
            SpeakerInfo(id: "S1", displayName: "Kim", source: .system, isUser: false, nameConfirmed: true),
            SpeakerInfo(id: "S2", displayName: "Speaker 2", source: .system, isUser: false, nameConfirmed: false),
        ]
        meeting.speakerSegments = [
            SpeakerSegment(start: 0, end: 25, speakerID: "S1", text: "x", words: nil),
            SpeakerSegment(start: 25, end: 60, speakerID: "S2", text: "x", words: nil),
            SpeakerSegment(start: 60, end: 80, speakerID: "S1", text: "x", words: nil),
        ]
        let sample = try XCTUnwrap(SpeakerClipSelector.voiceSample(for: "S1", meeting: meeting))
        let diarizer = RecordingEmbeddingDiarizer()

        let profile = try await VoiceProfileEnrollment(diarizer: diarizer, store: makeStore())
            .remember(name: "Kim", trackURL: sample.url, ranges: sample.ranges, consentGiven: true)

        XCTAssertEqual(diarizer.requests.count, 1, "One embedding, never one per speaker or segment")
        XCTAssertEqual(diarizer.requests.first?.url, trackFile)
        XCTAssertEqual(diarizer.requests.first?.ranges, [0...25, 60...65], "S2's 25–60 s is never analysed; 30 s in all")
        XCTAssertEqual(profile.name, "Kim")
    }

    func testNoConsentAnalysesNothing() async throws {
        let diarizer = RecordingEmbeddingDiarizer()

        do {
            try await VoiceProfileEnrollment(diarizer: diarizer, store: makeStore())
                .remember(name: "Kim", trackURL: track, ranges: [0...5], consentGiven: false)
            XCTFail("Expected consentRequired")
        } catch {
            XCTAssertEqual(error as? VoiceProfileStore.StoreError, .consentRequired)
        }
        XCTAssertTrue(diarizer.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A request that can never be saved analyses no audio at all.
    func testBlankNameOrDisabledAnalysesNothing() async throws {
        let diarizer = RecordingEmbeddingDiarizer()
        let cases: [(name: String, enabled: Bool, expected: VoiceProfileStore.StoreError)] = [
            ("  ", true, .emptyName),
            ("Kim", false, .disabled),
        ]
        for request in cases {
            do {
                try await VoiceProfileEnrollment(diarizer: diarizer, store: makeStore(enabled: LockedFlag(request.enabled)))
                    .remember(name: request.name, trackURL: track, ranges: [0...5], consentGiven: true)
                XCTFail("Expected \(request.expected)")
            } catch {
                XCTAssertEqual(error as? VoiceProfileStore.StoreError, request.expected)
            }
        }
        XCTAssertTrue(diarizer.requests.isEmpty, "No voice was analysed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// The user turns voice profiles off while the voice is being analysed:
    /// the late save is refused and nothing is written.
    func testTurningOffDuringAnalysisWritesNothing() async throws {
        let enabled = LockedFlag(true)
        let diarizer = RecordingEmbeddingDiarizer(hook: { enabled.value = false })

        do {
            try await VoiceProfileEnrollment(diarizer: diarizer, store: makeStore(enabled: enabled))
                .remember(name: "Kim", trackURL: track, ranges: [0...5], consentGiven: true)
            XCTFail("Expected disabled")
        } catch {
            XCTAssertEqual(error as? VoiceProfileStore.StoreError, .disabled)
        }
        XCTAssertEqual(diarizer.requests.count, 1, "The analysis did run; the save was refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCancellingStopsTheAnalysisAndSavesNothing() async throws {
        let diarizer = RecordingEmbeddingDiarizer(hook: { try await Task.sleep(for: .seconds(30)) })
        let enrollment = VoiceProfileEnrollment(diarizer: diarizer, store: makeStore())
        let started = ContinuousClock.now

        let task = Task {
            try await enrollment.remember(name: "Kim", trackURL: track, ranges: [0...5], consentGiven: true)
        }
        try await waitUntil { !diarizer.requests.isEmpty }
        task.cancel()
        let result = await task.result

        guard case .failure = result else { return XCTFail("A cancelled analysis must not succeed") }
        XCTAssertTrue(diarizer.sawCancellation, "The analysis itself was cancelled")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAnalysisTimesOut() async throws {
        let diarizer = RecordingEmbeddingDiarizer(hook: { try await Task.sleep(for: .seconds(30)) })
        var enrollment = VoiceProfileEnrollment(diarizer: diarizer, store: makeStore())
        enrollment.timeout = .milliseconds(100)
        XCTAssertEqual(VoiceProfileEnrollment.defaultTimeout, .seconds(120))

        do {
            try await enrollment.remember(name: "Kim", trackURL: track, ranges: [0...5], consentGiven: true)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(error is VoiceProfileEnrollment.TimeoutError, "Got \(error)")
        }
        XCTAssertTrue(diarizer.sawCancellation, "The timed-out analysis is cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - The sheet's model

    func testSaveNeedsConsent() {
        let model = SaveVoiceProfileModel(onSave: { _ in XCTFail("No save without consent") })
        XCTAssertFalse(model.canSave)
        model.save { XCTFail("No save without consent") }
        XCTAssertFalse(model.isSaving)

        model.consentGiven = true
        XCTAssertTrue(model.canSave)
    }

    /// Cancel works while saving: it cancels the running analysis, and the
    /// sheet neither closes as saved nor shows an error.
    func testCancelWhileSavingCancelsTheWork() async throws {
        let cancelled = LockedFlag(false)
        let model = SaveVoiceProfileModel(onSave: { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.value = true
                throw error
            }
        })
        model.consentGiven = true

        model.save { XCTFail("A cancelled save does not finish") }
        XCTAssertTrue(model.isSaving)
        XCTAssertFalse(model.canSave)

        model.cancel()
        XCTAssertTrue(model.isSaving, "Still saving until the work has really ended")
        XCTAssertFalse(model.canSave)
        try await waitUntil { !model.isSaving }

        XCTAssertTrue(cancelled.value, "The work itself was cancelled")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canSave, "The user can try again")
    }

    func testExistingProfileNote() {
        XCTAssertEqual(SaveVoiceProfileSheet.existingProfileNote(name: "Kim", sampleCount: 2), "Adds a sample to Kim (2 samples)")
        XCTAssertEqual(SaveVoiceProfileSheet.existingProfileNote(name: "Kim", sampleCount: 1), "Adds a sample to Kim (1 sample)")
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
