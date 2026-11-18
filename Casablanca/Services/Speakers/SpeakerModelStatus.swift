import Foundation
import Observation

/// Where the diarization models are, for Settings → Speakers. Updated by the
/// speaker step and by the "Download now" button; never blocks anything.
@MainActor
@Observable
final class SpeakerModelStatus {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double?)
        case ready
        case failed(String)
    }

    static let shared = SpeakerModelStatus(
        state: initialState(modelsDirectory: FluidAudioDiarizer.defaultModelsDirectory)
    )

    /// `.ready` when the models are already on disk, else `.notDownloaded`.
    nonisolated static func initialState(modelsDirectory: URL) -> State {
        FluidAudioDiarizer.modelsCached(in: modelsDirectory) ? .ready : .notDownloaded
    }

    var state: State = .notDownloaded

    init(state: State = .notDownloaded) {
        self.state = state
    }

    /// Prepares the models through `diarizer`, reporting progress here.
    /// A failure lands in `.failed` and is rethrown. Cheap once the diarizer
    /// has its models, so callers need not check `state` first.
    func prepare(using diarizer: SpeakerDiarizing) async throws {
        if state != .ready { state = .downloading(nil) }
        do {
            try await diarizer.prepareModels { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction)
                }
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }
}
