import SwiftUI
import SwiftData
import AppKit
import OSLog

@main
struct CasablancaApp: App {
    static let mainWindowID = "main-window"

    @State private var appModel: AppModel
    @AppStorage(AppPreferenceKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppPreferenceKey.recordingWorkspaceFocusMode) private var recordingWorkspaceFocusMode = false
    @State private var storeFailure: StoreFailure?
    private let sharedModelContainer: ModelContainer

    /// Unrecoverable persistence failure surfaced to the user instead of a crash.
    private struct StoreFailure: Identifiable {
        let id = UUID()
        let message: String
    }

    init() {
        AppPreferences.migrateLegacyAutoExportKeyIfNeeded()
        do {
            let result = try PersistenceController.makeAppContainer()
            sharedModelContainer = result.container
            if case .recovered(let backups) = result.recovery {
                _storeFailure = State(initialValue: StoreFailure(
                    message: "Your meeting database could not be opened and may have been corrupted. "
                        + "A fresh database has been created so Casablanca can keep working. "
                        + "Your previous data has been backed up (not deleted) and may be recoverable:\n\n"
                        + backups.map(\.lastPathComponent).joined(separator: "\n")
                ))
            }
            _appModel = State(initialValue: AppModel())
        } catch {
            // Even a fresh store could not be created. Fall back to an
            // in-memory store so the window can still open and present the
            // failure, rather than crashing on launch.
            Log.persistence.error("Falling back to in-memory store: \(error.localizedDescription)")
            do {
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                sharedModelContainer = try ModelContainer(
                    for: Meeting.self, TodoItem.self, configurations: configuration
                )
            } catch {
                // In-memory creation should never fail for a valid schema; if it
                // does, the schema itself is broken and there is nothing to do.
                Log.persistence.error("In-memory ModelContainer creation failed: \(error.localizedDescription)")
                fatalError("Unrecoverable persistence failure: \(error.localizedDescription)")
            }
            _storeFailure = State(initialValue: StoreFailure(
                message: "Casablanca could not open or recreate its meeting database. "
                    + "It is running in a temporary mode and changes will not be saved. "
                    + "Please restart the app; if the problem persists, contact support."
            ))
            _appModel = State(initialValue: AppModel())
        }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(viewModel: appModel.meetingListViewModel)
                .environment(appModel)
                .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
                .task {
                    await appModel.bootstrap(modelContext: sharedModelContainer.mainContext)
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
                .alert(
                    "Meeting Database",
                    isPresented: Binding(
                        get: { storeFailure != nil },
                        set: { if !$0 { storeFailure = nil } }
                    ),
                    presenting: storeFailure,
                    actions: { _ in Button("OK") { storeFailure = nil } },
                    message: { Text($0.message) }
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
            CommandGroup(after: .sidebar) {
                Button("Toggle Focus Mode") {
                    recordingWorkspaceFocusMode.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarMeetingView(viewModel: appModel.meetingListViewModel)
        } label: {
            // Reading pendingCount here keeps the menu-bar item reactive: it
            // updates whenever the action queue reloads (launch, file watcher,
            // in-app mutation). Image + trailing Text keeps the record.circle
            // glyph and shows the count beside it when there are pending items.
            Image(systemName: "record.circle")
            if appModel.actionQueueModel.pendingCount > 0 {
                Text("\(appModel.actionQueueModel.pendingCount)")
            }
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
    let exportStatusCenter = ExportStatusCenter()
    let toastCenter = ToastCenter()
    let meetingListViewModel: MeetingListViewModel
    let actionQueueModel = ActionQueueModel()
    let updateService: UpdateService
    let applicationsLocationCheck: ApplicationsLocationCheck
    let notificationCoordinator = AppNotificationCoordinator()
    let meetingStartNotifier: MeetingStartNotifier
    private let housekeeping: UpdateLaunchHousekeeping
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init() {
        meetingListViewModel = MeetingListViewModel(calendarService: calendarService)
        meetingStartNotifier = MeetingStartNotifier(calendarService: calendarService)

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

    func bootstrap(modelContext: ModelContext? = nil) async {
        housekeeping.runOnLaunch()
        registerSentinelCleanup()
        installMeetingStartNotifications()

        // One-shot recovery: meetings left mid-pipeline (`.processing`) by a
        // crash/force-quit would otherwise spin forever. Nothing is running at
        // launch, so downgrade them off `.processing`.
        if let modelContext {
            recoverStaleProcessingMeetings(modelContext: modelContext)
        }

        // Populate the approvals badge and start watching early — before the
        // (potentially slow) calendar permission check. The callback is set
        // before the first reload so launch, watcher-driven reloads, and every
        // in-app mutation all refresh the Dock badge (even with no window open).
        actionQueueModel.onPendingCountChange = { count in DockBadge.apply(count: count) }
        actionQueueModel.reload()
        actionQueueModel.startWatching()

        await permissionsManager.checkAll()
        if calendarService.authorizationStatus == .fullAccess {
            await calendarService.fetchUpcomingEvents()
            calendarService.startMonitoringIfAuthorized()
        }
        // Schedule prompts for whatever is already loaded (fetchUpcomingEvents
        // also fires onEventsRefreshed, but cover the no-access / cached path).
        meetingStartNotifier.reschedule()
        await applicationsLocationCheck.runOnceIfNeeded()
        updateService.startScheduling()
    }

    /// Sweeps SwiftData for meetings stuck in `.processing` and downgrades them
    /// per `StaleProcessingRecovery` so they stop spinning and the detail view
    /// surfaces a Retry. Pipeline-active guard means it's safe to call any time,
    /// though at launch nothing should be running yet.
    private func recoverStaleProcessingMeetings(modelContext: ModelContext) {
        let isAnyPipelineActive = transcriptionService.isTranscribing || summarizationService.isSummarizing
        // Enum-typed stored properties don't filter reliably in SwiftData
        // predicates, so fetch all and filter in memory — this is a one-shot at
        // launch over a small set.
        guard let all = try? modelContext.fetch(FetchDescriptor<Meeting>()) else { return }
        let stale = all.filter { $0.status == .processing }
        guard !stale.isEmpty else { return }

        var recovered = 0
        for meeting in stale {
            let hasTranscript = meeting.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasUserNotes = !meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let newStatus = StaleProcessingRecovery.recoveredStatus(
                currentStatus: meeting.status,
                hasTranscript: hasTranscript,
                hasUserNotes: hasUserNotes,
                isAnyPipelineActive: isAnyPipelineActive
            ) {
                meeting.status = newStatus
                recovered += 1
            }
        }
        if recovered > 0 {
            try? modelContext.save()
            Log.persistence.notice("Recovered \(recovered) stale .processing meeting(s) on launch.")
        }
    }

    /// Install the shared notification delegate + category and wire the calendar
    /// refresh hook so meeting-start prompts re-schedule on every settled change.
    private func installMeetingStartNotifications() {
        notificationCoordinator.onStartRecording = { [weak self] eventIdentifier in
            self?.startRecordingFromNotification(eventIdentifier: eventIdentifier)
        }
        notificationCoordinator.install()

        calendarService.onEventsRefreshed = { [weak meetingStartNotifier] in
            meetingStartNotifier?.reschedule()
        }
    }

    /// Handle the "Start Recording" notification action: re-resolve the event,
    /// suppress if a recording is already active (or already recording this
    /// meeting), otherwise begin recording and cancel the now-redundant prompt.
    private func startRecordingFromNotification(eventIdentifier: String) {
        // Suppression: never start a second recording over an active one.
        guard !recordingService.isRecording else {
            Log.recording.notice("Ignoring start-recording notification: a recording is already active.")
            return
        }
        guard let event = calendarService.event(withIdentifier: eventIdentifier) else {
            Log.recording.error("Start-recording notification could not resolve event \(eventIdentifier, privacy: .public).")
            return
        }
        meetingListViewModel.beginRecording(for: event)
        // Don't fire the prompt again for this meeting.
        meetingStartNotifier.cancel(eventIdentifier: eventIdentifier)
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
