import AppKit
import EventKit
import SwiftData
import SwiftUI
import XCTest
@testable import Casablanca

/// Regression tests for AppKit aborting with "more Update Constraints in Window
/// passes than there are views":
///
/// - 0.16.0: the dashboard column published a new minimum size during the
///   constraint pass whenever its content changed (the hero card appearing
///   after a calendar refresh, text re-wrapping at a new width) while the
///   window was small.
/// - SwiftUI's `.inspector` in the detail column (NotesEditorView's
///   Prep/To-Dos, RecordedMeetingView's details) is a nested NSSplitView whose
///   Auto Layout minimums the detail column's stable minimum does not cover;
///   shrinking the window toward its minimum (or collapsing/expanding the
///   sidebar there) made both split views re-dirty the pass until AppKit gave
///   up. Fixed by `widthGatedInspector`: a plain SwiftUI trailing panel, shown
///   only at `LayoutWidthClass.expanded`.
///
/// The layout is hosted in a real `NSWindow` that mirrors ContentView's split,
/// and `SplitColumnMinimumSizeProbe` counts the exact re-dirtying from the
/// crash report. An abort kills the test process, so reaching the end of a
/// test is part of its assertion.
@MainActor
final class SplitLayoutStabilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        SplitColumnMinimumSizeProbe.install()
        try XCTSkipUnless(
            SplitColumnMinimumSizeProbe.isInstalled,
            "AppKit no longer exposes the constraint-pass methods the probe hooks"
        )
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        try await super.tearDown()
    }

    // MARK: - Dashboard (0.16.0)

    /// The launch-time trigger: dashboard content changes (calendar refresh,
    /// "in N min" ticking, the hero appearing or disappearing) in a small window.
    func testDashboardContentChangesDoNotRedirtyTheConstraintPass() throws {
        // Control: without the fix the probe must see the crash path, otherwise
        // a zero below would prove nothing on this macOS.
        let unstabilized = redirtiesWhileDashboardContentChanges(stabilized: false)
        try XCTSkipIf(
            unstabilized == 0,
            "This macOS no longer re-dirties the pass for content-dependent column minimums; the probe cannot tell"
        )

        XCTAssertEqual(
            redirtiesWhileDashboardContentChanges(stabilized: true), 0,
            "The detail column published a new minimum size during a constraint pass (0.16.0 crash path)"
        )
    }

    // MARK: - Width-gated inspector: invariants

    /// The inspector may only be open where sidebar (at its maximum), detail
    /// (at its minimum) and inspector (at its minimum) all fit.
    func testInspectorBreakpointLeavesRoomForSidebarDetailAndInspector() {
        XCTAssertEqual(
            CasaLayout.inspectorMinimumWindowWidth,
            CasaLayout.sidebarMaxWidth + CasaLayout.detailColumnMinWidth + CasaLayout.inspectorColumnMinWidth
        )
        XCTAssertGreaterThanOrEqual(CasaLayout.layoutInspectorBreakpoint, CasaLayout.inspectorMinimumWindowWidth)
        XCTAssertGreaterThanOrEqual(CasaLayout.sidebarMaxWidth, CasaLayout.sidebarWidth)
        XCTAssertLessThanOrEqual(CasaLayout.inspectorColumnMinWidth, CasaLayout.inspectorColumnMaxWidth)
    }

    func testOnlyTheExpandedWidthClassAllowsAnInspector() {
        XCTAssertFalse(LayoutWidthClass.compact.allowsInspector)
        XCTAssertFalse(LayoutWidthClass.regular.allowsInspector)
        XCTAssertTrue(LayoutWidthClass.expanded.allowsInspector)
        XCTAssertFalse(LayoutWidthClass.from(width: CasaLayout.layoutInspectorBreakpoint - 1).allowsInspector)
        XCTAssertTrue(LayoutWidthClass.from(width: CasaLayout.layoutInspectorBreakpoint).allowsInspector)
        XCTAssertFalse(LayoutWidthClass.from(width: CasaLayout.windowMinWidth).allowsInspector)
    }

    // MARK: - Notes workspace inspector (Prep / To-Dos)

    /// Opening a meeting with prep in a wide window opens the notes inspector
    /// on its Prep tab programmatically, right after the asynchronous prep
    /// load, exactly once.
    func testNotesInspectorAutoOpenedAfterPrepLoadShowsInAWideWindow() {
        let control = HarnessControl()
        let (window, openCount) = makeNotesInspectorWindow(control: control, size: CGSize(width: 1080, height: 720))
        XCTAssertEqual(openCount(), 1, "The inspector should auto-open once the prep has loaded")
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window), "A wide window should show the auto-opened inspector")

        for size in [CGSize(width: 900, height: 600), CGSize(width: 1200, height: 800), CGSize(width: 1080, height: 720)] {
            resize(window, to: size)
            pump(window)
        }

        XCTAssertEqual(openCount(), 1, "Re-renders and resizes must not re-open the inspector")
    }

    /// The prep auto-open in a window too narrow for the inspector is deferred,
    /// not lost: nothing opens while narrow, and the inspector appears once the
    /// window is widened.
    func testNotesInspectorAutoOpenInANarrowWindowIsDeferredUntilItWidens() {
        let control = HarnessControl()
        let (window, openCount) = makeNotesInspectorWindow(control: control, size: CGSize(width: 700, height: 552))
        XCTAssertEqual(openCount(), 1, "The prep auto-open should still request the inspector")
        settle(window)
        XCTAssertTrue(control.inspectorRequested, "The open request must be kept while the window is narrow")
        XCTAssertFalse(isInspectorShown(control, in: window), "A regular-width window must not show the inspector")

        resize(window, to: CGSize(width: 1080, height: 720))
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window), "The deferred inspector should appear once the window is wide enough")
    }

    /// The crash: an open notes inspector while the window shrinks to its
    /// minimum and back, through every width tier and both breakpoints.
    func testOpenNotesInspectorSurvivesShrinkingTheWindowToItsMinimum() {
        let control = HarnessControl()
        let (window, _) = makeNotesInspectorWindow(control: control, size: CGSize(width: 1080, height: 720))
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window))

        resizeThroughAllTiers(window, control: control)

        XCTAssertTrue(control.inspectorRequested, "Shrinking must not drop the user's open inspector")
        resize(window, to: CGSize(width: 1080, height: 720))
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window), "The inspector should come back once the window is wide again")
    }

    /// The panel itself, open at every width with no width gate (so the gate's
    /// run-loop lag cannot hide anything): the native `.inspector` aborted here
    /// within a few resizes; the panel must survive the full sweep.
    func testUngatedInspectorPanelSurvivesEveryWindowWidth() {
        let control = HarnessControl()
        control.inspectorRequested = true
        let window = makeWindow(
            ResponsiveSplitHarness(stabilized: true, control: control, detail: UngatedPanelHarness(control: control)),
            size: CGSize(width: 1080, height: 720)
        )
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window))

        resizeThroughAllTiers(window, control: nil)

        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window), "Without the gate the panel stays open at every width")
    }

    // MARK: - Recorded meeting inspector

    func testOpenRecordedMeetingInspectorSurvivesShrinkingTheWindowToItsMinimum() throws {
        let control = HarnessControl()
        let window = try makeRecordedMeetingInspectorWindow(control: control, size: CGSize(width: 1080, height: 720))
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window), "A wide window shows the recorded meeting's inspector by default")

        resizeThroughAllTiers(window, control: control)

        resize(window, to: CGSize(width: 1080, height: 720))
        settle(window)
        XCTAssertTrue(isInspectorShown(control, in: window))
    }

    /// The toolbar toggle (or anything else) asking for the inspector while the
    /// window is narrow must not present it.
    func testRecordedMeetingInspectorRequestedInANarrowWindowStaysHidden() throws {
        let control = HarnessControl()
        let window = try makeRecordedMeetingInspectorWindow(control: control, size: CGSize(width: 700, height: 552))
        settle(window)
        XCTAssertFalse(isInspectorShown(control, in: window))

        control.inspectorRequested = true
        settle(window)
        XCTAssertFalse(isInspectorShown(control, in: window), "A regular-width window must not show the inspector")

        for size in [CGSize(width: 480, height: 500), CGSize(width: 620, height: 500), CGSize(width: 560, height: 500)] {
            resize(window, to: size)
            pump(window)
        }
        XCTAssertFalse(isInspectorShown(control, in: window))
    }

    // MARK: - Sidebar open/close with an inspector open

    /// Collapsing and expanding the sidebar (focus mode, the compact breakpoint)
    /// with an inspector open, at and around both breakpoints.
    func testSidebarCollapseAndExpandWithAnOpenInspectorAtTheBreakpoints() throws {
        let notesControl = HarnessControl()
        let (notesWindow, _) = makeNotesInspectorWindow(control: notesControl, size: CGSize(width: 1080, height: 720))
        let recordedControl = HarnessControl()
        let recordedWindow = try makeRecordedMeetingInspectorWindow(control: recordedControl, size: CGSize(width: 1080, height: 720))

        for (window, control) in [(notesWindow, notesControl), (recordedWindow, recordedControl)] {
            settle(window)
            let inspectorBreakpoint = CasaLayout.layoutInspectorBreakpoint
            let sidebarBreakpoint = CasaLayout.layoutSidebarBreakpoint
            for width in [inspectorBreakpoint, inspectorBreakpoint + 1, inspectorBreakpoint - 1,
                          sidebarBreakpoint, sidebarBreakpoint - 1, sidebarBreakpoint + 1, inspectorBreakpoint] {
                resize(window, to: CGSize(width: width, height: 600))
                pump(window)
                for hidden in [true, false, true, false] {
                    control.sidebarForcedHidden = hidden
                    pump(window)
                }
            }
            // Cross the compact breakpoint back and forth (the sidebar collapses
            // and expands on its own there).
            for _ in 0..<3 {
                for width in [sidebarBreakpoint - 1, sidebarBreakpoint, sidebarBreakpoint - 40, sidebarBreakpoint + 40] {
                    resize(window, to: CGSize(width: width, height: 552))
                    pump(window)
                }
            }

            resize(window, to: CGSize(width: inspectorBreakpoint, height: 600))
            settle(window)
            XCTAssertTrue(isInspectorShown(control, in: window), "At the inspector breakpoint the inspector should be shown")
        }
    }

    // MARK: - Scenarios

    /// Shrinks to the window minimum and back through every tier, repeatedly
    /// (the abort needed several passes at the wrong widths to trigger).
    private func resizeThroughAllTiers(_ window: NSWindow, control: HarnessControl?) {
        let widths: [CGFloat] = [
            1080, 900, 880, 879, 820, 760, 700, 640, 620, 600, 599, 560, 520, 480,
            620, 480, 760, 520, 700, 600, 599, 480, 900, 640, 480, 880, 879, 1080,
        ]
        for _ in 0..<3 {
            for width in widths {
                resize(window, to: CGSize(width: width, height: width < 600 ? 500 : 552))
                pump(window)
                // With a gated inspector (control given), none may show
                // below the inspector breakpoint once the gate has caught up.
                if let control, !LayoutWidthClass.from(width: width).allowsInspector {
                    settle(window)
                    XCTAssertFalse(isInspectorShown(control, in: window), "Inspector shown at \(width) pt")
                }
            }
        }
    }

    private func redirtiesWhileDashboardContentChanges(stabilized: Bool) -> Int {
        let calendar = Self.calendarService()
        let window = makeDashboardWindow(calendar: calendar, stabilized: stabilized, heroMinutesAhead: nil)

        SplitColumnMinimumSizeProbe.observe(window)
        let sizes = [
            CGSize(width: 480, height: 500),
            CGSize(width: 620, height: 500),
            CGSize(width: 700, height: 552),
            CGSize(width: 900, height: 500),
        ]
        for size in sizes {
            resize(window, to: size)
            pump(window)
            for minutes in [nil, 2, 9, 47, nil, 9] as [Int?] {
                Self.setEvents(on: calendar, heroMinutesAhead: minutes)
                pump(window)
            }
        }
        return SplitColumnMinimumSizeProbe.redirtyCount
    }

    // MARK: - Harness

    private func makeNotesInspectorWindow(control: HarnessControl, size: CGSize) -> (NSWindow, () -> Int) {
        final class Counter { var value = 0 }
        let counter = Counter()
        let window = makeWindow(
            ResponsiveSplitHarness(
                stabilized: true,
                control: control,
                detail: PrepAutoOpenInspectorHarness(
                    meeting: Meeting(title: "Wegiz BgZ refinement", date: Date()),
                    prep: "# Prep\n\n- Agree on the BgZ scope\n- Partner timeline",
                    control: control,
                    onOpen: { counter.value += 1 }
                )
            ),
            size: size
        )
        // Let the detached prep load return and the inspector open.
        let deadline = Date().addingTimeInterval(2)
        while counter.value == 0 && Date() < deadline { pump(window) }
        return (window, { counter.value })
    }

    private func makeRecordedMeetingInspectorWindow(control: HarnessControl, size: CGSize) throws -> NSWindow {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let meeting = Meeting(title: "Orchestra migration sync", date: Date())
        container.mainContext.insert(meeting)
        return makeWindow(
            ResponsiveSplitHarness(
                stabilized: true,
                control: control,
                detail: RecordedMeetingInspectorHarness(meeting: meeting, control: control)
            )
            .modelContainer(container),
            size: size
        )
    }

    /// Whether the harness's inspector panel is on screen. Also asserts the
    /// panel is plain layout: the sidebar's split view is the only one in the
    /// window (a nested split is what aborted the constraint pass).
    private func isInspectorShown(_ control: HarnessControl, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        func splitViews(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
        }
        if let root = window.contentView?.superview ?? window.contentView {
            XCTAssertEqual(splitViews(in: root).count, 1, "Only the sidebar split may exist; the inspector must not add one", file: file, line: line)
        }
        return control.inspectorVisible
    }

    /// Several pumps so state changes driven by the window width (the
    /// GeometryReader → width class → inspector gate chain) have landed.
    private func settle(_ window: NSWindow) {
        for _ in 0..<25 { pump(window) }
    }

    /// The calendar starts unauthorized so DashboardView's one-shot `.task`
    /// skips its EventKit fetch (the test host is the real app and may have
    /// calendar access); access and fixtures are granted after it has run, so
    /// the real calendar is never read and never replaces the fixtures.
    private func makeDashboardWindow(calendar: CalendarService, stabilized: Bool, heroMinutesAhead: Int?) -> NSWindow {
        let viewModel = MeetingListViewModel(calendarService: calendar, meetingHasPrep: { _ in false })
        let window = makeWindow(
            ResponsiveSplitHarness(stabilized: stabilized, control: HarnessControl(), detail: DashboardView(viewModel: viewModel)),
            size: CGSize(width: 1080, height: 720)
        )
        Self.setEvents(on: calendar, heroMinutesAhead: heroMinutesAhead)
        pump(window)
        return window
    }

    private func makeWindow<Content: View>(_ content: Content, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.orderFrontRegardless()
        windows.append(window)
        pump(window)
        return window
    }

    private func resize(_ window: NSWindow, to size: CGSize) {
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = window.frame.origin
        window.setFrame(frame, display: true)
    }

    /// Runs the constraint, layout and display passes, then lets the run loop
    /// turn so SwiftUI's deferred transactions and AppKit's display-cycle
    /// observers (where the crash fired) get to run.
    private func pump(_ window: NSWindow) {
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    // MARK: - Fixtures

    private static let store = EKEventStore()

    private static func calendarService() -> CalendarService {
        let service = CalendarService()
        service.authorizationStatus = .notDetermined
        return service
    }

    /// Today's hero meeting `heroMinutesAhead` minutes away (nil: nothing left
    /// today, so no hero) plus meetings on the next two days.
    private static func setEvents(on service: CalendarService, heroMinutesAhead: Int?) {
        service.authorizationStatus = .fullAccess
        let now = Date()
        var events: [EKEvent] = []
        if let minutes = heroMinutesAhead {
            let event = EKEvent(eventStore: store)
            event.title = "Wegiz BgZ exchange refinement with the integration partners"
            event.startDate = now.addingTimeInterval(TimeInterval(minutes * 60))
            event.endDate = event.startDate.addingTimeInterval(3600)
            events.append(event)
        }
        for day in 1...2 {
            let event = EKEvent(eventStore: store)
            event.title = "Orchestra migration sync \(day)"
            event.startDate = now.addingTimeInterval(TimeInterval(day * 86_400))
            event.endDate = event.startDate.addingTimeInterval(1800)
            events.append(event)
        }
        service.events = events
    }
}

