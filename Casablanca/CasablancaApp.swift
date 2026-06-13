import SwiftUI
import SwiftData
import AppKit
import OSLog

@main
struct CasablancaApp: App {
    static let mainWindowID = "main-window"

    @State private var appModel: AppModel
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    private let sharedModelContainer: ModelContainer

    init() {
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded()
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
                .sheet(isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { hasCompletedOnboarding = !$0 }
                )) {
                    OnboardingView()
                        .environment(appModel)
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
    let terminologyService = TerminologyService()
    let meetingListViewModel: MeetingListViewModel
    let actionQueueModel = ActionQueueModel()
    let updateService: UpdateService
    let applicationsLocationCheck: ApplicationsLocationCheck
    private let housekeeping: UpdateLaunchHousekeeping
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init() {
        meetingListViewModel = MeetingListViewModel(calendarService: calendarService)

        let paths = UpdatePaths.default
        housekeeping = UpdateLaunchHousekeeping(paths: paths)

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
            terminate: {
                // Graceful quit first. If AppKit defers termination — which it does
                // when this runs while the update progress sheet is presented — force
                // the process to exit so the relaunch helper (waiting on this PID) can
                // launch the new version. Only ever called on the updater install path.
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            }
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

        // Populate the approvals badge and start watching early — before the
        // (potentially slow) calendar permission check.
        actionQueueModel.reload()
        actionQueueModel.startWatching()

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
        ) { [housekeeping, summarizationService] _ in
            housekeeping.removeSentinelOnTerminate()
            // Cancel the detached background summarization task so it doesn't
            // outlive the process as an orphaned task.
            MainActor.assumeIsolated {
                summarizationService.cancelBackgroundWork()
            }
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
