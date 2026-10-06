import Foundation
import XCTest
@testable import Casablanca

/// Parser/serializer tests for the per-bucket action-card body structs.
/// For each bucket: happy-path parse, round-trip (parse → serialize → parse),
/// and malformed input → nil.
final class ActionCardBodyTests: XCTestCase {

    // MARK: - PartnerApiReplyBody

    func testPartnerApiReplyHappyPath() {
        let body = """
        To: l.geijsen@praktikon.nl
        Cc: kim@medicore.nl, arriejanne@medicore.nl
        Subject: API access to the MINT API

        Hi Lisanne,

        Here is the OpenAPI spec you requested.

        Kind regards,
        Youri
        """
        let parsed = PartnerApiReplyBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.to, "l.geijsen@praktikon.nl")
        XCTAssertEqual(parsed?.cc, ["kim@medicore.nl", "arriejanne@medicore.nl"])
        XCTAssertEqual(parsed?.subject, "API access to the MINT API")
        XCTAssertEqual(
            parsed?.bodyText,
            "Hi Lisanne,\n\nHere is the OpenAPI spec you requested.\n\nKind regards,\nYouri"
        )
    }

    func testPartnerApiReplyRoundTrip() {
        let body = """
        To: l.geijsen@praktikon.nl
        Cc: kim@medicore.nl
        Subject: API access

        Hi there.

        Bye.
        """
        let parsed = PartnerApiReplyBody(parsing: body)!
        let reparsed = PartnerApiReplyBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testPartnerApiReplyRoundTripNoCc() {
        let body = """
        To: x@y.nl
        Subject: Hello

        Body line.
        """
        let parsed = PartnerApiReplyBody(parsing: body)!
        XCTAssertTrue(parsed.cc.isEmpty)
        let reparsed = PartnerApiReplyBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testPartnerApiReplyCRLFRoundTrip() {
        // Realistic Outlook/Teams-origin body with CRLF separators.
        let lf = """
        To: l.geijsen@praktikon.nl
        Cc: kim@medicore.nl, arriejanne@medicore.nl
        Subject: API access to the MINT API

        Hi Lisanne,

        Here is the OpenAPI spec you requested.

        Kind regards,
        Youri
        """
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let fromLF = PartnerApiReplyBody(parsing: lf)
        let fromCRLF = PartnerApiReplyBody(parsing: crlf)
        XCTAssertNotNil(fromCRLF)
        XCTAssertEqual(fromCRLF, fromLF)
        // No stray carriage returns survive into parsed values.
        XCTAssertFalse(fromCRLF?.bodyText.contains("\r") ?? true)
        XCTAssertEqual(fromCRLF?.subject, "API access to the MINT API")
    }

    func testPartnerApiReplyMalformed() {
        // Missing Subject.
        XCTAssertNil(PartnerApiReplyBody(parsing: "To: a@b.nl\n\nBody"))
        // Missing To.
        XCTAssertNil(PartnerApiReplyBody(parsing: "Subject: Hi\n\nBody"))
        XCTAssertNil(PartnerApiReplyBody(parsing: ""))
    }

    // MARK: - TicketDraftBody

    func testTicketDraftHappyPath() {
        let body = """
        Project: IO
        Issue type: Bug
        Summary: BgZ exchange fails on empty payload
        Priority: High
        Labels: wegiz, bgz
        Components: Integration, API
        Fix version: 2026.4
        Epic link: IO-6000
        Assignee: youri
        Custom fields:
          - Release notes radio: Yes-External
          - Severity: Critical

        ---DESCRIPTION---
        h2. Environment
        Version: 2026.3
        """
        let parsed = TicketDraftBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.project, "IO")
        XCTAssertEqual(parsed?.issueType, "Bug")
        XCTAssertEqual(parsed?.summary, "BgZ exchange fails on empty payload")
        XCTAssertEqual(parsed?.priority, "High")
        XCTAssertEqual(parsed?.labels, ["wegiz", "bgz"])
        XCTAssertEqual(parsed?.components, ["Integration", "API"])
        XCTAssertEqual(parsed?.fixVersion, "2026.4")
        XCTAssertEqual(parsed?.epicLink, "IO-6000")
        XCTAssertEqual(parsed?.assignee, "youri")
        XCTAssertEqual(parsed?.customFields, [
            .init(name: "Release notes radio", value: "Yes-External"),
            .init(name: "Severity", value: "Critical"),
        ])
        XCTAssertEqual(parsed?.description, "h2. Environment\nVersion: 2026.3")
    }

    func testTicketDraftRoundTrip() {
        let body = """
        Project: MCINT
        Issue type: Story
        Summary: Orchestra migration step
        Priority: Medium
        Labels: orchestra
        Custom fields:
          - Release notes radio: No

        ---DESCRIPTION---
        As a PO I want migration.
        """
        let parsed = TicketDraftBody(parsing: body)!
        let reparsed = TicketDraftBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testTicketDraftNoDescriptionDelimiter() {
        let body = """
        Project: IO
        Issue type: Task
        Summary: Just a task
        """
        let parsed = TicketDraftBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.description, "")
        XCTAssertTrue(parsed?.customFields.isEmpty ?? false)
    }

    func testTicketDraftSlimParse() {
        let body = """
        Project: IO
        Summary: Tracking story for promised feature
        Description: We promised this in Q3.
        """
        // Strict parse fails (no Issue type); slim parse succeeds.
        XCTAssertNil(TicketDraftBody(parsing: body))
        let slim = TicketDraftBody(parsingSlim: body)
        XCTAssertNotNil(slim)
        XCTAssertEqual(slim?.project, "IO")
        XCTAssertEqual(slim?.summary, "Tracking story for promised feature")
        XCTAssertEqual(slim?.description, "We promised this in Q3.")
    }

    func testTicketDraftCRLFRoundTrip() {
        // Realistic body with the ---DESCRIPTION--- delimiter and CRLF endings.
        let lf = """
        Project: IO
        Issue type: Bug
        Summary: BgZ exchange fails on empty payload
        Priority: High
        Labels: wegiz, bgz
        Components: Integration, API
        Custom fields:
          - Release notes radio: Yes-External
          - Severity: Critical

        ---DESCRIPTION---
        h2. Environment
        Version: 2026.3
        """
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let fromLF = TicketDraftBody(parsing: lf)
        let fromCRLF = TicketDraftBody(parsing: crlf)
        XCTAssertNotNil(fromCRLF)
        XCTAssertEqual(fromCRLF, fromLF)
        XCTAssertFalse(fromCRLF?.description.contains("\r") ?? true)
        XCTAssertEqual(fromCRLF?.labels, ["wegiz", "bgz"])
        XCTAssertEqual(fromCRLF?.customFields, [
            .init(name: "Release notes radio", value: "Yes-External"),
            .init(name: "Severity", value: "Critical"),
        ])
        XCTAssertEqual(fromCRLF?.description, "h2. Environment\nVersion: 2026.3")
    }

    func testTicketDraftMalformed() {
        // Missing Summary.
        XCTAssertNil(TicketDraftBody(parsing: "Project: IO\nIssue type: Bug"))
        // Missing Project.
        XCTAssertNil(TicketDraftBody(parsing: "Issue type: Bug\nSummary: x"))
        XCTAssertNil(TicketDraftBody(parsing: ""))
    }

    // MARK: - TopdeskResponseBody

    func testTopdeskResponseHappyPath() {
        let body = """
        MC-ref: MC2604 0291
        Customer: Praktikon
        Caller: Lisanne Geijsen <l.geijsen@praktikon.nl>
        Visibility: internal-only
        Add Jira link: IO-6201

        ---RESPONSE---
        Beste Lisanne,

        Bedankt voor je melding.
        """
        let parsed = TopdeskResponseBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.mcRef, "MC2604 0291")
        XCTAssertEqual(parsed?.customer, "Praktikon")
        XCTAssertEqual(parsed?.caller, "Lisanne Geijsen <l.geijsen@praktikon.nl>")
        XCTAssertEqual(parsed?.visibility, .internalOnly)
        XCTAssertEqual(parsed?.addJiraLink, "IO-6201")
        XCTAssertEqual(parsed?.response, "Beste Lisanne,\n\nBedankt voor je melding.")
    }

    func testTopdeskResponseNoneJiraLinkAndVisibilityParse() {
        let body = """
        MC-ref: MC2604 0292
        Customer: Foo
        Visibility: visible-to-caller
        Add Jira link: none

        ---RESPONSE---
        Hallo.
        """
        let parsed = TopdeskResponseBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.addJiraLink, "\"none\" must parse to nil")
        XCTAssertEqual(parsed?.visibility, .visibleToCaller)
    }

    func testTopdeskResponseUnknownVisibilityDefaults() {
        let body = """
        MC-ref: MC1 1
        Customer: Bar
        Visibility: somethingelse

        ---RESPONSE---
        x
        """
        XCTAssertEqual(TopdeskResponseBody(parsing: body)?.visibility, .visibleToCaller)
    }

    func testTopdeskResponseRoundTrip() {
        let body = """
        MC-ref: MC2604 0291
        Customer: Praktikon
        Caller: Lisanne
        Visibility: internal-only
        Add Jira link: IO-6201

        ---RESPONSE---
        Beste Lisanne,

        Groet.
        """
        let parsed = TopdeskResponseBody(parsing: body)!
        let reparsed = TopdeskResponseBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testTopdeskResponseMalformed() {
        XCTAssertNil(TopdeskResponseBody(parsing: "MC-ref: MC1 1\n\n---RESPONSE---\nx"))
        XCTAssertNil(TopdeskResponseBody(parsing: "Customer: Foo\n\n---RESPONSE---\nx"))
        XCTAssertNil(TopdeskResponseBody(parsing: ""))
    }

    // MARK: - RefinementPrepBody

    func testRefinementPrepHappyPath() {
        let body = """
        Story: IO-6201 — BgZ producer endpoint
        Current radio: Unknown
        Proposed radio: Yes-External
        Current priority: Undefined
        Proposed priority: High
        Heuristic: V3 endpoint default Yes-External
        Confidence: high
        Estimation: missing
        AC gaps: Error handling, Logging
        Open comments: 2 @martijn @jeroen
        """
        let parsed = RefinementPrepBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.storyKey, "IO-6201")
        XCTAssertEqual(parsed?.storyTitle, "BgZ producer endpoint")
        XCTAssertEqual(parsed?.currentRadio, "Unknown")
        XCTAssertEqual(parsed?.proposedRadio, "Yes-External")
        XCTAssertEqual(parsed?.currentPriority, "Undefined")
        XCTAssertEqual(parsed?.proposedPriority, "High")
        XCTAssertEqual(parsed?.heuristic, "V3 endpoint default Yes-External")
        XCTAssertEqual(parsed?.confidence, "high")
        XCTAssertEqual(parsed?.estimation, "missing")
        XCTAssertEqual(parsed?.acGaps, ["Error handling", "Logging"])
        XCTAssertEqual(parsed?.openComments, "2 @martijn @jeroen")
    }

    func testRefinementPrepHyphenSeparatorAndNoneGaps() {
        let body = """
        Story: IO-7000 - Plain hyphen title
        Proposed radio: No
        AC gaps: none
        """
        let parsed = RefinementPrepBody(parsing: body)
        XCTAssertEqual(parsed?.storyKey, "IO-7000")
        XCTAssertEqual(parsed?.storyTitle, "Plain hyphen title")
        XCTAssertTrue(parsed?.acGaps.isEmpty ?? false)
    }

    func testRefinementPrepRoundTrip() {
        let body = """
        Story: IO-6201 — BgZ producer endpoint
        Current radio: Unknown
        Proposed radio: Yes-External
        Current priority: Undefined
        Proposed priority: High
        Heuristic: rule X
        Confidence: high
        Estimation: 5
        AC gaps: Logging
        Open comments: 0
        """
        let parsed = RefinementPrepBody(parsing: body)!
        let reparsed = RefinementPrepBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testRefinementPrepMalformed() {
        // Missing Proposed radio.
        XCTAssertNil(RefinementPrepBody(parsing: "Story: IO-1 — x"))
        // Missing Story.
        XCTAssertNil(RefinementPrepBody(parsing: "Proposed radio: No"))
        XCTAssertNil(RefinementPrepBody(parsing: ""))
    }

    // MARK: - RoadmapCommitmentBody

    func testRoadmapCommitmentHappyPathWithNestedTicket() {
        let body = """
        Asker: Marcel van den Berg
        Topic: When will BgZ consumer be ready
        Promised timeline: release 2026.4
        Source: Teams 1:1 — https://teams.microsoft.com/l/message/19:abc/167

        ---TICKET---
        Project: IO
        Summary: BgZ consumer roadmap commitment
        Description: Promised to Marcel for 2026.4.
        """
        let parsed = RoadmapCommitmentBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.asker, "Marcel van den Berg")
        XCTAssertEqual(parsed?.topic, "When will BgZ consumer be ready")
        XCTAssertEqual(parsed?.promisedTimeline, "release 2026.4")
        XCTAssertEqual(parsed?.permalink, "https://teams.microsoft.com/l/message/19:abc/167")
        XCTAssertNotNil(parsed?.ticket)
        XCTAssertEqual(parsed?.ticket?.project, "IO")
        XCTAssertEqual(parsed?.ticket?.summary, "BgZ consumer roadmap commitment")
        XCTAssertEqual(parsed?.ticket?.description, "Promised to Marcel for 2026.4.")
    }

    func testRoadmapCommitmentRoundTrip() {
        let body = """
        Asker: Marcel
        Topic: Timeline question
        Promised timeline: Q3 2026
        Source: Teams 1:1 — https://teams.microsoft.com/l/message/19:abc/167

        ---TICKET---
        Project: IO
        Summary: Roadmap commitment
        Description: Promised for Q3.
        """
        let parsed = RoadmapCommitmentBody(parsing: body)!
        let reparsed = RoadmapCommitmentBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testRoadmapCommitmentRichNestedTicketRoundTrip() {
        // A nested ticket carrying rich fields (issue type, labels, a custom
        // field) must survive serialize → parse via the slim parser.
        let ticket = TicketDraftBody(
            project: "IO",
            issueType: "Story",
            summary: "BgZ consumer roadmap commitment",
            labels: ["wegiz", "roadmap"],
            customFields: [.init(name: "Release notes radio", value: "Yes-External")],
            description: "Promised to Marcel for 2026.4."
        )
        let original = RoadmapCommitmentBody(
            asker: "Marcel van den Berg",
            topic: "When will BgZ consumer be ready",
            promisedTimeline: "release 2026.4",
            sourceLine: "Teams 1:1 — https://teams.microsoft.com/l/message/19:abc/167",
            permalink: "https://teams.microsoft.com/l/message/19:abc/167",
            ticket: ticket
        )
        let reparsed = RoadmapCommitmentBody(parsing: original.serialized())
        XCTAssertEqual(reparsed, original)
        // Specifically verify the rich nested fields were not dropped.
        XCTAssertEqual(reparsed?.ticket?.issueType, "Story")
        XCTAssertEqual(reparsed?.ticket?.labels, ["wegiz", "roadmap"])
        XCTAssertEqual(reparsed?.ticket?.customFields, [
            .init(name: "Release notes radio", value: "Yes-External"),
        ])
    }

    func testRoadmapCommitmentMalformed() {
        // Missing Promised timeline.
        XCTAssertNil(RoadmapCommitmentBody(parsing: "Asker: Marcel\nTopic: x"))
        // Missing Asker.
        XCTAssertNil(RoadmapCommitmentBody(parsing: "Promised timeline: Q3 2026"))
        XCTAssertNil(RoadmapCommitmentBody(parsing: ""))
    }

    // MARK: - CalendarEventBody

    func testCalendarEventHappyPath() {
        let body = """
        Subject: Bilateral — Marcel
        When: 2026-06-20 14:00–14:30 (CEST)
        Duration: 30
        Invitees: youri.broekhuizen@medicore.nl, marcel@medicore.nl
        Location: Microsoft Teams Meeting
        Agenda: Career discussion and roadmap.
        """
        let parsed = CalendarEventBody(parsing: body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.subject, "Bilateral — Marcel")
        XCTAssertEqual(parsed?.whenRaw, "2026-06-20 14:00–14:30 (CEST)")
        XCTAssertEqual(parsed?.duration, 30)
        XCTAssertEqual(parsed?.invitees, ["youri.broekhuizen@medicore.nl", "marcel@medicore.nl"])
        XCTAssertEqual(parsed?.location, "Microsoft Teams Meeting")
        XCTAssertEqual(parsed?.agenda, "Career discussion and roadmap.")
        XCTAssertEqual(parsed?.dateText, "2026-06-20")
        XCTAssertEqual(parsed?.timeRange, "14:00–14:30")
    }

    func testCalendarEventRoundTrip() {
        let body = """
        Subject: Refinement
        When: 2026-06-21 10:00–11:00 (CEST)
        Duration: 60
        Invitees: a@b.nl, c@d.nl
        Location: Room 1
        Agenda: Story refinement.
        """
        let parsed = CalendarEventBody(parsing: body)!
        let reparsed = CalendarEventBody(parsing: parsed.serialized())
        XCTAssertEqual(reparsed, parsed)
    }

    func testCalendarEventMalformed() {
        // Missing When.
        XCTAssertNil(CalendarEventBody(parsing: "Subject: x\nDuration: 30"))
        // Missing Subject.
        XCTAssertNil(CalendarEventBody(parsing: "When: 2026-06-20 14:00–14:30 (CEST)"))
        XCTAssertNil(CalendarEventBody(parsing: ""))
    }
}