/// Test-driven knobs shared by a harness and its test: the inspector request
/// (the user's intent, not whether it is shown) and a forced sidebar collapse
/// standing in for ContentView's focus mode.
@MainActor
private final class HarnessControl: ObservableObject {
    @Published var inspectorRequested = false
    @Published var sidebarForcedHidden = false
    /// Set by the inspector content's appear/disappear: whether it is shown.
    var inspectorVisible = false
}

/// NotesEditorView's inspector layout (notes column + `widthGatedInspector`
/// hosting `NotesEditorInspector`), opened exactly as NotesEditorView does it:
/// from the view's task, after the prep has been read off the main actor.
/// NotesEditorView itself needs the recording service, AppModel and a model
/// store, so its layout is mirrored here.
///
/// One deviation: the real view starts with no prep, so the hidden inspector
/// first builds the To-Dos panel, which needs the full AppModel in the
/// environment. The harness therefore starts on the Prep tab with the prep
/// already set; the async load then re-assigns it and opens the inspector, as
/// the real view does.
private struct PrepAutoOpenInspectorHarness: View {
    let meeting: Meeting
    let prep: String
    @ObservedObject var control: HarnessControl
    let onOpen: () -> Void
    @State private var inspectorTab: InspectorTab = .prep
    @State private var prepMarkdown: String?

