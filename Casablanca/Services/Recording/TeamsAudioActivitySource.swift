import CoreAudio
import Foundation

/// Answers one question for `TeamsCallMonitor`: is Microsoft Teams capturing
/// microphone input right now? Hidden behind a protocol so the debounce and the
/// monitor's scheduling are testable without CoreAudio.
@MainActor
protocol TeamsAudioActivitySource: AnyObject {
    /// False when this macOS cannot report per-process audio activity; the
    /// feature is then unavailable rather than silently never firing.
    var isSupported: Bool { get }
    /// A fresh read, never a cached answer.
    func isTeamsInputRunning() -> Bool
    /// Calls `onChange` (on the main actor) whenever the answer may have
    /// changed. A hint only: the receiver re-reads `isTeamsInputRunning()`.
    func startObserving(onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// Reads the HAL's process objects (`kAudioHardwarePropertyProcessObjectList`,
/// macOS 14 Sonoma and later): every client process connected to coreaudiod is
/// an `AudioObject` reporting its bundle ID and whether it is running audio
/// input. That tells us Teams is *in a call* — not merely open — without
/// screen recording, accessibility or a Teams API.
///
/// The SDK declares these selectors without availability macros, so there is
/// nothing to gate with `#available` on the macOS 14.0 deployment target; the
/// HAL is probed at runtime instead (`isSupported`), which also covers a
/// coreaudiod that does not publish the process list.
///
/// Listener bookkeeping is confined to a private serial queue: CoreAudio calls
/// the blocks there, and the per-process listeners are re-synced on it whenever
/// the process list changes.
@MainActor
final class CoreAudioTeamsActivitySource: TeamsAudioActivitySource {
    /// Prefix match: covers the new client (`com.microsoft.teams2`), classic
    /// Teams (`com.microsoft.teams`) and their helper processes, where the
    /// audio capture may actually live.
    nonisolated static let bundleIDPrefix = "com.microsoft.teams"

    private let listeners = ProcessListenerRegistry()

    var isSupported: Bool {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
    }

    func isTeamsInputRunning() -> Bool {
        Self.teamsProcessObjects().contains { Self.isRunningInput($0) }
    }

    func startObserving(onChange: @escaping @MainActor () -> Void) {
        listeners.install(onChange: onChange)
    }

    func stopObserving() {
        listeners.removeAll()
    }

    // MARK: - HAL reads (safe from any thread)

    nonisolated static func teamsProcessObjects() -> [AudioObjectID] {
        processObjects().filter { bundleID(of: $0)?.hasPrefix(bundleIDPrefix) == true }
    }

    nonisolated static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadObjectError }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        // The list can shrink between the size query and the read.
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    nonisolated static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        // The header: "The caller is responsible for releasing the returned CFObject."
        return value.takeRetainedValue() as String
    }

    nonisolated static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var running: UInt32 = 0
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Owns the CoreAudio property listeners: one on the system object's process
/// list, plus one `IsRunningInput` listener per Teams process. All state is
/// touched only on `queue` — the queue CoreAudio delivers the blocks on — which
/// is what makes the `@unchecked Sendable` sound.
private final class ProcessListenerRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nl.medicore.casablanca.teams-audio-activity")
    private var processListBlock: AudioObjectPropertyListenerBlock?
    private var inputBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var onChange: (@MainActor () -> Void)?

    func install(onChange: @escaping @MainActor () -> Void) {
        queue.sync {
            guard processListBlock == nil else { return }
            self.onChange = onChange
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Already on `queue`: CoreAudio invokes the block there.
                self?.syncProcessListeners()
                self?.notify()
            }
            var address = CoreAudioTeamsActivitySource.address(kAudioHardwarePropertyProcessObjectList)
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block
            )
            if status == noErr {
                processListBlock = block
            } else {
                Log.recording.error("Teams monitor: process-list listener failed (\(status, privacy: .public)); relying on polling")
            }
            syncProcessListeners()
        }
    }

    func removeAll() {
        queue.sync { removeAllListeners() }
    }

    deinit {
        // No other reference exists any more, so no queue hop — and a hop could
        // deadlock if the last release happened inside a block on `queue`.
        removeAllListeners()
    }

    private func removeAllListeners() {
        if let block = processListBlock {
            var address = CoreAudioTeamsActivitySource.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        processListBlock = nil
        for process in Array(inputBlocks.keys) {
            removeInputListener(process)
        }
        onChange = nil
    }

    /// Adds an `IsRunningInput` listener to every Teams process that has none
    /// yet and drops the ones whose process went away. Runs on `queue`.
    private func syncProcessListeners() {
        let current = Set(CoreAudioTeamsActivitySource.teamsProcessObjects())
        for gone in Set(inputBlocks.keys).subtracting(current) {
            removeInputListener(gone)
        }
        for process in current.subtracting(inputBlocks.keys) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.notify()
            }
            var address = CoreAudioTeamsActivitySource.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(process, &address, queue, block) == noErr {
                inputBlocks[process] = block
            }
        }
    }

    private func removeInputListener(_ process: AudioObjectID) {
        guard let block = inputBlocks.removeValue(forKey: process) else { return }
        var address = CoreAudioTeamsActivitySource.address(kAudioProcessPropertyIsRunningInput)
        // Fails harmlessly with a bad-object error once the process is gone.
        AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
    }

    private func notify() {
        guard let onChange else { return }
        Task { @MainActor in onChange() }
    }
}
