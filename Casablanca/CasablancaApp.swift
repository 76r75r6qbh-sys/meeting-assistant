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
    /// True when launched with `--benchmark-transcription`: the process measures
    /// one transcription and exits, so it must not run the normal launch work.
    private let isBenchmarkRun: Bool
    /// True when this process is the host of the unit tests: it must stay inert,
    /// so it never opens the real store and never runs launch housekeeping.
    private let isHostingTests: Bool

    /// Unrecoverable persistence failure surfaced to the user instead of a crash.
    private struct StoreFailure: Identifiable {
        let id = UUID()
        let message: String
    }

    init() {
        // Benchmark mode is decided before anything else: a measurement run must
        // not open (and so never migrate or mutate) the real meeting database.
        // The scene still needs *a* container, so it gets an in-memory one that
        // never reaches disk, and the run exits the process when it finishes.
        if let request = TranscriptionBenchmark.requestedRun(from: CommandLine.arguments) {
            isBenchmarkRun = true
            isHostingTests = false
            sharedModelContainer = Self.inMemoryContainer()
            _appModel = State(initialValue: AppModel())
            Task { @MainActor in exit(await TranscriptionBenchmark.run(request)) }
            return
        }
        isBenchmarkRun = false

        // The unit tests are hosted in this app. The host must not touch real
        // user data: no store open/migration/backup, no preference migration,
        // and (see `body`) no bootstrap housekeeping or recording recovery.
        isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isHostingTests {
            Log.persistence.info("Hosting unit tests: using an in-memory store and skipping launch work.")
            sharedModelContainer = Self.inMemoryContainer()
            _appModel = State(initialValue: AppModel())
            return
        }

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
            if case .migrationFailed(let legacyStoreURL) = result.recovery {
                _storeFailure = State(initialValue: StoreFailure(
                    message: "Casablanca could not copy your meeting database from its old location:\n\n"
                        + legacyStoreURL.path + "\n\n"
                        + "It is running in a temporary mode and changes will not be saved. "
                        + "The old database was not changed; Casablanca will try again the next time it starts."
                ))
            }
            if case .legacyStoreNotCopied(let legacyStoreURL) = result.recovery {
                _storeFailure = State(initialValue: StoreFailure(
                    message: "Your previous meeting database at " + legacyStoreURL.path
                        + " could not be copied and was left unchanged. A new database has been created."
                ))
            }
            _appModel = State(initialValue: AppModel())
        } catch {
            // Even a fresh store could not be created. Fall back to an
            // in-memory store so the window can still open and present the
            // failure, rather than crashing on launch.
            Log.persistence.error("Falling back to in-memory store: \(error.localizedDescription)")
            sharedModelContainer = Self.inMemoryContainer()
            _storeFailure = State(initialValue: StoreFailure(
                message: "Casablanca could not open or recreate its meeting database. "
                    + "It is running in a temporary mode and changes will not be saved. "
                    + "Please restart the app; if the problem persists, contact support."
            ))
            _appModel = State(initialValue: AppModel())
        }
    }

    /// A container that never reaches disk, for the cases that must not use the
    /// real store: a benchmark run, the unit-test host, and a store that could not
    /// be opened or recreated. In-memory creation only fails if the schema itself
    /// is broken, and then there is nothing left to fall back to.
    private static func inMemoryContainer() -> ModelContainer {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(for: Meeting.self, TodoItem.self, configurations: configuration)
        } catch {
            Log.persistence.error("In-memory ModelContainer creation failed: \(error.localizedDescription)")
            fatalError("Unrecoverable persistence failure: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(viewModel: appModel.meetingListViewModel)
                .environment(appModel)
                .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
                .task {
                    // A benchmark run measures transcription alone: launch
                    // housekeeping, calendar access and update checks would only
                    // add noise to the numbers (and prompts to the screen).
                    // The unit-test host must not touch real files either.
                    guard !isBenchmarkRun, !isHostingTests else { return }
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

                Divider()

                // The same sweep launch runs, for the user who did not relaunch
                // — or who wants to check after plugging a drive back in.
                Button("Recover Unfinished Recordings…") {
                    let modelContext = sharedModelContainer.mainContext
                    Task { await appModel.recoverOrphanedRecordingSessions(modelContext: modelContext) }
                }
                // Off-limits mid-capture: recovery and the capture units would
                // be reaching for the same raw PCM files.
                .disabled(appModel.recordingService.isRecording || appModel.recordingService.isPreparing)
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
    /// The one place capture starts and stops, shared by the editor view and
    /// the Teams monitor so either works with no window open.
    let recordingController: MeetingRecordingController
    let teamsCallMonitor = TeamsCallMonitor(source: CoreAudioTeamsActivitySource())
    /// Created on first enable: it holds `self` (weakly) as its host.
    private var teamsAutoRecordCoordinator: TeamsAutoRecordCoordinator?
    private let autoRecordNotifier = RecordingNotificationCenter()
    private let housekeeping: UpdateLaunchHousekeeping
    private let logger = Logger(subsystem: "nl.medicore.casablanca", category: "update")

    init() {
        meetingListViewModel = MeetingListViewModel(calendarService: calendarService)
        meetingStartNotifier = MeetingStartNotifier(calendarService: calendarService)
        recordingController = MeetingRecordingController(recordingService: recordingService)

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
            // The windowless recording paths (Teams auto-record, notification
            // Stop) persist through the list view model; give it the context
            // now rather than relying on a view having appeared first.
            meetingListViewModel.setModelContext(modelContext)
            recoverStaleProcessingMeetings(modelContext: modelContext)
            // Then the recording half: session directories a crash left behind,
            // and the meetings stuck in `.recording`/`.pausedRecording` on top
            // of them. Nine orphaned directories and ten stuck meetings had
            // accumulated before this ran at launch.
            await recoverOrphanedRecordingSessions(modelContext: modelContext)
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
        // After recovery and the calendar fetch, so a call already running at
        // launch is matched against settled meetings and events.
        updateTeamsCallMonitoring()
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

    /// Repairs the recording-session directories a crash or force quit left
    /// behind, then reconciles the meetings stuck in a recording status on top
    /// of them. Thin glue: the ordering, the repair and the toast wording all
    /// live in `RecordingSessionRecoveryCoordinator` / `RecoveryToastMessage`,
    /// which are tested directly.
    ///
    /// Also reachable from "Recover Unfinished Recordings…", so it has to be
    /// safe to run while the app is live. Two things make it so: the live set
    /// is read AFTER the scan (a recording that starts in between is filtered
    /// out, one that starts later is not in the findings at all), and the
    /// repair leaves any directory whose raw PCM was written seconds ago alone.
    ///
    /// Nothing destructive happens here. The only deletion is
    /// `deleteSessionIfEmpty` on a directory holding no recoverable byte;
    /// captured audio is merged away only when the user presses Stop.
    func recoverOrphanedRecordingSessions(modelContext: ModelContext) async {
        // Rendering the orphaned PCM one of these directories holds is a
        // synchronous ~65 MB write, so both filesystem phases run off the main
        // actor. Only the exclusion snapshot, the SwiftData writes and the
        // toast stay on it.
        let outcome = await RecordingSessionRecoveryCoordinator.sweep(
            scan: {
                await Task.detached(priority: .utility) { () -> [RecordingSessionRecovery.Finding] in
                    do {
                        return try RecordingSessionRecovery.scan(store: RecordingResumeSessionStore())
                    } catch {
                        Log.recording.error(
                            "Recording recovery could not scan the session directories: \(error.localizedDescription, privacy: .public)"
                        )
                        return []
                    }
                }.value
            },
            exclusions: {
                (
                    live: self.liveCaptureMeetingIDs(),
                    recordingStatus: Self.meetingIDsInARecordingStatus(in: modelContext)
                )
            },
            repair: { findings, recordingStatusMeetingIDs in
                await Task.detached(priority: .utility) {
                    RecordingSessionRecoveryCoordinator.repair(
                        findings: findings,
                        store: RecordingResumeSessionStore(),
                        recordingStatusMeetingIDs: recordingStatusMeetingIDs
                    )
                }.value
            }
        )

        let reconciled = reconcileStuckRecordingMeetings(
            modelContext: modelContext,
            excluding: liveCaptureMeetingIDs()
        )
        // Only meetings the user can actually act on are counted: a session
        // this sweep repaired, or one whose stale `.recording` became
        // `.pausedRecording`. A meeting downgraded to `.notesOnly` lost its
        // audio — telling the user to "open it to Resume or Stop" would send
        // them to a screen with neither button. Those are logged instead.
        let stillResumable = Set(reconciled.filter { $0.value == .pausedRecording }.keys)
        let cleared = reconciled.count - stillResumable.count
        if cleared > 0 {
            Log.recording.notice(
                "Recording recovery: \(cleared, privacy: .public) meeting(s) had no recording left and are now notes-only"
            )
        }

        let recovered = Set(outcome.repairedMeetingIDs).union(stillResumable)
        if let message = RecoveryToastMessage.compose(
            recoveredRecordings: recovered.count,
            strandedSegments: outcome.strandedSegments
        ) {
            toastCenter.show(message: message, duration: 8)
        }
    }

    /// The meeting being captured right now, if any: the one directory recovery
    /// must not touch at all. Read fresh at every use — a stale answer is the
    /// whole hazard.
    private func liveCaptureMeetingIDs() -> Set<UUID> {
        guard recordingService.isRecording || recordingService.isPreparing,
              let meetingID = recordingService.activeMeetingID else { return [] }
        return [meetingID]
    }

    /// The meetings SwiftData reports as `.recording`/`.pausedRecording` — the
    /// sessions whose manifest recovery may not delete, because Resume and Stop
    /// both read it.
    private static func meetingIDsInARecordingStatus(in modelContext: ModelContext) -> Set<UUID> {
        guard let all = try? modelContext.fetch(FetchDescriptor<Meeting>()) else { return [] }
        return Set(
            all
                .filter { $0.status == .recording || $0.status == .pausedRecording }
                .map(\.id)
        )
    }

    /// Applies `PausedRecordingRecovery` to every meeting left in a recording
    /// status: one whose audio is gone stops offering a Resume that fails, and a
    /// `.recording` meeting that outlived the process becomes the paused one it
    /// really is. Returns what changed, so the caller can report it.
    @discardableResult
    private func reconcileStuckRecordingMeetings(
        modelContext: ModelContext,
        excluding liveMeetingIDs: Set<UUID>
    ) -> [UUID: MeetingStatus] {
        guard let all = try? modelContext.fetch(FetchDescriptor<Meeting>()) else { return [:] }
        // Enum-typed stored properties don't filter reliably in SwiftData
        // predicates, so filter in memory — and narrowing first matters here:
        // `hasResumableSession` touches the filesystem, which must not happen
        // once per completed meeting ever recorded.
        let candidates = all.filter {
            ($0.status == .recording || $0.status == .pausedRecording) && !liveMeetingIDs.contains($0.id)
        }
        guard !candidates.isEmpty else { return [:] }

        var changes: [UUID: MeetingStatus] = [:]
        for meeting in candidates {
            guard let newStatus = PausedRecordingRecovery.recoveredStatus(
                current: meeting.status,
                hasResumableSession: recordingService.hasResumableSession(for: meeting.id)
            ) else { continue }
            meeting.status = newStatus
            changes[meeting.id] = newStatus
        }
        if !changes.isEmpty {
            try? modelContext.save()
            Log.recording.notice(
                "Recording recovery: reconciled \(changes.count, privacy: .public) stuck meeting status(es)"
            )
        }
        return changes
    }

    /// Install the shared notification delegate + category and wire the calendar
    /// refresh hook so meeting-start prompts re-schedule on every settled change.
    private func installMeetingStartNotifications() {
        notificationCoordinator.onStartRecording = { [weak self] eventIdentifier in
            self?.startRecordingFromNotification(eventIdentifier: eventIdentifier)
        }
        notificationCoordinator.onStopRecording = { [weak self] meetingID in
            guard let self else { return }
            // The notification may outlive its recording: only stop if this
            // meeting is the one still capturing.
            guard self.recordingService.isRecording, self.recordingService.activeMeetingID == meetingID else {
                Log.recording.notice("Ignoring Stop notification: that meeting is no longer recording.")
                return
            }
            Task { await self.stopRecordingWithoutWindow(meetingID: meetingID) }
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
        // Preparing counts too: a session is not published until it captures.
        guard !isRecordingBusy else {
            Log.recording.notice("Ignoring start-recording notification: a recording is already active.")
            return
        }
        guard let event = calendarService.event(withIdentifier: eventIdentifier) else {
            Log.recording.error("Start-recording notification could not resolve event \(eventIdentifier, privacy: .public).")
            return
        }
        guard let meeting = meetingListViewModel.findOrCreateMeeting(for: event),
              let context = meetingListViewModel.currentModelContext else { return }
        meetingListViewModel.beginRecording(for: meeting)
        // Don't fire the prompt again for this meeting.
        meetingStartNotifier.cancel(eventIdentifier: eventIdentifier)
        // Capture used to start only once the editor appeared, so tapping the
        // prompt with the main window closed recorded nothing. Start it here;
        // if the editor is showing too, whichever comes second joins the first.
        recordingService.refreshInputDevices(forcePreferredSelection: true)
        Task {
            _ = await recordingController.startRecording(
                for: meeting,
                save: { [weak self] in self?.persist(meeting, in: context) }
            )
        }
    }

    // MARK: Teams auto-record

    /// Starts or stops the Teams call monitor to match the preferences: it
    /// runs while either auto-record or auto-stop is on (auto-stop alone still
    /// needs to know when a call that overlapped a manual recording ends).
    /// Called at bootstrap and whenever either Settings toggle changes.
    func updateTeamsCallMonitoring() {
        let isNeeded = TeamsAutoRecordPolicy.isMonitorNeeded(
            autoRecordEnabled: AppPreferences.teamsAutoRecordEnabled(),
            autoStopEnabled: AppPreferences.teamsAutoRecordStopWhenCallEnds()
        )
        if isNeeded {
            let coordinator = teamsAutoRecordCoordinator ?? TeamsAutoRecordCoordinator(host: self)
            teamsAutoRecordCoordinator = coordinator
            teamsCallMonitor.onCallStarted = { Task { await coordinator.callStarted() } }
            teamsCallMonitor.onCallTick = { coordinator.callTick() }
            teamsCallMonitor.onCallEnded = { Task { await coordinator.callEnded() } }
            teamsCallMonitor.start()
        } else {
            teamsCallMonitor.stop()
            teamsAutoRecordCoordinator?.reset()
        }
    }

    /// Stops a recording from outside the editor (auto-stop, notification
    /// Stop) and starts the transcription pipeline itself: with no window open
    /// there is no `TranscriptionView` to kick it off. If one is showing this
    /// meeting, its own request is ignored as a duplicate.
    private func stopRecordingWithoutWindow(meetingID: UUID, notificationTitle: String? = nil) async {
        guard let meeting = meetingListViewModel.fetchMeeting(byID: meetingID),
              let context = meetingListViewModel.currentModelContext else {
            Log.recording.error("Stop without window: meeting \(meetingID.uuidString, privacy: .public) not found")
            return
        }
        do {
            guard try await recordingController.stopRecording(
                for: meeting,
                save: { [weak self] in self?.persist(meeting, in: context) }
            ) != nil else { return }
        } catch {
            autoRecordNotifier.post(title: "Recording could not be stopped", body: error.localizedDescription)
            return
        }
        transcriptionService.transcribeInBackground(
            meeting: meeting,
            modelContext: context,
            terminologyService: terminologyService,
            exportReporter: exportStatusCenter
        )
        autoRecordNotifier.post(
            title: notificationTitle ?? "Recording stopped — \(meeting.title)",
            body: notificationTitle == nil ? "Transcribing now." : "“\(meeting.title)” is being transcribed."
        )
    }

    /// What the editor's `save()` does: persist, then auto-export if enabled.
    private func persist(_ meeting: Meeting, in context: ModelContext) {
        try? context.save()
        let reporter = exportStatusCenter
        Task { @MainActor in
            await ExportService.exportAutomaticallyIfEnabled(meeting, reporter: reporter)
        }
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

extension AppModel: TeamsAutoRecordHost {
    var isRecordingBusy: Bool {
        recordingService.isRecording || recordingService.isPreparing || recordingController.isStartInFlight
    }

    var isRecording: Bool { recordingService.isRecording }

    var activeRecordingMeetingID: UUID? { recordingService.activeMeetingID }

    var selectedMeetingStatus: MeetingStatus? { meetingListViewModel.selectedMeeting?.status }

    func teamsCallCandidates() -> [TeamsCallEventCandidate] {
        calendarService.events.compactMap(TeamsCallEventCandidate.init(event:))
    }

    func startAutoRecording(eventIdentifier: String?, manualTitle: String) async -> UUID? {
        let viewModel = meetingListViewModel
        guard let context = viewModel.currentModelContext else {
            Log.recording.error("Teams auto-record: no model context yet; not recording")
            return nil
        }

        var meeting: Meeting?
        if let eventIdentifier, let event = calendarService.event(withIdentifier: eventIdentifier) {
            let existing = viewModel.findOrCreateMeeting(for: event)
            if let existing, TeamsAutoRecordPolicy.canRecordInto(existingStatus: existing.status) {
                meeting = existing
            } else {
                meeting = viewModel.createManualMeeting(title: "\(event.title ?? "Teams call") (continued)")
            }
            // Don't prompt to record a meeting that is already being recorded.
            meetingStartNotifier.cancel(eventIdentifier: eventIdentifier)
        } else {
            let title = manualTitle.isEmpty ? TeamsAutoRecordPolicy.manualMeetingTitle(at: Date()) : manualTitle
            meeting = viewModel.createManualMeeting(title: title)
        }
        guard let meeting else { return nil }

        // No suspension point between the status flip and the controller's
        // reservation: the editor `.task` the selection triggers (window open)
        // runs on a later turn and finds the start already in flight.
        // Selecting the meeting never activates the app, so Teams keeps focus.
        viewModel.beginRecording(for: meeting)
        recordingService.refreshInputDevices(forcePreferredSelection: true)
        let outcome = await recordingController.startRecording(
            for: meeting,
            save: { [weak self] in self?.persist(meeting, in: context) }
        )
        switch outcome {
        case .started:
            autoRecordNotifier.post(
                title: "Recording started — \(meeting.title)",
                body: "Casablanca detected a Microsoft Teams call.",
                categoryIdentifier: AppNotificationCoordinator.autoRecordingCategoryID,
                userInfo: [AppNotificationCoordinator.meetingIDKey: meeting.id.uuidString]
            )
            return meeting.id
        case .failed:
            autoRecordNotifier.post(
                title: "Could not record the Teams call",
                body: recordingService.errorMessage ?? "The recording did not start."
            )
            return nil
        case .alreadyRecording, .alreadyStarting:
            // Someone else's start: theirs to stop, not ours.
            return nil
        }
    }

    func meetingStatus(id: UUID) -> MeetingStatus? {
        meetingListViewModel.fetchMeeting(byID: id)?.status
    }

    func stopRecordingForEndedCall(meetingID: UUID) async {
        await stopRecordingWithoutWindow(meetingID: meetingID, notificationTitle: "Recording stopped — Teams call ended")
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
