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
