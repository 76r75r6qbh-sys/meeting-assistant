import AVFoundation
import XCTest
@testable import Casablanca

final class PermissionsBehaviorTests: XCTestCase {
    func testScreenCapturePermissionStateSkipsRequestWhenAlreadyGranted() {
        var requestCallCount = 0

        let state = ScreenCapturePermissionState.resolve(
            preflight: { true },
            request: {
                requestCallCount += 1
                return true
            }
        )

        XCTAssertEqual(state, .granted)
        XCTAssertEqual(requestCallCount, 0)
    }

    func testScreenCapturePermissionStateRequiresRestartAfterFreshGrant() {
        let state = ScreenCapturePermissionState.resolve(
            preflight: { false },
            request: { true }
        )

        XCTAssertEqual(state, .grantedRequiresRestart)
    }

    func testScreenCapturePermissionStateReportsDeniedWhenRequestFails() {
        let state = ScreenCapturePermissionState.resolve(
            preflight: { false },
            request: { false }
        )

        XCTAssertEqual(state, .denied)
    }
}

final class CaptureFileSettingsTests: XCTestCase {
    func testCaptureFileSettingsNormalizeToLinearPCM() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!

        let settings = CaptureFileSettings.make(for: format)

        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 24_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? UInt32, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? UInt32, 32)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, true)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, true)
    }
}
