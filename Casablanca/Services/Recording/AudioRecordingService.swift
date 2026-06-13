import CoreAudio
import Foundation
import Observation

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
            defer { clearActiveSessionState() }
            _ = try await finalizeActiveSegment(session: liveSession, meetingID: meeting.id, dropIfEmpty: true)
        }

        guard let persisted = try sessionStore.loadSession(for: meeting.id) else {
            throw RecordingError.noActiveRecording
        }

        let segmentURLs = persisted.segments.map { URL(fileURLWithPath: $0.filePath) }
        guard !segmentURLs.isEmpty else {
            bestEffort("delete recording session", Log.recording) {
                try sessionStore.deleteSession(for: meeting.id)
            }
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
            bestEffort("remove empty segment file", Log.recording) {
                try FileManager.default.removeItem(at: result.outputURL)
            }
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
}
