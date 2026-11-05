import Foundation
@testable import Casablanca

/// A `SpeakerDiarizing` that never touches FluidAudio, the network or a model:
/// it returns canned turns or throws, and counts its calls.
final class FakeSpeakerDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepareCalls = 0
    private var _diarizeCalls: [URL] = []
    private var _wasCancelled = false

    let prepareError: Error?
    let diarizeError: Error?
    let output: DiarizationOutput
    /// Seconds `diarize` sleeps first (for the timeout path).
    let delay: Double
    let isAvailable: Bool

    init(
        output: DiarizationOutput = DiarizationOutput(turns: [], embeddings: [:]),
        prepareError: Error? = nil,
        diarizeError: Error? = nil,
        delay: Double = 0,
        isAvailable: Bool = true
    ) {
        self.isAvailable = isAvailable
        self.output = output
        self.prepareError = prepareError
        self.diarizeError = diarizeError
        self.delay = delay
    }

    var prepareCalls: Int { lock.withLock { _prepareCalls } }
    var diarizeCalls: [URL] { lock.withLock { _diarizeCalls } }
    var totalCalls: Int { prepareCalls + diarizeCalls.count }
    /// Whether the run saw its task cancelled (the timeout path).
    var wasCancelled: Bool { lock.withLock { _wasCancelled } }

    func prepareModels(progress: @escaping @Sendable (Double?) -> Void) async throws {
        lock.withLock { _prepareCalls += 1 }
        if let prepareError { throw prepareError }
        progress(1)
    }

    func diarize(trackURL: URL) async throws -> DiarizationOutput {
        lock.withLock { _diarizeCalls.append(trackURL) }
        if delay > 0 {
            // Wakes early when cancelled; records that it was.
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { lock.withLock { _wasCancelled = true } }
        }
        if let diarizeError { throw diarizeError }
        return output
    }

    func embedding(trackURL: URL, ranges: [ClosedRange<Double>]) async throws -> [Float] {
        if let diarizeError { throw diarizeError }
        return output.embeddings.values.first ?? []
    }
}
