import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

struct RecordingInterruptionEvent: Equatable {
    enum Kind: Equatable { case started, ended }

    let kind: Kind
    let reason: RecordingInterruptionReason
    let at: Date
    /// Set only by the IOKit sleep path. The kernel is holding the sleep for
    /// this process while it finalizes; running this releases the hold, so the
    /// consumer must run it exactly when it is done — and on every path out,
    /// including "nothing was recording". Everything else leaves it `nil`.
    let completion: (@MainActor () -> Void)?

    init(
        kind: Kind,
        reason: RecordingInterruptionReason,
        at: Date,
        completion: (@MainActor () -> Void)? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.at = at
        self.completion = completion
    }

    /// `completion` is deliberately excluded: a closure has no identity worth
    /// comparing, and equality here is only ever about what happened and when.
    static func == (lhs: RecordingInterruptionEvent, rhs: RecordingInterruptionEvent) -> Bool {
        lhs.kind == rhs.kind && lhs.reason == rhs.reason && lhs.at == rhs.at
    }
}

/// A root-power-domain message, normalized so the monitor never touches IOKit
/// types directly (and tests never have to).
enum SystemSleepGateMessage: Equatable {
    /// The system is *asking* whether it may idle-sleep. Answering is mandatory;
    /// vetoing is not this layer's job (the recording holds a power assertion).
    case canSystemSleep(notificationID: Int)
    /// The system is going to sleep and waits (~30 s) for
    /// `allowPowerChange(notificationID:)` before suspending the process.
    case willSleep(notificationID: Int)
    case hasPoweredOn(notificationID: Int)
}

/// The IOKit power-change deferral behind a seam, so a unit test never calls
/// `IORegisterForSystemPower`. Implementations are main-queue confined: `start`
/// schedules its notification port on the main queue, so every callback — and
/// therefore every `allowPowerChange` — happens there too.
protocol SystemSleepGating: AnyObject {
    /// Registers for root-power-domain messages. `false` means the registration
    /// failed and there is no deferral to hand out, so the caller must fall back
    /// to `NSWorkspace`'s (undeferrable) sleep notifications.
    func start(onMessage: @escaping @MainActor (SystemSleepGateMessage) -> Void) -> Bool
    /// Tells the kernel this process is done with the pending power change.
    func allowPowerChange(notificationID: Int)
    func stop()
}

@MainActor
final class RecordingInterruptionMonitor {
    var onEvent: ((RecordingInterruptionEvent) -> Void)?
    /// Fires with `true` when the login session locks and `false` when it
    /// unlocks. Deliberately NOT an interruption: the recording holds a power
    /// assertion, so capture keeps running behind the lock screen. The consumer
    /// uses it for recovery decisions (retrying a failed resume once the user is
    /// back), not for pausing.
    var onSessionLockChanged: ((Bool) -> Void)?

    /// Whether the login session is locked right now. The hook for a follow-up
    /// we deliberately did not build yet: if on-device testing shows `SCStream`
    /// dying while the session is locked, a `.streamFailure` raised during an
    /// active lock should become auto-resumable on unlock.
    private(set) var isSessionLocked = false

    private let workspaceNotificationCenter: NotificationCenter
    private let screenNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter
    private let deviceListProvider: () -> [String]
    private let displayListProvider: () -> [CGDirectDisplayID]
    private let now: () -> Date
    /// `nonisolated(unsafe)`: only ever read on the main actor (or from
    /// `deinit`, which is the last reference by definition), and the gate
    /// itself is main-queue confined.
    nonisolated(unsafe) private let sleepGate: SystemSleepGating?
    private let sleepDeferralTimeout: TimeInterval
    private let willSleepFallbackGrace: TimeInterval

