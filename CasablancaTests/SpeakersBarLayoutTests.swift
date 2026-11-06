import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Casablanca

/// Hosts the transcript tab with a seeded speakers bar in a real `NSWindow`
/// that mirrors ContentView's split, and checks with
/// `SplitColumnMinimumSizeProbe` that resizing to the window minimum and
/// renaming speakers there never re-dirty the constraint pass. Also checks the
/// bar wraps its chips instead of widening the narrowest reading column. An
/// abort kills the test process, so reaching the end of a test is part of its
/// assertion.
///
/// `SplitLayoutStabilityTests` holds the probe's control; run it alongside.
@MainActor
final class SpeakersBarLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakersBarLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testTranscriptTabWithSpeakersSurvivesShrinkingTheWindowToItsMinimum() throws {
        let (meeting, container, store) = try makeMeeting()
        let control = SpeakersHarnessControl()
        let window = makeWindow(meeting: meeting, container: container, store: store, control: control, size: CGSize(width: 1080, height: 720))
        SplitColumnMinimumSizeProbe.observe(window)
        settle(window)
        XCTAssertTrue(control.appeared, "The transcript tab should be on screen")

        let widths: [CGFloat] = [1080, 900, 880, 879, 760, 700, 620, 600, 599, 560, 520, 480, 620, 480, 900, 599, 1080]
        for _ in 0..<2 {
            for width in widths {
                resize(window, to: CGSize(width: width, height: width < 600 ? 500 : 552))
                pump(window)
            }
        }
        settle(window)

