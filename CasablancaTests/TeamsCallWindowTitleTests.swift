import CoreGraphics
import Foundation
import XCTest
@testable import Casablanca

// MARK: - Single title

/// Titles are the literal strings captured from new Teams on 2026-11-05 (spec,
/// "Evidence"), account email included, so a change in the parser is checked
/// against what Teams really shows.
final class TeamsCallWindowTitleParserTests: XCTestCase {
    private let suffix = " | Medicore | youri.broekhuizen@medicore.nl"

    func testMainWindowSectionTitlesAreNotCalls() {
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Chat | Judith Koetsier, Marco Spoor, Wouter Tengeler +1 | Medicore | youri.broekhuizen@medicore.nl"))
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Chat | Marco Spoor | Medicore | youri.broekhuizen@medicore.nl"))
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Calendar | Medicore | youri.broekhuizen@medicore.nl"))
    }

    func testMeetNowPreJoinAndInCall() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting join | Meeting with Youri Broekhuizen | Medicore | youri.broekhuizen@medicore.nl"),
            "Meeting with Youri Broekhuizen")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting with Youri Broekhuizen | Medicore | youri.broekhuizen@medicore.nl"),
            "Meeting with Youri Broekhuizen")
    }

    /// Captured 2026-11-05 while sharing in an external meeting: the shared-
    /// content pop-out wraps the meeting's name.
    func testSharedContentWindowNamesTheMeeting() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Shared content | Medicore/Prakikon/Levvel | Medicore | youri.broekhuizen@medicore.nl"),
            "Medicore/Prakikon/Levvel")
    }

    func testScheduledMeetingPreJoinAndInCall() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Meeting join | Daily AI team | Medicore | youri.broekhuizen@medicore.nl"),
            "Daily AI team")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Daily AI team | Medicore | youri.broekhuizen@medicore.nl"),
            "Daily AI team")
    }

    func testSharingControlBarIsNotACall() {
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Sharing control bar | Medicore | youri.broekhuizen@medicore.nl"))
    }

    func testExpectedOneToOneCallTitle() {
        XCTAssertEqual(TeamsCallWindowTitle.callName(fromWindowTitle: "Marco Spoor" + suffix), "Marco Spoor")
    }

    func testTitleWithoutEmailSuffixIsRejected() {
        // Not the known format: stay conservative rather than guess.
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Daily AI team | Medicore"))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Daily AI team"))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Microsoft Teams"))
    }

    func testCallNameContainingTheSeparatorIsRejoined() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting join | Sprint review | Team Link" + suffix),
            "Sprint review | Team Link")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Sprint review | Team Link" + suffix),
            "Sprint review | Team Link")
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
                fromWindowTitle: "  Meeting join |  | Daily AI team  | Medicore |  youri.broekhuizen@medicore.nl "),
            "Daily AI team")
    }

    func testPreJoinTokenAloneLeavesNothing() {
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting join" + suffix))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "Medicore | youri.broekhuizen@medicore.nl"))
        XCTAssertNil(TeamsCallWindowTitle.callName(fromWindowTitle: "youri.broekhuizen@medicore.nl"))
    }

    // MARK: Placeholders (Revision 2)

    func testExternalMeetingPreJoinPlaceholderIsNoName() {
        // Captured 2026-11-05 10:01 for ~8 s before the subject appeared.
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Meeting join | Microsoft Teams meeting | Medicore | youri.broekhuizen@medicore.nl"))
    }

    func testExternalMeetingInCallTitleIsTheSubject() {
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(
                fromWindowTitle: "Medicore/Prakikon/Levvel | Medicore | youri.broekhuizen@medicore.nl"),
            "Medicore/Prakikon/Levvel")
    }

    func testPoppedOutChatIsNoName() {
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Chat | Marco Spoor | Medicore | youri.broekhuizen@medicore.nl"))
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
            TeamsCallWindowTitle.callName(fromWindowTitle: "Meeting with Youri Broekhuizen" + suffix),
            "Meeting with Youri Broekhuizen")
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Teams meeting Link" + suffix), "Teams meeting Link")
        XCTAssertFalse(TeamsCallWindowTitle.isPlaceholderCallName("Vergadering Team Link"))
    }

    func testAnyPlaceholderComponentMeansNoName() {
        // An unknown pre-join token in front of a placeholder: the joined
        // name is not a placeholder, but one of its components is.
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Deelnemen aan vergadering | Microsoft Teams-vergadering | Medicore | youri.broekhuizen@medicore.nl"))
        XCTAssertNil(TeamsCallWindowTitle.callName(
            fromWindowTitle: "Some prefix | Microsoft Teams meeting | Medicore | x@y.nl"))
        XCTAssertEqual(
            TeamsCallWindowTitle.callName(fromWindowTitle: "Vergadering Team Link | Sprint 3" + suffix),
            "Vergadering Team Link | Sprint 3")
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
    private let suffix = " | Medicore | youri.broekhuizen@medicore.nl"

    func testEmptyListHasNoCallName() {
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: []), [])
    }

    func testOnlyMainWindowHasNoCallName() {
        let windows = [TeamsWindow(number: 10, title: "Chat | Marco Spoor" + suffix)]
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
            TeamsWindow(number: 10, title: "Chat | Marco Spoor" + suffix),
            TeamsWindow(number: 42, title: "Daily AI team" + suffix),
            TeamsWindow(number: 50, title: "Sharing control bar" + suffix),
            TeamsWindow(number: 51, title: "Daily AI team" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows), ["Daily AI team"])
    }

    func testNewestWindowWinsAmongDistinctNames() {
        let windows = [
            TeamsWindow(number: 77, title: "Daily AI team" + suffix),
            TeamsWindow(number: 30, title: "Marco Spoor" + suffix),
        ]
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows).first, "Daily AI team")
        XCTAssertEqual(TeamsCallWindowTitle.callNames(fromWindows: windows.reversed()).first, "Daily AI team",
                       "Order of the list does not matter; the window number decides")
    }

    func testEveryDistinctNameIsReturnedNewestWindowFirst() {
        let windows = [
            TeamsWindow(number: 30, title: "Marco Spoor" + suffix),
            TeamsWindow(number: 10, title: "Chat | Marco Spoor" + suffix),
            TeamsWindow(number: 77, title: "Daily AI team" + suffix),
            TeamsWindow(number: 51, title: "Partner sync" + suffix),
            TeamsWindow(number: 20, title: "Daily AI team" + suffix),
        ]
        XCTAssertEqual(
            TeamsCallWindowTitle.callNames(fromWindows: windows),
            ["Daily AI team", "Partner sync", "Marco Spoor"]
        )
        XCTAssertEqual(
            TeamsCallWindowTitle.callNames(fromWindows: windows.reversed()),
            ["Daily AI team", "Partner sync", "Marco Spoor"]
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
}

// MARK: - Reader

@MainActor
final class CGTeamsWindowTitleReaderTests: XCTestCase {
    private let suffix = " | Medicore | youri.broekhuizen@medicore.nl"

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
                    self.window(pid: 100, number: 10, name: "Chat | Marco Spoor" + self.suffix),
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
            TeamsWindow(number: 10, title: "Chat | Marco Spoor" + suffix),
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
