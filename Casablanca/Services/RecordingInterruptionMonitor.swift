import AppKit
import CoreAudio
import Foundation

extension NSWorkspace {
    // macOS does not expose screen lock notifications publicly on `NSWorkspace`.
    // The platform posts well-known names on the distributed notification center
    // (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`); we declare matching
    // `Notification.Name` constants here so production code subscribes via the same
    // identifier the system uses, and tests can post the same name on a fake center.
    static let screensDidLockNotification = Notification.Name("com.apple.screenIsLocked")
    static let screensDidUnlockNotification = Notification.Name("com.apple.screenIsUnlocked")
}

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
            (NSWorkspace.screensDidLockNotification, .started, .screenLock),
            (NSWorkspace.screensDidUnlockNotification, .ended, .screenLock),
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
