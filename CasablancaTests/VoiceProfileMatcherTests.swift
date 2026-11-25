import XCTest
@testable import Casablanca

final class VoiceProfileMatcherTests: XCTestCase {

    private func profile(_ name: String, _ centroid: [Float]) -> VoiceProfile {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return VoiceProfile(id: UUID(), name: name, centroid: centroid, sampleCount: 1, consentedAt: date, createdAt: date)
    }

    func testCosineOfIdenticalIsOne() {
        XCTAssertEqual(VoiceProfileMatcher.cosine([0.3, -0.4, 0.5], [0.3, -0.4, 0.5]), 1, accuracy: 1e-6)
        XCTAssertEqual(VoiceProfileMatcher.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VoiceProfileMatcher.cosine([1, 0], [1, 0, 0]), 0, "Different dimensions never match")
        XCTAssertEqual(VoiceProfileMatcher.cosine([0, 0], [1, 0]), 0, "A zero vector never matches")
    }

    func testMatchAtThresholdSuggests() {
        let cluster: [Float] = [1, 0]
        let kim = profile("Kim", [0.8, 0.6])
        let threshold = VoiceProfileMatcher.cosine(cluster, kim.centroid)

        let suggestions = VoiceProfileMatcher.suggestions(
            clusterEmbeddings: ["S1": cluster],
            profiles: [kim],
            threshold: threshold
        )

        XCTAssertEqual(suggestions, [SpeakerNameSuggestion(
            speakerID: "S1",
            name: "Kim",
            evidence: "Voice profile match",
            source: .voiceProfile,
            score: Double(threshold)
        )])
    }

    func testBelowThresholdNoSuggestion() {
        let suggestions = VoiceProfileMatcher.suggestions(
            clusterEmbeddings: ["S1": [1, 0]],
            profiles: [profile("Kim", [0.79, (1 - 0.79 * 0.79).squareRoot()])]
        )

        XCTAssertEqual(suggestions, [])
    }

    func testEachProfileUsedOnce() {
        // Both clusters' best is Kim (S1 0.95, S2 1.0): S2 wins Kim, and S1
        // falls back to Jeroen (0.8075), still above the threshold.
        let suggestions = VoiceProfileMatcher.suggestions(
            clusterEmbeddings: [
                "S1": [0.95, 0, (1 - 0.9025 as Float).squareRoot()],
                "S2": [1, 0, 0],
            ],
            profiles: [profile("Kim", [1, 0, 0]), profile("Jeroen", [0.85, (1 - 0.7225 as Float).squareRoot(), 0])],
            threshold: 0.8
        )

        XCTAssertEqual(suggestions.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(suggestions.map(\.name), ["Jeroen", "Kim"], "The highest score wins Kim; S1 gets its next best")
        XCTAssertEqual(Set(suggestions.map(\.name)).count, suggestions.count)
    }

    func testDefaultThresholdPinned() {
        XCTAssertEqual(VoiceProfileMatcher.defaultThreshold, 0.80)
    }
}
