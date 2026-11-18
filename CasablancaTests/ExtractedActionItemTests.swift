import XCTest
@testable import Casablanca

final class ExtractedActionItemTests: XCTestCase {

    func testRoundTrip() {
        let items = [
            ExtractedActionItem(
                task: "Stuur de BgZ-spec naar Kim",
                owner: "Youri",
                due: "2026-11-12",
                dueIsExplicit: true,
                confidence: 0.9,
                quote: "ik stuur je de spec voor volgende week",
                timestamp: "12:34",
                verified: .supported,
                verificationReason: "quote found at 12:34"
            ),
            ExtractedActionItem(
                task: "Planning bespreken",
                owner: nil,
                due: nil,
                dueIsExplicit: false,
                confidence: 0.4,
                quote: nil,
                timestamp: nil,
                verified: .unverified,
                verificationReason: nil
            ),
        ]
        let data = ActionItemData.encode(items)
        XCTAssertNotNil(data)
        XCTAssertEqual(ActionItemData.decode(data), items)
    }

    func testDecodeNilIsEmpty() {
        XCTAssertEqual(ActionItemData.decode(nil), [])
        XCTAssertEqual(ActionItemData.decode(Data("garbage".utf8)), [])
    }

    func testVerificationStateRawValues() {
        XCTAssertEqual(VerificationState.unverified.rawValue, "unverified")
        XCTAssertEqual(VerificationState.supported.rawValue, "supported")
        XCTAssertEqual(VerificationState.unsupported.rawValue, "unsupported")
    }
}
