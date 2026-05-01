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
            _ = try? await NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
            NSApp.terminate(nil)
        } catch {
            logger.error("move-to-applications failed: \(error.localizedDescription)")
            await presenter.presentMoveFailed(error.localizedDescription)
        }
    }
}
