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
