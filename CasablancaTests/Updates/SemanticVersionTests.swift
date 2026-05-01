import XCTest
@testable import Casablanca

final class SemanticVersionTests: XCTestCase {
    func test_parse_acceptsLeadingV() throws {
        let v = try SemanticVersion(parsing: "v0.3.0")
        XCTAssertEqual(v.major, 0)
        XCTAssertEqual(v.minor, 3)
        XCTAssertEqual(v.patch, 0)
        XCTAssertNil(v.prerelease)
    }

    func test_parse_acceptsBareTriple() throws {
        let v = try SemanticVersion(parsing: "1.2.3")
        XCTAssertEqual(v, SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    func test_parse_capturesPrerelease() throws {
        let v = try SemanticVersion(parsing: "v0.4.0-beta.1")
        XCTAssertEqual(v.prerelease, "beta.1")
    }

    func test_parse_ignoresBuildMetadata() throws {
        let v = try SemanticVersion(parsing: "1.2.3+build.7")
        XCTAssertEqual(v, SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertNil(v.prerelease)
    }

    func test_parse_throwsOnMalformed() {
        for raw in ["", "v", "1", "1.2", "v.1.2.3", "1.2.3.4", "abc"] {
            XCTAssertThrowsError(try SemanticVersion(parsing: raw), "expected throw for '\(raw)'")
        }
    }

    func test_compare_majorMinorPatch() throws {
        XCTAssertLessThan(try SemanticVersion(parsing: "0.2.99"), try SemanticVersion(parsing: "0.3.0"))
        XCTAssertLessThan(try SemanticVersion(parsing: "0.3.0"), try SemanticVersion(parsing: "1.0.0"))
        XCTAssertEqual(try SemanticVersion(parsing: "1.2.3"), try SemanticVersion(parsing: "1.2.3"))
    }

    func test_compare_prereleaseIsLowerThanRelease() throws {
        XCTAssertLessThan(try SemanticVersion(parsing: "0.3.0-beta.1"), try SemanticVersion(parsing: "0.3.0"))
    }

    func test_compare_prereleaseNumericIdentifiersComparedNumerically() throws {
        // Per SemVer 11.4.4: 0.3.0-beta.10 > 0.3.0-beta.2 (numeric, not lexical)
        XCTAssertGreaterThan(try SemanticVersion(parsing: "0.3.0-beta.10"), try SemanticVersion(parsing: "0.3.0-beta.2"))
    }

    func test_compare_higherPatchBeatsLowerPatchPrerelease() throws {
        XCTAssertGreaterThan(try SemanticVersion(parsing: "0.4.1-beta.1"), try SemanticVersion(parsing: "0.4.0"))
    }

    func test_compare_lowerPatchPrereleaseIsLessThanHigherPatchStable() throws {
        XCTAssertLessThan(try SemanticVersion(parsing: "0.4.0-beta.1"), try SemanticVersion(parsing: "0.4.0"))
    }

    func test_buildMetadata_doesNotAffectEquality() throws {
        XCTAssertEqual(try SemanticVersion(parsing: "1.2.3+a"), try SemanticVersion(parsing: "1.2.3+b"))
    }
}
