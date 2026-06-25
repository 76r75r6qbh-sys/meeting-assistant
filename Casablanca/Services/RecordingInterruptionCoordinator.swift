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
    private var resumeTask: Task<Void, Never>?

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
        resumeTask?.cancel()
        resumeTask = nil
        activeReasons.removeAll()
        startedAt = nil
        recentEvents.removeAll()
    }

    func notifyMeetingTransitioned(to status: MeetingStatus) {
        guard status != .pausedRecording else { return }
        cancelPendingDeadline()
        resumeTask?.cancel()
        resumeTask = nil
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
        let recordIndexAtDispatch = recentEvents.indices.last
        let capturedMeeting = meeting
        resumeTask = Task { @MainActor [weak self, service, notifier] in
            do {
                try await service?.resumeRecording(for: capturedMeeting)
                if let self {
                    if let lastIdx = recordIndexAtDispatch, lastIdx < self.recentEvents.count {
                        self.recentEvents[lastIdx].resumedAutomatically = true
                    }
                    // Only mutate the bound meeting if it's still the one we resumed.
                    if self.meeting?.id == capturedMeeting.id {
                        self.meeting?.status = .recording
                        self.save()
                    }
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
        case .displayUnavailable: return "No display available for system audio (lid closed?)."
        case .streamFailure(let description): return description
        }
    }

    private func bodyForResume(_ reason: RecordingInterruptionReason) -> String {
        switch reason {
        case .screenLock: return "screen unlock."
        case .systemSleep: return "system wake."
        case .audioDeviceLost: return "microphone reconnect."
        case .displayUnavailable: return "display reconnect."
        case .streamFailure: return "stream recovery."
        }
    }
}
