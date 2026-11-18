import AppKit
import SwiftUI
import XCTest
@testable import Casablanca

/// The summary hero header with the template row ("Template: …" and
/// "Regenerate with…") at the window's minimum width: no constraint-pass loop
/// (the 0.16.0 abort path, counted by `SplitColumnMinimumSizeProbe`) while the
/// window shrinks and the template name changes, and the row fits the narrowest
/// detail column instead of widening it.
///
/// MeetingSummaryTab needs AppModel, so its hero header is mirrored here with
/// the real `SummaryTemplateMenuContent`, inside a split that mirrors
/// ContentView's (stabilized detail column, window minimum) and the
/// RecordedMeetingView reading column. The probe's ability to see the abort
/// path on this macOS is proven by SplitLayoutStabilityTests' control run.
@MainActor
final class SummaryTemplateMenuLayoutTests: XCTestCase {
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

    /// Long template names truncate; the row never asks for more than the
    /// narrowest hero content width (detail column minimum minus the reading
    /// column's and the hero's padding).
    func testTemplateRowFitsTheNarrowestHeroWidth() {
        let width = CasaLayout.detailColumnMinWidth - 2 * CasaSpace.xl - 2 * CasaSpace.lg
        for presentation in Self.presentations {
            let host = NSHostingController(rootView: SummaryTemplateMenuContent(presentation: presentation, onPick: { _ in }))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
            XCTAssertLessThanOrEqual(size.width, width, "\"\(presentation.currentName)\" widens the hero at the minimum width")
        }
    }

    func testHeroHeaderAtMinimumWidthDoesNotRedirtyTheConstraintPass() {
        let state = HeaderState()
        let window = makeWindow(HeroSplitHarness(state: state), size: CGSize(width: 1080, height: 720))
        SplitColumnMinimumSizeProbe.observe(window)

        let widths: [CGFloat] = [1080, 900, 760, 620, 600, 599, 560, 520, CasaLayout.windowMinWidth, 620, CasaLayout.windowMinWidth]
        for _ in 0..<2 {
            for width in widths {
                resize(window, to: CGSize(width: width, height: width < 600 ? 500 : 552))
                pump(window)
            }
        }
        // At the minimum width, the template name changes (a regenerate, or the
        // auto pick changing with the title) and the menu toggles disabled.
        resize(window, to: CGSize(width: CasaLayout.windowMinWidth, height: CasaLayout.windowMinHeight))
        for _ in 0..<3 {
            for presentation in Self.presentations {
                state.presentation = presentation
                state.isDisabled.toggle()
                pump(window)
            }
        }

        XCTAssertEqual(
            SplitColumnMinimumSizeProbe.redirtyCount, 0,
            "The detail column published a new minimum size during a constraint pass (0.16.0 crash path)"
        )
    }

    // MARK: - Fixtures

    private static let presentations: [SummaryTemplateMenuPresentation] = {
        let custom = SummaryTemplate(
            id: "custom-long",
            name: "Kwartaalreview met alle integratiepartners en het volledige productteam",
            prompt: "p",
            isBuiltIn: false
        )
        let templates = SummaryTemplateCatalog.builtIns + [custom]
        return [
            SummaryTemplateMenuPresentation(templates: templates, currentID: nil, autoID: SummaryTemplateID.general),
            SummaryTemplateMenuPresentation(templates: templates, currentID: nil, autoID: SummaryTemplateID.external),
            SummaryTemplateMenuPresentation(templates: templates, currentID: SummaryTemplateID.standup, autoID: SummaryTemplateID.general),
            SummaryTemplateMenuPresentation(templates: templates, currentID: "custom-long", autoID: SummaryTemplateID.general),
        ]
    }()

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
private final class HeaderState: ObservableObject {
    @Published var presentation = SummaryTemplateMenuPresentation(
        templates: SummaryTemplateCatalog.builtIns, currentID: nil, autoID: SummaryTemplateID.general)
    @Published var isDisabled = false
}

/// ContentView's split (sidebar limits, stabilized detail column, window
/// minimum) around RecordedMeetingView's reading column holding a mirror of
/// MeetingSummaryTab's hero header.
private struct HeroSplitHarness: View {
    @ObservedObject var state: HeaderState

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
                hero
                    .padding(CasaSpace.xl)
                    .frame(maxWidth: CasaLayout.contentMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .stableSplitColumnMinimumSize(minWidth: CasaLayout.detailColumnMinWidth)
        }
        .frame(minWidth: CasaLayout.windowMinWidth, minHeight: CasaLayout.windowMinHeight)
    }

    /// Mirrors `MeetingSummaryTab.summaryHero`.
    private var hero: some View {
        VStack(alignment: .leading, spacing: CasaSpace.sm) {
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                Spacer()
                Button {} label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption)
                }
                .buttonStyle(GhostButtonStyle())
            }

            SummaryTemplateMenuContent(presentation: state.presentation, onPick: { _ in })
                .disabled(state.isDisabled)

            Text(String(repeating: "De migratie naar Orchestra op Azure loopt volgens planning. ", count: 6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CasaSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stateAIGenerated, in: RoundedRectangle(cornerRadius: CasaRadius.xl))
    }
}
