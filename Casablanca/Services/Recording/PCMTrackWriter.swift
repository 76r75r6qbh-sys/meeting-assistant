@preconcurrency import AVFoundation
import Foundation
import OSLog
import os

/// Captures one audio track to a temporary float32 PCM file.
///
/// Phase 1c extraction from `RecordingSession`: owns a single track's serial
/// queue, `FileHandle`, `AVAudioConverter` + format-signature cache, and frame
/// counter. The per-buffer convert-then-write path is the verbatim
/// `processMicrophoneBuffer`/`writeMicrophoneBuffer`/`writeSystemAudioBuffer`
/// logic, so the on-disk PCM bytes are unchanged.
///
/// Thread-safety: conversion + writes + the source-format cache are confined to
/// `queue`. The frame counter is exposed via an `OSAllocatedUnfairLock` so it
/// can be read safely from any thread (e.g. the MainActor facade's
/// `hasCapturedFrames`) without relying on a queue barrier. `@unchecked
/// Sendable` because that synchronization is enforced by the queue + lock, not
/// the compiler.
final class PCMTrackWriter: @unchecked Sendable {
    private let label: StaticString
    private let queue: DispatchQueue
    private let targetFormat: AVAudioFormat
    private let onFailure: (Error) -> Void

    private var fileHandle: FileHandle?
    private var converter: AVAudioConverter?
    private var sourceSignature: AudioFormatSignature?

    private let frameCounter = OSAllocatedUnfairLock<AVAudioFramePosition>(initialState: 0)

    init(
        label: StaticString,
        queueLabel: String,
        targetFormat: AVAudioFormat,
        fileHandle: FileHandle,
        onFailure: @escaping (Error) -> Void
    ) {
        self.label = label
        self.queue = DispatchQueue(label: queueLabel)
        self.targetFormat = targetFormat
        self.fileHandle = fileHandle
        self.onFailure = onFailure
    }

    /// Frames written so far. Safe to read from any thread.
    var frames: AVAudioFramePosition {
        frameCounter.withLock { $0 }
    }

    /// Converts `buffer` to the target format and appends it to the temp file on
    /// the writer's serial queue. `onConverted` (if provided) is invoked on that
    /// queue with the converted buffer just before it is written — used by the
    /// system-audio track to compute its level from the converted samples,
    /// matching the original behavior.
    func enqueue(buffer: AVAudioPCMBuffer, onConverted: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let converted = self.convert(buffer) else { return }
            onConverted?(converted)
            self.write(converted)
        }
    }

    /// Drains any pending work and closes the file handle.
    func drainAndClose() {
        queue.sync {
            let handle = fileHandle
            fileHandle = nil
            do {
                try handle?.close()
            } catch {
                Log.recording.warning("Closing \(self.label, privacy: .public) temp file failed: \(error.localizedDescription)")
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let signature = AudioFormatSignature(buffer.format)
        if sourceSignature != signature {
            sourceSignature = signature
            let targetSignature = AudioFormatSignature(targetFormat)
            converter = targetSignature == signature
                ? nil
                : AVAudioConverter(from: buffer.format, to: targetFormat)
        }

        return Self.convert(
            buffer: buffer,
            with: converter,
            targetFormat: targetFormat,
            onFailure: onFailure
        )
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let fileHandle else { return }

        do {
            try fileHandle.write(contentsOf: TemporaryRecordingPCMStorage.data(from: buffer))
            frameCounter.withLock { $0 += AVAudioFramePosition(buffer.frameLength) }
        } catch {
            onFailure(error)
        }
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
}

/// Identifies an `AVAudioFormat` by the fields that matter for converter reuse.
struct AudioFormatSignature: Equatable {
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

/// Feeds a single buffer into `AVAudioConverter.convert` exactly once.
/// `@unchecked Sendable`: the converter input block runs synchronously on the
/// calling thread, so the single mutable field is never touched concurrently.
final class SingleBufferInputState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func takeBuffer() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
