# Auto-Update From GitHub Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app updater that polls GitHub Releases for `76r75r6qbh-sys/meeting-assistant` on launch + every 24h, prompts the user with release notes, and atomically swaps `Casablanca.app` with the new bundle on confirmation.

**Architecture:** Six new units in `Casablanca/Services/Updates/`. `UpdateService` is the `@Observable` coordinator with a single `State` enum that drives all UI. `GitHubReleaseClient` does pure HTTP. `UpdateDownloader` is a three-method protocol (download / extract+strip-quarantine / verify). `UpdateInstaller` performs the atomic swap from Swift via `FileManager.replaceItem` (uses APFS `renamex_np`) before terminating, and spawns a tiny relaunch-only helper script via `posix_spawn` with `POSIX_SPAWN_SETSID`. `SafeToQuitProbe` gates installs on no active recording / transcription / summary. `UpdatePreferences` is a `UserDefaults` wrapper. `ApplicationsLocationCheck` (in `Utilities/`) handles the first-launch /Applications prompt.

**Tech Stack:** Swift, SwiftUI, Foundation `URLSession` + `URLProtocol`, `FileManager.replaceItem`, `Darwin.posix_spawn` + `POSIX_SPAWN_SETSID`, `Process` (for ditto, codesign, xattr), XCTest, `xcodebuild`, OSLog.

**Spec:** `docs/superpowers/specs/2026-05-01-auto-update-design.md`

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Casablanca/Services/Updates/UpdateError.swift` | `enum UpdateError: LocalizedError, Equatable` covering every failure case in the spec's error matrix. |
| `Casablanca/Services/Updates/SemanticVersion.swift` | Value type with strict-SemVer parsing and comparison (incl. SemVer 11.4.4 numeric prerelease comparison). |
| `Casablanca/Services/Updates/UpdatePaths.swift` | Resolves the staging / logs / sentinel / relaunch-script paths under `~/Library/Application Support/Casablanca/Updates/`. Single source of truth for all update file paths. |
| `Casablanca/Services/Updates/ReleaseInfo.swift` | Plain value type returned by the client. |
| `Casablanca/Services/Updates/GitHubReleaseClient.swift` | Protocol + `URLSessionGitHubReleaseClient` with redirect delegate that strips `Authorization` across origins. |
| `Casablanca/Services/Updates/UpdatePreferences.swift` | `UserDefaults`-backed wrapper for `automaticChecksEnabled`, `includePrereleases`, `skippedVersion`, `lastCheckAt`, `applicationsLocationPromptShown`. |
| `Casablanca/Services/Updates/SafeToQuitProbe.swift` | Protocol + `CasablancaSafeToQuitProbe` checking recording / transcription / summarization. |
| `Casablanca/Services/Updates/UpdateDownloader.swift` | Protocol with three async methods (download / extract / verify) + `DefaultUpdateDownloader`. Strips `com.apple.quarantine` recursively after unzip. |
| `Casablanca/Services/Updates/UpdateInstaller.swift` | Protocol + `DefaultUpdateInstaller`. Calls `FileManager.replaceItem` for the atomic swap, writes the relaunch script, spawns it via `posix_spawn` with `POSIX_SPAWN_SETSID`. |
| `Casablanca/Services/Updates/UpdateService.swift` | `@MainActor @Observable` coordinator. Owns the state machine, schedules the 24h timer, exposes `checkNow`, `installUpdate`, `skipVersion`, `remindLater`, `dismissError`. |
| `Casablanca/Utilities/ApplicationsLocationCheck.swift` | First-launch /Applications prompt + translocation handling. |
| `Casablanca/Views/UpdatePromptView.swift` | Sheet shown on `.available`. Release-notes preview + Install / Later / Skip. |
| `Casablanca/Views/UpdateProgressView.swift` | Sheet shown on `.downloading` / `.staged`. Progress bar + Cancel. |
| `Casablanca/Views/UpdatesSettingsView.swift` | New Settings tab. Auto-check toggle + Last-checked timestamp + manual check button + hidden Option-click reveal for prereleases / install-logs. |
| `Casablanca/CasablancaApp.swift` | Wire `UpdateService`, `ApplicationsLocationCheck`, sentinel-file lifecycle, app-launch housekeeping (staging wipe + orphan helper-script cleanup + unconditional sentinel rewrite), `Check for Updates…` menu item. |
| `Casablanca/Views/SettingsView.swift` | Add Updates tab to the existing `TabView`. |
| `CasablancaTests/Updates/SemanticVersionTests.swift` | Parse + comparison + SemVer 11.4.4 prerelease cases. |
| `CasablancaTests/Updates/UpdatePathsTests.swift` | Path resolution. |
| `CasablancaTests/Updates/GitHubReleaseClientTests.swift` | `URLProtocol`-stubbed: parse latest, parse prerelease list, asset regex, 429 + Retry-After, malformed, missing asset, redirect strips Authorization across origins. |
| `CasablancaTests/Updates/UpdatePreferencesTests.swift` | `UserDefaults` round-trip in an isolated suite. |
| `CasablancaTests/Updates/SafeToQuitProbeTests.swift` | Each of recording / transcription / summarization in turn returns the right reason. |
| `CasablancaTests/Updates/UpdateDownloaderTests.swift` | `file://` fixture zip, quarantine xattr setup + assert removal, codesign verify against ad-hoc-signed fixture, version regression. |
| `CasablancaTests/Updates/UpdateInstallerScriptTests.swift` | Script-content tests + temp-dir `replaceItem` atomic-swap tests. |
| `CasablancaTests/Updates/UpdateServiceTests.swift` | Every state-machine transition with fake client/downloader/installer/probe/clock. |
| `CasablancaTests/Updates/ApplicationsLocationCheckTests.swift` | In-Applications / translocated / not-yet-prompted / already-prompted / replace-confirmation cases. |
| `CasablancaTests/Fixtures/Updates/Casablanca-99.0.0-macOS.zip` | Test fixture: ad-hoc-signed stub bundle with `CFBundleShortVersionString = 99.0.0`. Built once by the script below. |
| `CasablancaTests/Fixtures/Updates/Casablanca-0.0.1-macOS.zip` | Test fixture for version-regression case. |
| `CasablancaTests/Fixtures/Updates/build-fixtures.sh` | One-time fixture-building script (committed; not run on every test). |

## Test Commands

The Casablanca scheme runs tests with code signing disabled:

```bash
xcodebuild test \
  -project Casablanca.xcodeproj \
  -scheme Casablanca \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-update-tests \
  -only-testing:CasablancaTests/<TestClass> \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

For a full regression after the plan completes, drop the `-only-testing` filter.

## Adding Files To The Xcode Project

The project uses a hand-curated `Casablanca.xcodeproj/project.pbxproj`. After creating any new `.swift` file on disk, add it to the project: open `Casablanca.xcodeproj` in Xcode → right-click the appropriate group in the Project navigator → **Add Files to "Casablanca"** → select the file → ensure target membership is **Casablanca** for production code or **CasablancaTests** for test code → Add. New folders (`Casablanca/Services/Updates/`, `CasablancaTests/Updates/`) become groups in the navigator. Each task that creates files calls this out explicitly.

---

### Task 1: `UpdateError` Enum

Defines the error type used throughout the updater. Tests are minimal because the enum is data; downstream tests cover the cases that matter.

**Files:**
- Create: `Casablanca/Services/Updates/UpdateError.swift`
- Create: `CasablancaTests/Updates/UpdateErrorTests.swift`

- [ ] **Step 1: Create the directory and write the failing test**

Create the directory:

```bash
mkdir -p Casablanca/Services/Updates CasablancaTests/Updates
```

Write `CasablancaTests/Updates/UpdateErrorTests.swift`:

```swift
import XCTest
@testable import Casablanca

final class UpdateErrorTests: XCTestCase {
    func test_localizedDescription_isHumanReadable_forEveryCase() {
        let cases: [UpdateError] = [
            .notInApplicationsFolder,
            .checkFailed(URLError(.notConnectedToInternet)),
            .rateLimited(retryAfter: Date(timeIntervalSince1970: 0)),
            .malformedResponse,
            .assetNotFound,
            .notSafeToQuit(reason: "a recording"),
            .downloadFailed(URLError(.timedOut)),
            .unzipFailed,
            .quarantineStripFailed("xattr exited 1"),
            .versionRegression,
            .codesignFailed,
            .swapFailed("permission denied"),
            .helperSpawnFailed("posix_spawn returned 13")
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "missing description for \(error)")
            XCTAssertFalse(description.contains("Optional("), "raw Optional in \(error)")
        }
    }

    func test_equatable_distinguishesAssociatedValues() {
        XCTAssertNotEqual(
            UpdateError.swapFailed("disk full"),
            UpdateError.swapFailed("permission denied")
        )
        XCTAssertEqual(UpdateError.unzipFailed, UpdateError.unzipFailed)
    }
}
```

- [ ] **Step 2: Add the test file to Xcode**

Open `Casablanca.xcodeproj` in Xcode. Right-click `CasablancaTests` → **Add Files to "Casablanca"** → create a new group `Updates` → add `UpdateErrorTests.swift` → target: **CasablancaTests** only.

- [ ] **Step 3: Run the test, verify it fails to compile**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -derivedDataPath .build/xcode-update-tests -only-testing:CasablancaTests/UpdateErrorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: build failure ("Cannot find type 'UpdateError'").

- [ ] **Step 4: Write `UpdateError`**

Create `Casablanca/Services/Updates/UpdateError.swift`:

```swift
import Foundation

enum UpdateError: LocalizedError, Equatable {
    case notInApplicationsFolder
    case checkFailed(URLError)
    case rateLimited(retryAfter: Date)
    case malformedResponse
    case assetNotFound
    case notSafeToQuit(reason: String)
    case downloadFailed(URLError)
    case unzipFailed
    case quarantineStripFailed(String)
    case versionRegression
    case codesignFailed
    case swapFailed(String)
    case helperSpawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInApplicationsFolder:
            return "Move Casablanca to /Applications to enable updates."
        case .checkFailed(let urlError):
            return "Could not reach GitHub: \(urlError.localizedDescription)"
        case .rateLimited(let retryAfter):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "GitHub rate limit hit. Try again after \(formatter.string(from: retryAfter))."
        case .malformedResponse:
            return "Unexpected response from GitHub."
        case .assetNotFound:
            return "No macOS asset was found in the latest release."
        case .notSafeToQuit(let reason):
            return "Casablanca is busy with \(reason). Finish or stop it, then click Install again."
        case .downloadFailed(let urlError):
            return "Update download failed: \(urlError.localizedDescription)"
        case .unzipFailed:
            return "Update download was corrupt."
        case .quarantineStripFailed(let detail):
            return "Could not prepare the update for installation. (\(detail))"
        case .versionRegression:
            return "Update package was older than the current version. Cancelling."
        case .codesignFailed:
            return "Update package was corrupt. Update was not installed."
        case .swapFailed(let detail):
            return "Could not install the update. Your existing app is unchanged. (\(detail))"
        case .helperSpawnFailed(let detail):
            return "Update was installed but Casablanca could not relaunch automatically. Please reopen Casablanca. (\(detail))"
        }
    }

    static func == (lhs: UpdateError, rhs: UpdateError) -> Bool {
        switch (lhs, rhs) {
        case (.notInApplicationsFolder, .notInApplicationsFolder): return true
        case (.checkFailed(let l), .checkFailed(let r)): return l.code == r.code
        case (.rateLimited(let l), .rateLimited(let r)): return l == r
        case (.malformedResponse, .malformedResponse): return true
        case (.assetNotFound, .assetNotFound): return true
        case (.notSafeToQuit(let l), .notSafeToQuit(let r)): return l == r
        case (.downloadFailed(let l), .downloadFailed(let r)): return l.code == r.code
        case (.unzipFailed, .unzipFailed): return true
        case (.quarantineStripFailed(let l), .quarantineStripFailed(let r)): return l == r
        case (.versionRegression, .versionRegression): return true
        case (.codesignFailed, .codesignFailed): return true
        case (.swapFailed(let l), .swapFailed(let r)): return l == r
        case (.helperSpawnFailed(let l), .helperSpawnFailed(let r)): return l == r
        default: return false
        }
    }
}
```

- [ ] **Step 5: Add `UpdateError.swift` to Xcode**

Add to a new group `Casablanca/Services/Updates/` with target membership **Casablanca**.

- [ ] **Step 6: Run the test, verify it passes**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -derivedDataPath .build/xcode-update-tests -only-testing:CasablancaTests/UpdateErrorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: `Test Suite 'UpdateErrorTests' passed`.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Services/Updates/UpdateError.swift CasablancaTests/Updates/UpdateErrorTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdateError typed enum"
```

---

### Task 2: `SemanticVersion` Value Type

Strict SemVer 2.0.0 parsing + comparison, including the SemVer 11.4.4 numeric prerelease identifier rule. Spec Decision 6 + the SemanticVersionTests test target.

