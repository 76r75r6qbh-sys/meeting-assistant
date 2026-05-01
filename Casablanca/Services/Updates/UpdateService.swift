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
            if trigger == .manual {
                state = .error(mapped, visibility: .alert)
            } else {
                state = .idle
            }
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
    // startScheduling()/stopScheduling() - implemented in Task 15
}
