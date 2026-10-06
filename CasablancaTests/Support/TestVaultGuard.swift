import Foundation
import XCTest
@testable import Casablanca

/// Keeps the test suite off the user's real Obsidian vault and real
/// `~/Library` tree.
///
/// The Casablanca test bundle is hosted by the app itself
/// (`PRODUCT_BUNDLE_IDENTIFIER = com.casablanca.app`, not sandboxed), so in a
/// test the standard preference domain IS the user's own domain and
/// `FileManager.default`'s user directories ARE the user's folders. A suite that
/// exports meeting notes, syncs todos or writes prep notes must therefore
/// resolve its vault root from an injected scratch preference domain, and must
/// prove the resolved root lives under the temporary directory before writing.
///
/// Two real incidents motivated this helper: full-suite runs wrote
/// `2023-11-14 Sync.md` / `2023-11-14 Sync - Notes.md` into
/// `~/Documents/Obsidian Vault/meeting notes/` and `2023-11-14 Standup.txt`
/// into `~/Library/Application Support/Casablanca/Transcriptions/`.
enum TestVaultGuard {
    /// Real user directories a test must never write into. Deliberately narrow:
    /// the temporary directory (and `/tmp`) are legitimate test destinations.
    static var forbiddenRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Library", isDirectory: true)
        ]
    }

    /// Fail the test if `url` resolves under the real home directory's
    /// `Documents` or `Library` rather than a temporary directory.
    static func assertTemporary(
        _ url: URL,
        _ what: String = "vault root",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let path = normalized(url)

        // A path inside the per-process temporary directory is always fine, even
        // if a sandbox were ever to place that inside a container's Library.
        if isContained(path, in: normalized(FileManager.default.temporaryDirectory)) { return }

        for forbidden in forbiddenRoots where isContained(path, in: normalized(forbidden)) {
            XCTFail(
                """
                Test \(what) resolves to the REAL user directory \(path).
                Tests must never write there. Inject a scratch UserDefaults \
                (TestVaultGuard.makeScratchDefaults) pointing at a temporary \
                directory (TestVaultGuard.makeScratchVault) and pass it into the \
                service under test.
                """,
                file: file,
                line: line
            )
            return
        }
    }

    /// Same as `assertTemporary(_:)` but tolerates `nil` (a service configured
    /// without a vault, e.g. local-only todo storage, resolves no root at all).
    static func assertTemporaryIfPresent(
        _ url: URL?,
        _ what: String = "vault root",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url else { return }
        assertTemporary(url, what, file: file, line: line)
    }

    /// A unique, existing scratch vault root under the temporary directory.
    /// Guarded, so a misconfigured temporary directory fails loudly here rather
    /// than by littering the user's folders.
    static func makeScratchVault(
        _ label: String = "vault",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        // Guard BEFORE creating, so a misconfigured temporary directory fails
        // the test instead of leaving a directory in the user's folders.
        assertTemporary(url, "scratch vault", file: file, line: line)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A throwaway preference domain — never `.standard` — optionally pointed at
    /// `vaultRoot`. Call `removeScratchDefaults` in `tearDown` so the plist does
    /// not outlive the test.
    static func makeScratchDefaults(
        vaultRoot: URL? = nil,
        suiteName: String = "CasablancaTests.\(UUID().uuidString)"
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let vaultRoot {
            defaults.set(vaultRoot.path, forKey: AppPreferenceKey.obsidianVaultPath)
        }
        return defaults
    }

    /// Drop a scratch preference domain created by `makeScratchDefaults`. The
    /// (now empty) plist may survive in `~/Library/Preferences` — `cfprefsd`
    /// owns that file — but the domain holds no values.
    static func removeScratchDefaults(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Private

    private static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

extension XCTestCase {
    /// A unique scratch vault root under the temporary directory, removed when
    /// the test ends. Guarded, so a bad root fails the test instead of littering
    /// the user's folders.
    func makeScratchVault(
        _ label: String = "vault",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        let url = TestVaultGuard.makeScratchVault(label, file: file, line: line)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A throwaway preference domain — never the standard one, which in this
    /// test host is the user's own — optionally pointed at `vaultRoot`. The
    /// domain's plist is removed when the test ends.
    func makeScratchDefaults(vaultRoot: URL? = nil, label: String = "scratch") -> UserDefaults {
        let suiteName = "CasablancaTests.\(label).\(UUID().uuidString)"
        addTeardownBlock {
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            TestVaultGuard.removeScratchDefaults(defaults, suiteName: suiteName)
        }
        return TestVaultGuard.makeScratchDefaults(vaultRoot: vaultRoot, suiteName: suiteName)
    }

    /// Prove the vault root the code under test will resolve from `defaults` is
    /// not one of the user's real folders.
    func assertScratchVault(
        _ defaults: UserDefaults,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        TestVaultGuard.assertTemporaryIfPresent(
            ObsidianMeetingFiles.meetingNotesDirectory(userDefaults: defaults),
            "meeting notes directory",
            file: file,
            line: line
        )
        TestVaultGuard.assertTemporaryIfPresent(
            ObsidianMeetingFiles.genericTodosURL(userDefaults: defaults),
            "generic todos file",
            file: file,
            line: line
        )
    }
}