**Files:**
- Create: `Casablanca/Services/Updates/SemanticVersion.swift`
- Create: `CasablancaTests/Updates/SemanticVersionTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CasablancaTests/Updates/SemanticVersionTests.swift`:

```swift
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
```

- [ ] **Step 2: Add to Xcode (CasablancaTests target)**

- [ ] **Step 3: Run tests, expect compile failure**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -derivedDataPath .build/xcode-update-tests -only-testing:CasablancaTests/SemanticVersionTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: "Cannot find 'SemanticVersion' in scope".

- [ ] **Step 4: Implement `SemanticVersion`**

Create `Casablanca/Services/Updates/SemanticVersion.swift`:

```swift
import Foundation

struct SemanticVersion: Comparable, Codable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    enum ParseError: Error, Equatable { case malformed(String) }

    init(parsing raw: String) throws {
        var input = raw
        if input.hasPrefix("v") { input.removeFirst() }

        // strip build metadata
        if let plus = input.firstIndex(of: "+") {
            input = String(input[..<plus])
        }

        var prerelease: String? = nil
        if let dash = input.firstIndex(of: "-") {
            prerelease = String(input[input.index(after: dash)...])
            input = String(input[..<dash])
        }

        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0
        else {
            throw ParseError.malformed(raw)
        }
        if let pre = prerelease, pre.isEmpty {
            throw ParseError.malformed(raw)
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?):  return false              // release > prerelease
        case (_?, nil):  return true               // prerelease < release
        case (let l?, let r?):
            return comparePrereleaseIdentifiers(l, r) == .orderedAscending
        }
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    private static func comparePrereleaseIdentifiers(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".")
        let bParts = b.split(separator: ".")
        for i in 0..<min(aParts.count, bParts.count) {
            let l = String(aParts[i])
            let r = String(bParts[i])
            let lNum = Int(l)
            let rNum = Int(r)
            switch (lNum, rNum) {
            case (let li?, let ri?):
                if li != ri { return li < ri ? .orderedAscending : .orderedDescending }
            case (_?, nil): return .orderedAscending          // numeric < alphanumeric
            case (nil, _?): return .orderedDescending
            case (nil, nil):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            }
        }
        if aParts.count == bParts.count { return .orderedSame }
        return aParts.count < bParts.count ? .orderedAscending : .orderedDescending
    }
}
```

- [ ] **Step 5: Add `SemanticVersion.swift` to the Casablanca target in Xcode**

- [ ] **Step 6: Run tests, expect pass**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -derivedDataPath .build/xcode-update-tests -only-testing:CasablancaTests/SemanticVersionTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: all 11 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/Services/Updates/SemanticVersion.swift CasablancaTests/Updates/SemanticVersionTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add SemanticVersion value type with SemVer 2.0.0 parse and compare"
```

---

### Task 3: `UpdatePaths` Helper

Single source of truth for every path the updater touches. All later tasks depend on it.

**Files:**
- Create: `Casablanca/Services/Updates/UpdatePaths.swift`
- Create: `CasablancaTests/Updates/UpdatePathsTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Casablanca

final class UpdatePathsTests: XCTestCase {
    func test_default_resolvesUnderApplicationSupport() {
        let paths = UpdatePaths.default
        XCTAssertTrue(paths.updatesRoot.path.contains("Application Support/Casablanca/Updates"))
    }

    func test_subpaths_haveExpectedNames() {
        let root = URL(fileURLWithPath: "/tmp/Updates")
        let paths = UpdatePaths(updatesRoot: root)
        XCTAssertEqual(paths.stagingRoot.lastPathComponent, "staging")
        XCTAssertEqual(paths.logsRoot.lastPathComponent, "logs")
        XCTAssertEqual(paths.sentinel.lastPathComponent, "relaunch.sentinel")
    }

    func test_stagingDirectory_perVersion() throws {
        let root = URL(fileURLWithPath: "/tmp/Updates")
        let paths = UpdatePaths(updatesRoot: root)
        let v = try SemanticVersion(parsing: "0.4.0-beta.1")
        XCTAssertEqual(paths.stagingDirectory(for: v).lastPathComponent, "0.4.0-beta.1")
        XCTAssertEqual(paths.stagingDirectory(for: v).deletingLastPathComponent(), paths.stagingRoot)
    }

    func test_relaunchScript_andInstallLog_useTimestampedFilenames() {
        let root = URL(fileURLWithPath: "/tmp/Updates")
        let paths = UpdatePaths(updatesRoot: root)
        let date = Date(timeIntervalSince1970: 1_714_550_400) // 2024-05-01T08:00:00Z
        let log = paths.installLog(at: date)
        let script = paths.relaunchScript(at: date)
        XCTAssertTrue(log.lastPathComponent.hasPrefix("install-"))
        XCTAssertTrue(log.lastPathComponent.hasSuffix(".log"))
        XCTAssertTrue(script.lastPathComponent.hasPrefix("relaunch-"))
        XCTAssertTrue(script.lastPathComponent.hasSuffix(".sh"))
    }
}
```

- [ ] **Step 2: Add to Xcode, run, expect compile failure**

- [ ] **Step 3: Implement `UpdatePaths`**

```swift
import Foundation

struct UpdatePaths: Sendable {
    let updatesRoot: URL

    var stagingRoot: URL { updatesRoot.appendingPathComponent("staging", isDirectory: true) }
    var logsRoot: URL { updatesRoot.appendingPathComponent("logs", isDirectory: true) }
    var sentinel: URL { updatesRoot.appendingPathComponent("relaunch.sentinel", isDirectory: false) }

    func stagingDirectory(for version: SemanticVersion) -> URL {
        stagingRoot.appendingPathComponent(version.description, isDirectory: true)
    }

    func relaunchScript(at date: Date) -> URL {
        updatesRoot.appendingPathComponent("relaunch-\(Self.timestamp(date)).sh", isDirectory: false)
    }

    func installLog(at date: Date) -> URL {
        logsRoot.appendingPathComponent("install-\(Self.timestamp(date)).log", isDirectory: false)
    }

    static let `default`: UpdatePaths = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return UpdatePaths(updatesRoot: appSupport.appendingPathComponent("Casablanca/Updates", isDirectory: true))
    }()

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "")
    }
}
```

- [ ] **Step 4: Add to Xcode, run, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdatePaths.swift CasablancaTests/Updates/UpdatePathsTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdatePaths single source of truth"
```

---

### Task 4: `ReleaseInfo` + `GitHubReleaseClient` Protocol & Implementation

Pure HTTP client. Uses `URLProtocol` stubbing for tests.

**Files:**
- Create: `Casablanca/Services/Updates/ReleaseInfo.swift`
- Create: `Casablanca/Services/Updates/GitHubReleaseClient.swift`
- Create: `CasablancaTests/Updates/GitHubReleaseClientTests.swift`

- [ ] **Step 1: Write failing tests for parsing latest, prerelease selection, asset regex, 429 with Retry-After, malformed, missing asset, redirect Authorization stripping**

```swift
import XCTest
@testable import Casablanca

final class GitHubReleaseClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> URLSessionGitHubReleaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionGitHubReleaseClient(owner: "x", repo: "y", session: URLSession(configuration: config))
    }

    func test_fetchLatest_parsesReleaseAndPicksMacOSAsset() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/x/y/releases/latest")
            let body = """
            {"tag_name":"v0.3.0","name":"Casablanca 0.3.0","body":"notes",
             "assets":[
               {"name":"source.zip","browser_download_url":"https://example.com/source.zip","size":1},
               {"name":"Casablanca-0.3.0-macOS.zip","browser_download_url":"https://example.com/asset.zip","size":12345}
             ]}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        let info = try await makeClient().fetchLatestRelease(includePrereleases: false)
        XCTAssertEqual(info.tag, "v0.3.0")
        XCTAssertEqual(info.version, try SemanticVersion(parsing: "0.3.0"))
        XCTAssertEqual(info.assetURL, URL(string: "https://example.com/asset.zip")!)
        XCTAssertEqual(info.assetByteCount, 12345)
        XCTAssertEqual(info.bodyMarkdown, "notes")
    }

    func test_fetchLatest_includePrereleases_picksFirstFromList() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/x/y/releases")
            let body = """
            [
              {"tag_name":"v0.4.0-beta.1","name":"Beta","body":"b","prerelease":true,
               "assets":[{"name":"Casablanca-0.4.0-beta.1-macOS.zip","browser_download_url":"https://example.com/b.zip","size":2}]}
            ]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        let info = try await makeClient().fetchLatestRelease(includePrereleases: true)
        XCTAssertEqual(info.version.prerelease, "beta.1")
    }

    func test_fetchLatest_throwsAssetNotFound_whenZipPatternMissing() async throws {
        StubURLProtocol.handler = { request in
            let body = """
            {"tag_name":"v0.3.0","name":"x","body":"x","assets":[
               {"name":"weirdname.zip","browser_download_url":"https://example.com/w.zip","size":1}]}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, body)
        }
        do {
            _ = try await makeClient().fetchLatestRelease(includePrereleases: false)
            XCTFail("expected assetNotFound")
        } catch UpdateError.assetNotFound {
            // ok
        }
    }

    func test_fetchLatest_throwsRateLimited_with429AndRetryAfterHeader() async throws {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!, Data())
        }
        do {
            _ = try await makeClient().fetchLatestRelease(includePrereleases: false)
            XCTFail("expected rateLimited")
        } catch let error as UpdateError {
            switch error {
            case .rateLimited(let retryAfter):
                XCTAssertGreaterThan(retryAfter.timeIntervalSinceNow, 30)
                XCTAssertLessThan(retryAfter.timeIntervalSinceNow, 90)
            default: XCTFail("wrong error: \(error)")
            }
        }
    }

    func test_fetchLatest_throwsMalformed_whenJSONBroken() async throws {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data("{".utf8))
        }
        do {
            _ = try await makeClient().fetchLatestRelease(includePrereleases: false)
            XCTFail("expected malformedResponse")
        } catch UpdateError.malformedResponse {}
    }

    func test_redirectDelegate_stripsAuthorizationHeader_acrossOrigin() async {
        // URLSession does not drive a 302 from URLProtocol stubs through the redirect
        // delegate, so we test the delegate method directly with a real URLSession task.
        let session = URLSession(configuration: .ephemeral)
        let originalRequest = URLRequest(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!)
        let task = session.dataTask(with: originalRequest)

        var newRequest = URLRequest(url: URL(string: "https://objects.githubusercontent.com/redirected")!)
        newRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(url: originalRequest.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": newRequest.url!.absoluteString])!

        let client = URLSessionGitHubReleaseClient(owner: "x", repo: "y")
        var rewritten: URLRequest?
        let expect = expectation(description: "completion handler called")
        client.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: newRequest) { rq in
            rewritten = rq
            expect.fulfill()
        }
        await fulfillment(of: [expect], timeout: 1)
        XCTAssertNil(rewritten?.value(forHTTPHeaderField: "Authorization"))
    }

    func test_redirectDelegate_keepsAuthorizationHeader_sameOrigin() async {
        let session = URLSession(configuration: .ephemeral)
        let originalRequest = URLRequest(url: URL(string: "https://api.github.com/repos/x/y/releases/latest")!)
        let task = session.dataTask(with: originalRequest)

        var newRequest = URLRequest(url: URL(string: "https://api.github.com/redirected")!)
        newRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(url: originalRequest.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": newRequest.url!.absoluteString])!

        let client = URLSessionGitHubReleaseClient(owner: "x", repo: "y")
        var rewritten: URLRequest?
        let expect = expectation(description: "completion handler called")
        client.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: newRequest) { rq in
            rewritten = rq
            expect.fulfill()
        }
        await fulfillment(of: [expect], timeout: 1)
        XCTAssertEqual(rewritten?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (HTTPURLResponse, Data)
    static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Add files to Xcode (test file → CasablancaTests)**

- [ ] **Step 3: Run, expect compile failure**

- [ ] **Step 4: Implement `ReleaseInfo`**

```swift
// ReleaseInfo.swift
import Foundation

struct ReleaseInfo: Equatable {
    let version: SemanticVersion
    let tag: String
    let title: String
    let bodyMarkdown: String
    let assetURL: URL
    let assetByteCount: Int64
}
```

- [ ] **Step 5: Implement `GitHubReleaseClient`**

```swift
// GitHubReleaseClient.swift
import Foundation
import OSLog

protocol GitHubReleaseClient {
    func fetchLatestRelease(includePrereleases: Bool) async throws -> ReleaseInfo
}

final class URLSessionGitHubReleaseClient: NSObject, GitHubReleaseClient, URLSessionTaskDelegate {
    private let owner: String
    private let repo: String
    private let baseURL: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    static let assetNamePattern = try! NSRegularExpression(
        pattern: #"^Casablanca-([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)-macOS\.zip$"#
    )

    init(
        owner: String,
        repo: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.owner = owner
        self.repo = repo
        self.baseURL = baseURL
        self.session = session
    }

