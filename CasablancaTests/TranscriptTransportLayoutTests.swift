import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Casablanca

/// The transcript tab with its transport bar (Task 2.1) at the narrowest
/// widths it gets.
///
/// - The bar's minimum width (its size for a 1 pt proposal) fits the reading
///   column at the detail column's minimum, and it stays one line there.
/// - In a window that mirrors ContentView's split, shrinking to the window
///   minimum and then jumping (chapter expands, line highlights, playback
///   starts, the time text changes width, pause) must not make a split column
///   publish a new minimum size during a constraint pass (the 0.16.0 abort
///   path, counted by `SplitColumnMinimumSizeProbe`; its control run is in
///   SplitLayoutStabilityTests). An abort kills the test process, so reaching
///   the end is part of the assertion.
@MainActor
final class TranscriptTransportLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var directory: URL!
    private var container: ModelContainer?
    private var engines: [TransportFakeEngine] = []

    /// The reading column at the detail column's minimum.
    private static let narrowColumn = CasaLayout.detailColumnMinWidth - 2 * CasaSpace.xl

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptTransportLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engines = []
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
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testTransportBarFitsTheNarrowestReadingColumnOnOneLine() throws {
        let recording = try makeRecordingFile()
        let player = makePlayer()
        // The widest time text: loaded, past an hour, of a long recording.
        try player.play(url: recording, from: 3723)
        XCTAssertEqual(player.duration, 7200)

        for (canPlay, unavailable) in [(true, false), (false, false), (true, true)] {
            let bar = TranscriptTransportBar(
                recordingURL: recording, canPlay: canPlay, isUnavailable: unavailable,
                knownDuration: 7200, onPlay: { _ in }, player: player
            )
            XCTAssertEqual(bar.timeText, "1:02:03 / 2:00:00")
            let host = NSHostingController(rootView: bar)
            let minimum = host.sizeThatFits(in: CGSize(width: 1, height: 10_000))
            XCTAssertLessThanOrEqual(
                minimum.width, Self.narrowColumn,
                "The transport needs \(minimum.width) pt; the reading column gives \(Self.narrowColumn) pt"
            )
            let fitted = host.sizeThatFits(in: CGSize(width: Self.narrowColumn, height: 10_000))
            XCTAssertLessThanOrEqual(fitted.width, Self.narrowColumn + 0.5)
            XCTAssertLessThan(fitted.height, 32, "The transport stays a single small line")
        }
    }

    func testJumpAtTheMinimumWindowSizeDoesNotRedirtyTheConstraintPass() throws {
        let recording = try makeRecordingFile()
        let meeting = try makeMeeting(recordingPath: recording.path)
        let player = makePlayer()
        let state = TransportHarnessState()
        let window = makeWindow(
            TransportSplitHarness(meeting: meeting, playback: TranscriptPlayback(player: player), state: state),
            size: CGSize(width: 1080, height: 720)
        )
        SplitColumnMinimumSizeProbe.observe(window)
        settle(window)

        let widths: [CGFloat] = [
            1080, 900, 880, 879, 760, 700, 620, 600, 599, 560, 520, CasaLayout.windowMinWidth,
            900, CasaLayout.windowMinWidth,
        ]
        for width in widths {
            resize(window, to: CGSize(width: width, height: width < 600 ? 500 : 552))
            pump(window)
        }
        resize(window, to: CGSize(width: CasaLayout.windowMinWidth, height: CasaLayout.windowMinHeight))
        settle(window)

        // A jump into the third (collapsed) chapter at the minimum width.
        state.jump = TimestampJump(token: UUID(), meetingID: meeting.id, seconds: 754)
        settle(window)

        XCTAssertNil(state.jump, "The tab reports the jump as handled")
        XCTAssertTrue(player.isPlaying, "A completed meeting with a recording plays")
        XCTAssertEqual(player.playingURL, recording)
        XCTAssertEqual(engines.last?.currentTime, 754, "Playback starts at the label's time, not the line's")

        // The time text grows past an hour, then playback pauses.
        player.seek(to: 3723)
        settle(window)
        player.pause()
        settle(window)
        for width in [CGFloat(620), CasaLayout.windowMinWidth, 900, CasaLayout.windowMinWidth] {
            resize(window, to: CGSize(width: width, height: 500))
            pump(window)
        }
        settle(window)

        XCTAssertEqual(
            SplitColumnMinimumSizeProbe.redirtyCount, 0,
            "A split column published a new minimum size during a constraint pass (0.16.0 crash path)"
        )
    }

    func testJumpWithoutARecordingFileScrollsWithoutPlaying() throws {
        let meeting = try makeMeeting(recordingPath: directory.appendingPathComponent("missing.m4a").path)
        let player = makePlayer()
        let state = TransportHarnessState()
        let window = makeWindow(
            TransportSplitHarness(meeting: meeting, playback: TranscriptPlayback(player: player), state: state),
            size: CGSize(width: CasaLayout.windowMinWidth, height: CasaLayout.windowMinHeight)
        )
        settle(window)

        state.jump = TimestampJump(token: UUID(), meetingID: meeting.id, seconds: 754)
        settle(window)

        XCTAssertNil(state.jump, "The jump is still carried out (scroll only)")
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(engines.isEmpty, "No playback is attempted without a file")
    }

    // MARK: - Fixtures

    private func makeRecordingFile() throws -> URL {
        let url = directory.appendingPathComponent("recording.m4a")
        try Data([0]).write(to: url)
        return url
    }

    private func makePlayer() -> AudioClipPlayer {
        AudioClipPlayer(
            makeEngine: { [unowned self] url in
                let engine = TransportFakeEngine()
                self.engines.append(engine)
                return engine
            },
            makeTicker: { _, _ in AnyCancellable {} }
        )
    }

    /// A completed meeting with three five-minute chapters of transcript.
    private func makeMeeting(recordingPath: String) throws -> Meeting {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        self.container = container
        let meeting = Meeting(
            title: "Refinement Team Link",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            participants: ["Kim Owen-Jones"],
            status: .completed
        )
        container.mainContext.insert(meeting)
        meeting.recordingFileURL = recordingPath
        meeting.recordingDuration = 7200
        meeting.transcript = stride(from: 0, to: 900, by: 30).map { second in
            let label = TranscriptLineFormat.timestampLabel(seconds: Double(second))
            return "[\(label)] Kim Owen-Jones: We bespreken de BgZ-uitwisseling en de planning voor de volgende sprint, regel \(second)."
        }.joined(separator: "\n")
        return meeting
    }

    private func makeWindow<Content: View>(_ content: Content, size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content.modelContainer(container!))
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
private final class TransportFakeEngine: AudioPlaybackEngine {
    var currentTime: Double = 0
    var duration: Double = 7200
    private(set) var isPlaying = false
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
private final class TransportHarnessState: ObservableObject {
    @Published var jump: TimestampJump?
}

/// ContentView's split with the transcript tab as the detail, laid out as
/// RecordedMeetingView does (scroll view reader, padding, content max width,
/// transport pinned with `safeAreaInset`).
private struct TransportSplitHarness: View {
    let meeting: Meeting
    let playback: TranscriptPlayback
    @ObservedObject var state: TransportHarnessState
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
            ScrollViewReader { proxy in
                ScrollView {
                    MeetingTranscriptTab(
                        meeting: meeting,
                        terminologyService: terminologyService,
                        onTranscribe: {},
                        onSave: {},
                        jump: state.jump,
                        scrollProxy: proxy,
                        onJumpHandled: { state.jump = nil },
                        playback: playback
                    )
                    .padding(CasaSpace.xl)
                    .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                // Pinned as in RecordedMeetingView.
                .safeAreaInset(edge: .top, spacing: 0) {
                    TranscriptTransportInset(meeting: meeting, isTranscribing: false, playback: playback)
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
        .onChange(of: widthClass, initial: true) { _, _ in
            columnVisibility = widthClass == .compact ? .detailOnly : .automatic
        }
        .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
    }
}
