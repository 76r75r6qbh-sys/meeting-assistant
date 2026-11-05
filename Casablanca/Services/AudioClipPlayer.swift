import AVFoundation
import Combine
import Foundation

/// The playback primitive `AudioClipPlayer` drives. Production uses
/// `AVAudioPlayer`; tests inject a fake so no audio hardware or file is needed.
@MainActor
protocol AudioPlaybackEngine: AnyObject {
    /// Playback position in seconds. Settable to seek.
    var currentTime: Double { get set }
    /// Length of the file in seconds.
    var duration: Double { get }
    var isPlaying: Bool { get }
    /// Starts playback from `currentTime`. Returns `false` when it could not start.
    func play() -> Bool
    func stop()
}

enum AudioClipPlayerError: Error, Equatable {
    case playbackFailed(URL)
}

/// Plays short clips (a speaker's sample, a transcript line) from a recording.
/// One clip at a time app-wide via ``shared``: playing a new clip stops the
/// previous one. A clip with a `duration` stops itself at `start + duration`;
/// without one it plays to the end of the file.
@MainActor
final class AudioClipPlayer: ObservableObject {
    typealias EngineFactory = @MainActor (URL) throws -> any AudioPlaybackEngine
    typealias TickerFactory = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable

    static let shared = AudioClipPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var playingURL: URL?

    /// How often the position is published and the clip end is checked.
    static let tickInterval: TimeInterval = 0.05

    private let makeEngine: EngineFactory
    private let makeTicker: TickerFactory
    private var engine: (any AudioPlaybackEngine)?
    private var ticker: AnyCancellable?
    private var endTime: Double?

    init(
        makeEngine: @escaping EngineFactory = { try AVAudioPlayerEngine(url: $0) },
        makeTicker: @escaping TickerFactory = AudioClipPlayer.timerTicker
    ) {
        self.makeEngine = makeEngine
        self.makeTicker = makeTicker
    }

    /// Plays `url` from `start` seconds. When `duration` is given, playback stops
    /// at `start + duration`. Stops whatever was playing first.
    func play(url: URL, from start: Double, duration: Double? = nil) throws {
        stop()

        let engine = try makeEngine(url)
        let clampedStart = max(0, min(start, engine.duration))
        engine.currentTime = clampedStart
        guard engine.play() else {
            throw AudioClipPlayerError.playbackFailed(url)
        }

        self.engine = engine
        endTime = duration.map { clampedStart + max(0, $0) }
        playingURL = url
        currentTime = clampedStart
        isPlaying = true
        ticker = makeTicker(Self.tickInterval) { [weak self] in self?.tick() }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        engine?.stop()
        engine = nil
        endTime = nil
        playingURL = nil
        isPlaying = false
    }

    private func tick() {
        guard let engine else { return }
        currentTime = engine.currentTime
        if let endTime, engine.currentTime >= endTime {
            stop()
        } else if !engine.isPlaying {
            // Reached the end of the file (or the system stopped playback).
            stop()
        }
    }

    static func timerTicker(
        interval: TimeInterval,
        tick: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in MainActor.assumeIsolated { tick() } }
    }
}

/// `AVAudioPlayer` adapter for ``AudioPlaybackEngine``.
@MainActor
final class AVAudioPlayerEngine: AudioPlaybackEngine {
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
    }

    var currentTime: Double {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }

    var duration: Double { player.duration }
    var isPlaying: Bool { player.isPlaying }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }
}
