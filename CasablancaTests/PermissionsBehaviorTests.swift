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

final class TemporaryRecordingPCMStorageTests: XCTestCase {
    func testRawPCMStorageRoundTripsFloatSamples() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        buffer.floatChannelData!.pointee[0] = -0.25
        buffer.floatChannelData!.pointee[1] = 0.0
        buffer.floatChannelData!.pointee[2] = 0.5
        buffer.floatChannelData!.pointee[3] = 1.0

        let data = TemporaryRecordingPCMStorage.data(from: buffer)
        let samples = TemporaryRecordingPCMStorage.samples(from: data)

        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], -0.25, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(samples[2], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[3], 1.0, accuracy: 0.0001)
    }
}
