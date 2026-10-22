@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Owns the microphone capture path: the `AVAudioEngine`, its sink node, and
/// the input tap. Phase 1c extraction from `RecordingSession`
/// (`configureEngine`/`configureMicrophoneInput`/`reconfigureMicrophoneInput`/
/// `setInputDevice`). Captured buffers are copied off the realtime tap thread
/// and forwarded to the supplied handler verbatim.
///
/// All methods are called from the MainActor facade. `@unchecked Sendable`
/// because the tap callback (a realtime audio thread) copies the buffer and the
/// only shared escape is the `onBuffer`/`onLevel` closures the caller routes to
/// thread-safe sinks.
final class MicrophoneCaptureUnit: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let sinkNode = AVAudioSinkNode { _, _, _ in noErr }
    private let processingQueue = DispatchQueue(label: "com.casablanca.recording.microphone")
    private let notificationCenter: NotificationCenter

    private let onLevel: (AVAudioPCMBuffer) -> Void
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    /// Raised when the engine stopped underneath us and could not be brought
    /// back. Routed to the stream-failure path, so the meeting pauses instead
    /// of recording a silent microphone track.
    private let onFatal: (Error) -> Void

    /// Serializes engine start/stop/restart. The configuration-change
    /// notification arrives on an arbitrary thread, `stop()` runs on the
    /// cooperative pool and a mic switch on the main actor.
    private let lock = NSLock()
    private var configurationObserver: NSObjectProtocol?

    private var selectedInputDeviceID: AudioDeviceID?
    private(set) var isRunning = false

    init(
        inputDeviceID: AudioDeviceID?,
        notificationCenter: NotificationCenter = .default,
        onLevel: @escaping (AVAudioPCMBuffer) -> Void,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onFatal: @escaping (Error) -> Void = { _ in }
    ) {
        self.selectedInputDeviceID = inputDeviceID
        self.notificationCenter = notificationCenter
        self.onLevel = onLevel
        self.onBuffer = onBuffer
        self.onFatal = onFatal
    }

    deinit {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
    }

    /// Serial queue draining barrier so the facade can order shutdown against
    /// in-flight tap buffers, matching the original `queue.sync { }`.
    func drainPendingWork() {
        processingQueue.sync { }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        if !engine.attachedNodes.contains(sinkNode) {
            engine.attach(sinkNode)
        }

        try configureInput()

        engine.prepare()
        try engine.start()
        isRunning = true
        installConfigurationObserverLocked()
    }

    func stop() {
        lock.lock()
        // Observer first: an engine stopped on purpose must not be "repaired".
        let observer = configurationObserver
        configurationObserver = nil
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        isRunning = false
        lock.unlock()
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    func setInputDevice(_ deviceID: AudioDeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        selectedInputDeviceID = deviceID

        guard isRunning else {
            return
        }

        try restartEngineLocked()
    }

    /// Tears the tap down and brings the engine back on the current input
    /// device, picking up whatever format the hardware delivers now. Shared by
    /// the user's mic switch and the configuration-change recovery. The caller
    /// holds `lock`.
    private func restartEngineLocked() throws {
#if DEBUG
        if let restartEngineForTesting {
            try restartEngineForTesting()
            return
        }
#endif
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }

        engine.stop()
        isRunning = false
        try configureInput()
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    // MARK: - Configuration changes

    /// `AVAudioEngineConfigurationChange` is posted when the input hardware
    /// changes sample rate or channel count under a running engine -- AirPods
    /// switching to the call (HFP) profile as soon as Teams opens the mic is
    /// the everyday case. The engine stops itself, so without this the
    /// microphone track went silent for the rest of the meeting with nothing
    /// paused and nothing reported.
    private func installConfigurationObserverLocked() {
        guard configurationObserver == nil else { return }
        // `queue: nil`: handled synchronously on the posting thread under
        // `lock`, so a concurrent `stop()` either lands first (the handler then
        // finds the observer gone) or waits for the restart to finish.
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }
        // A deliberate stop already ran: nothing to repair. And only an engine
        // that really stopped is restarted -- a restart of our own may post the
        // notification again while the engine runs fine, and restarting on
        // that would feed itself.
        guard configurationObserver != nil, isRunning, !engine.isRunning else { return }

        let format = engine.inputNode.inputFormat(forBus: 0)
        Log.recording.notice(
            """
            Microphone engine configuration changed (input now \(format.sampleRate, privacy: .public) Hz, \
            \(format.channelCount, privacy: .public) ch); restarting the engine
            """
        )
        do {
            try restartEngineLocked()
            Log.recording.notice("Microphone engine restarted after the configuration change")
        } catch {
            isRunning = false
            Log.recording.error(
                "Microphone engine could not restart after a configuration change: \(error.localizedDescription, privacy: .public)"
            )
            onFatal(
                RecordingError.systemAudioCaptureFailed(
                    "The microphone stopped after an audio device change (\(error.localizedDescription))."
                )
            )
        }
    }

#if DEBUG
    /// Test seam: replaces the real engine restart so the configuration-change
    /// path can be driven without audio hardware.
    var restartEngineForTesting: (() throws -> Void)?

    /// The engine whose configuration changes this unit observes.
    var engineForTesting: AVAudioEngine { engine }

    /// Test seam: the state `start()` leaves the unit in, minus the real engine.
    func markRunningForTesting() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = true
        installConfigurationObserverLocked()
    }
#endif

    private func configureInput() throws {
        if let selectedInputDeviceID {
            try Self.setInputDevice(selectedInputDeviceID, on: engine.inputNode)
        }

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeInput(sinkNode)
        engine.connect(engine.inputNode, to: sinkNode, format: inputFormat)

        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel(buffer)

            guard let copiedBuffer = Self.copyPCMBuffer(buffer) else {
                return
            }

            self.processingQueue.async { [weak self] in
                self?.onBuffer(copiedBuffer)
            }
        }
    }

    private static func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw RecordingError.systemAudioCaptureFailed("Casablanca could not access the microphone input unit.")
        }

        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw RecordingError.systemAudioCaptureFailed(
                "Casablanca could not switch microphones (Core Audio \(status))."
            )
        }
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = buffer.frameLength

        let sourceAudioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationAudioBufferList = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        for index in 0..<min(sourceAudioBufferList.count, destinationAudioBufferList.count) {
            guard let sourceData = sourceAudioBufferList[index].mData,
                  let destinationData = destinationAudioBufferList[index].mData
            else {
                continue
            }

            memcpy(
                destinationData,
                sourceData,
                Int(min(sourceAudioBufferList[index].mDataByteSize, destinationAudioBufferList[index].mDataByteSize))
            )
        }

        return copiedBuffer
    }
}