    init(meeting: Meeting, prep: String, control: HarnessControl, onOpen: @escaping () -> Void) {
        self.meeting = meeting
        self.prep = prep
        self.control = control
        self.onOpen = onOpen
        _prepMarkdown = State(initialValue: prep)
    }

    var body: some View {
        ToastMarkdownEditor(text: .constant("Notes"), placeholder: "Type your notes here...")
            .padding(CasaSpace.lg)
            .widthGatedInspector(isPresented: $control.inspectorRequested, idealWidth: 340) {
                NotesEditorInspector(
                    meeting: meeting,
                    prepPresentation: MeetingPrepPresentation(markdown: prepMarkdown, isExpanded: control.inspectorRequested),
                    inspectorTab: $inspectorTab
                )
                .onAppear { control.inspectorVisible = true }
                .onDisappear { control.inspectorVisible = false }
            }
            .task(id: meeting.id) {
                let source = MeetingPrepService.PrepSource(candidateURLs: [], localNotes: prep)
                let markdown = await Task.detached { MeetingPrepService.resolvedPrepMarkdown(from: source) }.value
                prepMarkdown = markdown
                let decision = PrepInspectorAutoOpenDecision(
                    isEnabled: true,
                    hasPrep: MeetingPrepService.hasPrepContent(markdown),
                    isFocusModeActive: false
                )
                if decision.shouldOpenPrep {
                    inspectorTab = .prep
                    control.inspectorRequested = true
                    onOpen()
                }
            }
    }
}

