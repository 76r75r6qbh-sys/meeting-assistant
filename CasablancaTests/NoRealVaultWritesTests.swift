import Foundation
import XCTest

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
    /// *writes* to the standard domain.
    private static let allowlist: [String: String] = [:]

    func testNoTestSourceTouchesTheStandardPreferenceDomain() throws {
        // Split so this guard file does not match its own needle.
        let needle = "UserDefaults" + ".standard"
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
            guard contents.contains(needle) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated()
            where line.contains(needle) {
                offenders.append("\(relativePath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
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