    private var activeReasons: Set<RecordingInterruptionReason> = []
    private var activeInputDeviceID: String?
    private var observers: [NSObjectProtocol] = []
    private var screenObservers: [NSObjectProtocol] = []
    /// `nonisolated(unsafe)`: appended to only on the main actor, and read once
    /// more from `deinit` (the last reference by definition) to unregister --
    /// the same rationale as `sleepGate` above.
    nonisolated(unsafe) private var distributedObservers: [NSObjectProtocol] = []
    private var coreAudioListenerInstalled = false
    private var coreAudioListenerBlock: AudioObjectPropertyListenerBlock?
    private var coreAudioListenerAddress: AudioObjectPropertyAddress?
    /// True once `IORegisterForSystemPower` succeeded. While it is true the
    /// IOKit path owns the `.systemSleep` start (see `installWorkspaceObservers`).
    private var sleepGateActive = false
    private var pendingSleepNotificationID: Int?
    private var pendingSleepStartedAt: Date?
    private var sleepDeferralSafetyTask: Task<Void, Never>?
    /// Set by `start()`, so a repeated call never registers twice.
    private var didStart = false
    /// Armed by the NSWorkspace `willSleep` fallback while it waits for the
    /// IOKit will-sleep that is supposed to follow.
    private var willSleepFallbackTask: Task<Void, Never>?

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenNotificationCenter: NotificationCenter = .default,
        distributedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        deviceListProvider: @escaping () -> [String] = RecordingInterruptionMonitor.defaultDeviceListProvider,
        displayListProvider: @escaping () -> [CGDirectDisplayID] = RecordingInterruptionMonitor.defaultOnlineDisplayList,
        now: @escaping () -> Date = Date.init,
        sleepGate: SystemSleepGating? = nil,
        sleepDeferralTimeout: TimeInterval = 20,
        willSleepFallbackGrace: TimeInterval = 0.5
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.screenNotificationCenter = screenNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.deviceListProvider = deviceListProvider
        self.displayListProvider = displayListProvider
        self.now = now
        self.sleepGate = sleepGate
        self.sleepDeferralTimeout = sleepDeferralTimeout
        self.willSleepFallbackGrace = willSleepFallbackGrace
        installWorkspaceObservers()
        installScreenParameterObserver()
    }

    /// Registers for system power notifications and the session lock. Separate
    /// from `init` and idempotent: `ContentView` is a struct whose body is
    /// re-evaluated whenever the app model changes, so its `@State` initializer
    /// expression runs on every view value SwiftUI builds while only the first
    /// object is kept. Registering in `init` therefore did an
    /// `IORegisterForSystemPower` (plus a notification port) per rebuild, all
    /// but one of them immediately thrown away -- and the lock observers live
    /// on `distnoted`, so each throwaway cost a cross-process register plus
    /// unregister too. Call this once from `.task`/`onAppear` on the retained
    /// instance.
    func start() {
        guard !didStart else { return }
        didStart = true
        installSleepGate()
        installSessionLockObservers()
    }

    deinit {
        // Tear the IOKit registration down before this object goes away: the
        // gate holds an unretained pointer back to itself in the notification
        // port's refcon, so the port must stop delivering first.
        sleepDeferralSafetyTask?.cancel()
        willSleepFallbackTask?.cancel()
        sleepGate?.stop()
        for observer in observers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        for observer in screenObservers {
            screenNotificationCenter.removeObserver(observer)
        }
        for observer in distributedObservers {
            distributedNotificationCenter.removeObserver(observer)
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
        // `screensDidSleep`/`screensDidWake` are deliberately absent. They fire on
        // a plain idle DISPLAY sleep -- lid open, the user just not touching the
        // Mac -- which used to pause a running recording for no reason. With the
        // recording's power assertion in place, neither a dark screen nor the
        // session lock that may follow it harms capture, so only a real system
        // sleep interrupts here. The genuine lock is observed separately (see
        // `installSessionLockObservers`) and only reported.
        let pairs: [(Notification.Name, RecordingInterruptionEvent.Kind, RecordingInterruptionReason)] = [
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
                    // `NSWorkspace.willSleep` cannot be deferred, so an event
                    // emitted from here carries no completion. If it won the
                    // race with `kIOMessageSystemWillSleep`, `emit`'s de-dupe
                    // would swallow the IOKit event and its completion, leaving
                    // the safety timer as the only thing letting the Mac sleep.
                    // So while the gate is live the IOKit path owns this reason
                    // -- but only briefly: this arms a short grace timer that
                    // pauses the recording anyway if the IOKit message never
                    // shows up, so a silent regression can't leave a sleep
                    // completely unhandled.
                    if kind == .started, reason == .systemSleep, self.sleepGateActive {
                        self.armWillSleepFallback()
                        return
                    }
                    // A wake settles the question: whatever the IOKit path was
                    // going to say about this sleep is moot, and a grace timer
                    // resuming after the suspend would raise a spurious pause
                    // that nothing would ever end.
                    if kind == .ended, reason == .systemSleep {
                        self.cancelWillSleepFallback()
                    }
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

    /// Observes the real session lock. `com.apple.screenIsLocked` /
    /// `com.apple.screenIsUnlocked` are posted on the *distributed* center by
    /// loginwindow, and unlike `screensDidSleep` they mean the user actually
    /// locked the session (or the lock screen came up after the idle timeout) --
    /// not merely that the display went dark. Neither pauses the recording; they
    /// are logged and reported.
    private func installSessionLockObservers() {
        let pairs: [(Notification.Name, Bool)] = [
            (Notification.Name("com.apple.screenIsLocked"), true),
            (Notification.Name("com.apple.screenIsUnlocked"), false)
        ]

        for (name, locked) in pairs {
            let observer = distributedNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSessionLocked = locked
                    // Only worth a line while something is actually recording
                    // (`activeInputDeviceID` is set only then); every other lock
                    // of the day is none of this subsystem's business.
                    if self.activeInputDeviceID != nil {
                        if locked {
                            Log.recording.notice(
                                "Session locked; the recording keeps running (the power assertion holds capture up)"
                            )
                        } else {
                            Log.recording.notice("Session unlocked; the user is back at the Mac")
                        }
                    }
                    self.onSessionLockChanged?(locked)
                }
            }
            distributedObservers.append(observer)
        }
    }

    // MARK: - IOKit sleep deferral

    private func installSleepGate() {
        guard let sleepGate else { return }
        sleepGateActive = sleepGate.start { [weak self] message in
            self?.handleSleepGateMessage(message)
        }
        if sleepGateActive {
            Log.recording.notice("Registered for system power notifications; sleep will wait for the finalize")
        } else {
            Log.recording.error(
                "IORegisterForSystemPower failed; sleep falls back to NSWorkspace willSleep with no deferral"
            )
        }
    }

    /// Waits `willSleepFallbackGrace` for `kIOMessageSystemWillSleep`; if it
    /// never arrives, pauses the recording the old (undeferrable) way rather
    /// than letting the sleep pass unhandled.
    private func armWillSleepFallback() {
        willSleepFallbackTask?.cancel()
        let grace = willSleepFallbackGrace
        Log.recording.notice(
            "NSWorkspace willSleep: waiting \(grace, privacy: .public)s for the IOKit will-sleep that carries the deferral"
        )
        willSleepFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            self.willSleepFallbackTask = nil
            Log.recording.error(
                "IOKit will-sleep did not arrive within \(grace, privacy: .public)s; pausing via the NSWorkspace fallback, with no deferral for the finalize"
            )
            self.emit(.started, reason: .systemSleep)
        }
    }

    private func cancelWillSleepFallback() {
        willSleepFallbackTask?.cancel()
        willSleepFallbackTask = nil
    }

    private func handleSleepGateMessage(_ message: SystemSleepGateMessage) {
        switch message {
        case .canSystemSleep(let notificationID):
            // Idle sleep is prevented by the recording's power assertion, not
            // vetoed here — and an unanswered "can I sleep?" stalls the whole
            // system for 30 s, so answer immediately.
            Log.recording.notice("IOKit kIOMessageCanSystemSleep(\(notificationID, privacy: .public)): allowing")
            sleepGate?.allowPowerChange(notificationID: notificationID)
        case .willSleep(let notificationID):
            beginSleepDeferral(notificationID: notificationID)
        case .hasPoweredOn(let notificationID):
            Log.recording.notice("IOKit kIOMessageSystemHasPoweredOn(\(notificationID, privacy: .public))")
            // The Mac has already slept and woken. A deferral still pending
            // here means the kernel slept on its own timeout instead of on
            // our allow, so answering that notification ID now is
            // meaningless -- drop it rather than let the safety timer fire
            // after the fact.
            discardPendingSleepDeferral()
            cancelWillSleepFallback()
            emit(.ended, reason: .systemSleep)
        }
    }

    /// Holds the sleep and hands the release out with the event. The consumer
    /// (the interruption coordinator) runs it once the segment is finalized.
    private func beginSleepDeferral(notificationID: Int) {
        // The IOKit message arrived, so the NSWorkspace fallback is not needed.
        cancelWillSleepFallback()
        // A second will-sleep without an intervening wake shouldn't happen, but
        // if it does, release the older ID first: nobody will answer it, and the
        // kernel would sit out its full timeout waiting.
        if let stale = pendingSleepNotificationID, stale != notificationID {
            releaseSleepDeferral(notificationID: stale, trigger: "superseded")
        }
        pendingSleepNotificationID = notificationID
        pendingSleepStartedAt = now()
        Log.recording.notice(
            """
            IOKit kIOMessageSystemWillSleep(\(notificationID, privacy: .public)): deferring sleep until the \
            active segment is finalized
            """
        )
        startSleepDeferralSafetyTimer(notificationID: notificationID)

        let emitted = emit(.started, reason: .systemSleep, completion: { [weak self] in
            self?.releaseSleepDeferral(notificationID: notificationID, trigger: "finalize")
        })
        if !emitted {
            Log.recording.error(
                """
                A systemSleep interruption was already active when kIOMessageSystemWillSleep arrived; \
                the \(self.sleepDeferralTimeout, privacy: .public)s safety timer now owns the deferral
                """
            )
        }
    }

    private func discardPendingSleepDeferral() {
        guard let notificationID = pendingSleepNotificationID else { return }
        pendingSleepNotificationID = nil
        pendingSleepStartedAt = nil
        sleepDeferralSafetyTask?.cancel()
        sleepDeferralSafetyTask = nil
        Log.recording.error(
            "Woke with sleep deferral \(notificationID, privacy: .public) still pending: the kernel slept without waiting for IOAllowPowerChange, so the finalize may have been cut short"
        )
    }

    private func startSleepDeferralSafetyTimer(notificationID: Int) {
        sleepDeferralSafetyTask?.cancel()
        let timeout = sleepDeferralTimeout
        sleepDeferralSafetyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            Log.recording.error(
                """
                Sleep deferral safety timer fired after \(timeout, privacy: .public)s: allowing the power \
                change with the finalize still in flight
                """
            )
            self.releaseSleepDeferral(notificationID: notificationID, trigger: "safetyTimer")
        }
    }

    /// Releases the pending deferral exactly once: the completion and the safety
    /// timer both land here, and whichever is second finds the ID already gone.
    private func releaseSleepDeferral(notificationID: Int, trigger: String) {
        guard pendingSleepNotificationID == notificationID else { return }
        pendingSleepNotificationID = nil
        sleepDeferralSafetyTask?.cancel()
        sleepDeferralSafetyTask = nil
        let heldFor = pendingSleepStartedAt.map { now().timeIntervalSince($0) } ?? 0
        pendingSleepStartedAt = nil
        Log.recording.notice(
            """
            IOAllowPowerChange(\(notificationID, privacy: .public)) via \(trigger, privacy: .public) after \
            holding sleep for \(heldFor, privacy: .public)s
            """
        )
        sleepGate?.allowPowerChange(notificationID: notificationID)
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

    /// Returns whether the event was actually emitted; `false` means it was
    /// de-duplicated away, and any `completion` handed in was NOT delivered to
    /// the consumer.
    @discardableResult
    private func emit(
        _ kind: RecordingInterruptionEvent.Kind,
        reason: RecordingInterruptionReason,
        completion: (@MainActor () -> Void)? = nil
    ) -> Bool {
        switch kind {
        case .started:
            guard !activeReasons.contains(reason) else { return false }
            activeReasons.insert(reason)
        case .ended:
            guard activeReasons.contains(reason) else { return false }
            activeReasons.remove(reason)
        }
        onEvent?(
            RecordingInterruptionEvent(kind: kind, reason: reason, at: now(), completion: completion)
        )
        return true
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

/// The real power-change deferral. `NSWorkspace.willSleepNotification` gives the
/// app no way to delay sleep, so a mixdown of a long segment races the kernel
/// suspending the process. `IORegisterForSystemPower` does: after
/// `kIOMessageSystemWillSleep` macOS waits (~30 s) for `IOAllowPowerChange`.
///
/// Confined to the main queue: the notification port is scheduled on
/// `DispatchQueue.main`, so the C callback, `allowPowerChange` and `stop` all run
/// there and the mutable state below needs no lock.
final class IOKitSystemSleepGate: SystemSleepGating {
    // `kIOMessage*` are C macros (`iokit_common_msg(0x…)`), so Swift can't see
    // them; these are the values IOKit/IOMessage.h expands to.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private var onMessage: (@MainActor (SystemSleepGateMessage) -> Void)?

    func start(onMessage: @escaping @MainActor (SystemSleepGateMessage) -> Void) -> Bool {
        guard rootPort == 0 else { return true }
        self.onMessage = onMessage

        var notificationPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        // Unretained: this object owns the registration and tears it down in
        // `stop()` (called from its own `deinit` and from the monitor's), so the
        // port never outlives it. Retaining here would instead make the
        // registration keep the gate alive forever.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let port = IORegisterForSystemPower(refcon, &notificationPort, systemSleepGateCallback, &notifier)

        guard port != 0, let notificationPort else {
            self.onMessage = nil
            return false
        }
        IONotificationPortSetDispatchQueue(notificationPort, .main)
        self.rootPort = port
        self.notificationPort = notificationPort
        self.notifierObject = notifier
        return true
    }

    func allowPowerChange(notificationID: Int) {
        guard rootPort != 0 else { return }
        let result = IOAllowPowerChange(rootPort, notificationID)
        if result != kIOReturnSuccess {
            // Usually means the kernel already gave up waiting for us and slept
            // (or woke) on its own timeout.
            Log.recording.error(
                "IOAllowPowerChange(\(notificationID, privacy: .public)) failed: \(result, privacy: .public)"
            )
        }
    }

    func stop() {
        onMessage = nil
        if notifierObject != 0 {
            IODeregisterForSystemPower(&notifierObject)
            notifierObject = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    deinit {
        stop()
    }

    /// Called from the C callback, which the notification port delivers on the
    /// main queue.
    @MainActor
    fileprivate func deliver(messageType: UInt32, notificationID: Int) {
        let message: SystemSleepGateMessage
        switch messageType {
        case Self.canSystemSleep:
            message = .canSystemSleep(notificationID: notificationID)
        case Self.systemWillSleep:
            message = .willSleep(notificationID: notificationID)
        case Self.systemHasPoweredOn:
            message = .hasPoweredOn(notificationID: notificationID)
        default:
            return
        }
        onMessage?(message)
    }
}

/// Top-level so it converts to a C function pointer (no captures). The gate is
/// reached through the refcon it registered with.
private func systemSleepGateCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard refcon != nil else { return }
    // Raw pointers aren't `Sendable`, so cross into the main actor carrying only
    // integers and rebuild the pointer there. The port is scheduled on the main
    // queue, so this really is the main thread. `messageArgument` is the opaque
    // notification ID to hand back to IOAllowPowerChange, passed as a
    // pointer-sized integer rather than as a pointer to anything.
    let gateAddress = Int(bitPattern: refcon)
    let notificationID = Int(bitPattern: messageArgument)
    MainActor.assumeIsolated {
        guard let opaque = UnsafeMutableRawPointer(bitPattern: gateAddress) else { return }
        let gate = Unmanaged<IOKitSystemSleepGate>.fromOpaque(opaque).takeUnretainedValue()
        gate.deliver(messageType: messageType, notificationID: notificationID)
    }
}
