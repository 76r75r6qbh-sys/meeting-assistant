import AppKit
import SwiftUI
import XCTest
@testable import Casablanca

/// Hosts `AskView` in a real `NSWindow` that mirrors ContentView's split
/// (sidebar column limits, window minimum, stable detail-column minimum,
/// sidebar collapse below the compact breakpoint) and checks, with
/// `SplitColumnMinimumSizeProbe`, that its content changes (index build, an
/// answer with citations arriving, the summary-busy hint, filter options) and
/// window resizes down to the minimum never re-dirty the constraint pass —
/// the path behind the app's earlier layout-constraint aborts. An abort kills
/// the test process, so reaching the end of a test is part of its assertion.
///
/// `SplitLayoutStabilityTests` holds the probe's control (the unstabilized
/// dashboard must re-dirty); run it alongside this class.
@MainActor
final class AskViewLayoutTests: XCTestCase {
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

    // MARK: - Tests

    /// An answer with resolved citations, shown in a typical window, then the
    /// window shrinks to its minimum and back through every width tier.
    func testAnsweredAskViewSurvivesShrinkingTheWindowToItsMinimum() async throws {
        let (service, _) = makeService()
        let control = AskHarnessControl()
        let window = makeWindow(service: service, control: control, size: CGSize(width: 1080, height: 720))
        SplitColumnMinimumSizeProbe.observe(window)

        try await ask(service, window: window)
        let answer = try XCTUnwrap(service.answer)
        XCTAssertFalse(answer.sources.isEmpty)
        XCTAssertFalse(AskCitations.attributed(answer.segments).targets.isEmpty, "The answer should carry a citation link")
        XCTAssertFalse(service.filterOptions.participants.isEmpty)

        let widths: [CGFloat] = [1080, 900, 880, 879, 760, 700, 620, 600, 599, 560, 520, 480, 620, 480, 900, 599, 1080]
        for _ in 0..<2 {
            for width in widths {
                resize(window, to: CGSize(width: width, height: width < 600 ? 500 : 552))
                pump(window)
            }
        }
        settle(window)

        XCTAssertEqual(SplitColumnMinimumSizeProbe.redirtyCount, 0, "The Ask detail column re-dirtied the constraint pass")
        XCTAssertTrue(control.appeared, "AskView should be on screen")
    }

    /// Content changes while the window is at its minimum size: the index
    /// build, the answer arriving, the summary-busy hint toggling, and the
    /// sidebar collapsing/expanding.
    func testContentChangesAtTheMinimumWindowSizeDoNotRedirtyTheConstraintPass() async throws {
        let (service, _) = makeService()
        let control = AskHarnessControl()
        let window = makeWindow(
            service: service,
            control: control,
            size: CGSize(width: CasaLayout.windowMinWidth, height: CasaLayout.windowMinHeight)
        )
        SplitColumnMinimumSizeProbe.observe(window)

        try await ask(service, window: window)
        XCTAssertNotNil(service.answer)

        for busy in [true, false, true, false] {
            control.isSummaryInProgress = busy
            pump(window)
        }
        for hidden in [true, false, true, false] {
            control.sidebarForcedHidden = hidden
            settle(window)
        }
        service.invalidateIndex()
        await service.prepareIndex().value
        settle(window)

        XCTAssertEqual(SplitColumnMinimumSizeProbe.redirtyCount, 0, "The Ask detail column re-dirtied the constraint pass")
        XCTAssertTrue(control.appeared)
    }

