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
    private var lastAvailableRelease: ReleaseInfo?
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")
    private let initialCheckDelay: TimeInterval
    private let autoCheckInterval: TimeInterval
    private var schedulerTask: Task<Void, Never>?

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
        self.initialCheckDelay = initialCheckDelay
        self.autoCheckInterval = autoCheckInterval
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
            if trigger == .manual {
                state = .error(mapped, visibility: .alert)
            } else {
                // silent → straight to idle
                state = .idle
            }
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
}
