// CasablancaTests/TodoReviewLayoutTests.swift
import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Casablanca

/// The review row and strip at the narrowest widths they get: the inspector
/// panel at its minimum (MeetingTodosPanel) and the summary tab's reading
/// column at the detail column's minimum (TodoReviewStrip).
///
/// - The minimum width each view insists on (its size for a 1 pt proposal)
///   must fit those widths; a row whose buttons, badge or header cannot
///   shrink or wrap would widen the panel or push the split.
/// - In a window that mirrors ContentView's split with the panel open,
///   shrinking to the window minimum and changing the rows (accept removes
///   one, an edit lengthens one, verification changes) must not make a split
///   column publish a new minimum size during a constraint pass (the 0.16.0
///   abort path, counted by `SplitColumnMinimumSizeProbe`). The probe's
///   ability to see that path on this macOS is proven by
///   SplitLayoutStabilityTests' control run.
@MainActor
final class TodoReviewLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var container: ModelContainer?

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
        container = nil
        try await super.tearDown()
    }

    /// MeetingTodosPanel pads its list by `CasaSpace.lg` inside the panel.
    private static let inspectorContentWidth = CasaLayout.inspectorColumnMinWidth - 2 * CasaSpace.lg
    /// The summary tab's reading column at the detail column's minimum.
    private static let summaryContentWidth = CasaLayout.detailColumnMinWidth - 2 * CasaSpace.xl

    func testReviewRowFitsTheMinimumInspectorWidth() throws {
        for todo in try makeTodos() {
            let host = NSHostingController(rootView: Self.row(todo))
            let minimum = host.sizeThatFits(in: CGSize(width: 1, height: 10_000))
            XCTAssertLessThanOrEqual(
                minimum.width, Self.inspectorContentWidth,
                "\"\(todo.text)\" needs \(minimum.width) pt; the inspector gives \(Self.inspectorContentWidth) pt"
            )
            // At that width the row wraps instead of growing sideways.
            let fitted = host.sizeThatFits(in: CGSize(width: Self.inspectorContentWidth, height: 10_000))
            XCTAssertLessThanOrEqual(fitted.width, Self.inspectorContentWidth)
            XCTAssertGreaterThan(fitted.height, 0)
        }
    }

    func testReviewStripFitsTheNarrowestSummaryColumn() throws {
        let todos = try makeTodos()
        for count in [0, 12] {
            let strip = TodoReviewStripContent(
                todos: todos,
                verifiedCount: count,
                onAccept: { _ in }, onReject: { _ in }, onEdit: { _, _, _, _ in }, onAcceptAllVerified: {}
            )
            let host = NSHostingController(rootView: strip)
            let minimum = host.sizeThatFits(in: CGSize(width: 1, height: 10_000))
            XCTAssertLessThanOrEqual(
                minimum.width, Self.summaryContentWidth,
                "The strip needs \(minimum.width) pt; the summary column gives \(Self.summaryContentWidth) pt"
            )
        }
    }

    func testReviewUIAtMinimumWidthDoesNotRedirtyTheConstraintPass() throws {
        let state = ReviewState(todos: try makeTodos())
        let window = makeWindow(ReviewSplitHarness(state: state), size: CGSize(width: 1080, height: 720))
        SplitColumnMinimumSizeProbe.observe(window)

        let widths: [CGFloat] = [
            1080, 900, 880, 879, 760, 700, 620, 600, 599, 560, 520, CasaLayout.windowMinWidth,
            760, CasaLayout.windowMinWidth, 900, 640, CasaLayout.windowMinWidth,
        ]
        for _ in 0..<2 {
            for width in widths {
                resize(window, to: CGSize(width: width, height: width < 600 ? 500 : 552))
                pump(window)
            }
        }

        // At the minimum width the rows change the way review changes them.
        resize(window, to: CGSize(width: CasaLayout.windowMinWidth, height: CasaLayout.windowMinHeight))
        pump(window)
        let first = try XCTUnwrap(state.todos.first)
        first.text = String(repeating: "Stuur de herziene offerte met de nieuwe tarieven naar Kim. ", count: 3)
        first.verification = .unsupported
        pump(window)
        state.verifiedCount = 0
        pump(window)
        state.todos.removeLast()
        pump(window)
        first.owner = "Arriejanne Brouwer en Kim Owen-Jones namens het partnerteam"
        pump(window)
        for width in [CGFloat(620), CasaLayout.windowMinWidth, 900, CasaLayout.windowMinWidth] {
            resize(window, to: CGSize(width: width, height: 500))
            pump(window)
        }

        XCTAssertEqual(
            SplitColumnMinimumSizeProbe.redirtyCount, 0,
            "A split column published a new minimum size during a constraint pass (0.16.0 crash path)"
        )
    }

    // MARK: - Fixtures

    private static func row(_ todo: TodoItem) -> TodoReviewRow {
        TodoReviewRow(todo: todo, onAccept: {}, onReject: {}, onEdit: { _, _, _ in })
    }

    private func makeTodos() throws -> [TodoItem] {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        self.container = container
        let context = container.mainContext
        let meeting = Meeting(title: "Wegiz BgZ refinement", date: Date(), participants: ["Kim Owen-Jones", "Arriejanne Brouwer"])
        context.insert(meeting)

        func proposed(_ text: String, owner: String?, due: Bool, timestamp: String?, quote: String?, verification: VerificationState?) -> TodoItem {
            let todo = TodoItem(text: text, meeting: meeting)
            todo.status = .proposed
            todo.owner = owner
            todo.dueDate = due ? Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6)) : nil
            todo.sourceTimestamp = timestamp
            todo.quote = quote
            todo.verification = verification
            context.insert(todo)
            return todo
        }
        return [
            proposed("Plan de demo", owner: nil, due: false, timestamp: nil, quote: nil, verification: nil),
            proposed(
                "Stuur de herziene offerte voor de BgZ-uitwisseling naar Kim en vraag om akkoord van het partnerteam",
                owner: "Youri Broekhuizen", due: true, timestamp: "1:02:03",
                quote: String(repeating: "dan stuur ik de offerte nog deze week naar Kim toe, ", count: 4),
                verification: .supported
            ),
            proposed(
                "Bel leverancier", owner: "Youri", due: true, timestamp: "12:34",
                quote: "ik bel ze morgen", verification: .unsupported
            ),
            // An owner as long as `sanitizedOwner` allows (60 characters).
            proposed(
                "Deel de planning", owner: "Arriejanne Brouwer en Kim Owen-Jones namens het partnerteam",
                due: true, timestamp: "1:12:34", quote: nil, verification: .unverified
            ),
        ]
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

    /// Constraint, layout and display passes, then a run-loop turn so SwiftUI's
    /// deferred transactions and AppKit's display-cycle observers run.
    private func pump(_ window: NSWindow) {
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
private final class ReviewState: ObservableObject {
    @Published var todos: [TodoItem]
    @Published var verifiedCount = 1

    init(todos: [TodoItem]) {
        self.todos = todos
    }
}

/// ContentView's split (sidebar limits, stabilized detail column, window
/// minimum) around the summary tab's reading column with the review strip,
/// and the meeting inspector panel (ungated, so it stays open at every width)
/// with MeetingTodosPanel's review section.
private struct ReviewSplitHarness: View {
    @ObservedObject var state: ReviewState

    var body: some View {
        NavigationSplitView {
            List { Text("Meetings") }
                .navigationSplitViewColumnWidth(
                    min: CasaLayout.sidebarMinWidth,
                    ideal: CasaLayout.sidebarWidth,
                    max: CasaLayout.sidebarMaxWidth
                )
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: CasaSpace.xl) {
                    TodoReviewStripContent(
                        todos: state.todos,
                        verifiedCount: state.verifiedCount,
                        onAccept: { _ in }, onReject: { _ in }, onEdit: { _, _, _, _ in }, onAcceptAllVerified: {}
                    )
                    Text(String(repeating: "De migratie naar Orchestra op Azure loopt volgens planning. ", count: 6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(CasaSpace.xl)
                .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ungatedInspectorPanel(isPresented: .constant(true), idealWidth: CasaLayout.inspectorColumnMinWidth) {
                ScrollView {
                    MeetingTodosReviewSection(
                        todos: state.todos,
                        onAccept: { _ in }, onReject: { _ in }, onEdit: { _, _, _, _ in }
                    )
                    .padding(CasaSpace.lg)
                }
            }
            .stableSplitColumnMinimumSize(minWidth: CasaLayout.detailColumnMinWidth)
        }
        .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
    }
}