        XCTAssertEqual(SplitColumnMinimumSizeProbe.redirtyCount, 0, "The transcript tab re-dirtied the constraint pass")
    }

    /// Renames and a merge at the minimum window size: the chips change
    /// width and count while the column is at its narrowest.
    func testRenamesAtTheMinimumWindowSizeDoNotRedirtyTheConstraintPass() throws {
        let (meeting, container, store) = try makeMeeting()
        let control = SpeakersHarnessControl()
        let window = makeWindow(
            meeting: meeting,
            container: container,
            store: store,
            control: control,
            size: CGSize(width: CasaLayout.windowMinWidth, height: CasaLayout.windowMinHeight)
        )
        SplitColumnMinimumSizeProbe.observe(window)
        settle(window)

        try SpeakerRenamer.rename(speakerID: "S1", to: "Kim Owen-Jones", in: meeting, store: store)
        settle(window)
        try SpeakerRenamer.rename(speakerID: "S2", to: String(repeating: "Langenaam ", count: 5), in: meeting, store: store)
        settle(window)
        XCTAssertTrue(try SpeakerRenamer.rename(speakerID: "S3", to: "Kim Owen-Jones", in: meeting, store: store))
        settle(window)
        try SpeakerRenamer.setIsUser(true, speakerID: "S4", in: meeting)
        settle(window)

        XCTAssertEqual(meeting.speakers.map(\.id), ["me", "S1", "S2", "S4"])
        XCTAssertTrue(meeting.transcript?.contains("[00:20] Kim Owen-Jones: Derde.") ?? false)
        XCTAssertEqual(SplitColumnMinimumSizeProbe.redirtyCount, 0, "The speakers bar re-dirtied the constraint pass")
    }

    /// At the narrowest reading column the chips wrap onto more rows instead
    /// of asking for more width; at a typical width they need fewer rows.
    func testBarWrapsWithinTheNarrowestColumn() throws {
        let (meeting, container, store) = try makeMeeting()
        let narrow: CGFloat = CasaLayout.detailColumnMinWidth - 2 * CasaSpace.xl
        let typical: CGFloat = CasaLayout.contentMaxWidth - 2 * CasaSpace.xl

        let narrowSize = fittingSize(meeting: meeting, container: container, store: store, width: narrow)
        let typicalSize = fittingSize(meeting: meeting, container: container, store: store, width: typical)

        XCTAssertLessThanOrEqual(narrowSize.width, narrow + 0.5, "The bar must not widen the narrowest column")
        XCTAssertLessThanOrEqual(typicalSize.width, typical + 0.5)
        XCTAssertGreaterThan(narrowSize.height, typicalSize.height, "Chips should wrap onto more rows when narrow")
    }

    func testFailureCaptionText() {
        XCTAssertEqual(
            SpeakersBar.failureCaption(.failed(reason: "The Internet connection appears to be offline.")),
            "Speaker recognition unavailable: The Internet connection appears to be offline."
        )
        XCTAssertNil(SpeakersBar.failureCaption(.succeeded(clusterCount: 2)))
        XCTAssertNil(SpeakersBar.failureCaption(nil))
    }

    // MARK: - Fixtures

    private func makeMeeting() throws -> (Meeting, ModelContainer, SpeakerAnalysisStore) {
        let schema = Schema([Meeting.self, TodoItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let meeting = Meeting(
            title: "Refinement Team Link",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            participants: ["Kim Owen-Jones", "Arriejanne Brouwer", "Jeroen van Dijk"],
            status: .completed
        )
        container.mainContext.insert(meeting)

        // Only the mic track exists, so "me" and the room speaker get ▶ and
        // the system speakers do not (their track is gone).
        let mic = directory.appendingPathComponent("mic.m4a")
        try Data([0]).write(to: mic)
        meeting.micTrackFileURL = mic.path
        meeting.systemTrackFileURL = directory.appendingPathComponent("system.m4a").path

        meeting.speakers = [
            SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true),
            SpeakerInfo(id: "S1", displayName: "Speaker 1", source: .system, isUser: false, nameConfirmed: false),
            SpeakerInfo(id: "S2", displayName: "Speaker 2", source: .system, isUser: false, nameConfirmed: false),
            SpeakerInfo(id: "S3", displayName: "Speaker 3", source: .system, isUser: false, nameConfirmed: false),
            SpeakerInfo(id: "S4", displayName: "Een heel lange naam die tot veertig tek", source: .room, isUser: false, nameConfirmed: true),
        ]
        meeting.speakerSegments = [
            SpeakerSegment(start: 0, end: 10, speakerID: "me", text: "Eerste.", words: nil),
            SpeakerSegment(start: 10, end: 20, speakerID: "S1", text: "Tweede.", words: nil),
            SpeakerSegment(start: 20, end: 26, speakerID: "S3", text: "Derde.", words: nil),
            SpeakerSegment(start: 26, end: 30, speakerID: "S2", text: "Vierde.", words: nil),
            SpeakerSegment(start: 30, end: 33, speakerID: "S4", text: "Vijfde.", words: nil),
        ]
        meeting.transcript = """
        [00:00] Youri: Eerste.
        [00:10] Speaker 1: Tweede.
        [00:20] Speaker 3: Derde.
        [00:26] Speaker 2: Vierde.
        [00:30] Een heel lange naam die tot veertig tek: Vijfde.
        """

        let store = SpeakerAnalysisStore(directory: directory.appendingPathComponent("Speakers", isDirectory: true))
        try store.save(SpeakerAnalysisRecord(
            meetingID: meeting.id,
            diarization: .failed(reason: "The Internet connection appears to be offline."),
            suggestions: [SpeakerNameSuggestion(speakerID: "S1", name: "Kim Owen-Jones", evidence: "Tweede", source: .transcript, score: nil)]
        ))
        return (meeting, container, store)
    }

    private func fittingSize(meeting: Meeting, container: ModelContainer, store: SpeakerAnalysisStore, width: CGFloat) -> CGSize {
        let controller = NSHostingController(
            rootView: SpeakersBar(meeting: meeting, store: store).modelContainer(container)
        )
        return controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    private func makeWindow(
        meeting: Meeting,
        container: ModelContainer,
        store: SpeakerAnalysisStore,
        control: SpeakersHarnessControl,
        size: CGSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: TranscriptSplitHarness(meeting: meeting, store: store, control: control)
                .modelContainer(container)
        )
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

@MainActor
private final class SpeakersHarnessControl: ObservableObject {
    var appeared = false
}

/// ContentView's split with the recorded meeting's transcript tab as the
/// detail, laid out as RecordedMeetingView does (scroll view, padding,
/// content max width).
private struct TranscriptSplitHarness: View {
    let meeting: Meeting
    let store: SpeakerAnalysisStore
    let control: SpeakersHarnessControl
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var windowWidth: CGFloat = CasaLayout.windowDefaultWidth
    @State private var terminologyService = TerminologyService(providerFactory: { StubLLMProvider() })

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
            ScrollView {
                MeetingTranscriptTab(
                    meeting: meeting,
                    terminologyService: terminologyService,
                    onTranscribe: {},
                    onSave: {},
                    speakerAnalysisStore: store
                )
                .padding(CasaSpace.xl)
                .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onAppear { control.appeared = true }
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
        .onChange(of: widthClass, initial: true) { _, _ in
            columnVisibility = widthClass == .compact ? .detailOnly : .automatic
        }
        .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
    }
}
