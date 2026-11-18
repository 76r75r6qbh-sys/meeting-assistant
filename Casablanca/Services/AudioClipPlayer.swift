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
    /// Starts or resumes playback from `currentTime`. Returns `false` when it could not start.
    func play() -> Bool
    /// Pauses, keeping the position.
    func pause()
    func stop()
}

enum AudioClipPlayerError: Error, Equatable {
    case playbackFailed(URL)
}

/// Plays short clips (a speaker's sample, a transcript line) from a recording,
/// and backs the transcript transport bar (play/pause, seek, time).
/// One clip at a time app-wide via ``shared``: playing a new clip stops the
/// previous one. A clip with a `duration` stops itself at `start + duration`
/// (seeking does not lift that bound); without one it plays to the end of the file.
/// `currentTime` is published every ``tickInterval`` while playing.
@MainActor
final class AudioClipPlayer: ObservableObject {
    typealias EngineFactory = @MainActor (URL) throws -> any AudioPlaybackEngine
    typealias TickerFactory = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable

    static let shared = AudioClipPlayer()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    /// The loaded file, also while paused. `nil` when stopped.
    @Published private(set) var playingURL: URL?
    /// Length of the loaded file in seconds; 0 when nothing is loaded.
    @Published private(set) var duration: Double = 0

    /// How often the position is published and the clip end is checked.
    static let tickInterval: TimeInterval = 0.25

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
        self.duration = engine.duration
        currentTime = clampedStart
        isPlaying = true
        startTicker()
    }

    /// Pauses the loaded clip, keeping it loaded at its position. No-op when not playing.
    func pause() {
        guard let engine, isPlaying else { return }
        engine.pause()
        stopTicker()
        currentTime = engine.currentTime
        isPlaying = false
    }

    /// Resumes a paused clip. No-op when nothing is loaded or it is already
    /// playing; stops (unloads) the clip when the engine refuses to restart.
    func resume() {
        guard let engine, !isPlaying else { return }
        guard engine.play() else {
            stop()
            return
        }
        isPlaying = true
        startTicker()
    }

    /// Moves the position of the loaded clip, clamped to the file. Works while
    /// playing or paused; no-op when nothing is loaded.
    func seek(to seconds: Double) {
        guard let engine else { return }
        let target = seconds.isFinite ? max(0, min(seconds, engine.duration)) : 0
        engine.currentTime = target
        currentTime = target
    }

    /// Stops and unloads: `currentTime` and `duration` go to 0, `playingURL` to nil.
    func stop() {
        stopTicker()
        engine?.stop()
        engine = nil
        endTime = nil
        playingURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        stopTicker()
        ticker = makeTicker(Self.tickInterval) { [weak self] in self?.tick() }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let engine, isPlaying else { return }
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
    func pause() { player.pause() }
    func stop() { player.stop() }
}