    /// Typical size, no answer yet: the view prepares the index on appear.
    func testAskViewPreparesTheIndexOnAppear() async throws {
        let (service, loads) = makeService()
        let control = AskHarnessControl()
        let window = makeWindow(service: service, control: control, size: CGSize(width: 900, height: 600))
        let deadline = Date().addingTimeInterval(2)
        while !service.isIndexFresh && Date() < deadline {
            pump(window)
            // Let the main-actor build task run between pumps.
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(control.appeared, "AskView should be on screen")
        XCTAssertTrue(service.isIndexFresh, "onAppear should build the index")
        XCTAssertEqual(loads.count, 1)
    }

    /// Leaving the Ask view (routing elsewhere) cancels the in-flight answer:
    /// the provider call is cancelled and the service ends with neither an
    /// answer nor an error.
    func testLeavingTheAskViewCancelsAnInFlightAnswer() async throws {
        let provider = HangingLLMProvider()
        let calendar = Calendar.current
        let meeting = Meeting(
            title: "Refinement Team Link",
            date: calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!,
            participants: ["Kim"],
            status: .completed
        )
        meeting.transcript = "[00:10] Kim: We besluiten de BgZ uitwisseling via Wegiz te bouwen."
        let snapshot = AskMeetingSnapshot(meeting: meeting)
        let service = AskService(
            snapshotLoader: { [snapshot] },
            providerFactory: { provider },
            retryPolicy: LLMRetryPolicy(maxAttempts: 1, baseDelay: 0, sleep: { _ in }),
            thinkingEnabled: { true }
        )
        let control = AskHarnessControl()
        let window = makeWindow(service: service, control: control, size: CGSize(width: 900, height: 600))
        XCTAssertNotNil(service.ask("Wat hebben we besloten over BgZ?", filter: .none))

        var deadline = Date().addingTimeInterval(2)
        while !provider.started && Date() < deadline {
            pump(window)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(provider.started, "The ask should reach the provider")
        XCTAssertTrue(service.isAnswering)

        control.showsAsk = false
        deadline = Date().addingTimeInterval(2)
        while (service.isAnswering || !provider.cancelled) && Date() < deadline {
            pump(window)
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(service.isAnswering, "Leaving Ask should stop the answer")
        XCTAssertTrue(provider.cancelled, "The provider call should be cancelled")
        XCTAssertNil(service.answer)
        XCTAssertNil(service.errorMessage)
    }

    // MARK: - Fixtures

    @MainActor
    private final class LoadCounter { var count = 0 }

    private func makeService() -> (AskService, LoadCounter) {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
        let meeting = Meeting(
            title: "Refinement Team Link",
            date: date,
            participants: ["Kim Owen-Jones", "Arriejanne Brouwer"],
            status: .completed
        )
        meeting.transcript = """
        [00:10] Kim: We besluiten de BgZ uitwisseling via Wegiz te bouwen.
        [00:40] Youri: Akkoord, de BgZ gaat in sprint drie.
        """
        meeting.tags = ["wegiz"]
        let snapshot = AskMeetingSnapshot(meeting: meeting)
        let citation = "[\(AskCitationFormat.citationTitle(meeting.title)), \(AskCitationFormat.dateLabel(meeting.date)), 00:10]"
        let reply = "We bouwen de BgZ uitwisseling via Wegiz \(citation). "
            + String(repeating: "Dit is een lange toelichting die over meerdere regels loopt. ", count: 8)
        let stub = StubLLMProvider(outcomes: [.success(reply)])
        let loads = LoadCounter()
        let service = AskService(
            snapshotLoader: {
                loads.count += 1
                return [snapshot]
            },
            providerFactory: { stub },
            retryPolicy: LLMRetryPolicy(maxAttempts: 1, baseDelay: 0, sleep: { _ in }),
            thinkingEnabled: { true }
        )
        return (service, loads)
    }

    private func ask(_ service: AskService, window: NSWindow) async throws {
        let task = try XCTUnwrap(service.ask("Wat hebben we besloten over BgZ?", filter: .none))
        await task.value
        let deadline = Date().addingTimeInterval(2)
        while (service.isAnswering || service.isIndexing) && Date() < deadline { pump(window) }
        settle(window)
    }

    private func makeWindow(service: AskService, control: AskHarnessControl, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AskSplitHarness(service: service, control: control))
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

    private func settle(_ window: NSWindow) {
        for _ in 0..<25 { pump(window) }
    }

    private func pump(_ window: NSWindow) {
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

private final class AskHarnessControl: ObservableObject {
    @Published var isSummaryInProgress = false
    @Published var sidebarForcedHidden = false
    @Published var showsAsk = true
    var appeared = false
}

/// ContentView's split with `AskView` as the detail, exactly as routed there
/// (stable detail-column minimum, width class, compact sidebar collapse).
private struct AskSplitHarness: View {
    let service: AskService
    @ObservedObject var control: AskHarnessControl
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
                if control.showsAsk {
                    AskView(
                        service: service,
                        isSummaryInProgress: control.isSummaryInProgress,
                        onOpenCitation: { _ in }
                    )
                    .onAppear { control.appeared = true }
                } else {
                    // Stands in for routing to another destination.
                    Text("Dashboard")
                }
            }
            .stableSplitColumnMinimumSize(minWidth: CasaLayout.detailColumnMinWidth)
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

/// A provider whose generation runs until cancelled, so a test can act while
/// an answer is in flight.
private final class HangingLLMProvider: LLMProvider, @unchecked Sendable {
    let displayName = "Hanging"
    let endpoint = "stub://hanging"
    let preferredTimeout: TimeInterval? = nil
    let supportsFullTranscriptEcho = true
    let promptTokenBudget = LLMPromptSupport.localPromptTokenBudget

    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func generate(
        prompt: String,
        temperature: Double?,
        maxTokens: Int?,
        timeout: TimeInterval,
        truncated: ((Bool) -> Void)?
    ) async throws -> String {
        lock.withLock { didStart = true }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            lock.withLock { didCancel = true }
            throw error
        }
        return "late"
    }

    func fetchAvailableModels(endpoint: String) async throws -> [String] { [] }
}
