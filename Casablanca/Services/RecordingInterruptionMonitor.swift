import AppKit
import CoreAudio
import CoreGraphics
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
    private let screenNotificationCenter: NotificationCenter
    private let deviceListProvider: () -> [String]
    private let displayListProvider: () -> [CGDirectDisplayID]
    private let now: () -> Date

    private var activeReasons: Set<RecordingInterruptionReason> = []
    private var activeInputDeviceID: String?
    private var observers: [NSObjectProtocol] = []
    private var screenObservers: [NSObjectProtocol] = []
    private var coreAudioListenerInstalled = false
    private var coreAudioListenerBlock: AudioObjectPropertyListenerBlock?
    private var coreAudioListenerAddress: AudioObjectPropertyAddress?

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenNotificationCenter: NotificationCenter = .default,
        deviceListProvider: @escaping () -> [String] = RecordingInterruptionMonitor.defaultDeviceListProvider,
        displayListProvider: @escaping () -> [CGDirectDisplayID] = RecordingInterruptionMonitor.defaultOnlineDisplayList,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.screenNotificationCenter = screenNotificationCenter
        self.deviceListProvider = deviceListProvider
        self.displayListProvider = displayListProvider
        self.now = now
        installWorkspaceObservers()
        installScreenParameterObserver()
    }

    deinit {
        for observer in observers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        for observer in screenObservers {
            screenNotificationCenter.removeObserver(observer)
        }
        if let block = coreAudioListenerBlock, var address = coreAudioListenerAddress {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
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

    /// Re-evaluates whether a capturable display is available and starts/ends a
    /// `.displayUnavailable` interruption accordingly. Gated on `activeInputDeviceID`
    /// (set only while recording) so display changes never pause a meeting that
    /// isn't recording. `emit` de-dupes, so repeated changes are idempotent.
    ///
    /// System audio is captured by ScreenCaptureKit off a display; with the lid
    /// closed and no external monitor there is no active display, so capture
    /// can't run. Pausing here (rather than recording microphone-only) is the
    /// desired behavior — the recording resumes automatically when a display
    /// returns and full audio is available again.
    func reportDisplayConfigurationChanged() {
        guard activeInputDeviceID != nil else { return }
        if displayListProvider().isEmpty {
            emit(.started, reason: .displayUnavailable)
        } else {
            emit(.ended, reason: .displayUnavailable)
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
                    guard let self else { return }
                    self.emit(kind, reason: reason)
                    // On any wake/unlock, re-evaluate display availability so a
                    // `.displayUnavailable` interruption gets its `.ended` even if
                    // `didChangeScreenParametersNotification` doesn't re-fire on
                    // wake. Without this, display-unavailable could stay in the
                    // coordinator's active-reason set forever and block auto-resume
                    // (the screen-lock/sleep reason ends here, but display-unavailable
                    // would not), leaving the recording stuck paused.
                    if kind == .ended {
                        self.reportDisplayConfigurationChanged()
                    }
                }
            }
            observers.append(observer)
        }
    }

    private func installScreenParameterObserver() {
        // `didChangeScreenParametersNotification` fires when displays are added,
        // removed, or reconfigured — including the lid opening/closing and
        // docking/undocking, which is exactly when system-audio capturability
        // changes. It is posted on the default center, not NSWorkspace's.
        let observer = screenNotificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reportDisplayConfigurationChanged()
            }
        }
        screenObservers.append(observer)
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
        coreAudioListenerBlock = block
        coreAudioListenerAddress = address
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

    /// The currently *online* displays. Deliberately uses online (not *active*)
    /// displays: a closed-lid built-in with no external monitor goes offline, so
    /// this is empty exactly when ScreenCaptureKit has nothing to capture. An
    /// idle display that merely went to sleep (lid open, screen dimmed) stays
    /// online — so a recording left running unattended is NOT falsely paused,
    /// since ScreenCaptureKit can still capture from an online-but-asleep display.
    static func defaultOnlineDisplayList() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
