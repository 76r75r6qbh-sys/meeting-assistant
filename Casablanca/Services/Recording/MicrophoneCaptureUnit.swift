@preconcurrency import AVFoundation
import CoreAudio
import Foundation

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

    private let onLevel: (AVAudioPCMBuffer) -> Void
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    private var selectedInputDeviceID: AudioDeviceID?
    private(set) var isRunning = false

    init(
        inputDeviceID: AudioDeviceID?,
        onLevel: @escaping (AVAudioPCMBuffer) -> Void,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        self.selectedInputDeviceID = inputDeviceID
        self.onLevel = onLevel
        self.onBuffer = onBuffer
    }

    /// Serial queue draining barrier so the facade can order shutdown against
    /// in-flight tap buffers, matching the original `queue.sync { }`.
    func drainPendingWork() {
        processingQueue.sync { }
    }

    func start() throws {
        if !engine.attachedNodes.contains(sinkNode) {
            engine.attach(sinkNode)
        }

        try configureInput()

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        isRunning = false
    }

    func setInputDevice(_ deviceID: AudioDeviceID) throws {
        selectedInputDeviceID = deviceID

        guard isRunning else {
            return
        }

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
