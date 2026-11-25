import CoreGraphics
import Foundation
import XCTest
@testable import Casablanca

// MARK: - Single title

/// Titles are the literal strings captured from new Teams on 2026-11-05 (spec,
/// "Evidence"), account email included, so a change in the parser is checked
/// against what Teams really shows.
final class TeamsCallWindowTitleParserTests: XCTestCase {
    private let suffix = " | Zenith | joris@example.com"

    func testMainWindowSectionTitlesAreNotCalls() {
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Chat | Judith Meijer, Marco Smit, Wouter Smeets +1 | Zenith | joris@example.com"))
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Chat | Marco Smit | Zenith | joris@example.com"))
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Calendar | Zenith | joris@example.com"))
    }

    func testMeetNowPreJoinAndInCall() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting join | Meeting with Joris Verbeek | Zenith | joris@example.com"),
            "Meeting with Joris Verbeek")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting with Joris Verbeek | Zenith | joris@example.com"),
            "Meeting with Joris Verbeek")
    }

    /// Captured 2026-11-05 while sharing in an external meeting: the shared-
    /// content pop-out wraps the meeting's name.
    /// Captured 2026-11-05: a 1:1 call window has no prefix and no pre-join.
    func testOneToOneCallWindowNamesThePerson() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Romy Mulder | Zenith | joris@example.com"),
            "Romy Mulder")
    }

    func testOneToOneCallAlongsideItsChatYieldsOnlyThePerson() {
        let windows = [
            TeamsWindow(number: 10, title: "Chat | Romy Mulder | Zenith | joris@example.com"),
            TeamsWindow(number: 42, title: "Romy Mulder | Zenith | joris@example.com"),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), ["Romy Mulder"])
    }

    func testSharedContentWindowNamesTheMeeting() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Shared content | Zenith/Northwind/Contoso | Zenith | joris@example.com"),
            "Zenith/Northwind/Contoso")
    }

    // 2026-11-09: Teams' compact meeting view (the floating mini window it
    // shows when the meeting window loses focus or a screen is shared) was
    // read as a call named "Meeting compact view | <meeting>".
    func testCompactViewWindowNamesTheMeeting() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting compact view | AI frontrunners  | Zenith | joris@example.com"),
            "AI frontrunners")
        let windows = TeamsCallWindowTitle.callWindows(fromWindows: [
            TeamsWindow(number: 22489, title: "Meeting compact view | Daily AI team | Zenith | joris@example.com"),
        ])
        XCTAssertEqual(windows, [TeamsCallWindowName(number: 22489, name: "Daily AI team", isPreJoin: false)],
                       "The compact view is in the call, not a pre-join screen")
    }

    func testScheduledMeetingPreJoinAndInCall() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting join | Daily AI team | Zenith | joris@example.com"),
            "Daily AI team")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Daily AI team | Zenith | joris@example.com"),
            "Daily AI team")
    }

    func testSharingControlBarIsNotACall() {
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Sharing control bar | Zenith | joris@example.com"))
    }

    func testExpectedOneToOneCallTitle() {
        XCTAssertEqual(TeamsCallWindowTitle.callName(fromWindowTitle: "Marco Smit" + suffix), "Marco Smit")
    }

    func testTitleWithoutEmailSuffixIsRejected() {
        // Not the known format: stay conservative rather than guess.
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Daily AI team | Zenith"))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Daily AI team"))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Microsoft Teams"))
    }

    func testCallNameContainingTheSeparatorIsRejoined() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting join | Sprint review | Team Comet" + suffix),
            "Sprint review | Team Comet")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Sprint review | Team Comet" + suffix),
            "Sprint review | Team Comet")
    }

    func testDutchSectionNamesAreNotCalls() {
        for section in ["Activiteit", "Agenda", "Oproepen", "Bestanden", "Instellingen", "Zoeken",
                        "Meldingen", "Vergaderingen"] {
            XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: section + suffix), section)
        }
    }

    func testEnglishSectionNamesAreNotCallsCaseInsensitively() {
        for section in ["Activity", "chat", "TEAMS", "Calls", "OneDrive", "Files", "Apps", "Copilot",
                        "Communities", "Assignments", "Approvals", "Planner", "Shifts", "Settings",
                        "Help", "Search", "Notifications", "sharing control bar"] {
            XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: section + suffix), section)
        }
    }

    func testOnlyTheFirstComponentIsCheckedAgainstSections() {
        // A meeting named after a section word further in is still a meeting.
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Planning | Calendar" + suffix),
            "Planning | Calendar")
    }

    func testComponentsAreTrimmedAndEmptyOnesDropped() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "  Meeting join |  | Daily AI team  | Zenith |  joris@example.com "),
            "Daily AI team")
    }

    func testPreJoinTokenAloneLeavesNothing() {
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting join" + suffix))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Zenith | joris@example.com"))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "joris@example.com"))
    }

    // MARK: Placeholders (Revision 2)

    func testExternalMeetingPreJoinPlaceholderIsNoName() {
        // Captured 2026-11-05 10:01 for ~8 s before the subject appeared.
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Meeting join | Microsoft Teams meeting | Zenith | joris@example.com"))
    }

    func testExternalMeetingInCallTitleIsTheSubject() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Zenith/Northwind/Contoso | Zenith | joris@example.com"),
            "Zenith/Northwind/Contoso")
    }

    func testPoppedOutChatIsNoName() {
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Chat | Marco Smit | Zenith | joris@example.com"))
    }

    func testEveryPlaceholderIsNoNameWhateverItsCasePunctuationOrSpacing() {
        for placeholder in [
            "Microsoft Teams meeting", "Microsoft Teams-vergadering", "Microsoft Teams vergadering",
            "Teams meeting", "Meeting", "Vergadering",
            "MICROSOFT TEAMS MEETING", "microsoft  teams-meeting", "Teams Meeting.", "vergadering",
        ] {
            XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: placeholder + suffix), placeholder)
            XCTAssertNil(
                TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting join | " + placeholder + suffix), placeholder)
            XCTAssertTrue(TeamsCallWindowTitle.isPlaceholderCallName(placeholder), placeholder)
        }
    }

    func testNamesThatOnlyContainAPlaceholderAreStillNames() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting with Joris Verbeek" + suffix),
            "Meeting with Joris Verbeek")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Teams meeting Link" + suffix), "Teams meeting Link")
        XCTAssertFalse(TeamsCallWindowTitle.isPlaceholderCallName("Vergadering Team Comet"))
    }

    func testAnyPlaceholderComponentMeansNoName() {
        // An unknown pre-join token in front of a placeholder: the joined
        // name is not a placeholder, but one of its components is.
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Deelnemen aan vergadering | Microsoft Teams-vergadering | Zenith | joris@example.com"))
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Some prefix | Microsoft Teams meeting | Zenith | x@y.nl"))
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Vergadering Team Comet | Sprint 3" + suffix),
            "Vergadering Team Comet | Sprint 3")
    }

    func testShortDutchTeamsMeetingPlaceholderIsNoName() {
        for placeholder in ["Teams-vergadering", "Teams vergadering", "teams-VERGADERING"] {
            XCTAssertTrue(TeamsCallWindowTitle.isPlaceholderCallName(placeholder), placeholder)
            XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: placeholder + suffix), placeholder)
        }
        XCTAssertTrue(TeamsCallWindowTitle.placeholderCallNames.contains("teams vergadering"))
    }

    func testEmptyAndWhitespaceTitles() {
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: ""))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "   "))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: " | | "))
    }
}

