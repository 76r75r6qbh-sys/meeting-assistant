import Combine
import XCTest
@testable import Casablanca

@MainActor
private final class FakePlaybackEngine: AudioPlaybackEngine {
    let url: URL
    var currentTime: Double = 0
    var duration: Double = 120
    private(set) var isPlaying = false
    private(set) var playCount = 0
    private(set) var stopCount = 0
    var playSucceeds = true

    init(url: URL) { self.url = url }

    func play() -> Bool {
        playCount += 1
        isPlaying = playSucceeds
        return playSucceeds
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }

    /// Simulates the file reaching its natural end.
    func finish() { isPlaying = false }
}

/// Captures the tick closure so a test drives time by hand instead of a Timer.
@MainActor
private final class ManualTicker {
    private(set) var tick: (@MainActor () -> Void)?
    private(set) var cancelCount = 0

    func make(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> AnyCancellable {
        self.tick = tick
        return AnyCancellable { [weak self] in self?.cancelCount += 1 }
    }

    func fire() { tick?() }
}

@MainActor
final class AudioClipPlayerTests: XCTestCase {
    private var engines: [FakePlaybackEngine] = []
    private var ticker = ManualTicker()

    override func setUp() async throws {
        engines = []
        ticker = ManualTicker()
    }

    private func makePlayer() -> AudioClipPlayer {
        AudioClipPlayer(
            makeEngine: { [unowned self] url in
                let engine = FakePlaybackEngine(url: url)
                self.engines.append(engine)
                return engine
            },
            makeTicker: { [unowned self] interval, tick in self.ticker.make(interval, tick) }
        )
    }

    private let urlA = URL(fileURLWithPath: "/tmp/casablanca-test/a.m4a")
    private let urlB = URL(fileURLWithPath: "/tmp/casablanca-test/b.m4a")

    func testPlayStopsPreviousClip() throws {
        let player = makePlayer()

        try player.play(url: urlA, from: 3, duration: 5)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playingURL, urlA)

        try player.play(url: urlB, from: 7)

        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engines[0].stopCount, 1, "the previous clip is stopped")
        XCTAssertFalse(engines[0].isPlaying)
        XCTAssertTrue(engines[1].isPlaying)
        XCTAssertEqual(engines[1].currentTime, 7)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playingURL, urlB)
        XCTAssertEqual(player.currentTime, 7)
    }

    func testStopsAtDuration() throws {
        let player = makePlayer()

        try player.play(url: urlA, from: 10, duration: 5)
        let engine = try XCTUnwrap(engines.first)
        XCTAssertEqual(engine.currentTime, 10, "playback seeks to the start offset")

        engine.currentTime = 14
        ticker.fire()
        XCTAssertTrue(player.isPlaying, "still inside the clip")
        XCTAssertEqual(player.currentTime, 14)

        engine.currentTime = 15.02
        ticker.fire()
        XCTAssertFalse(player.isPlaying, "stops at start + duration")
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(ticker.cancelCount, 1, "the ticker is torn down")
    }

    func testStopsWhenFileEndsWithoutDuration() throws {
        let player = makePlayer()
        try player.play(url: urlA, from: 0)
        engines[0].finish()
        ticker.fire()
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingURL)
    }

    func testStopResetsState() throws {
        let player = makePlayer()
        try player.play(url: urlA, from: 2, duration: 1)
        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(engines[0].stopCount, 1)
    }

    func testPlayThrowsWhenEngineRefuses() {
        let player = AudioClipPlayer(
            makeEngine: { url in
                let engine = FakePlaybackEngine(url: url)
                engine.playSucceeds = false
                return engine
            },
            makeTicker: { [unowned self] interval, tick in self.ticker.make(interval, tick) }
        )
        XCTAssertThrowsError(try player.play(url: urlA, from: 0))
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingURL)
    }

    func testPlayThrowsWhenEngineCannotOpenFile() {
        struct OpenFailure: Error {}
        let player = AudioClipPlayer(
            makeEngine: { _ in throw OpenFailure() },
            makeTicker: { [unowned self] interval, tick in self.ticker.make(interval, tick) }
        )
        XCTAssertThrowsError(try player.play(url: urlA, from: 0))
        XCTAssertFalse(player.isPlaying)
    }
}
