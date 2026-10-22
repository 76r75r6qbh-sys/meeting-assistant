import AppKit
import EventKit
import SwiftUI
import XCTest
@testable import Casablanca

/// Regression tests for the 0.16.0 crash: AppKit aborted with "more Update
/// Constraints in Window passes than there are views" because the dashboard
/// column published a new minimum size during the constraint pass whenever its
/// content changed (the hero card appearing after a calendar refresh, text
/// re-wrapping at a new width) while the window was small.
///
/// The layout is hosted in a real `NSWindow` that mirrors ContentView's split,
/// and `SplitColumnMinimumSizeProbe` counts the exact re-dirtying from the
/// crash report.
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

    /// Opening a meeting with prep opens the notes inspector on its Prep tab
    /// programmatically, right after the asynchronous prep load. Hosts the real
    /// `NotesEditorInspector` and notes editor in NotesEditorView's inspector
    /// layout inside the split and opens it the same way, at regular window
    /// sizes. An AppKit constraint-pass abort kills the test process, so
    /// reaching the end is part of the assertion.
    func testInspectorAutoOpenedAfterPrepLoadOpensOnceWithoutAborting() {
        let (window, openCount) = makeAutoOpenedInspectorWindow()
        XCTAssertEqual(openCount(), 1, "The inspector should auto-open once the prep has loaded")

        for size in [CGSize(width: 900, height: 600), CGSize(width: 1200, height: 800), CGSize(width: 1080, height: 720)] {
            resize(window, to: size)
            pump(window)
        }

        XCTAssertEqual(openCount(), 1, "Re-renders and resizes must not re-open the inspector")
    }

    /// KNOWN, PRE-EXISTING crash (not caused by auto-open): with ANY open
    /// `.inspector` in the split's detail column, shrinking the window toward
    /// its minimum (480–620 pt wide) aborts AppKit with "more Update Constraints
    /// in Window passes than there are views". Reproduced in this harness
    /// regardless of how the inspector was opened (presented from the start or
    /// programmatically later), of its content (real inspector, web viewer
    /// only, segmented picker only, or `Color.clear`), and of its
    /// `inspectorColumnWidth` (range, ideal-only, fixed, none); hosting the same
    /// layout WITHOUT the NavigationSplitView did not abort. RecordedMeetingView
    /// uses the same inspector pattern. Skipped because it kills the test
    /// process; remove the skip to reproduce.
    func testOpenInspectorSurvivesShrinkingTheWindowToItsMinimum() throws {
        try XCTSkipIf(true, "Known pre-existing AppKit constraint-pass abort for an open inspector in a narrow window")

        let (window, _) = makeAutoOpenedInspectorWindow()
        for size in [CGSize(width: 700, height: 552), CGSize(width: 480, height: 500),
                     CGSize(width: 620, height: 500), CGSize(width: 900, height: 600)] {
            resize(window, to: size)
            pump(window)
        }
    }

    private func makeAutoOpenedInspectorWindow() -> (NSWindow, () -> Int) {
        final class Counter { var value = 0 }
        let counter = Counter()
        let window = makeWindow(
            ResponsiveSplitHarness(
                stabilized: true,
                detail: PrepAutoOpenInspectorHarness(
                    meeting: Meeting(title: "Wegiz BgZ refinement", date: Date()),
                    prep: "# Prep\n\n- Agree on the BgZ scope\n- Partner timeline",
                    onOpen: { counter.value += 1 }
                )
            ),
            size: CGSize(width: 1080, height: 720)
        )
        // Let the detached prep load return and the inspector open.
        let deadline = Date().addingTimeInterval(2)
        while counter.value == 0 && Date() < deadline { pump(window) }
        return (window, { counter.value })
    }

    // MARK: - Scenarios

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

    /// The calendar starts unauthorized so DashboardView's one-shot `.task`
    /// skips its EventKit fetch (the test host is the real app and may have
    /// calendar access); access and fixtures are granted after it has run, so
    /// the real calendar is never read and never replaces the fixtures.
    private func makeDashboardWindow(calendar: CalendarService, stabilized: Bool, heroMinutesAhead: Int?) -> NSWindow {
        let viewModel = MeetingListViewModel(calendarService: calendar, meetingHasPrep: { _ in false })
        let window = makeWindow(
            ResponsiveSplitHarness(stabilized: stabilized, detail: DashboardView(viewModel: viewModel)),
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

/// NotesEditorView's inspector layout (notes column + `.inspector` hosting
/// `NotesEditorInspector`), opened exactly as NotesEditorView does it: from the
/// view's task, after the prep has been read off the main actor. NotesEditorView
/// itself needs the recording service, AppModel and a model store, so its
/// layout is mirrored here.
///
/// One deviation: the real view starts with no prep, so the hidden inspector
/// first builds the To-Dos panel, which needs the full AppModel in the
/// environment. The harness therefore starts on the Prep tab with the prep
/// already set; the async load then re-assigns it and opens the inspector, as
/// the real view does.
private struct PrepAutoOpenInspectorHarness: View {
    let meeting: Meeting
    let prep: String
    let onOpen: () -> Void
    @State private var isInspectorPresented = false
    @State private var inspectorTab: InspectorTab = .prep
    @State private var prepMarkdown: String?

    init(meeting: Meeting, prep: String, onOpen: @escaping () -> Void) {
        self.meeting = meeting
        self.prep = prep
        self.onOpen = onOpen
        _prepMarkdown = State(initialValue: prep)
    }

    var body: some View {
        ToastMarkdownEditor(text: .constant("Notes"), placeholder: "Type your notes here...")
            .padding(CasaSpace.lg)
            .inspector(isPresented: $isInspectorPresented) {
                NotesEditorInspector(
                    meeting: meeting,
                    prepPresentation: MeetingPrepPresentation(markdown: prepMarkdown, isExpanded: isInspectorPresented),
                    inspectorTab: $inspectorTab
                )
                .stableSplitColumnMinimumSize()
                .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
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
                    isInspectorPresented = true
                    onOpen()
                }
            }
    }
}

/// Mirrors ContentView's split: the same sidebar column limits and window
/// minimum, and the GeometryReader-driven sidebar collapse below the
/// responsive breakpoint. `stabilized` applies the fix to the detail column
/// exactly as ContentView does. ContentView itself needs the full AppModel and
/// store, so it is mirrored rather than hosted; the inspector columns and
/// ContentView's toolbar are not covered here.
private struct ResponsiveSplitHarness<Detail: View>: View {
    let stabilized: Bool
    let detail: Detail
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var windowWidth: CGFloat = CasaLayout.windowDefaultWidth

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarPlaceholderView()
                .navigationSplitViewColumnWidth(min: CasaLayout.sidebarMinWidth, ideal: CasaLayout.sidebarWidth, max: 260)
        } detail: {
            if stabilized {
                detail.stableSplitColumnMinimumSize(minWidth: CasaLayout.detailColumnMinWidth)
            } else {
                detail
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    windowWidth = width
                }
            }
        }
        .onChange(of: LayoutWidthClass.from(width: windowWidth), initial: true) { _, widthClass in
            withAnimation(CasaAnimation.standard) {
                columnVisibility = widthClass == .compact ? .detailOnly : .automatic
            }
        }
        .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
    }
}
