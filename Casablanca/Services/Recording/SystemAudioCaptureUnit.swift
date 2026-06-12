@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import os
@preconcurrency import ScreenCaptureKit

/// Owns the system-audio capture path: the `SCStream`, its output/delegate
/// glue, and the cross-thread flags that gate sample handling. Phase 1c
/// extraction from `RecordingSession` (`configureSystemAudioCapture`/
/// `handleSystemAudioSampleBuffer` and the nested `SCStream` types).
///
/// Thread-safety: `systemAudioEnabled` (written from the MainActor toggle) and
/// `isAcceptingInput` (false until the engine has started; replaces the old
/// cross-thread `didStartEngine` read) are `OSAllocatedUnfairLock<Bool>` so the
/// SCStream sample-handler queue can read them race-free. `@unchecked
/// Sendable`: the locks guard the shared flags, the `SCStream` is touched only
/// from the MainActor facade.
final class SystemAudioCaptureUnit: @unchecked Sendable {
    private let pipeline: DeferredRecordingPipeline
    private let targetFormat: AVAudioFormat
    private let streamQueue = DispatchQueue(label: "com.casablanca.recording.stream")
    private let streamDelegate = StreamLifecycleDelegate()

    /// Invoked on the SCStream sample-handler queue with each raw source PCM
    /// buffer while system audio is enabled. Conversion + level + writing happen
    /// downstream (the `PCMTrackWriter` converts and publishes the level via its
    /// `onConverted` hook), matching the original ordering.
    private let onSampleBuffer: (AVAudioPCMBuffer) -> Void
    private let onSystemDisabled: () -> Void

    private let systemAudioEnabled: OSAllocatedUnfairLock<Bool>
    private let isAcceptingInput = OSAllocatedUnfairLock<Bool>(initialState: false)

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?

    init(
        pipeline: DeferredRecordingPipeline,
        targetFormat: AVAudioFormat,
        systemAudioEnabled: Bool,
        onSampleBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onSystemDisabled: @escaping () -> Void,
        onStreamFatal: @escaping (Error) -> Void
    ) {
        self.pipeline = pipeline
        self.targetFormat = targetFormat
        self.systemAudioEnabled = OSAllocatedUnfairLock(initialState: systemAudioEnabled)
        self.onSampleBuffer = onSampleBuffer
        self.onSystemDisabled = onSystemDisabled
        streamDelegate.onStop = { error in
            onStreamFatal(error)
        }
    }

    /// Opens the capture path. After this returns, the unit still drops samples
    /// until `beginAcceptingInput()` is called (matching the original gate on
    /// `didStartEngine`).
    func start() async throws {
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
            configuration.sampleRate = Int(targetFormat.sampleRate)
            configuration.channelCount = Int(targetFormat.channelCount)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)
            let output = SystemAudioStreamOutput { [weak self] sampleBuffer in
                self?.handleSampleBuffer(sampleBuffer)
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

    func beginAcceptingInput() {
        isAcceptingInput.withLock { $0 = true }
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        systemAudioEnabled.withLock { $0 = enabled }

        if !enabled {
            onSystemDisabled()
        }
    }

    /// Stops the stream and tears down outputs. After this, the
    /// sample-handler gate is closed and the serial queue is drained.
    func stop() async throws {
        isAcceptingInput.withLock { $0 = false }

        if let stream {
            try await stream.stopCapture()
        }

        streamOutput = nil
        stream = nil

        streamQueue.sync { }
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isAcceptingInput.withLock({ $0 }),
              let sourceBuffer = sampleBuffer.makePCMBuffer()
        else {
            return
        }

        // The original converted before this gate, but conversion is pure and
        // its only side effect (signature-cache mutation) now lives in the
        // writer; the source buffer carries identical samples either way.
        if systemAudioEnabled.withLock({ $0 }) {
            onSampleBuffer(sourceBuffer)
        } else {
            onSystemDisabled()
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

extension SCStream {
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