/// RecordedMeetingView's inspector layout: the reading column in a ScrollView
/// plus `widthGatedInspector` hosting the real `MeetingDetailInspector`, open
/// by default whenever the window enters the expanded tier. RecordedMeetingView
/// itself needs AppModel's services, so its layout is mirrored here.
private struct RecordedMeetingInspectorHarness: View {
    let meeting: Meeting
    @ObservedObject var control: HarnessControl
    @Environment(\.layoutWidthClass) private var widthClass

    var body: some View {
        ScrollView {
            Text(String(repeating: "Summary of the Orchestra migration sync. ", count: 40))
                .padding(CasaSpace.xl)
                .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widthGatedInspector(isPresented: $control.inspectorRequested, idealWidth: 320) {
            MeetingDetailInspector(meeting: meeting, canExport: true, onSelectMeeting: { _ in })
                .onAppear { control.inspectorVisible = true }
                .onDisappear { control.inspectorVisible = false }
        }
        .onChange(of: widthClass, initial: true) { _, cls in
            control.inspectorRequested = (cls == .expanded)
        }
    }
}

/// Mirrors ContentView's split: the same sidebar column limits and window
/// minimum, the GeometryReader-driven sidebar collapse below the responsive
/// breakpoint (plus a forced collapse standing in for focus mode), and the
/// width class published to the detail column. `stabilized` applies the
/// detail column's constant minimum exactly as ContentView does. ContentView
/// itself needs the full AppModel and store, so it is mirrored rather than
/// hosted; its toolbar is not covered here.
private struct ResponsiveSplitHarness<Detail: View>: View {
    let stabilized: Bool
    @ObservedObject var control: HarnessControl
    let detail: Detail
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var windowWidth: CGFloat = CasaLayout.windowDefaultWidth