// MARK: - Window lists

final class TeamsCallWindowListTests: XCTestCase {
    private let suffix = " | Zenith | joris@example.com"

    func testEmptyListHasNoCallName() {
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: []), [])
    }

    func testOnlyMainWindowHasNoCallName() {
        let windows = [TeamsWindow(number: 10, title: "Chat | Marco Smit" + suffix)]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), [])
    }

    func testPreJoinWindowNextToMainWindow() {
        let windows = [
            TeamsWindow(number: 10, title: "Calendar" + suffix),
            TeamsWindow(number: 42, title: "Meeting join | Daily AI team" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), ["Daily AI team"])
    }

    func testScreenSharingDuplicatesAreOneName() {
        // During sharing the call window and its system-dialog twin carry the
        // same title, next to the sharing bar.
        let windows = [
            TeamsWindow(number: 10, title: "Chat | Marco Smit" + suffix),
            TeamsWindow(number: 42, title: "Daily AI team" + suffix),
            TeamsWindow(number: 50, title: "Sharing control bar" + suffix),
            TeamsWindow(number: 51, title: "Daily AI team" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), ["Daily AI team"])
    }

    func testNewestWindowWinsAmongDistinctNames() {
        let windows = [
            TeamsWindow(number: 77, title: "Daily AI team" + suffix),
            TeamsWindow(number: 30, title: "Marco Smit" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows).first, "Daily AI team")
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows.reversed()).first, "Daily AI team",
                       "Order of the list does not matter; the window number decides")
    }

    func testEveryDistinctNameIsReturnedNewestWindowFirst() {
        let windows = [
            TeamsWindow(number: 30, title: "Marco Smit" + suffix),
            TeamsWindow(number: 10, title: "Chat | Marco Smit" + suffix),
            TeamsWindow(number: 77, title: "Daily AI team" + suffix),
            TeamsWindow(number: 51, title: "Partner sync" + suffix),
            TeamsWindow(number: 20, title: "Daily AI team" + suffix),
        ]
        XCTAssertEqual(
            TeamsCallWindowTitle.callNames(fromWindows: windows),
            ["Daily AI team", "Partner sync", "Marco Smit"]
        )
        XCTAssertEqual(
            TeamsCallWindowTitle.callNames(fromWindows: windows.reversed()),
            ["Daily AI team", "Partner sync", "Marco Smit"]
        )
    }

    func testNamesDifferingOnlyInNormalizationAreOneNameNewestSpellingKept() {
        let windows = [
            TeamsWindow(number: 20, title: "daily ai team" + suffix),
            TeamsWindow(number: 77, title: "Daily AI-team" + suffix),
            TeamsWindow(number: 51, title: "Partner sync" + suffix),
            TeamsWindow(number: 30, title: "DAILY  AI TEAM" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), ["Daily AI-team", "Partner sync"])
    }

    func testPlaceholderWindowIsLeftOutOfTheList() {
        let windows = [
            TeamsWindow(number: 10, title: "Calendar" + suffix),
            TeamsWindow(number: 42, title: "Meeting join | Microsoft Teams meeting" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), [])
    }

    // MARK: Call windows (Revision 3)

    func testCallWindowsAreNewestFirstAndNotDeduplicated() {
        let windows = [
            TeamsWindow(number: 10, title: "Chat | Marco Smit" + suffix),
            TeamsWindow(number: 42, title: "Daily AI team" + suffix),
            TeamsWindow(number: 50, title: "Sharing control bar" + suffix),
            TeamsWindow(number: 51, title: "Shared content | Daily AI team" + suffix),
            TeamsWindow(number: 60, title: "Meeting join | Partner sync" + suffix),
            TeamsWindow(number: 61, title: "Meeting join | Microsoft Teams meeting" + suffix),
        ]
        let expected = [
            TeamsCallWindowName(number: 60, name: "Partner sync", isPreJoin: true),
            TeamsCallWindowName(number: 51, name: "Daily AI team", isPreJoin: false),
            TeamsCallWindowName(number: 42, name: "Daily AI team", isPreJoin: false),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callWindows(fromWindows: windows), expected)
        XCTAssertEqual(TeamsCallWindowTitle.callWindows(fromWindows: windows.reversed()), expected,
                       "The window number decides the order, not the list")
    }

    func testCallNamesAreTheDeduplicatedCallWindowNames() {
        let windows = [
            TeamsWindow(number: 42, title: "Daily AI team" + suffix),
            TeamsWindow(number: 51, title: "Shared content | Daily AI team" + suffix),
            TeamsWindow(number: 60, title: "Meeting join | Partner sync" + suffix),
        ]
        let callWindows = TeamsCallWindowTitle.callWindows(fromWindows: windows)
        XCTAssertEqual(TeamsCallWindowTitle.callNames(from: callWindows), ["Partner sync", "Daily AI team"])
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), ["Partner sync", "Daily AI team"])
    }
}