    func fetchLatestRelease(includePrereleases: Bool) async throws -> ReleaseInfo {
        let path = includePrereleases
            ? "/repos/\(owner)/\(repo)/releases"
            : "/repos/\(owner)/\(repo)/releases/latest"
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Casablanca-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: self)
        } catch let urlError as URLError {
            throw UpdateError.checkFailed(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.malformedResponse
        }

        if http.statusCode == 429 || http.statusCode == 403 {
            let seconds = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Int.init) ?? 60
            throw UpdateError.rateLimited(retryAfter: Date().addingTimeInterval(TimeInterval(seconds)))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.malformedResponse
        }

        if includePrereleases {
            let releases: [GHReleasePayload]
            do { releases = try JSONDecoder().decode([GHReleasePayload].self, from: data) }
            catch { throw UpdateError.malformedResponse }
            guard let first = releases.first else { throw UpdateError.assetNotFound }
            return try Self.parse(first)
        } else {
            let release: GHReleasePayload
            do { release = try JSONDecoder().decode(GHReleasePayload.self, from: data) }
            catch { throw UpdateError.malformedResponse }
            return try Self.parse(release)
        }
    }

    private static func parse(_ payload: GHReleasePayload) throws -> ReleaseInfo {
        let version = try SemanticVersion(parsing: payload.tag_name)
        guard let asset = payload.assets.first(where: { asset in
            let range = NSRange(asset.name.startIndex..., in: asset.name)
            return assetNamePattern.firstMatch(in: asset.name, range: range) != nil
        }) else {
            throw UpdateError.assetNotFound
        }
        return ReleaseInfo(
            version: version,
            tag: payload.tag_name,
            title: payload.name ?? payload.tag_name,
            bodyMarkdown: payload.body ?? "",
            assetURL: asset.browser_download_url,
            assetByteCount: Int64(asset.size)
        )
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var rewritten = request
        if let originalHost = task.originalRequest?.url?.host,
           let newHost = request.url?.host,
           originalHost != newHost {
            rewritten.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(rewritten)
    }
}

private struct GHReleasePayload: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let prerelease: Bool?
    let assets: [GHAsset]
}

private struct GHAsset: Decodable {
    let name: String
    let browser_download_url: URL
    let size: Int
}
```

- [ ] **Step 6: Add files to Xcode (Casablanca target)**

- [ ] **Step 7: Run, expect pass**

- [ ] **Step 8: Commit**

```bash
git add Casablanca/Services/Updates/ReleaseInfo.swift Casablanca/Services/Updates/GitHubReleaseClient.swift CasablancaTests/Updates/GitHubReleaseClientTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add GitHubReleaseClient with redirect-stripping delegate"
```

---

### Task 5: `UpdatePreferences` UserDefaults Wrapper

**Files:**
- Create: `Casablanca/Services/Updates/UpdatePreferences.swift`
- Create: `CasablancaTests/Updates/UpdatePreferencesTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Casablanca

final class UpdatePreferencesTests: XCTestCase {
    private func makeIsolated() -> (UpdatePreferences, UserDefaults) {
        let suite = "test.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UpdatePreferences(defaults: defaults), defaults)
    }

    func test_defaults() {
        let (prefs, _) = makeIsolated()
        XCTAssertTrue(prefs.automaticChecksEnabled)
        XCTAssertFalse(prefs.includePrereleases)
        XCTAssertNil(prefs.skippedVersion)
        XCTAssertNil(prefs.lastCheckAt)
        XCTAssertFalse(prefs.applicationsLocationPromptShown)
    }

    func test_skippedVersion_roundTrip() throws {
        var (prefs, _) = makeIsolated()
        prefs.skippedVersion = try SemanticVersion(parsing: "0.4.0-beta.1")
        XCTAssertEqual(prefs.skippedVersion, try SemanticVersion(parsing: "0.4.0-beta.1"))
        prefs.skippedVersion = nil
        XCTAssertNil(prefs.skippedVersion)
    }

    func test_lastCheckAt_roundTrip() {
        var (prefs, _) = makeIsolated()
        let now = Date(timeIntervalSince1970: 1_714_550_400)
        prefs.lastCheckAt = now
        XCTAssertEqual(prefs.lastCheckAt, now)
    }

    func test_includePrereleases_andAutomaticChecks_roundTrip() {
        var (prefs, _) = makeIsolated()
        prefs.automaticChecksEnabled = false
        prefs.includePrereleases = true
        XCTAssertFalse(prefs.automaticChecksEnabled)
        XCTAssertTrue(prefs.includePrereleases)
    }
}
```

- [ ] **Step 2: Implement `UpdatePreferences`**

```swift
import Foundation

struct UpdatePreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.automaticChecksEnabled: true])
    }

    private enum Keys {
        static let automaticChecksEnabled = "updater.automaticChecksEnabled"
        static let includePrereleases = "updater.includePrereleases"
        static let skippedVersion = "updater.skippedVersion"
        static let lastCheckAt = "updater.lastCheckAt"
        static let applicationsLocationPromptShown = "updater.applicationsLocationPromptShown"
    }

    var automaticChecksEnabled: Bool {
        get { defaults.bool(forKey: Keys.automaticChecksEnabled) }
        set { defaults.set(newValue, forKey: Keys.automaticChecksEnabled) }
    }

    var includePrereleases: Bool {
        get { defaults.bool(forKey: Keys.includePrereleases) }
        set { defaults.set(newValue, forKey: Keys.includePrereleases) }
    }

    var skippedVersion: SemanticVersion? {
        get {
            guard let raw = defaults.string(forKey: Keys.skippedVersion) else { return nil }
            return try? SemanticVersion(parsing: raw)
        }
        set { defaults.set(newValue?.description, forKey: Keys.skippedVersion) }
    }

    var lastCheckAt: Date? {
        get { defaults.object(forKey: Keys.lastCheckAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastCheckAt) }
    }

    var applicationsLocationPromptShown: Bool {
        get { defaults.bool(forKey: Keys.applicationsLocationPromptShown) }
        set { defaults.set(newValue, forKey: Keys.applicationsLocationPromptShown) }
    }
}
```

- [ ] **Step 3: Add to Xcode, run, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdatePreferences.swift CasablancaTests/Updates/UpdatePreferencesTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdatePreferences UserDefaults wrapper"
```

---

### Task 6: `SafeToQuitProbe`

Decision 12. Returns nil when safe; otherwise a localized reason string. Default impl reads recording / transcription / summarization state.

**Files:**
- Create: `Casablanca/Services/Updates/SafeToQuitProbe.swift`
- Create: `CasablancaTests/Updates/SafeToQuitProbeTests.swift`

- [ ] **Step 1: Write failing tests with fake services**

```swift
import XCTest
@testable import Casablanca

@MainActor
final class SafeToQuitProbeTests: XCTestCase {
    func test_returnsNil_whenAllIdle() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { false },
            isTranscriptionActive: { false },
            isSummarizationActive: { false }
        )
        XCTAssertNil(probe.reasonInstallShouldWait())
    }

    func test_returnsRecording_whenRecording() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { true },
            isTranscriptionActive: { false },
            isSummarizationActive: { false }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an active recording")
    }

    func test_returnsTranscription_whenTranscribing() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { false },
            isTranscriptionActive: { true },
            isSummarizationActive: { false }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an in-flight transcription")
    }

    func test_returnsSummary_whenSummarizing() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { false },
            isTranscriptionActive: { false },
            isSummarizationActive: { true }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an in-flight summary")
    }

    func test_recordingTakesPriority_overTranscriptionAndSummary() {
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { true },
            isTranscriptionActive: { true },
            isSummarizationActive: { true }
        )
        XCTAssertEqual(probe.reasonInstallShouldWait(), "an active recording")
    }
}
```

- [ ] **Step 2: Implement `SafeToQuitProbe` and `ClosureSafeToQuitProbe`**

```swift
import Foundation

protocol SafeToQuitProbe: AnyObject {
    @MainActor func reasonInstallShouldWait() -> String?
}

@MainActor
final class ClosureSafeToQuitProbe: SafeToQuitProbe {
    private let isRecordingActive: () -> Bool
    private let isTranscriptionActive: () -> Bool
    private let isSummarizationActive: () -> Bool

    init(
        isRecordingActive: @escaping () -> Bool,
        isTranscriptionActive: @escaping () -> Bool,
        isSummarizationActive: @escaping () -> Bool
    ) {
        self.isRecordingActive = isRecordingActive
        self.isTranscriptionActive = isTranscriptionActive
        self.isSummarizationActive = isSummarizationActive
    }

    func reasonInstallShouldWait() -> String? {
        if isRecordingActive() { return "an active recording" }
        if isTranscriptionActive() { return "an in-flight transcription" }
        if isSummarizationActive() { return "an in-flight summary" }
        return nil
    }
}
```

The default app-wide probe is built in Task 19 (AppModel wiring) using the real services. `ClosureSafeToQuitProbe` is also the production type — it just gets closures over the real services injected at construction.

- [ ] **Step 3: Add to Xcode, run, expect pass, commit**

```bash
git add Casablanca/Services/Updates/SafeToQuitProbe.swift CasablancaTests/Updates/SafeToQuitProbeTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add SafeToQuitProbe gating install on active work"
```

---

### Task 7: `UpdateDownloader` Protocol + `download()`

Implements the first of three protocol methods. Uses `URLSession` + an `AsyncStream` for progress.

**Files:**
- Create: `Casablanca/Services/Updates/UpdateDownloader.swift`
- Create: `CasablancaTests/Updates/UpdateDownloaderTests.swift`
- Create: `CasablancaTests/Fixtures/Updates/build-fixtures.sh`
- Create: `CasablancaTests/Fixtures/Updates/Casablanca-99.0.0-macOS.zip` (built via the script)
- Create: `CasablancaTests/Fixtures/Updates/Casablanca-0.0.1-macOS.zip` (older for regression test)

- [ ] **Step 1: Write the fixture-building script**

`CasablancaTests/Fixtures/Updates/build-fixtures.sh`:

```bash
#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

build_fixture() {
  local version="$1"
  local out_zip="$ROOT/Casablanca-$version-macOS.zip"
  local app="$WORK/Casablanca.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>nl.medicore.casablanca.fixture</string>
  <key>CFBundleName</key><string>Casablanca</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleExecutable</key><string>Casablanca</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/Casablanca"
  chmod +x "$app/Contents/MacOS/Casablanca"
  codesign --force --sign - --deep "$app"
  rm -f "$out_zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$out_zip"
  echo "built $out_zip"
}

build_fixture "99.0.0"
build_fixture "0.0.1"
```

- [ ] **Step 2: Build the fixtures**

```bash
chmod +x CasablancaTests/Fixtures/Updates/build-fixtures.sh
./CasablancaTests/Fixtures/Updates/build-fixtures.sh
```

Expected output: `built .../Casablanca-99.0.0-macOS.zip` and the older one.

- [ ] **Step 3: Add the zip fixtures to Xcode**

In Xcode: right-click `CasablancaTests` → **Add Files to "Casablanca"** → select the two `.zip` files → target: **CasablancaTests** → ensure they appear under **Build Phases → Copy Bundle Resources** for the test target.

- [ ] **Step 4: Write the failing tests for `download()`**

```swift
import XCTest
@testable import Casablanca

final class UpdateDownloaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle(for: type(of: self)).url(forResource: name, withExtension: "zip")!
    }

    // MARK: - download()

    func test_download_writesZipAndReportsProgress() async throws {
        let downloader = DefaultUpdateDownloader()
        let dest = tempDir.appendingPathComponent("out.zip")
        var progressValues: [Double] = []
        let result = try await downloader.download(
            from: fixtureURL("Casablanca-99.0.0-macOS"),
            expectedByteCount: -1,
            to: dest,
            progress: { progressValues.append($0) }
        )
        XCTAssertEqual(result, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThan(progressValues.count, 0)
        XCTAssertEqual(progressValues, progressValues.sorted())
        XCTAssertGreaterThanOrEqual(progressValues.last ?? 0, 0.99)
    }
}
```

- [ ] **Step 5: Implement the protocol shell + `download()`**

```swift
// Casablanca/Services/Updates/UpdateDownloader.swift
import Foundation
import OSLog

protocol UpdateDownloader {
    func download(
        from url: URL,
        expectedByteCount: Int64,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL

    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL

    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion
}

final class DefaultUpdateDownloader: NSObject, UpdateDownloader, URLSessionDownloadDelegate {
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var resultContinuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    func download(
        from url: URL,
        expectedByteCount: Int64,
        to destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        self.destination = destination

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        self.progressContinuation = continuation

        let progressTask = Task {
            for await value in stream { progress(value) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.resultContinuation = cont
            let task = session.downloadTask(with: url)
            task.resume()
            _ = progressTask // keep alive
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressContinuation?.yield(min(max(p, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination = destination else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            progressContinuation?.yield(1.0)
            progressContinuation?.finish()
            resultContinuation?.resume(returning: destination)
        } catch {
            resultContinuation?.resume(throwing: error)
        }
        resultContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        progressContinuation?.finish()
        let mapped: Error
        if let urlError = error as? URLError {
            mapped = UpdateError.downloadFailed(urlError)
        } else {
            mapped = UpdateError.downloadFailed(URLError(.unknown))
        }
        resultContinuation?.resume(throwing: mapped)
        resultContinuation = nil
    }

    // MARK: extract / verify (fail with fatalError until implemented in Tasks 8 & 9)

    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL {
        fatalError("implement in Task 8")
    }
    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion {
        fatalError("implement in Task 9")
    }
}
```

