@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

final class RecordingSession: NSObject, RecordingSessionControlling, @unchecked Sendable {
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

    private let engine = AVAudioEngine()
    private let microphoneSinkNode = AVAudioSinkNode { _, _, _ in noErr }
    private let microphoneProcessingQueue = DispatchQueue(label: "com.casablanca.recording.microphone")
    private let streamQueue = DispatchQueue(label: "com.casablanca.recording.stream")
    private let streamDelegate = StreamLifecycleDelegate()
    private let levelQueue = DispatchQueue(label: "com.casablanca.recording.level")

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var outputFormat: AVAudioFormat?
    private var microphoneFileHandle: FileHandle?
    private var systemAudioFileHandle: FileHandle?
    private var microphoneCaptureConverter: AVAudioConverter?
    private var systemSourceSignature: AudioFormatSignature?
    private var microphoneSourceSignature: AudioFormatSignature?
    private var systemAudioCaptureConverter: AVAudioConverter?
    private var didStartEngine = false
    private var capturedMicrophoneFrames: AVAudioFramePosition = 0
    private var capturedSystemAudioFrames: AVAudioFramePosition = 0
    private var latestMicrophoneLevel = 0.0
    private var latestSystemLevel = 0.0
    private var latestDisplayedLevel = 0.0
    private var lastMicrophoneLevelAt = 0.0
    private var lastSystemLevelAt = 0.0
    private var lastLevelPublishAt = 0.0

    private let levelPublishInterval = 1.0 / 15.0

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

    func start() async throws {
        try await Self.ensureMicrophonePermission()
        try Self.ensureScreenCapturePermission()
        try configureEngine()
        try await configureSystemAudioCapture()
    }

    func stop() async throws -> RecordingResult {
        if let stream {
            try await stream.stopCapture()
        }

        streamOutput = nil
        stream = nil

        microphoneProcessingQueue.sync { }
        streamQueue.sync { }

        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        didStartEngine = false
        bestEffort("close microphone temp file", Log.recording) { try microphoneFileHandle?.close() }
        bestEffort("close system audio temp file", Log.recording) { try systemAudioFileHandle?.close() }
        microphoneFileHandle = nil
        systemAudioFileHandle = nil

        guard capturedMicrophoneFrames > 0 || capturedSystemAudioFrames > 0 else {
            bestEffort("remove microphone temp file", Log.recording) { try FileManager.default.removeItem(at: microphoneTempURL) }
            bestEffort("remove system audio temp file", Log.recording) { try FileManager.default.removeItem(at: systemAudioTempURL) }
            bestEffort("remove output file", Log.recording) { try FileManager.default.removeItem(at: outputURL) }
            throw RecordingError.noCapturedAudio
        }

        try mixTemporaryRecordings()

        let duration = Date().timeIntervalSince(startedAt)
        return RecordingResult(outputURL: outputURL, duration: duration)
    }

    func setMicrophoneDevice(_ deviceID: AudioDeviceID) throws {
        selectedInputDeviceID = deviceID

        guard didStartEngine else {
            return
        }

        try reconfigureMicrophoneInput()
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        systemAudioEnabled = enabled

        if !enabled {
            levelQueue.async { [weak self] in
                guard let self else { return }
                self.latestSystemLevel = 0
                self.lastSystemLevelAt = 0
                self.publishCombinedLevelLocked()
            }
        }
    }

