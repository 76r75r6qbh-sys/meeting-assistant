import Foundation
import XCTest

/// Finds references to the standard preference domain in Swift source, ignoring
/// comments. Split out as a pure function so its own edge cases are testable.
///
/// Comment handling matters: a test file is allowed to *describe* the hazard in
/// a doc comment (`PostTranscriptionPipelineTests` does exactly that) without
/// being an offender.
enum RealPreferenceDomainScanner {
    /// Assembled at runtime so this file never contains the literals it hunts.
    /// `UserDefaults()` — the no-argument initializer — is the standard domain
    /// too, just spelled differently.
    static let needles: [String] = ["UserDefaults" + ".standard", "UserDefaults" + "()"]

    /// 1-based line numbers, and the source text, of every line whose CODE
    /// (comments stripped) contains one of `needles`.
    static func offendingLines(in source: String) -> [(line: Int, text: String)] {
        var offenders: [(line: Int, text: String)] = []
        var inBlockComment = false

        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            let code = codePortion(of: line, inBlockComment: &inBlockComment)
            guard needles.contains(where: code.contains) else { continue }
            offenders.append((index + 1, line.trimmingCharacters(in: .whitespaces)))
        }

        return offenders
    }

    /// The part of `line` that is code: `//` line comments (`///` included) and
    /// `/* … */` block comments removed, while `//` and `/*` inside a string
    /// literal are left alone. `inBlockComment` carries block-comment state
    /// across lines. Text inside a string literal counts as code — deliberately
    /// conservative, since a needle in a string is usually a path being built.
    static func codePortion(of line: String, inBlockComment: inout Bool) -> String {
        var code = ""
        var inString = false
        var escaped = false
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                code.append(character)
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                code.append(character)
                index += 1
                continue
            }
            if character == "/", next == "/" {
                break // the rest of the line is a comment
            }
            if character == "/", next == "*" {
                inBlockComment = true
                index += 2
                continue
            }

            code.append(character)
            index += 1
        }

        return code
    }
}

/// Repo-level guard. The test bundle is hosted by the unsandboxed app, so the
/// standard preference domain in a test IS the user's own domain: a suite that
/// writes there (or reads a real path out of it) can point production code at
/// the user's real Obsidian vault, and a crash mid-test leaves the user's
/// preferences pointing at a deleted temporary directory.
///
/// Every suite must therefore inject a scratch `UserDefaults(suiteName:)` —
/// `TestVaultGuard.makeScratchDefaults()` — instead. This test scans the test
/// sources and fails naming any file that reaches for the standard domain.
final class NoRealVaultWritesTests: XCTestCase {
    /// Files permitted to reference the standard preference domain, each with a
    /// justification. Keep this empty unless a test genuinely has to assert on
    /// production's default-argument behaviour, and never add a file that
    /// *writes* to the standard domain. Describing the hazard in a comment needs
    /// no entry here — the scanner ignores comments.
    private static let allowlist: [String: String] = [:]

    func testNoTestSourceTouchesTheStandardPreferenceDomain() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return XCTFail("Test sources not found at \(root.path); this guard would be inert.")
        }

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        )

        var offenders: [String] = []
        var scannedFileCount = 0

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFileCount += 1
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard Self.allowlist[relativePath] == nil else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for offender in RealPreferenceDomainScanner.offendingLines(in: contents) {
                offenders.append("\(relativePath):\(offender.line): \(offender.text)")
            }
        }

        XCTAssertGreaterThan(scannedFileCount, 50, "Scan found suspiciously few test sources")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(offenders.count) reference(s) to the standard preference domain in test sources. \
            Use TestVaultGuard.makeScratchDefaults() and pass the result into the code under test:
            \(offenders.joined(separator: "\n"))
            """
        )
    }
}

/// The scanner's own edge cases. Every fixture is built by interpolating
/// `needle`, so this file never contains the literals under test.
final class RealPreferenceDomainScannerTests: XCTestCase {
    private let needle = RealPreferenceDomainScanner.needles[0]
    private let noArgNeedle = RealPreferenceDomainScanner.needles[1]

    private func offenders(_ source: String) -> [Int] {
        RealPreferenceDomainScanner.offendingLines(in: source).map(\.line)
    }

    func testLineAndDocCommentsAreIgnored() {
        XCTAssertEqual(offenders("// \(needle)"), [])
        XCTAssertEqual(offenders("/// reads \(needle) at runtime"), [])
        XCTAssertEqual(offenders("    ///   \(needle)"), [])
    }

    func testBlockCommentsAreIgnored() {
        XCTAssertEqual(offenders("/* \(needle) */"), [])
        XCTAssertEqual(offenders("let a = 1 /* \(needle) */"), [])
        // Spanning several lines: the state must carry across them.
        XCTAssertEqual(offenders("/*\n \(needle)\n*/"), [])
        // …and code after the block closes is still code.
        XCTAssertEqual(offenders("/*\n comment\n*/ let d = \(needle)"), [3])
    }

    func testRealStatementsAreCounted() {
        XCTAssertEqual(offenders("let d = \(needle)"), [1])
        XCTAssertEqual(offenders("        \(needle).set(1, forKey: \"k\")"), [1])
        XCTAssertEqual(offenders("let a = 1\nlet d = \(needle)\nlet b = 2"), [2])
    }

    func testCodeWithATrailingCommentIsCounted() {
        XCTAssertEqual(offenders("let d = \(needle) // the real domain"), [1])
        // Literal only in the comment part: not an offender.
        XCTAssertEqual(offenders("let d = scratch // not \(needle)"), [])
        // A `//` inside a string must not swallow the code that follows it.
        XCTAssertEqual(offenders("let u = \"http://x\"; let d = \(needle)"), [1])
    }

    func testNoArgumentInitializerIsCaught() {
        XCTAssertEqual(offenders("let d = \(noArgNeedle)"), [1])
        XCTAssertEqual(offenders("// \(noArgNeedle)"), [])
        // The scratch-domain initializer is fine and must not match.
        XCTAssertEqual(offenders("let d = UserDefaults(suiteName: \"scratch\")!"), [])
    }
}