// MARK: - Reader

@MainActor
final class CGTeamsWindowTitleReaderTests: XCTestCase {
    private let suffix = " | Zenith | joris@example.com"

    private func window(pid: Int, number: Int, layer: Int = 0, name: String?) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowNumber as String: number,
            kCGWindowLayer as String: layer,
        ]
        if let name { info[kCGWindowName as String] = name }
        return info
    }

    func testWithoutScreenRecordingPermissionReturnsEmptyAndNeverListsWindows() {
        var listed = 0
        var pidsRead = 0
        let reader = CGTeamsWindowTitleReader(
            preflight: { false },
            teamsPIDs: { pidsRead += 1; return [100] },
            windowList: { listed += 1; return [self.window(pid: 100, number: 1, name: "Daily AI team" + self.suffix)] }
        )
        XCTAssertEqual(reader.teamsWindows(), [])
        XCTAssertEqual(listed, 0)
        XCTAssertEqual(pidsRead, 0)
    }

    func testNoTeamsProcessReturnsEmptyWithoutListingWindows() {
        var listed = 0
        let reader = CGTeamsWindowTitleReader(
            preflight: { true },
            teamsPIDs: { [] },
            windowList: { listed += 1; return [] }
        )
        XCTAssertEqual(reader.teamsWindows(), [])
        XCTAssertEqual(listed, 0)
    }

    func testKeepsTitledTeamsWindowsOnAnyLayer() {
        let reader = CGTeamsWindowTitleReader(
            preflight: { true },
            teamsPIDs: { [100] },
            windowList: {
                [
                    self.window(pid: 100, number: 10, name: "Chat | Marco Smit" + self.suffix),
                    self.window(pid: 100, number: 42, layer: 3, name: "Daily AI team" + self.suffix),
                    self.window(pid: 100, number: 50, layer: 19, name: "Sharing control bar" + self.suffix),
                    self.window(pid: 100, number: 51, name: ""),
                    self.window(pid: 100, number: 52, name: nil),
                    self.window(pid: 200, number: 60, name: "Daily AI team | other app"),
                    self.window(pid: 300, number: 61, name: "Teams WebView helper"),
                ]
            }
        )
        XCTAssertEqual(reader.teamsWindows(), [
            TeamsWindow(number: 10, title: "Chat | Marco Smit" + suffix),
            TeamsWindow(number: 42, title: "Daily AI team" + suffix),
            TeamsWindow(number: 50, title: "Sharing control bar" + suffix),
        ])
    }

    func testWhitespaceOnlyWindowNameIsIgnored() {
        let reader = CGTeamsWindowTitleReader(
            preflight: { true },
            teamsPIDs: { [100] },
            windowList: {
                [
                    self.window(pid: 100, number: 10, name: "   "),
                    self.window(pid: 100, number: 11, name: " \n\t "),
                    self.window(pid: 100, number: 42, name: "Daily AI team" + self.suffix),
                ]
            }
        )
        XCTAssertEqual(reader.teamsWindows(), [TeamsWindow(number: 42, title: "Daily AI team" + suffix)])
    }

    func testOwnerPIDAndWindowNumberAsInt32NSNumbersAreRead() {
        // The window server hands out CFNumbers of 32-bit ints.
        let reader = CGTeamsWindowTitleReader(
            preflight: { true },
            teamsPIDs: { [100] },
            windowList: {
                [
                    [
                        kCGWindowOwnerPID as String: NSNumber(value: Int32(100)),
                        kCGWindowNumber as String: NSNumber(value: Int32(42)),
                        kCGWindowLayer as String: NSNumber(value: Int32(0)),
                        kCGWindowName as String: "Daily AI team" + self.suffix,
                    ],
                    [
                        kCGWindowOwnerPID as String: NSNumber(value: Int32(200)),
                        kCGWindowNumber as String: NSNumber(value: Int32(43)),
                        kCGWindowName as String: "Other app" + self.suffix,
                    ],
                ]
            }
        )
        XCTAssertEqual(reader.teamsWindows(), [TeamsWindow(number: 42, title: "Daily AI team" + suffix)])
    }

    func testWindowsWithoutANumberAreSkipped() {
        let reader = CGTeamsWindowTitleReader(
            preflight: { true },
            teamsPIDs: { [100] },
            windowList: { [[kCGWindowOwnerPID as String: 100, kCGWindowName as String: "Daily AI team" + self.suffix]] }
        )
        XCTAssertEqual(reader.teamsWindows(), [])
    }

    func testTeamsBundleIDMatchesExactly() {
        XCTAssertTrue(CGTeamsWindowTitleReader.isTeamsBundleID("com.microsoft.teams2"))
        XCTAssertFalse(CGTeamsWindowTitleReader.isTeamsBundleID("com.microsoft.teams2.helper"))
        XCTAssertFalse(CGTeamsWindowTitleReader.isTeamsBundleID("com.microsoft.teams2.notificationcenter"))
        XCTAssertFalse(CGTeamsWindowTitleReader.isTeamsBundleID("com.microsoft.teams"))
        XCTAssertFalse(CGTeamsWindowTitleReader.isTeamsBundleID("COM.MICROSOFT.TEAMS2"))
        XCTAssertFalse(CGTeamsWindowTitleReader.isTeamsBundleID(nil))
    }
}