    private func configureEngine() throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.failedToCreateAudioFile
        }

        self.outputFormat = outputFormat
        microphoneCaptureConverter = nil
        systemAudioCaptureConverter = nil
        microphoneSourceSignature = nil
        systemSourceSignature = nil

        guard FileManager.default.createFile(atPath: microphoneTempURL.path, contents: nil),
              FileManager.default.createFile(atPath: systemAudioTempURL.path, contents: nil),
              let microphoneFileHandle = try? FileHandle(forWritingTo: microphoneTempURL),
              let systemAudioFileHandle = try? FileHandle(forWritingTo: systemAudioTempURL)
        else {
            throw RecordingError.failedToCreateAudioFile
        }
        self.microphoneFileHandle = microphoneFileHandle
        self.systemAudioFileHandle = systemAudioFileHandle

        if !engine.attachedNodes.contains(microphoneSinkNode) {
            engine.attach(microphoneSinkNode)
        }

        try configureMicrophoneInput()

        engine.prepare()
        try engine.start()
        didStartEngine = true
    }

    private func configureMicrophoneInput() throws {
        if let selectedInputDeviceID {
            try Self.setInputDevice(selectedInputDeviceID, on: engine.inputNode)
        }

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.inputNode)
        engine.disconnectNodeInput(microphoneSinkNode)
        engine.connect(engine.inputNode, to: microphoneSinkNode, format: inputFormat)

        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.publishMicrophoneLevel(from: buffer)

            guard let copiedBuffer = Self.copyPCMBuffer(buffer) else {
                return
            }

            self.microphoneProcessingQueue.async { [weak self] in
                self?.processMicrophoneBuffer(copiedBuffer)
            }
        }
    }

    private func reconfigureMicrophoneInput() throws {
        if engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }

        engine.stop()
        didStartEngine = false
        try configureMicrophoneInput()
        engine.prepare()
        try engine.start()
        didStartEngine = true
    }

    private func configureSystemAudioCapture() async throws {
        guard let outputFormat else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayAvailable
            }

            let currentBundleID = Bundle.main.bundleIdentifier
            let excludedApps = content.applications.filter { $0.bundleIdentifier == currentBundleID }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            configuration.width = 16
            configuration.height = 16
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 1
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(outputFormat.sampleRate)
            configuration.channelCount = Int(outputFormat.channelCount)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)
            let output = SystemAudioStreamOutput { [weak self] sampleBuffer in
                self?.handleSystemAudioSampleBuffer(sampleBuffer)
            }

            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: streamQueue)
            if pipeline.requiresScreenStreamOutput {
                let screenOutput = ScreenStreamOutput()
                try stream.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: streamQueue)
            }
            try await stream.startCapture()

            self.stream = stream
            self.streamOutput = output
        } catch let error as RecordingError {
            throw error
        } catch {
            throw Self.mapSystemAudioError(error)
        }
    }

    private func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard didStartEngine,
              let outputFormat,
              let sourceBuffer = sampleBuffer.makePCMBuffer()
        else {
            return
        }

        let sourceSignature = AudioFormatSignature(sourceBuffer.format)
        if systemSourceSignature != sourceSignature {
            systemSourceSignature = sourceSignature
            let captureSignature = AudioFormatSignature(outputFormat)
            systemAudioCaptureConverter = captureSignature == sourceSignature
            ? nil
            : AVAudioConverter(from: sourceBuffer.format, to: outputFormat)
        }

        guard let captureBuffer = Self.convert(
            buffer: sourceBuffer,
            with: systemAudioCaptureConverter,
            targetFormat: outputFormat,
            onFailure: onFailure
        ) else {
            return
        }

        if systemAudioEnabled {
            publishSystemLevel(from: captureBuffer)
            writeSystemAudioBuffer(captureBuffer)
        } else {
            levelQueue.async { [weak self] in
                guard let self else { return }
                self.latestSystemLevel = 0
                self.lastSystemLevelAt = 0
                self.publishCombinedLevelLocked()
            }
        }
    }

    private func processMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let outputFormat else { return }
        let sourceSignature = AudioFormatSignature(buffer.format)
        if microphoneSourceSignature != sourceSignature {
            microphoneSourceSignature = sourceSignature
            let captureSignature = AudioFormatSignature(outputFormat)
            microphoneCaptureConverter = captureSignature == sourceSignature
            ? nil
            : AVAudioConverter(from: buffer.format, to: outputFormat)
        }

        guard let captureBuffer = Self.convert(
            buffer: buffer,
            with: microphoneCaptureConverter,
            targetFormat: outputFormat,
            onFailure: onFailure
        ) else {
            return
        }

        writeMicrophoneBuffer(captureBuffer)
    }

    private func writeMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let microphoneFileHandle else { return }

        do {
            try microphoneFileHandle.write(contentsOf: TemporaryRecordingPCMStorage.data(from: buffer))
            capturedMicrophoneFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            onFailure(error)
        }
    }

    private func writeSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let systemAudioFileHandle else { return }

        do {
            try systemAudioFileHandle.write(contentsOf: TemporaryRecordingPCMStorage.data(from: buffer))
            capturedSystemAudioFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            onFailure(error)
        }
    }

    private func publishMicrophoneLevel(from buffer: AVAudioPCMBuffer) {
        let level = normalizedLevel(from: buffer)
        levelQueue.async { [weak self] in
            guard let self else { return }
            self.latestMicrophoneLevel = level
            self.lastMicrophoneLevelAt = Date().timeIntervalSinceReferenceDate
            self.publishCombinedLevelLocked()
        }
    }

    private func publishSystemLevel(from buffer: AVAudioPCMBuffer) {
        let level = normalizedLevel(from: buffer)
        levelQueue.async { [weak self] in
            guard let self else { return }
            self.latestSystemLevel = level
            self.lastSystemLevelAt = Date().timeIntervalSinceReferenceDate
            self.publishCombinedLevelLocked()
        }
    }

    private func publishCombinedLevelLocked() {
        let now = Date().timeIntervalSinceReferenceDate
        let activeMicrophoneLevel = now - lastMicrophoneLevelAt < 0.25 ? latestMicrophoneLevel : 0
        let activeSystemLevel = now - lastSystemLevelAt < 0.25 ? latestSystemLevel : 0
        let combinedLevel = max(activeMicrophoneLevel, activeSystemLevel)

        // Smooth the decay so the bars stay readable between adjacent buffers.
        latestDisplayedLevel = max(combinedLevel, latestDisplayedLevel * 0.8)
        if latestDisplayedLevel < 0.02 {
            latestDisplayedLevel = 0
        }

        guard now - lastLevelPublishAt >= levelPublishInterval else {
            return
        }

        lastLevelPublishAt = now
        onLevelUpdate(latestDisplayedLevel)
    }

    private func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else {
            return 0
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData?.pointee else {
                return 0
            }
            return normalizedPeakLevel(
                from: UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
            )
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData?.pointee else {
                return 0
            }
            let peak = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
                .reduce(0.0) { current, sample in
                    max(current, Double(Int(sample).magnitude) / Double(Int16.max))
                }
            return normalizedPeakLevel(fromUnitPeak: peak)
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData?.pointee else {
                return 0
            }
            let peak = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
                .reduce(0.0) { current, sample in
                    max(current, Double(sample.magnitude) / Double(Int32.max))
                }
            return normalizedPeakLevel(fromUnitPeak: peak)
        default:
            return 0
        }
    }

    private func normalizedPeakLevel<T: BinaryFloatingPoint>(from samples: UnsafeBufferPointer<T>) -> Double {
        let peak = samples.reduce(0.0) { current, sample in
            max(current, Double(abs(sample)))
        }
        return normalizedPeakLevel(fromUnitPeak: peak)
    }

    private func normalizedPeakLevel(fromUnitPeak peak: Double) -> Double {
        guard peak > 0 else {
            return 0
        }

        let decibels = 20 * log10(peak)
        return min(max((decibels + 50) / 50, 0), 1)
    }

    private func mixTemporaryRecordings() throws {
        let microphoneBytes = Self.fileSize(at: microphoneTempURL)
        let systemAudioBytes = Self.fileSize(at: systemAudioTempURL)

        Log.recording.debug(
            "Finalizing recording: micFrames=\(self.capturedMicrophoneFrames) micBytes=\(microphoneBytes) systemFrames=\(self.capturedSystemAudioFrames) systemBytes=\(systemAudioBytes)"
        )

        let microphoneHandle = capturedMicrophoneFrames > 0
            ? try? FileHandle(forReadingFrom: microphoneTempURL)
            : nil
        let systemAudioHandle = capturedSystemAudioFrames > 0
            ? try? FileHandle(forReadingFrom: systemAudioTempURL)
            : nil

        guard microphoneHandle != nil || systemAudioHandle != nil else {
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not reopen its temporary recordings. micFrames=\(capturedMicrophoneFrames), micBytes=\(microphoneBytes), systemFrames=\(capturedSystemAudioFrames), systemBytes=\(systemAudioBytes)."
            )
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            bestEffort("remove existing output file", Log.recording) {
                try FileManager.default.removeItem(at: outputURL)
            }
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL)
        else {
            throw RecordingError.failedToFinalizeRecording("Casablanca could not create the final WAV file.")
        }

        let chunkFrames = 4_096
        let chunkBytes = chunkFrames * MemoryLayout<Float>.size
        var mixedAudioByteCount = 0

        let expectedOutputFrames = pipeline.expectedOutputFrameCount(
            microphoneFrames: capturedMicrophoneFrames,
            systemAudioFrames: capturedSystemAudioFrames
        )

        do {
            try outputHandle.write(contentsOf: Data(repeating: 0, count: 44))
        } catch {
            bestEffort("close output handle", Log.recording) { try outputHandle.close() }
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not initialize the final WAV file: \(Self.describeFinalizationError(error))."
            )
        }

        do {
            while true {
                let microphoneData = try microphoneHandle?.read(upToCount: chunkBytes) ?? Data()
                let systemAudioData = try systemAudioHandle?.read(upToCount: chunkBytes) ?? Data()

                let microphoneSamples = TemporaryRecordingPCMStorage.samples(from: microphoneData)
                let systemAudioSamples = TemporaryRecordingPCMStorage.samples(from: systemAudioData)
                let frameCount = max(microphoneSamples.count, systemAudioSamples.count)

                guard frameCount > 0 else { break }

                var mixedSamples = [Int16](repeating: 0, count: frameCount)
                for index in 0..<frameCount {
                    var sample: Float = 0

                    if index < microphoneSamples.count {
                        sample += microphoneSamples[index] * 1.35
                    }

                    if index < systemAudioSamples.count {
                        sample += systemAudioSamples[index] * 0.8
                    }

                    let clamped = min(max(sample, -1), 1)
                    mixedSamples[index] = Int16((clamped * Float(Int16.max)).rounded())
                }

                let mixedData = mixedSamples.withUnsafeBufferPointer { buffer in
                    Data(buffer: buffer)
                }
                try outputHandle.write(contentsOf: mixedData)
                mixedAudioByteCount += mixedData.count
            }
        } catch {
            bestEffort("close output handle", Log.recording) { try outputHandle.close() }
            bestEffort("close microphone handle", Log.recording) { try microphoneHandle?.close() }
            bestEffort("close system audio handle", Log.recording) { try systemAudioHandle?.close() }
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not read one of the temporary recordings: \(Self.describeFinalizationError(error))."
            )
        }

        do {
            try outputHandle.seek(toOffset: 0)
            try outputHandle.write(contentsOf: Self.wavHeader(dataByteCount: mixedAudioByteCount))
            try outputHandle.close()
            bestEffort("close microphone handle", Log.recording) { try microphoneHandle?.close() }
            bestEffort("close system audio handle", Log.recording) { try systemAudioHandle?.close() }
        } catch {
            bestEffort("close output handle", Log.recording) { try outputHandle.close() }
            bestEffort("close microphone handle", Log.recording) { try microphoneHandle?.close() }
            bestEffort("close system audio handle", Log.recording) { try systemAudioHandle?.close() }
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca could not finalize the final WAV file: \(Self.describeFinalizationError(error))."
            )
        }

        let renderedFrameCount = mixedAudioByteCount / MemoryLayout<Int16>.size
        if expectedOutputFrames > 0, renderedFrameCount == 0 {
            throw RecordingError.failedToFinalizeRecording(
                "Casablanca produced an empty final mix despite capturing audio. expectedFrames=\(expectedOutputFrames)."
            )
        }

        bestEffort("remove microphone temp file", Log.recording) { try FileManager.default.removeItem(at: microphoneTempURL) }
        bestEffort("remove system audio temp file", Log.recording) { try FileManager.default.removeItem(at: systemAudioTempURL) }
    }

    private static func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw RecordingError.microphonePermissionDenied
            }
        default:
            throw RecordingError.microphonePermissionDenied
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

    private static func ensureScreenCapturePermission() throws {
        switch ScreenCapturePermissionState.resolve(
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }
        ) {
        case .granted:
            return
        case .grantedRequiresRestart:
            throw RecordingError.systemAudioPermissionRequiresRestart
        case .denied:
            throw RecordingError.systemAudioPermissionDenied
        }
    }

    private static func mapSystemAudioError(_ error: Error) -> RecordingError {
        let nsError = error as NSError
        Log.recording.error("System audio capture error: \(nsError.domain, privacy: .public) \(nsError.code) \(nsError.localizedDescription)")

        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
            return .systemAudioPermissionDenied
        }

        return .systemAudioCaptureFailed(
            "System audio capture failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
        )
    }

    private static func makeTemporaryURL(for outputURL: URL, suffix: String) -> URL {
        outputURL
            .deletingPathExtension()
            .appendingPathExtension(suffix)
            .appendingPathExtension("pcm")
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func describeFinalizationError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter?,
        targetFormat: AVAudioFormat,
        onFailure: ((Error) -> Void)? = nil
    ) -> AVAudioPCMBuffer? {
        if AudioFormatSignature(buffer.format) == AudioFormatSignature(targetFormat) {
            return buffer
        }

        guard let converter else { return nil }
        converter.reset()

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let expectedFrames = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32, 64)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: expectedFrames) else {
            return nil
        }

        var error: NSError?
        let inputState = SingleBufferInputState(buffer)

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            guard let nextBuffer = inputState.takeBuffer() else {
                outStatus.pointee = .endOfStream
                return nil
            }

            outStatus.pointee = .haveData
            return nextBuffer
        }

        if let error {
            onFailure?(error)
            return nil
        }

        switch status {
        case .haveData, .endOfStream, .inputRanDry:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func wavHeader(dataByteCount: Int) -> Data {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let riffChunkSize = UInt32(36 + dataByteCount)
        let dataSize = UInt32(dataByteCount)

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: riffChunkSize.littleEndian, Array.init))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)

        let fmtChunkSize: UInt32 = 16
        let audioFormat: UInt16 = 1
        header.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: channelCount.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        return header
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

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        handler(sampleBuffer)
    }
}

private final class ScreenStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The stream still emits screen frames even when we only care about system audio.
    }
}

private final class StreamLifecycleDelegate: NSObject, SCStreamDelegate {
    var onStop: ((Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

private struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let interleaved: Bool

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        interleaved = format.isInterleaved
    }
}

private final class SingleBufferInputState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func takeBuffer() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

private extension CMSampleBuffer {
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else {
            return nil
        }

        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        pcmBuffer.frameLength = frameLength

        let bufferCount = max(Int(format.channelCount), 1)
        let bufferListSize = MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        let destination = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for index in 0..<min(audioBufferList.count, destination.count) {
            guard let sourceData = audioBufferList[index].mData,
                  let destinationData = destination[index].mData
            else {
                continue
            }

            memcpy(destinationData, sourceData, Int(min(audioBufferList[index].mDataByteSize, destination[index].mDataByteSize)))
        }

        return pcmBuffer
    }
}

private extension SCStream {
    func startCapture() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func stopCapture() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stopCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
