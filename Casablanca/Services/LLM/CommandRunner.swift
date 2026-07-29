import Foundation
import os

/// The outcome of running a subprocess to completion.
struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// Why running a subprocess did not produce a `CommandResult`.
enum CommandRunError: Error, Equatable {
    /// The executable could not be launched (missing, not executable, bad path).
    case launchFailed(String)
    /// The process was still running when `timeout` elapsed, and was terminated.
    case timedOut
}

/// Runs a subprocess, feeding it `standardInput` and capturing its output.
/// Exists so `ClaudeCLIProvider` can be tested without spawning `claude`
/// (mirrors the `urlSession` injection in the HTTP-backed providers).
protocol CommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult
}

/// `CommandRunning` backed by `Foundation.Process`.
///
/// One `run` occupies four background threads: one that owns the `Process` and
/// blocks on its exit, plus one each for stdin, stdout and stderr. Servicing the
/// three streams concurrently is load-bearing rather than stylistic — a pipe
/// buffers only ~64 KB, so an implementation that writes a large prompt before it
/// starts reading (or drains stdout to EOF before touching stderr) deadlocks: the
/// child blocks writing its reply while we block writing the prompt.
struct ProcessCommandRunner: CommandRunning {
    /// How long a terminated process gets to die from `SIGTERM` before `SIGKILL`.
    private static let killGracePeriod: TimeInterval = 2
    /// Chunk size for pipe reads.
    private static let readChunkSize = 64 * 1024

    /// Upper bound on waiting for stdout/stderr to reach EOF once the child has
    /// exited. Bounded so a grandchild that inherited the pipes cannot hang the
    /// caller forever; in the normal case EOF arrives with the child's exit.
    /// Overrunning it is reported as `CommandRunError.timedOut` rather than as a
    /// possibly-truncated success.
    ///
    /// Injectable only so the tests can reach that path without a five-second wait.
    private let drainGracePeriod: TimeInterval

    init(drainGracePeriod: TimeInterval = 5) {
        self.drainGracePeriod = drainGracePeriod
    }