- [ ] **Step 6: Add files to Xcode, run download test, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateDownloader.swift CasablancaTests/Updates/UpdateDownloaderTests.swift CasablancaTests/Fixtures/Updates/build-fixtures.sh CasablancaTests/Fixtures/Updates/Casablanca-99.0.0-macOS.zip CasablancaTests/Fixtures/Updates/Casablanca-0.0.1-macOS.zip Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdateDownloader.download() with progress reporting"
```

---

### Task 8: `UpdateDownloader.extract()` + Quarantine Strip

Spec Decision 13.

**Files:**
- Modify: `Casablanca/Services/Updates/UpdateDownloader.swift`
- Modify: `CasablancaTests/Updates/UpdateDownloaderTests.swift`

- [ ] **Step 1: Append failing tests for `extract()`**

Append to `UpdateDownloaderTests.swift`:

```swift
extension UpdateDownloaderTests {
    private func copyFixture(_ name: String) throws -> URL {
        let src = fixtureURL(name)
        let dst = tempDir.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    private func setQuarantineXattr(at url: URL) throws {
        let process = Process()
        process.launchPath = "/usr/bin/xattr"
        process.arguments = ["-w", "com.apple.quarantine", "0181;00000000;Casablanca;|nl.medicore.casablanca.fixture", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "xattr write failed")
    }

    private func hasQuarantine(at url: URL) -> Bool {
        let process = Process()
        process.launchPath = "/usr/bin/xattr"
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").contains("com.apple.quarantine")
    }

    func test_extract_unzipsBundle() async throws {
        let zip = try copyFixture("Casablanca-99.0.0-macOS")
        let downloader = DefaultUpdateDownloader()
        let outDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let bundle = try await downloader.extract(zipAt: zip, to: outDir)
        XCTAssertEqual(bundle.lastPathComponent, "Casablanca.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path))
    }

    func test_extract_stripsQuarantineXattrRecursively() async throws {
        let zip = try copyFixture("Casablanca-99.0.0-macOS")
        try setQuarantineXattr(at: zip)
        let downloader = DefaultUpdateDownloader()
        let outDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let bundle = try await downloader.extract(zipAt: zip, to: outDir)
        XCTAssertFalse(hasQuarantine(at: bundle))
        let executable = bundle.appendingPathComponent("Contents/MacOS/Casablanca")
        XCTAssertFalse(hasQuarantine(at: executable))
    }

    func test_extract_throwsUnzipFailed_onCorruptZip() async throws {
        let bad = tempDir.appendingPathComponent("bad.zip")
        try Data("not a zip".utf8).write(to: bad)
        let downloader = DefaultUpdateDownloader()
        let outDir = tempDir.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        do {
            _ = try await downloader.extract(zipAt: bad, to: outDir)
            XCTFail("expected throw")
        } catch UpdateError.unzipFailed {}
    }
}
```

- [ ] **Step 2: Run, expect failure (extract still fatalErrors)**

- [ ] **Step 3: Replace the `extract` placeholder with the real implementation**

In `Casablanca/Services/Updates/UpdateDownloader.swift`, replace:

```swift
    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL {
        fatalError("implement in Task 8")
    }
```

with:

```swift
    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", source.path, destinationDir.path], errorOnFailure: .unzipFailed)
        let appURL = destinationDir.appendingPathComponent("Casablanca.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw UpdateError.unzipFailed }
        do {
            try Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path], errorOnFailure: nil)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.quarantineStripFailed(error.localizedDescription)
        }
        return appURL
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String], errorOnFailure: UpdateError?) throws -> String {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            if let error = errorOnFailure { throw error }
            throw UpdateError.quarantineStripFailed("\(launchPath) exited \(process.terminationStatus): \(stderrText)")
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
```

- [ ] **Step 4: Run tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateDownloader.swift CasablancaTests/Updates/UpdateDownloaderTests.swift
git commit -m "feat(updater): implement UpdateDownloader.extract() with quarantine strip"
```

---

### Task 9: `UpdateDownloader.verify()` Codesign + Version

**Files:**
- Modify: `Casablanca/Services/Updates/UpdateDownloader.swift`
- Modify: `CasablancaTests/Updates/UpdateDownloaderTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
extension UpdateDownloaderTests {
    private func extractedBundle(_ fixtureName: String) async throws -> URL {
        let zip = try copyFixture(fixtureName)
        let outDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return try await DefaultUpdateDownloader().extract(zipAt: zip, to: outDir)
    }

    func test_verify_returnsBundleVersion_whenNewer() async throws {
        let bundle = try await extractedBundle("Casablanca-99.0.0-macOS")
        let v = try await DefaultUpdateDownloader().verify(bundleAt: bundle, currentVersion: try SemanticVersion(parsing: "0.3.0"))
        XCTAssertEqual(v, try SemanticVersion(parsing: "99.0.0"))
    }

    func test_verify_throwsVersionRegression_whenOlder() async throws {
        let bundle = try await extractedBundle("Casablanca-0.0.1-macOS")
        do {
            _ = try await DefaultUpdateDownloader().verify(bundleAt: bundle, currentVersion: try SemanticVersion(parsing: "0.3.0"))
            XCTFail("expected versionRegression")
        } catch UpdateError.versionRegression {}
    }

    func test_verify_throwsCodesignFailed_whenSealBroken() async throws {
        let bundle = try await extractedBundle("Casablanca-99.0.0-macOS")
        // Tamper with the bundle to break the seal
        try "tampered".data(using: .utf8)!.write(to: bundle.appendingPathComponent("Contents/Resources/extra.txt"))
        do {
            _ = try await DefaultUpdateDownloader().verify(bundleAt: bundle, currentVersion: try SemanticVersion(parsing: "0.3.0"))
            XCTFail("expected codesignFailed")
        } catch UpdateError.codesignFailed {}
    }
}
```

- [ ] **Step 2: Replace the `verify` placeholder**

```swift
    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion {
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path], errorOnFailure: .codesignFailed)

        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlist),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let raw = plist["CFBundleShortVersionString"] as? String
        else {
            throw UpdateError.unzipFailed
        }
        let bundleVersion: SemanticVersion
        do { bundleVersion = try SemanticVersion(parsing: raw) }
        catch { throw UpdateError.unzipFailed }

        guard bundleVersion > currentVersion else { throw UpdateError.versionRegression }
        return bundleVersion
    }
```

- [ ] **Step 3: Run tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateDownloader.swift CasablancaTests/Updates/UpdateDownloaderTests.swift
git commit -m "feat(updater): implement UpdateDownloader.verify() with codesign and version regression"
```

---

### Task 10: `UpdateInstaller` Script Generation

Spec Decisions 10, 11, 16. The script's only job is "wait for sentinel, then `open -n`".

**Files:**
- Create: `Casablanca/Services/Updates/UpdateInstaller.swift`
- Create: `CasablancaTests/Updates/UpdateInstallerScriptTests.swift`

- [ ] **Step 1: Write failing tests for script content**

```swift
import XCTest
@testable import Casablanca

final class UpdateInstallerScriptTests: XCTestCase {
    func test_script_containsSentinelWaitLoop_andTimeout_andOpen() {
        let script = DefaultUpdateInstaller.relaunchScript(
            sentinelPath: URL(fileURLWithPath: "/tmp/relaunch.sentinel"),
            newAppPath: URL(fileURLWithPath: "/Applications/Casablanca.app"),
            logPath: URL(fileURLWithPath: "/tmp/install.log")
        )
        XCTAssertTrue(script.contains("while [ -e"), "missing sentinel wait loop")
        XCTAssertTrue(script.contains("i=$((i+1))"), "missing iteration counter")
        XCTAssertTrue(script.contains("open -n"), "missing open -n")
        XCTAssertTrue(script.contains("set -u"), "missing set -u")
    }

    func test_script_quotesPathsWithSpacesAndQuotes() {
        let script = DefaultUpdateInstaller.relaunchScript(
            sentinelPath: URL(fileURLWithPath: "/tmp/has space/relaunch.sentinel"),
            newAppPath: URL(fileURLWithPath: "/Applications/has 'quote'/Casablanca.app"),
            logPath: URL(fileURLWithPath: "/tmp/log.log")
        )
        XCTAssertTrue(script.contains("'/tmp/has space/relaunch.sentinel'"))
        XCTAssertTrue(script.contains(#"'/Applications/has '\''quote'\''/Casablanca.app'"#))
    }
}
```

- [ ] **Step 2: Implement `UpdateInstaller` protocol + relaunch-script generator**

```swift
// Casablanca/Services/Updates/UpdateInstaller.swift
import Foundation
import OSLog
import Darwin
import AppKit

protocol UpdateInstaller {
    @MainActor
    func install(stagedBundle: URL, currentBundle: URL, paths: UpdatePaths, now: Date) throws
}

final class DefaultUpdateInstaller: UpdateInstaller {
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    @MainActor
    func install(stagedBundle: URL, currentBundle: URL, paths: UpdatePaths, now: Date) throws {
        // Step 1: atomic swap (Task 11 fills this in).
        try atomicSwap(stagedBundle: stagedBundle, currentBundle: currentBundle)

        // Step 2: write relaunch script.
        try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
        let logPath = paths.installLog(at: now)
        let scriptPath = paths.relaunchScript(at: now)
        let body = Self.relaunchScript(
            sentinelPath: paths.sentinel,
            newAppPath: currentBundle,
            logPath: logPath
        )
        try body.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Step 3: spawn helper detached.
        try spawnDetached(scriptPath: scriptPath)
    }

    @MainActor
    func atomicSwap(stagedBundle: URL, currentBundle: URL) throws {
        fatalError("implemented in Task 11")
    }

    func spawnDetached(scriptPath: URL) throws {
        fatalError("implemented in Task 12")
    }

    static func relaunchScript(sentinelPath: URL, newAppPath: URL, logPath: URL) -> String {
        let sentinel = posixSingleQuote(sentinelPath.path)
        let app = posixSingleQuote(newAppPath.path)
        let log = posixSingleQuote(logPath.path)
        return """
        #!/bin/sh
        set -u
        SENTINEL=\(sentinel)
        NEW_APP=\(app)
        LOG=\(log)

        log() { printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

        log "waiting for parent to exit (sentinel: $SENTINEL)"
        i=0
        while [ -e "$SENTINEL" ]; do
          sleep 0.2
          i=$((i+1))
          if [ "$i" -gt 150 ]; then
            log "parent did not remove sentinel within 30s, launching anyway"
            break
          fi
        done

        log "launching $NEW_APP"
        open -n "$NEW_APP"
        """
    }

    static func posixSingleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
```

- [ ] **Step 3: Add to Xcode, run script tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateInstaller.swift CasablancaTests/Updates/UpdateInstallerScriptTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdateInstaller skeleton + relaunch-script generator"
```

---

### Task 11: Atomic Swap Implementation

Spec Decision 10. Uses `FileManager.replaceItem`, which APFS routes through `renamex_np`.

**Files:**
- Modify: `Casablanca/Services/Updates/UpdateInstaller.swift`
- Modify: `CasablancaTests/Updates/UpdateInstallerScriptTests.swift`

- [ ] **Step 1: Append swap tests using temp dirs (no `/Applications` touch)**

```swift
extension UpdateInstallerScriptTests {
    private func makeTempBundle(version: String, in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("Casablanca-\(version).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(version.utf8).write(to: bundle.appendingPathComponent("Contents/version.txt"))
        return bundle
    }

    func test_atomicSwap_replacesDestinationAtomically() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let current = try makeTempBundle(version: "old", in: tempDir)
        let staged = try makeTempBundle(version: "new", in: tempDir)
        let target = tempDir.appendingPathComponent("Casablanca.app", isDirectory: true)
        try FileManager.default.moveItem(at: current, to: target)

        let installer = DefaultUpdateInstaller()
        try await MainActor.run { try installer.atomicSwap(stagedBundle: staged, currentBundle: target) }

        let postSwapVersion = String(data: try Data(contentsOf: target.appendingPathComponent("Contents/version.txt")), encoding: .utf8)
        XCTAssertEqual(postSwapVersion, "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged path should have been consumed")
    }

    func test_atomicSwap_whenDestinationMissing_movesStagedIntoPlace() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let staged = try makeTempBundle(version: "fresh", in: tempDir)
        let target = tempDir.appendingPathComponent("Casablanca.app", isDirectory: true)

        let installer = DefaultUpdateInstaller()
        try await MainActor.run { try installer.atomicSwap(stagedBundle: staged, currentBundle: target) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func test_atomicSwap_throwsSwapFailed_onUnwritableDestination() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let staged = try makeTempBundle(version: "new", in: tempDir)
        let target = tempDir.appendingPathComponent("Casablanca.app", isDirectory: true)
        try FileManager.default.moveItem(at: try makeTempBundle(version: "old", in: tempDir), to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)

        let installer = DefaultUpdateInstaller()
        do {
            try await MainActor.run { try installer.atomicSwap(stagedBundle: staged, currentBundle: target) }
            XCTFail("expected swapFailed")
        } catch UpdateError.swapFailed {}
    }
}
```

- [ ] **Step 2: Replace the `atomicSwap` placeholder**

```swift
    @MainActor
    func atomicSwap(stagedBundle: URL, currentBundle: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: currentBundle.path) {
                _ = try fm.replaceItemAt(currentBundle, withItemAt: stagedBundle)
            } else {
                try fm.createDirectory(
                    at: currentBundle.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: stagedBundle, to: currentBundle)
            }
        } catch {
            throw UpdateError.swapFailed(error.localizedDescription)
        }
    }
```

- [ ] **Step 3: Run tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateInstaller.swift CasablancaTests/Updates/UpdateInstallerScriptTests.swift
git commit -m "feat(updater): atomic bundle swap via FileManager.replaceItem"
```

---

### Task 12: Detached Helper Spawn With `POSIX_SPAWN_SETSID`

Spec Decision 16.

**Files:**
- Modify: `Casablanca/Services/Updates/UpdateInstaller.swift`
- Modify: `CasablancaTests/Updates/UpdateInstallerScriptTests.swift`

- [ ] **Step 1: Append a spawn test that verifies the helper actually runs**

`POSIX_SPAWN_SETSID`'s "survives parent process group" property cannot be cleanly tested from inside an XCTestCase (it would require killing the test process). The spec already lists this as covered by manual verification only. The unit test here verifies the simpler property: the helper is spawned with the right flags + fds and runs to completion. The session-leader behavior is asserted by inspecting the running helper's process group via `ps` while it sleeps.

```swift
extension UpdateInstallerScriptTests {
    func test_spawnDetached_runsScriptToCompletion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let marker = tempDir.appendingPathComponent("marker.txt")
        let pidfile = tempDir.appendingPathComponent("helper.pid")
        let script = tempDir.appendingPathComponent("helper.sh")
        try """
        #!/bin/sh
        echo $$ > '\(pidfile.path)'
        sleep 0.5
        printf 'alive' > '\(marker.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let installer = DefaultUpdateInstaller()
        try installer.spawnDetached(scriptPath: script)

        // Wait for the helper to write its PID, then assert it is its own session leader.
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: pidfile.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pid = Int(try String(contentsOf: pidfile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 0)

        // SETSID makes the helper its own session leader: its sid equals its pid.
        let inspect = Process()
        inspect.launchPath = "/bin/ps"
        inspect.arguments = ["-o", "sess=", "-p", String(pid)]
        let pipe = Pipe()
        inspect.standardOutput = pipe
        try inspect.run()
        inspect.waitUntilExit()
        let sid = Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        XCTAssertEqual(sid, pid, "helper should be its own session leader (POSIX_SPAWN_SETSID)")

        try await Task.sleep(nanoseconds: 1_000_000_000)
        let value = try? String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(value, "alive", "helper script should have completed and written the marker")
    }
}
```

- [ ] **Step 2: Replace the `spawnDetached` placeholder**

```swift
    func spawnDetached(scriptPath: URL) throws {
        var fileActions: posix_spawn_file_actions_t? = nil
        var attrs: posix_spawnattr_t? = nil

        defer {
            if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) }
            if attrs != nil { posix_spawnattr_destroy(&attrs) }
        }

        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attrs) == 0 else {
            throw UpdateError.helperSpawnFailed("posix_spawn_*_init failed")
        }

        // Redirect stdin/stdout/stderr to /dev/null
        for fd in 0...2 {
            let rc = "/dev/null".withCString { devnull in
                posix_spawn_file_actions_addopen(&fileActions, Int32(fd), devnull, fd == 0 ? O_RDONLY : O_WRONLY, 0)
            }
            guard rc == 0 else {
                throw UpdateError.helperSpawnFailed("addopen for fd \(fd) failed: \(rc)")
            }
        }

        // Become a session leader (decouple from parent's process group)
        let flags = Int16(POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attrs, flags) == 0 else {
            throw UpdateError.helperSpawnFailed("posix_spawnattr_setflags failed")
        }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"),
            strdup(scriptPath.path),
            nil
        ]
        defer { for ptr in argv where ptr != nil { free(ptr) } }

        let envp: [UnsafeMutablePointer<CChar>?] = [nil]

        let rc = posix_spawn(&pid, "/bin/sh", &fileActions, &attrs, argv, envp)
        if rc != 0 {
            throw UpdateError.helperSpawnFailed("posix_spawn returned \(rc)")
        }
    }
```

- [ ] **Step 3: Run tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateInstaller.swift CasablancaTests/Updates/UpdateInstallerScriptTests.swift
git commit -m "feat(updater): spawn relaunch helper via posix_spawn with SETSID"
```

---

### Task 13: `UpdateService` State Machine + Check Flow

The coordinator. Drives all UI state. Heavy use of fakes in tests.

**Files:**
- Create: `Casablanca/Services/Updates/UpdateService.swift`
- Create: `CasablancaTests/Updates/UpdateServiceTests.swift`

- [ ] **Step 1: Write failing tests for the check flow (state, transitions, lastCheckAt-on-success-only, manual vs automatic visibility)**

```swift
import XCTest
@testable import Casablanca

@MainActor
final class UpdateServiceTests: XCTestCase {
    private var fakeClient: FakeReleaseClient!
    private var fakeDownloader: FakeDownloader!
    private var fakeInstaller: FakeInstaller!
    private var fakeProbe: FakeSafeToQuitProbe!
    private var defaults: UserDefaults!
    private var preferences: UpdatePreferences!
    private var clock: ClockStub!
    private var paths: UpdatePaths!
    private var tempUpdatesRoot: URL!
    private var terminateInvocationCount = 0

    override func setUpWithError() throws {
        let suite = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        preferences = UpdatePreferences(defaults: defaults)
        fakeClient = FakeReleaseClient()
        fakeDownloader = FakeDownloader()
        fakeInstaller = FakeInstaller()
        fakeProbe = FakeSafeToQuitProbe()
        clock = ClockStub(now: Date(timeIntervalSince1970: 1_700_000_000))
        tempUpdatesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = UpdatePaths(updatesRoot: tempUpdatesRoot)
        terminateInvocationCount = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempUpdatesRoot)
    }

    private func makeService(currentVersion: String = "0.3.0", bundleURL: URL = URL(fileURLWithPath: "/Applications/Casablanca.app")) -> UpdateService {
        UpdateService(
            client: fakeClient,
            downloader: fakeDownloader,
            installer: fakeInstaller,
            probe: fakeProbe,
            preferences: preferences,
            paths: paths,
            currentVersion: try! SemanticVersion(parsing: currentVersion),
            currentBundleURL: bundleURL,
            now: { [unowned self] in self.clock.now },
            terminate: { [unowned self] in self.terminateInvocationCount += 1 }
        )
        // Note: initialCheckDelay/autoCheckInterval parameters are added in Task 15;
        // update this helper accordingly when you reach that task.
    }

    func test_checkNow_setsAvailable_whenNewerReleaseFound() async {
        fakeClient.result = .success(makeRelease("0.4.0"))
        let service = makeService()
        await service.checkNow(trigger: .manual)
        guard case .available(let release) = service.state else { return XCTFail("state=\(service.state)") }
        XCTAssertEqual(release.version, try? SemanticVersion(parsing: "0.4.0"))
        XCTAssertEqual(preferences.lastCheckAt, clock.now)
    }

    func test_checkNow_setsIdle_whenSameOrOlder() async {
        fakeClient.result = .success(makeRelease("0.3.0"))
        let service = makeService()
        await service.checkNow(trigger: .automatic)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(preferences.lastCheckAt, clock.now)
    }

    func test_checkNow_setsIdle_whenSkipped() async {
        preferences.skippedVersion = try! SemanticVersion(parsing: "0.4.0")
        fakeClient.result = .success(makeRelease("0.4.0"))
        let service = makeService()
        await service.checkNow(trigger: .automatic)
        XCTAssertEqual(service.state, .idle)
    }

    func test_checkNow_silentOnAutoFailure_andDoesNotAdvanceLastCheckAt() async {
        fakeClient.result = .failure(UpdateError.checkFailed(URLError(.notConnectedToInternet)))
        let service = makeService()
        await service.checkNow(trigger: .automatic)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(preferences.lastCheckAt)
    }

    func test_checkNow_alertsOnManualFailure() async {
        fakeClient.result = .failure(UpdateError.checkFailed(URLError(.notConnectedToInternet)))
        let service = makeService()
        await service.checkNow(trigger: .manual)
        guard case .error(_, let visibility) = service.state else { return XCTFail("state=\(service.state)") }
        XCTAssertEqual(visibility, .alert)
        XCTAssertNil(preferences.lastCheckAt)
    }

    func test_skipVersion_persists_andDismisses() async {
        let release = makeRelease("0.4.0")
        let service = makeService()
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)
        service.skipVersion(release)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(preferences.skippedVersion, release.version)
    }

    func test_remindLater_returnsToIdle_withoutPersistingSkip() async {
        let release = makeRelease("0.4.0")
        let service = makeService()
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)
        service.remindLater()
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(preferences.skippedVersion)
    }

    private func makeRelease(_ version: String) -> ReleaseInfo {
        ReleaseInfo(
            version: try! SemanticVersion(parsing: version),
            tag: "v\(version)",
            title: "Casablanca \(version)",
            bodyMarkdown: "notes",
            assetURL: URL(string: "https://example.com/Casablanca-\(version)-macOS.zip")!,
            assetByteCount: 1
        )
    }
}

// MARK: - Fakes

@MainActor
final class FakeReleaseClient: GitHubReleaseClient {
    var result: Result<ReleaseInfo, Error> = .failure(URLError(.unknown))
    func fetchLatestRelease(includePrereleases: Bool) async throws -> ReleaseInfo {
        try result.get()
    }
}

@MainActor
final class FakeDownloader: UpdateDownloader {
    var downloadResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/x.zip"))
    var extractResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/Casablanca.app"))
    var verifyResult: Result<SemanticVersion, Error> = .success(try! SemanticVersion(parsing: "99.0.0"))
    var progressValues: [Double] = [0.5, 1.0]

    func download(from url: URL, expectedByteCount: Int64, to destination: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        for value in progressValues { progress(value) }
        return try downloadResult.get()
    }
    func extract(zipAt source: URL, to destinationDir: URL) async throws -> URL { try extractResult.get() }
    func verify(bundleAt url: URL, currentVersion: SemanticVersion) async throws -> SemanticVersion { try verifyResult.get() }
}

@MainActor
final class FakeInstaller: UpdateInstaller {
    var installError: Error?
    var installCallCount = 0
    func install(stagedBundle: URL, currentBundle: URL, paths: UpdatePaths, now: Date) throws {
        installCallCount += 1
        if let installError { throw installError }
    }
}

@MainActor
final class FakeSafeToQuitProbe: SafeToQuitProbe {
    var reason: String?
    func reasonInstallShouldWait() -> String? { reason }
}

final class ClockStub: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}
```

- [ ] **Step 2: Implement `UpdateService` (check + skip + later only; install in Task 14)**

```swift
// Casablanca/Services/Updates/UpdateService.swift
import Foundation
import OSLog
import AppKit

@MainActor
@Observable
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking(trigger: CheckTrigger)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case staged(stagedBundle: URL, ReleaseInfo)
        case error(UpdateError, visibility: ErrorVisibility)
    }

    enum CheckTrigger: Equatable { case automatic, manual }
    enum ErrorVisibility: Equatable { case silent, alert }

    private(set) var state: State = .idle

    private let client: GitHubReleaseClient
    private let downloader: UpdateDownloader
    private let installer: UpdateInstaller
    private let probe: SafeToQuitProbe
    private var preferences: UpdatePreferences
    private let paths: UpdatePaths
    private let currentVersion: SemanticVersion
    private let currentBundleURL: URL
    private let now: () -> Date
    private let terminate: () -> Void
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init(
        client: GitHubReleaseClient,
        downloader: UpdateDownloader,
        installer: UpdateInstaller,
        probe: SafeToQuitProbe,
        preferences: UpdatePreferences,
        paths: UpdatePaths,
        currentVersion: SemanticVersion,
        currentBundleURL: URL,
        now: @escaping () -> Date,
        terminate: @escaping () -> Void
    ) {
        self.client = client
        self.downloader = downloader
        self.installer = installer
        self.probe = probe
        self.preferences = preferences
        self.paths = paths
        self.currentVersion = currentVersion
        self.currentBundleURL = currentBundleURL
        self.now = now
        self.terminate = terminate
    }

    func checkNow(trigger: CheckTrigger) async {
        state = .checking(trigger: trigger)
        do {
            let release = try await client.fetchLatestRelease(includePrereleases: preferences.includePrereleases)
            preferences.lastCheckAt = now()
            if release.version <= currentVersion {
                state = .idle
                return
            }
            if let skipped = preferences.skippedVersion, release.version <= skipped {
                state = .idle
                return
            }
            state = .available(release)
        } catch {
            let mapped = (error as? UpdateError) ?? .checkFailed(URLError(.unknown))
            logger.error("checkNow failed: \(String(describing: mapped))")
            state = .error(mapped, visibility: trigger == .manual ? .alert : .silent)
        }
    }

    func skipVersion(_ release: ReleaseInfo) {
        preferences.skippedVersion = release.version
        state = .idle
    }

    func remindLater() {
        state = .idle
    }

    func dismissError() {
        state = .idle
    }

    // installUpdate(_:) - implemented in Task 14
}
```

- [ ] **Step 3: Add to Xcode, run tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateService.swift CasablancaTests/Updates/UpdateServiceTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdateService state machine for check / skip / later"
```

---

### Task 14: `UpdateService.installUpdate()` Flow

Pulls together downloader + probe + installer + termination.

**Files:**
- Modify: `Casablanca/Services/Updates/UpdateService.swift`
- Modify: `CasablancaTests/Updates/UpdateServiceTests.swift`

- [ ] **Step 1: Append failing install-flow tests**

```swift
extension UpdateServiceTests {
    func test_installUpdate_walksThroughDownloadingExtractVerifyToStagedAndTerminates() async {
        let release = makeRelease("0.4.0")
        let service = makeService()
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)

        await service.installUpdate(release)
        XCTAssertEqual(fakeInstaller.installCallCount, 1)
        XCTAssertEqual(terminateInvocationCount, 1)
    }

    func test_installUpdate_refusedWhenSafeToQuitReturnsReason() async {
        let release = makeRelease("0.4.0")
        let service = makeService()
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)
        fakeProbe.reason = "an active recording"

        await service.installUpdate(release)
        guard case .error(.notSafeToQuit(let reason), let visibility) = service.state else {
            return XCTFail("state=\(service.state)")
        }
        XCTAssertEqual(reason, "an active recording")
        XCTAssertEqual(visibility, .alert)
        XCTAssertEqual(fakeInstaller.installCallCount, 0)
        XCTAssertEqual(terminateInvocationCount, 0)

        // After dismiss, return to .available so user can retry without re-checking.
        service.dismissError()
        guard case .available = service.state else { return XCTFail("expected .available") }
    }

    func test_installUpdate_alertOnDownloadFailure() async {
        let release = makeRelease("0.4.0")
        let service = makeService()
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)
        fakeDownloader.downloadResult = .failure(UpdateError.downloadFailed(URLError(.networkConnectionLost)))

        await service.installUpdate(release)
        guard case .error(.downloadFailed, .alert) = service.state else { return XCTFail("state=\(service.state)") }
    }

    func test_installUpdate_alertOnSwapFailure_originalAppUntouched() async {
        let release = makeRelease("0.4.0")
        let service = makeService()
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)
        fakeInstaller.installError = UpdateError.swapFailed("permission denied")

        await service.installUpdate(release)
        guard case .error(.swapFailed, .alert) = service.state else { return XCTFail("state=\(service.state)") }
        XCTAssertEqual(terminateInvocationCount, 0, "must not terminate when swap failed")
    }

    func test_installUpdate_refusesWhenAppIsNotInApplications() async {
        let release = makeRelease("0.4.0")
        let bundleURL = URL(fileURLWithPath: "/tmp/Casablanca.app")
        let service = makeService(bundleURL: bundleURL)
        fakeClient.result = .success(release)
        await service.checkNow(trigger: .manual)

        await service.installUpdate(release)
        guard case .error(.notInApplicationsFolder, .alert) = service.state else { return XCTFail("state=\(service.state)") }
        XCTAssertEqual(fakeInstaller.installCallCount, 0)
    }
}
```

- [ ] **Step 2: Replace the existing `UpdateService` body with the install-flow version**

Replace `Casablanca/Services/Updates/UpdateService.swift` in full:

```swift
import Foundation
import OSLog
import AppKit

@MainActor
@Observable
final class UpdateService {
    enum State: Equatable {
        case idle
        case checking(trigger: CheckTrigger)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case staged(stagedBundle: URL, ReleaseInfo)
        case error(UpdateError, visibility: ErrorVisibility)
    }

    enum CheckTrigger: Equatable { case automatic, manual }
    enum ErrorVisibility: Equatable { case silent, alert }

    private(set) var state: State = .idle

    private let client: GitHubReleaseClient
    private let downloader: UpdateDownloader
    private let installer: UpdateInstaller
    private let probe: SafeToQuitProbe
    private var preferences: UpdatePreferences
    private let paths: UpdatePaths
    private let currentVersion: SemanticVersion
    private let currentBundleURL: URL
    private let now: () -> Date
    private let terminate: () -> Void
    private var lastAvailableRelease: ReleaseInfo?
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init(
        client: GitHubReleaseClient,
        downloader: UpdateDownloader,
        installer: UpdateInstaller,
        probe: SafeToQuitProbe,
        preferences: UpdatePreferences,
        paths: UpdatePaths,
        currentVersion: SemanticVersion,
        currentBundleURL: URL,
        now: @escaping () -> Date,
        terminate: @escaping () -> Void
    ) {
        self.client = client
        self.downloader = downloader
        self.installer = installer
        self.probe = probe
        self.preferences = preferences
        self.paths = paths
        self.currentVersion = currentVersion
        self.currentBundleURL = currentBundleURL
        self.now = now
        self.terminate = terminate
    }

    func checkNow(trigger: CheckTrigger) async {
        lastAvailableRelease = nil
        state = .checking(trigger: trigger)
        do {
            let release = try await client.fetchLatestRelease(includePrereleases: preferences.includePrereleases)
            preferences.lastCheckAt = now()
            if release.version <= currentVersion {
                state = .idle
                return
            }
            if let skipped = preferences.skippedVersion, release.version <= skipped {
                state = .idle
                return
            }
            lastAvailableRelease = release
            state = .available(release)
        } catch {
            let mapped = (error as? UpdateError) ?? .checkFailed(URLError(.unknown))
            logger.error("checkNow failed: \(String(describing: mapped))")
            state = .error(mapped, visibility: trigger == .manual ? .alert : .silent)
        }
    }

    func installUpdate(_ release: ReleaseInfo) async {
        guard currentBundleURL.path == "/Applications/Casablanca.app" else {
            state = .error(.notInApplicationsFolder, visibility: .alert)
            return
        }
        if let reason = probe.reasonInstallShouldWait() {
            state = .error(.notSafeToQuit(reason: reason), visibility: .alert)
            return
        }

        let stagingDir = paths.stagingDirectory(for: release.version)
        let zipPath = stagingDir.appendingPathComponent("Casablanca.zip")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            state = .error(.swapFailed(error.localizedDescription), visibility: .alert)
            return
        }

        state = .downloading(release, progress: 0)
        do {
            _ = try await downloader.download(
                from: release.assetURL,
                expectedByteCount: release.assetByteCount,
                to: zipPath,
                progress: { [weak self] value in
                    Task { @MainActor in self?.state = .downloading(release, progress: value) }
                }
            )
            let bundle = try await downloader.extract(zipAt: zipPath, to: stagingDir)
            _ = try await downloader.verify(bundleAt: bundle, currentVersion: currentVersion)

            state = .staged(stagedBundle: bundle, release)
            try installer.install(stagedBundle: bundle, currentBundle: currentBundleURL, paths: paths, now: now())
            terminate()
        } catch {
            let mapped = (error as? UpdateError) ?? .downloadFailed(URLError(.unknown))
            logger.error("install failed: \(String(describing: mapped))")
            state = .error(mapped, visibility: .alert)
        }
    }

    func skipVersion(_ release: ReleaseInfo) {
        preferences.skippedVersion = release.version
        lastAvailableRelease = nil
        state = .idle
    }

    func remindLater() {
        lastAvailableRelease = nil
        state = .idle
    }

    func dismissError() {
        if case .error(_, _) = state, let release = lastAvailableRelease {
            state = .available(release)
            return
        }
        state = .idle
    }

    // startScheduling()/stopScheduling() are added in Task 15.
}
```

Note `lastAvailableRelease` is reset at the start of `checkNow` and on `skipVersion`/`remindLater`, and set after `state = .available(release)`. After any error the user can dismiss and bounce back to the prompt without re-fetching the release info.

- [ ] **Step 3: Run install-flow tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateService.swift CasablancaTests/Updates/UpdateServiceTests.swift
git commit -m "feat(updater): UpdateService.installUpdate() with safe-to-quit and location guards"
```

---

### Task 15: `UpdateService` 24h Scheduling

Spec Decision 4 + 17. Adds `startScheduling()` and the recurring auto-check.

**Files:**
- Modify: `Casablanca/Services/Updates/UpdateService.swift`
- Modify: `CasablancaTests/Updates/UpdateServiceTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
extension UpdateServiceTests {
    func test_startScheduling_skipsCheck_whenLastCheckWithin24h() async {
        preferences.lastCheckAt = clock.now.addingTimeInterval(-3600) // 1h ago
        fakeClient.result = .success(makeRelease("0.4.0"))
        let service = makeService()
        service.startScheduling()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.state, .idle)
    }

    func test_startScheduling_runsImmediately_whenLastCheckOlderThan24h() async {
        preferences.lastCheckAt = clock.now.addingTimeInterval(-25 * 3600)
        fakeClient.result = .success(makeRelease("0.4.0"))
        let service = makeService()
        service.startScheduling()
        for _ in 0..<50 {
            if case .available = service.state { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("expected .available within 5s, got \(service.state)")
    }

    func test_startScheduling_doesNothing_whenAutoChecksDisabled() async {
        preferences.automaticChecksEnabled = false
        preferences.lastCheckAt = nil
        fakeClient.result = .success(makeRelease("0.4.0"))
        let service = makeService()
        service.startScheduling()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(service.state, .idle)
    }
}
```

- [ ] **Step 2: Add `startScheduling()` to `UpdateService` (initial delay is injectable so tests don't wait 5s)**

In the existing initializer, add two new parameters with defaults:

```swift
    private let initialCheckDelay: TimeInterval
    private let autoCheckInterval: TimeInterval

    init(
        client: GitHubReleaseClient,
        downloader: UpdateDownloader,
        installer: UpdateInstaller,
        probe: SafeToQuitProbe,
        preferences: UpdatePreferences,
        paths: UpdatePaths,
        currentVersion: SemanticVersion,
        currentBundleURL: URL,
        now: @escaping () -> Date,
        terminate: @escaping () -> Void,
        initialCheckDelay: TimeInterval = 5,
        autoCheckInterval: TimeInterval = 24 * 3600
    ) {
        // ... existing assignments ...
        self.initialCheckDelay = initialCheckDelay
        self.autoCheckInterval = autoCheckInterval
    }
```

Add the scheduling methods:

```swift
    private var schedulerTask: Task<Void, Never>?

    func startScheduling() {
        schedulerTask?.cancel()
        guard preferences.automaticChecksEnabled else { return }
        schedulerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runScheduleLoop()
        }
    }

    func stopScheduling() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    private func runScheduleLoop() async {
        try? await Task.sleep(nanoseconds: UInt64(initialCheckDelay * 1_000_000_000))
        while !Task.isCancelled {
            if shouldRunAutomaticCheckNow() {
                await self.checkNow(trigger: .automatic)
            }
            try? await Task.sleep(nanoseconds: UInt64(autoCheckInterval * 1_000_000_000))
        }
    }

    private func shouldRunAutomaticCheckNow() -> Bool {
        guard preferences.automaticChecksEnabled else { return false }
        guard case .idle = state else { return false }
        if let last = preferences.lastCheckAt {
            return now().timeIntervalSince(last) >= autoCheckInterval
        }
        return true
    }
```

Update `makeService` in `UpdateServiceTests` to pass `initialCheckDelay: 0.05` and `autoCheckInterval: 60`:

```swift
    private func makeService(currentVersion: String = "0.3.0", bundleURL: URL = URL(fileURLWithPath: "/Applications/Casablanca.app")) -> UpdateService {
        UpdateService(
            client: fakeClient,
            downloader: fakeDownloader,
            installer: fakeInstaller,
            probe: fakeProbe,
            preferences: preferences,
            paths: paths,
            currentVersion: try! SemanticVersion(parsing: currentVersion),
            currentBundleURL: bundleURL,
            now: { [unowned self] in self.clock.now },
            terminate: { [unowned self] in self.terminateInvocationCount += 1 },
            initialCheckDelay: 0.05,
            autoCheckInterval: 60
        )
    }
```

The 50ms initial delay + 60s recheck interval keep the scheduling tests fast and free of flakes.

- [ ] **Step 3: Run tests, expect pass, commit**

```bash
git add Casablanca/Services/Updates/UpdateService.swift CasablancaTests/Updates/UpdateServiceTests.swift
git commit -m "feat(updater): 24h auto-check scheduler with initial-launch eligibility window"
```

---

### Task 16: `ApplicationsLocationCheck`

Spec section "First-Launch Location Check".

**Files:**
- Create: `Casablanca/Utilities/ApplicationsLocationCheck.swift`
- Create: `CasablancaTests/Updates/ApplicationsLocationCheckTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Casablanca

@MainActor
final class ApplicationsLocationCheckTests: XCTestCase {
    private var defaults: UserDefaults!
    private var presenter: SpyAlertPresenter!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")
        presenter = SpyAlertPresenter()
    }

    func test_returnsImmediately_whenAlreadyInApplications() async {
        let check = ApplicationsLocationCheck(
            bundleURL: URL(fileURLWithPath: "/Applications/Casablanca.app"),
            defaults: defaults,
            alertPresenter: presenter
        )
        await check.runOnceIfNeeded()
        XCTAssertEqual(presenter.shownAlerts, [])
    }

    func test_returnsImmediately_whenFlagAlreadySet() async {
        defaults.set(true, forKey: "updater.applicationsLocationPromptShown")
        let check = ApplicationsLocationCheck(
            bundleURL: URL(fileURLWithPath: "/Users/me/Downloads/Casablanca.app"),
            defaults: defaults,
            alertPresenter: presenter
        )
        await check.runOnceIfNeeded()
        XCTAssertEqual(presenter.shownAlerts, [])
    }

    func test_showsTranslocationAlert_whenAtTranslocatedPath() async {
        let translocated = URL(fileURLWithPath: "/private/var/folders/12/abcd/T/AppTranslocation/XYZ/d/Casablanca.app")
        let check = ApplicationsLocationCheck(
            bundleURL: translocated,
            defaults: defaults,
            alertPresenter: presenter
        )
        await check.runOnceIfNeeded()
        XCTAssertEqual(presenter.shownAlerts.first?.kind, .translocated)
    }

    func test_showsMovePrompt_whenInDownloads_andFlagUnset() async {
        let check = ApplicationsLocationCheck(
            bundleURL: URL(fileURLWithPath: "/Users/me/Downloads/Casablanca.app"),
            defaults: defaults,
            alertPresenter: presenter
        )
        await check.runOnceIfNeeded()
        XCTAssertEqual(presenter.shownAlerts.first?.kind, .moveToApplications)
    }

    func test_setsFlag_whenUserPicksNotNow() async {
        presenter.responseForMoveAlert = .notNow
        let check = ApplicationsLocationCheck(
            bundleURL: URL(fileURLWithPath: "/Users/me/Downloads/Casablanca.app"),
            defaults: defaults,
            alertPresenter: presenter
        )
        await check.runOnceIfNeeded()
        XCTAssertTrue(defaults.bool(forKey: "updater.applicationsLocationPromptShown"))
    }
}

@MainActor
final class SpyAlertPresenter: ApplicationsLocationAlertPresenter {
    enum ShownKind: Equatable { case moveToApplications, translocated, replaceConfirmation }
    struct Shown: Equatable { let kind: ShownKind }
    var shownAlerts: [Shown] = []
    var responseForMoveAlert: ApplicationsLocationCheck.MoveResponse = .notNow

    func presentMoveToApplications() async -> ApplicationsLocationCheck.MoveResponse {
        shownAlerts.append(Shown(kind: .moveToApplications))
        return responseForMoveAlert
    }
    func presentTranslocated() async -> ApplicationsLocationCheck.MoveResponse {
        shownAlerts.append(Shown(kind: .translocated))
        return responseForMoveAlert
    }
    func presentReplaceConfirmation() async -> Bool {
        shownAlerts.append(Shown(kind: .replaceConfirmation))
        return false
    }
    func presentMoveFailed(_ message: String) async {}
}
```

- [ ] **Step 2: Implement the helper**

```swift
// Casablanca/Utilities/ApplicationsLocationCheck.swift
import Foundation
import AppKit
import OSLog

@MainActor
protocol ApplicationsLocationAlertPresenter: AnyObject {
    func presentMoveToApplications() async -> ApplicationsLocationCheck.MoveResponse
    func presentTranslocated() async -> ApplicationsLocationCheck.MoveResponse
    func presentReplaceConfirmation() async -> Bool
    func presentMoveFailed(_ message: String) async
}

@MainActor
final class ApplicationsLocationCheck {
    enum MoveResponse: Equatable { case moveToApplications, notNow, quit }
    private static let flagKey = "updater.applicationsLocationPromptShown"
    private static let applicationsBundlePath = "/Applications/Casablanca.app"

    private let bundleURL: URL
    private let defaults: UserDefaults
    private let presenter: ApplicationsLocationAlertPresenter
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init(bundleURL: URL, defaults: UserDefaults, alertPresenter: ApplicationsLocationAlertPresenter) {
        self.bundleURL = bundleURL
        self.defaults = defaults
        self.presenter = alertPresenter
    }

    func runOnceIfNeeded() async {
        if bundleURL.path == Self.applicationsBundlePath { return }
        if defaults.bool(forKey: Self.flagKey) && !isTranslocated { return }

        let response: MoveResponse
        if isTranslocated {
            response = await presenter.presentTranslocated()
        } else {
            response = await presenter.presentMoveToApplications()
        }

        switch response {
        case .moveToApplications:
            await performMove()
        case .notNow:
            defaults.set(true, forKey: Self.flagKey)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private var isTranslocated: Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    private func performMove() async {
        let target = URL(fileURLWithPath: Self.applicationsBundlePath)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) {
                let confirmed = await presenter.presentReplaceConfirmation()
                if !confirmed {
                    return
                }
                _ = try fm.replaceItemAt(target, withItemAt: bundleURL)
            } else {
                try fm.copyItem(at: bundleURL, to: target)
            }
            try? NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
            NSApp.terminate(nil)
        } catch {
            logger.error("move-to-applications failed: \(error.localizedDescription)")
            await presenter.presentMoveFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 3: Add to Xcode (Casablanca target), run, expect pass, commit**

```bash
git add Casablanca/Utilities/ApplicationsLocationCheck.swift CasablancaTests/Updates/ApplicationsLocationCheckTests.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add ApplicationsLocationCheck with translocation handling"
```

---

### Task 17: Sentinel-File Lifecycle + Launch-Time Housekeeping

Spec Decision 11 + Phase 9 launch-time ordering.

**Files:**
- Create: `Casablanca/Services/Updates/UpdateLaunchHousekeeping.swift`

- [ ] **Step 1: Add the housekeeping helper**

Create `Casablanca/Services/Updates/UpdateLaunchHousekeeping.swift`:

```swift
import Foundation
import OSLog

@MainActor
struct UpdateLaunchHousekeeping {
    let paths: UpdatePaths
    private static let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    /// Spec Phase 9, in order: wipe staging, delete orphan relaunch scripts, unconditionally rewrite the sentinel.
    func runOnLaunch() {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.stagingRoot.path) {
            try? fm.removeItem(at: paths.stagingRoot)
        }
        if let entries = try? fm.contentsOfDirectory(at: paths.updatesRoot, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasPrefix("relaunch-") && url.pathExtension == "sh" {
                try? fm.removeItem(at: url)
            }
        }
        try? fm.createDirectory(at: paths.updatesRoot, withIntermediateDirectories: true)
        try? Data().write(to: paths.sentinel)
        Self.logger.info("launch housekeeping done; sentinel at \(paths.sentinel.path)")
    }

    func removeSentinelOnTerminate() {
        try? FileManager.default.removeItem(at: paths.sentinel)
    }
}
```

Add to Xcode (Casablanca target).

- [ ] **Step 2: Add to Xcode (Casablanca target)**

Wiring into `CasablancaApp` happens in Task 21; this task only creates the helper file.

Commit:

```bash
git add Casablanca/Services/Updates/UpdateLaunchHousekeeping.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdateLaunchHousekeeping for staging wipe + sentinel rewrite"
```

(Smoke-test housekeeping behavior in the manual verification at the end of the plan; pure file I/O is not unit-tested here.)

---

### Task 18: `UpdatePromptView`

Sheet shown for `.available`. Three buttons + release-notes preview.

**Files:**
- Create: `Casablanca/Views/UpdatePromptView.swift`

- [ ] **Step 1: Implement the view**

```swift
// Casablanca/Views/UpdatePromptView.swift
import SwiftUI

struct UpdatePromptView: View {
    let release: ReleaseInfo
    let onInstall: () -> Void
    let onLater: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Casablanca \(release.version.description) is available")
                .font(.title2.bold())
            Text("You're running \(Bundle.main.shortVersionString). Updating restarts the app.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(release.bodyMarkdown)
                    .font(.system(.body, design: .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .padding(.horizontal, 4)

            HStack {
                Button("Skip This Version", action: onSkip)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Remind Me Later", action: onLater)
                    .buttonStyle(.bordered)
                Button("Install Update", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private extension Bundle {
    var shortVersionString: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }
}
```

- [ ] **Step 2: Add to Xcode (Casablanca target). No tests — pure presentation. Commit**

```bash
git add Casablanca/Views/UpdatePromptView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdatePromptView sheet"
```

---

### Task 19: `UpdateProgressView`

Sheet shown during `.downloading` and `.staged`.

**Files:**
- Create: `Casablanca/Views/UpdateProgressView.swift`

- [ ] **Step 1: Implement the view**

```swift
// Casablanca/Views/UpdateProgressView.swift
import SwiftUI

struct UpdateProgressView: View {
    let release: ReleaseInfo
    let progress: Double
    let phase: Phase
    let onCancel: () -> Void

    enum Phase { case downloading, staged }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installing Casablanca \(release.version.description)")
                .font(.headline)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if phase == .downloading {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var label: String {
        switch phase {
        case .downloading: return "Downloading… \(Int(progress * 100))%"
        case .staged: return "Preparing to install. Casablanca will restart."
        }
    }
}
```

- [ ] **Step 2: Add to Xcode, commit**

```bash
git add Casablanca/Views/UpdateProgressView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): add UpdateProgressView sheet"
```

---

### Task 20: `UpdatesSettingsView` + Settings Integration

Spec Settings Pane section.

**Files:**
- Create: `Casablanca/Views/UpdatesSettingsView.swift`
- Modify: `Casablanca/Views/SettingsView.swift`

- [ ] **Step 1: Implement `UpdatesSettingsView`**

```swift
// Casablanca/Views/UpdatesSettingsView.swift
import SwiftUI

struct UpdatesSettingsView: View {
    let updateService: UpdateService
    @State private var preferences = UpdatePreferences()
    @State private var showHidden = false
    @State private var lastCheckedDisplay = "—"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { preferences.automaticChecksEnabled },
                    set: { newValue in
                        preferences.automaticChecksEnabled = newValue
                        if newValue { updateService.startScheduling() } else { updateService.stopScheduling() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically check for updates")
                        Text("Checks GitHub every 24 hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Last checked: \(lastCheckedDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for Updates…") {
                    Task { await updateService.checkNow(trigger: .manual) }
                }
            } header: {
                Text("Updates")
                    .onTapGesture(count: 1) { /* no-op */ }
                    .gesture(
                        TapGesture()
                            .modifiers(.option)
                            .onEnded { showHidden.toggle() }
                    )
            }

            if showHidden {
                Section("Advanced") {
                    Toggle("Include prereleases", isOn: Binding(
                        get: { preferences.includePrereleases },
                        set: { preferences.includePrereleases = $0 }
                    ))
                    Button("Reveal install logs in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([UpdatePaths.default.logsRoot])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            lastCheckedDisplay = preferences.lastCheckAt.map { Self.dateFormatter.string(from: $0) } ?? "—"
        }
    }
}
```

- [ ] **Step 2: Add the Updates tab to `SettingsView`**

Modify `Casablanca/Views/SettingsView.swift`. The current `body` uses `TabView`. Add a third tab.

Append the existing `TabView` block with:

```swift
            UpdatesSettingsView(updateService: appModel.updateService)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
```

`SettingsView` does not currently take an `appModel`. To inject it without restructuring the view, add an `@Environment(AppModel.self)` lookup at the top of `SettingsView`:

```swift
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    // … existing code …
```

`AppModel` becomes the host of `updateService`; this is wired in Task 21.

- [ ] **Step 3: Add to Xcode, commit**

```bash
git add Casablanca/Views/UpdatesSettingsView.swift Casablanca/Views/SettingsView.swift Casablanca.xcodeproj/project.pbxproj
git commit -m "feat(updater): Updates tab in Settings with Option-click reveal"
```

---

### Task 21: Wire Everything Into `CasablancaApp` + AppModel + App Menu (Including Real `SafeToQuitProbe`)

Spec sections "Architecture", "First-Launch Location Check", Decision 12, and Phase 9.

This task hoists `AudioRecordingService`, `TranscriptionService`, and `SummarizationService` (currently `@State` on `ContentView` and `RecordedMeetingView`) into `AppModel` so the `SafeToQuitProbe` reads their real state. Without this hoist, the install gate would be a no-op and a recording could be cut off mid-flight — a regression vs. spec Decision 12.

This task is larger than the others; treat each numbered step as its own commit so the diff is reviewable.

**Files:**
- Modify: `Casablanca/CasablancaApp.swift`
- Modify: `Casablanca/Views/ContentView.swift`
- Modify: `Casablanca/Views/RecordedMeetingView.swift`

- [ ] **Step 1: Hoist services into `AppModel`**

Replace the existing `AppModel` definition in `Casablanca/CasablancaApp.swift` with the wired version below. `AudioRecordingService`, `TranscriptionService`, and `SummarizationService` move from view-local `@State` into `AppModel` so the probe can read them.

- [ ] **Step 2: Update `ContentView` to consume the hoisted services**

In `Casablanca/Views/ContentView.swift`, replace:

```swift
    @State private var recordingService = AudioRecordingService()
    @State private var transcriptionService = TranscriptionService()
```

with:

```swift
    @Environment(AppModel.self) private var appModel
    private var recordingService: AudioRecordingService { appModel.recordingService }
    private var transcriptionService: TranscriptionService { appModel.transcriptionService }
```

The `interruptionMonitor`, `interruptionNotifier`, and `interruptionCoordinator` `@State` properties stay in `ContentView` for now — they're already wired against the hoisted `recordingService` via property accessors above.

- [ ] **Step 3: Update `RecordedMeetingView` to consume the hoisted summarization service**

In `Casablanca/Views/RecordedMeetingView.swift`, replace:

```swift
    @State private var summarizationService = SummarizationService()
```

with:

```swift
    @Environment(AppModel.self) private var appModel
    private var summarizationService: SummarizationService { appModel.summarizationService }
```

- [ ] **Step 4: Replace `CasablancaApp.swift` with the wired version**

```swift
import SwiftUI
import SwiftData
import AppKit
import OSLog

@main
struct CasablancaApp: App {
    static let mainWindowID = "main-window"

    @State private var appModel: AppModel
    private let sharedModelContainer: ModelContainer

    init() {
        do {
            sharedModelContainer = try ModelContainer(for: Meeting.self, TodoItem.self)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
        _appModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(viewModel: appModel.meetingListViewModel)
                .environment(appModel)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    await appModel.bootstrap()
                }
                .sheet(isPresented: appModel.isAvailableSheetPresented) {
                    if case .available(let release) = appModel.updateService.state {
                        UpdatePromptView(
                            release: release,
                            onInstall: { Task { await appModel.updateService.installUpdate(release) } },
                            onLater: { appModel.updateService.remindLater() },
                            onSkip: { appModel.updateService.skipVersion(release) }
                        )
                    }
                }
                .sheet(isPresented: appModel.isProgressSheetPresented) {
                    if let (release, progress, phase) = appModel.progressSheetParameters() {
                        UpdateProgressView(
                            release: release,
                            progress: progress,
                            phase: phase,
                            onCancel: { /* TODO: cancel-mid-download in a follow-up; for now no-op */ }
                        )
                    }
                }
                .alert(
                    "Update",
                    isPresented: appModel.isErrorAlertPresented,
                    presenting: appModel.currentAlertError(),
                    actions: { _ in
                        Button("OK") { appModel.updateService.dismissError() }
                    },
                    message: { error in
                        Text(error.errorDescription ?? "Update failed.")
                    }
                )
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: CasaLayout.windowDefaultWidth, height: CasaLayout.windowDefaultHeight)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Manual Meeting") {
                    appModel.meetingListViewModel.beginManualMeeting()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await appModel.updateService.checkNow(trigger: .manual) }
                }
            }
        }

        MenuBarExtra("Casablanca", systemImage: "record.circle") {
            MenuBarMeetingView(viewModel: appModel.meetingListViewModel)
        }
        .modelContainer(sharedModelContainer)
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let calendarService = CalendarService()
    let permissionsManager = PermissionsManager()
    let recordingService = AudioRecordingService()
    let transcriptionService = TranscriptionService()
    let summarizationService = SummarizationService()
    let meetingListViewModel: MeetingListViewModel
    let updateService: UpdateService
    let applicationsLocationCheck: ApplicationsLocationCheck
    private let housekeeping: UpdateLaunchHousekeeping
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init() {
        meetingListViewModel = MeetingListViewModel(calendarService: calendarService)

        let paths = UpdatePaths.default
        housekeeping = UpdateLaunchHousekeeping(paths: paths)

        // Real probe reading the hoisted @Observable services. Closures defer
        // property reads to call time so they always see current state.
        let recording = recordingService
        let transcription = transcriptionService
        let summarization = summarizationService
        let probe = ClosureSafeToQuitProbe(
            isRecordingActive: { recording.isRecording },
            isTranscriptionActive: { transcription.isTranscribing },
            isSummarizationActive: { summarization.isSummarizing }
        )
        let currentVersion: SemanticVersion
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let parsed = try? SemanticVersion(parsing: raw) {
            currentVersion = parsed
        } else {
            currentVersion = SemanticVersion(major: 0, minor: 0, patch: 0)
        }
        let bundleURL = Bundle.main.bundleURL

        updateService = UpdateService(
            client: URLSessionGitHubReleaseClient(owner: "76r75r6qbh-sys", repo: "meeting-assistant"),
            downloader: DefaultUpdateDownloader(),
            installer: DefaultUpdateInstaller(),
            probe: probe,
            preferences: UpdatePreferences(),
            paths: paths,
            currentVersion: currentVersion,
            currentBundleURL: bundleURL,
            now: { Date() },
            terminate: { NSApp.terminate(nil) }
        )

        applicationsLocationCheck = ApplicationsLocationCheck(
            bundleURL: bundleURL,
            defaults: .standard,
            alertPresenter: NSApplicationsLocationAlertPresenter()
        )
    }

    func bootstrap() async {
        housekeeping.runOnLaunch()
        registerSentinelCleanup()

        await permissionsManager.checkAll()
        if calendarService.authorizationStatus == .fullAccess {
            await calendarService.fetchUpcomingEvents()
        }
        await applicationsLocationCheck.runOnceIfNeeded()
        updateService.startScheduling()
    }

    private func registerSentinelCleanup() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [housekeeping] _ in
            housekeeping.removeSentinelOnTerminate()
        }
    }

    // MARK: Sheet / alert bindings

    var isAvailableSheetPresented: Binding<Bool> {
        Binding(
            get: { if case .available = self.updateService.state { return true } else { return false } },
            set: { _ in }
        )
    }

    var isProgressSheetPresented: Binding<Bool> {
        Binding(
            get: {
                switch self.updateService.state {
                case .downloading, .staged: return true
                default: return false
                }
            },
            set: { _ in }
        )
    }

    var isErrorAlertPresented: Binding<Bool> {
        Binding(
            get: {
                if case .error(_, let visibility) = self.updateService.state, visibility == .alert { return true }
                return false
            },
            set: { _ in }
        )
    }

    func progressSheetParameters() -> (ReleaseInfo, Double, UpdateProgressView.Phase)? {
        switch updateService.state {
        case .downloading(let release, let progress): return (release, progress, .downloading)
        case .staged(_, let release): return (release, 1.0, .staged)
        default: return nil
        }
    }

    func currentAlertError() -> UpdateError? {
        if case .error(let error, .alert) = updateService.state { return error }
        return nil
    }
}

@MainActor
final class NSApplicationsLocationAlertPresenter: ApplicationsLocationAlertPresenter {
    func presentMoveToApplications() async -> ApplicationsLocationCheck.MoveResponse {
        let alert = NSAlert()
        alert.messageText = "Move Casablanca to /Applications?"
        alert.informativeText = "Casablanca runs best from the /Applications folder. Auto-update requires this."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .moveToApplications : .notNow
    }

    func presentTranslocated() async -> ApplicationsLocationCheck.MoveResponse {
        let alert = NSAlert()
        alert.messageText = "Casablanca is running from a randomized read-only location"
        alert.informativeText = "Move Casablanca to /Applications to enable updates."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .moveToApplications : .quit
    }

    func presentReplaceConfirmation() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "A copy of Casablanca already exists in /Applications. Replace it?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func presentMoveFailed(_ message: String) async {
        let alert = NSAlert()
        alert.messageText = "Could not move Casablanca to /Applications"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
```

- [ ] **Step 5: Build and run**

```bash
xcodebuild -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -derivedDataPath .build/xcode-update-app build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: build succeeds with no errors.

- [ ] **Step 6: Run the full test regression**

```bash
xcodebuild test -project Casablanca.xcodeproj -scheme Casablanca -destination 'platform=macOS' -derivedDataPath .build/xcode-update-full CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
```

Expected: all existing tests + every new `Updates/*Tests` suite pass.

- [ ] **Step 7: Commit**

```bash
git add Casablanca/CasablancaApp.swift Casablanca/Views/ContentView.swift Casablanca/Views/RecordedMeetingView.swift
git commit -m "feat(updater): hoist services to AppModel, wire UpdateService + real SafeToQuitProbe"
```

---

### Task 22: README + Manual Verification

Spec section "Testing Plan" → manual verification list.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Append an Auto-Update section to `README.md`**

```markdown
## Auto-update

Casablanca checks `https://api.github.com/repos/76r75r6qbh-sys/meeting-assistant/releases/latest` shortly after launch (only when more than 24 hours have passed since the last successful check) and then every 24 hours. Manual checks live under `Casablanca → Check for Updates…`.

When a newer release is found, you'll see a prompt with the release notes and three options:

- **Install Update** — downloads the zip, strips the macOS quarantine attribute, atomically swaps `/Applications/Casablanca.app`, and relaunches.
- **Remind Me Later** — re-prompts at the next check.
- **Skip This Version** — silenced until a strictly newer version (per SemVer 2.0.0) appears.

### Requirements
- Casablanca must live at `/Applications/Casablanca.app`. On first launch from any other location, you'll be prompted to move it there.
- Install is refused while a recording, transcription, or summarization is in flight (this is best-effort in v1; see Known Limitations).
- Updates are not cryptographically signed beyond GitHub's HTTPS — same trust model as `brew install`. If the GitHub repo is compromised, the updater would deliver the compromised binary.

### Settings → Updates
- Toggle: **Automatically check for updates**
- Last-checked timestamp
- Manual **Check for Updates…** button
- Hidden (Option-click the section title): **Include prereleases**, **Reveal install logs in Finder**

### Recovering from a failed update
- The install is atomic — either the new bundle is in place or the existing one is untouched.
- Failed installs leave a log under `~/Library/Application Support/Casablanca/Updates/logs/install-<timestamp>.log`. The Settings pane has a button to reveal that folder.
```

- [ ] **Step 2: Manual verification**

Walk through every step in the spec's "Manual verification" list (steps 1–8). Document any deviations as follow-up issues. The hot-path checks: step 2 (Gatekeeper "damaged" dialog must NOT appear after install), step 5 (recording-active install refusal), and step 6 (helper failure recovery — the bundle on disk is still the new version after manually killing the relaunch helper).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(updater): document auto-update flow and recovery paths"
```

---

## Self-Review Checklist

After completing all 22 tasks, verify:

- [ ] **Spec coverage:** every Decision (1–19) is implemented or explicitly out-of-scope (Sparkle, EdDSA, delta updates, multi-arch).
- [ ] **Tests:** every Tests file in the file-structure table exists; running the full regression passes.
- [ ] **Manual verification list (spec § Testing Plan):** all eight steps performed against a test release.
- [ ] **Storage layout:** `~/Library/Application Support/Casablanca/Updates/` shows `staging/`, `logs/`, `relaunch.sentinel` while running, and orphan helper scripts are wiped at next launch.
- [ ] **Logs:** `Console.app` filtered by subsystem `nl.medicore.casablanca` category `update` shows the full check-and-install audit trail.
- [ ] **Gatekeeper:** the relaunched ad-hoc-signed app launches without the "damaged" dialog (the quarantine-strip check).
- [ ] **Atomicity:** during a manual `pkill -f relaunch-` between swap and `open -n`, the bundle on disk is still the new version and re-opening Casablanca launches the new version.

---

## Known Follow-Ups

- **Cancel mid-download.** The `UpdateProgressView` shows a Cancel button but Task 21 wires it to a no-op. Implement download cancellation (`URLSessionDownloadTask.cancel`) as a small follow-up.
- **GitHub-flavored Markdown.** `MarkdownConverter` targets CommonMark. `@user` mentions, `#1234` issue refs, and tables in release notes render as plain text. Live with it for v1 (release notes are informational).