    private var widthClass: LayoutWidthClass { .from(width: windowWidth) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarPlaceholderView()
                .navigationSplitViewColumnWidth(
                    min: CasaLayout.sidebarMinWidth,
                    ideal: CasaLayout.sidebarWidth,
                    max: CasaLayout.sidebarMaxWidth
                )
        } detail: {
            Group {
                if stabilized {
                    detail.stableSplitColumnMinimumSize(minWidth: CasaLayout.detailColumnMinWidth)
                } else {
                    detail
                }
            }
            .environment(\.layoutWidthClass, widthClass)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    windowWidth = width
                }
            }
        }
        .onChange(of: widthClass, initial: true) { _, _ in updateColumnVisibility() }
        .onChange(of: control.sidebarForcedHidden) { _, _ in updateColumnVisibility() }
        .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
    }

    private func updateColumnVisibility() {
        let collapse = control.sidebarForcedHidden || widthClass == .compact
        withAnimation(CasaAnimation.standard) {
            columnVisibility = collapse ? .detailOnly : .automatic
        }
    }
}

/// The notes column with the inspector panel always open, no width gate.
private struct UngatedPanelHarness: View {
    @ObservedObject var control: HarnessControl

    var body: some View {
        ToastMarkdownEditor(text: .constant("Notes"), placeholder: "Type your notes here...")
            .padding(CasaSpace.lg)
            .ungatedInspectorPanel(isPresented: $control.inspectorRequested, idealWidth: 340) {
                Text(String(repeating: "Prep for the Wegiz BgZ refinement. ", count: 20))
                    .padding(CasaSpace.lg)
                    .onAppear { control.inspectorVisible = true }
                    .onDisappear { control.inspectorVisible = false }
            }
    }
}