    func run(
        executable: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                // `Process` and pipe I/O block, so keep all of it off the cooperative
                // thread pool. Everything non-`Sendable` is created and used inside
                // this closure, never captured across it.
                DispatchQueue.global().async {
                    do {
                        continuation.resume(returning: try Self.execute(
                            executable: executable,
                            arguments: arguments,
                            standardInput: standardInput,
                            workingDirectory: workingDirectory,
                            timeout: timeout,
                            drainGracePeriod: drainGracePeriod,
                            control: control
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Only flips a flag and wakes the executing thread, which owns the
            // process and does the killing. Signalling from here would race the
            // reap, and this closure can run on any thread at any time.
            control.cancel()
        }
    }

    /// Launches the process and blocks until it exits, times out, or the caller
    /// cancels. Runs entirely on one background thread.
    private static func execute(
        executable: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL?,
        timeout: TimeInterval,
        drainGracePeriod: TimeInterval,
        control: ProcessControl
    ) throws -> CommandResult {
        let process = Process()
        // Always set `executableURL`: `Process` raises `NSInvalidArgumentException`
        // when it is nil, while a bad path merely makes `run()` throw.
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { finished in
            control.noteExit(status: finished.terminationStatus)
        }

        guard !control.isCancelled else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw CommandRunError.launchFailed(error.localizedDescription)
        }

        let streams = DispatchGroup()
        let standardOutput = OSAllocatedUnfairLock(initialState: Data())
        let standardError = OSAllocatedUnfairLock(initialState: Data())
        write(standardInput, to: stdinPipe.fileHandleForWriting, in: streams)
        drain(stdoutPipe.fileHandleForReading, into: standardOutput, in: streams)
        drain(stderrPipe.fileHandleForReading, into: standardError, in: streams)

        let outcome = control.waitForOutcome(timeout: timeout)
        switch outcome {
        case .exited:
            break
        case .timedOut, .cancelled:
            // Never leave a runaway child behind.
            terminate(pid: process.processIdentifier, control: control)
        }
        // Closing the child's ends of the pipes ends the reads, so this returns as
        // soon as both streams hit EOF — which normally happens as the child exits.
        let drained = streams.wait(timeout: .now() + drainGracePeriod) == .success

        switch outcome {
        case .timedOut:
            throw CommandRunError.timedOut
        case .cancelled:
            throw CancellationError()
        case .exited(let status):
            // A stream that never reached EOF (a grandchild is still holding the
            // write end) means the bytes in hand may be an arbitrary prefix of the
            // real output. Returning them as a `CommandResult` would hand the caller
            // a plausible-looking truncated reply — or, for a fast-exiting child, a
            // bogus empty one — reported as success, which no retry policy can see
            // through. Fail loudly instead.
            guard drained else { throw CommandRunError.timedOut }
            return CommandResult(
                exitCode: status,
                standardOutput: String(decoding: standardOutput.withLock { $0 }, as: UTF8.self),
                standardError: String(decoding: standardError.withLock { $0 }, as: UTF8.self)
            )
        }
    }

    /// `SIGTERM`, escalating to `SIGKILL` if the process is still alive after the
    /// grace period. Returns once the process has been reaped.
    private static func terminate(pid: pid_t, control: ProcessControl) {
        control.signalIfRunning(SIGTERM, pid: pid)
        guard !control.waitForExit(timeout: killGracePeriod) else { return }
        control.signalIfRunning(SIGKILL, pid: pid)
        _ = control.waitForExit(timeout: killGracePeriod)
    }

    /// Writes `text` to the child's stdin on its own thread and closes the handle,
    /// so the child sees EOF. An empty `text` closes stdin immediately.
    private static func write(_ text: String, to handle: FileHandle, in group: DispatchGroup) {
        let handle = HandleBox(handle)
        group.enter()
        DispatchQueue.global().async {
            // The child may exit before reading everything. `F_SETNOSIGPIPE` turns the
            // resulting `EPIPE` into a thrown error instead of a `SIGPIPE` that would
            // take the whole app down; a broken pipe just means the rest is unwanted.
            _ = fcntl(handle.wrapped.fileDescriptor, F_SETNOSIGPIPE, 1)
            if !text.isEmpty {
                try? handle.wrapped.write(contentsOf: Data(text.utf8))
            }
            try? handle.wrapped.close()
            group.leave()
        }
    }

    /// Reads `handle` to EOF on its own thread, appending each chunk to `destination`
    /// as it arrives. Publishing incrementally rather than once at EOF means a read
    /// that never finishes cannot silently discard what it already collected.
    private static func drain(
        _ handle: FileHandle,
        into destination: OSAllocatedUnfairLock<Data>,
        in group: DispatchGroup
    ) {
        let handle = HandleBox(handle)
        group.enter()
        DispatchQueue.global().async {
            while let chunk = try? handle.wrapped.read(upToCount: readChunkSize), !chunk.isEmpty {
                destination.withLock { $0.append(chunk) }
            }
            group.leave()
        }
    }
}

/// Cross-thread state for one `run`: whether the caller cancelled, and whether the
/// child has exited and with what status. An `NSCondition` lets the executing
/// thread block on "exited, cancelled, or deadline reached" in a single wait, and
/// lets signals be sent under the same lock that records the exit — so a signal can
/// never reach a pid that has already been reaped and recycled.
///
/// `@unchecked Sendable`: every field is only touched while holding `condition`.
private final class ProcessControl: @unchecked Sendable {
    enum Outcome {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    private let condition = NSCondition()
    private var cancelled = false
    private var exitStatus: Int32?

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func noteExit(status: Int32) {
        condition.lock()
        exitStatus = status
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until the child exits, the caller cancels, or `timeout` elapses.
    /// A completed run wins over a simultaneous cancellation: the result is already
    /// in hand, so there is nothing to be gained by discarding it.
    func waitForOutcome(timeout: TimeInterval) -> Outcome {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while exitStatus == nil, !cancelled {
            if !condition.wait(until: deadline) { break }
        }
        if let exitStatus { return .exited(exitStatus) }
        return cancelled ? .cancelled : .timedOut
    }

    /// Blocks until the child exits or `timeout` elapses, ignoring cancellation.
    /// Used while escalating `SIGTERM` to `SIGKILL`, where giving up early is what
    /// would leak the process. Returns whether the child exited.
    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while exitStatus == nil {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    /// Sends `signal` to `pid` unless the child has already exited.
    func signalIfRunning(_ signal: Int32, pid: pid_t) {
        condition.lock()
        defer { condition.unlock() }
        guard exitStatus == nil else { return }
        _ = kill(pid, signal)
    }
}

/// Hands a non-`Sendable` `FileHandle` to the one background thread that services
/// it. `@unchecked Sendable`: each boxed handle is touched only by that thread.
private final class HandleBox: @unchecked Sendable {
    let wrapped: FileHandle

    init(_ wrapped: FileHandle) {
        self.wrapped = wrapped
    }
}
