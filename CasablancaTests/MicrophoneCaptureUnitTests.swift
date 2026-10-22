@preconcurrency import AVFoundation
import XCTest
@testable import Casablanca

/// `AVAudioEngineConfigurationChange` handling. When the input hardware
/// changes format underneath a running engine -- AirPods dropping to the
/// call (HFP) profile the moment Teams opens the mic is the common case -- the
/// engine stops itself. Unobserved, the microphone track simply went silent
/// for the rest of the meeting with nothing paused and nothing reported.
///
/// Headless: the engine restart goes through the DEBUG seam, so no audio
/// hardware is touched.
final class MicrophoneCaptureUnitTests: XCTestCase {
    private func makeUnit(
        center: NotificationCenter,
        onFatal: @escaping (Error) -> Void = { _ in }
    ) -> MicrophoneCaptureUnit {
        MicrophoneCaptureUnit(
            inputDeviceID: nil,
            notificationCenter: center,
            onLevel: { _ in },
            onBuffer: { _ in },
            onFatal: onFatal
        )
    }

    func testConfigurationChangeRestartsTheEngine() {
        let center = NotificationCenter()
        let unit = makeUnit(center: center)
        var restarts = 0
        unit.restartEngineForTesting = { restarts += 1 }
        unit.markRunningForTesting()

        center.post(name: .AVAudioEngineConfigurationChange, object: unit.engineForTesting)

        XCTAssertEqual(restarts, 1)
        XCTAssertTrue(unit.isRunning)
    }

    func testFailedRestartRaisesAFatalSoTheMeetingPauses() {
        let center = NotificationCenter()
        var fatals: [Error] = []
        let unit = makeUnit(center: center, onFatal: { fatals.append($0) })
        unit.restartEngineForTesting = { throw NSError(domain: "test", code: -10868) }
        unit.markRunningForTesting()

        center.post(name: .AVAudioEngineConfigurationChange, object: unit.engineForTesting)

        XCTAssertEqual(fatals.count, 1)
        XCTAssertFalse(unit.isRunning)
    }

    func testConfigurationChangeAfterStopIsIgnored() {
        let center = NotificationCenter()
        var fatals: [Error] = []
        let unit = makeUnit(center: center, onFatal: { fatals.append($0) })
        var restarts = 0
        unit.restartEngineForTesting = { restarts += 1 }
        unit.markRunningForTesting()

        unit.stop()
        center.post(name: .AVAudioEngineConfigurationChange, object: unit.engineForTesting)

        XCTAssertEqual(restarts, 0, "stop() must remove the observer")
        XCTAssertTrue(fatals.isEmpty)
    }

    func testAnotherEnginesConfigurationChangeIsIgnored() {
        let center = NotificationCenter()
        let unit = makeUnit(center: center)
        var restarts = 0
        unit.restartEngineForTesting = { restarts += 1 }
        unit.markRunningForTesting()

        center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())

        XCTAssertEqual(restarts, 0)
    }
}
