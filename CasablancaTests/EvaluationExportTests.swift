import XCTest
@testable import Casablanca

final class EvaluationExportTests: XCTestCase {

    private let meetingDate = Date(timeIntervalSince1970: 1_762_160_400) // 2025-11-03T09:00:00Z

    private func bareMeeting(title: String = "X") -> Meeting {
        Meeting(title: title, date: meetingDate)
    }

    private func json(_ meeting: Meeting, exportedAt: Date = Date(timeIntervalSince1970: 0)) throws -> [String: Any] {
        let document = EvaluationExport.document(for: meeting, exportedAt: exportedAt, appVersion: "0.20.0")
        let data = try EvaluationExport.encode(document)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func structuredItem(owner: String? = "Kim") -> ExtractedActionItem {
        ExtractedActionItem(
            task: "Offerte opvragen", owner: owner, due: "2026-11-07", dueIsExplicit: true,
            confidence: 0.9, quote: "ik vraag de offerte op", timestamp: "12:34",
            verified: .supported, verificationReason: nil
        )
    }

    // MARK: - Contract shape

    func testTopLevelKeysMatchContract() throws {
        let dict = try json(bareMeeting())
        XCTAssertEqual(Set(dict.keys), EvaluationExport.topLevelKeys)
        XCTAssertEqual(dict["schema"] as? String, "casablanca.eval-export")
        XCTAssertEqual(dict["schemaVersion"] as? Int, 1)
        XCTAssertEqual(dict["appVersion"] as? String, "0.20.0")
    }

    func testNestedKeysAreAlwaysPresent() throws {
        let dict = try json(bareMeeting())
        let meeting = try XCTUnwrap(dict["meeting"] as? [String: Any])
        XCTAssertEqual(Set(meeting.keys), ["id", "title", "date", "endDate", "durationSeconds", "language",
                                           "participants", "tags", "summaryTemplateID"])
        let transcript = try XCTUnwrap(dict["transcript"] as? [String: Any])
        XCTAssertEqual(Set(transcript.keys), ["text", "lines"])
        let summary = try XCTUnwrap(dict["summary"] as? [String: Any])
        XCTAssertEqual(Set(summary.keys), ["markdown", "decisions", "actionItemTexts"])
    }

    func testNilsAreEncodedAsNull() throws {
        let dict = try json(bareMeeting())
        let transcript = try XCTUnwrap(dict["transcript"] as? [String: Any])
        XCTAssertTrue(transcript["text"] is NSNull)
        XCTAssertEqual((transcript["lines"] as? [Any])?.count, 0)
        let summary = try XCTUnwrap(dict["summary"] as? [String: Any])
        XCTAssertTrue(summary["markdown"] is NSNull)
        XCTAssertEqual((summary["decisions"] as? [Any])?.count, 0)
        XCTAssertEqual((summary["actionItemTexts"] as? [Any])?.count, 0)
        let meeting = try XCTUnwrap(dict["meeting"] as? [String: Any])
        XCTAssertTrue(meeting["endDate"] is NSNull)
        XCTAssertTrue(meeting["durationSeconds"] is NSNull)
        XCTAssertTrue(meeting["summaryTemplateID"] is NSNull)
        XCTAssertEqual((dict["actionItems"] as? [Any])?.count, 0)
        XCTAssertEqual((dict["speakers"] as? [Any])?.count, 0)
        XCTAssertEqual((dict["decisions"] as? [Any])?.count, 0)
        XCTAssertEqual(dict["actionItemsSource"] as? String, "none")
    }

    func testNilActionItemFieldsAreEncodedAsNull() throws {
        let meeting = bareMeeting()
        meeting.actionItems = [ExtractedActionItem(
            task: "Planning bespreken", owner: nil, due: nil, dueIsExplicit: false, confidence: 0.5,
            quote: nil, timestamp: nil, verified: .unverified, verificationReason: nil
        )]
        let dict = try json(meeting)
        let items = try XCTUnwrap(dict["actionItems"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(Set(item.keys), ["task", "owner", "due", "dueIsExplicit", "confidence", "quote",
                                        "timestamp", "verified", "verificationReason"])
        XCTAssertTrue(item["owner"] is NSNull)
        XCTAssertTrue(item["due"] is NSNull)
        XCTAssertTrue(item["quote"] is NSNull)
        XCTAssertTrue(item["timestamp"] is NSNull)
        XCTAssertTrue(item["verificationReason"] is NSNull)
        XCTAssertEqual(item["verified"] as? String, "unverified")
    }

    func testNilLineSpeakerIsEncodedAsNull() throws {
        let meeting = bareMeeting()
        meeting.transcript = "[00:10] zonder spreker"
        let dict = try json(meeting)
        let transcript = try XCTUnwrap(dict["transcript"] as? [String: Any])
        let lines = try XCTUnwrap(transcript["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0]["speaker"] is NSNull)
        XCTAssertEqual(lines[0]["label"] as? String, "00:10")
        XCTAssertEqual(lines[0]["seconds"] as? Double, 10)
    }

    // MARK: - Action item source

    func testStructuredItemsWin() {
        let meeting = bareMeeting()
        meeting.actionItems = [structuredItem()]
        meeting.summary = "# S\n\n## Action Items\n- **Youri** — iets anders [01:00]\n"
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        XCTAssertEqual(document.actionItemsSource, .structured)
        XCTAssertEqual(document.actionItems.map(\.extractedActionItem), [structuredItem()])
        XCTAssertEqual(document.summary.actionItemTexts, ["**Youri** — iets anders [01:00]"])
    }

    /// R4: items stored on the meeting count as structured even when they came
    /// from Track B's markdown fallback (confidence 0.5, quote nil).
    func testStoredMarkdownFallbackItemsAreStructured() {
        let meeting = bareMeeting()
        let stored = ExtractedActionItem(
            task: "Notulen delen", owner: nil, due: nil, dueIsExplicit: false, confidence: 0.5,
            quote: nil, timestamp: nil, verified: .unverified, verificationReason: nil
        )
        meeting.actionItems = [stored]
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        XCTAssertEqual(document.actionItemsSource, .structured)
        XCTAssertEqual(document.actionItems.map(\.extractedActionItem), [stored])
    }

    func testOldMeetingFallsBackToSummaryMarkdown() {
        let meeting = bareMeeting()
        meeting.summary = "# S\n\n## Actiepunten\n- **Kim** — offerte opvragen [12:34]\n- **?** — notulen delen\n"
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        XCTAssertEqual(document.actionItemsSource, .summaryMarkdown)
        let items = document.actionItems.map(\.extractedActionItem)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].task, "offerte opvragen")
        XCTAssertEqual(items[0].owner, "Kim")
        XCTAssertEqual(items[0].timestamp, "12:34")
        XCTAssertEqual(items[1].task, "notulen delen")
        XCTAssertNil(items[1].owner)
        XCTAssertNil(items[1].timestamp)
        for item in items {
            XCTAssertEqual(item.verified, .unverified)
            XCTAssertEqual(item.confidence, 0)
            XCTAssertNil(item.due)
            XCTAssertFalse(item.dueIsExplicit)
            XCTAssertNil(item.quote)
            XCTAssertNil(item.verificationReason)
        }
    }

    /// R5: Track B renders `**owner** — task (yyyy-MM-dd) [mm:ss]`.
    func testFallbackStripsTrackBDueDateAndTimestamp() {
        let items = EvaluationExport.fallbackActionItems(fromSummary:
            "## Action Items\n- **Kim** — offerte opvragen (2026-11-07) [12:34]\n- **Youri** — spec sturen (2026-11-12)\n- **Kim** — lang overleg [1:02:03]\n"
        )
        XCTAssertEqual(items.map(\.task), ["offerte opvragen", "spec sturen", "lang overleg"])
        XCTAssertEqual(items.map(\.timestamp), ["12:34", nil, "1:02:03"])
        XCTAssertEqual(items.map(\.owner), ["Kim", "Youri", "Kim"])
        XCTAssertEqual(items.map(\.due), [nil, nil, nil])
    }

    func testFallbackKeepsTextInsideTask() {
        let items = EvaluationExport.fallbackActionItems(fromSummary:
            "## Action Items\n- **Kim** — punt [12:34] bespreken\n"
        )
        XCTAssertEqual(items.map(\.task), ["punt [12:34] bespreken"])
        XCTAssertEqual(items.map(\.timestamp), [nil])
    }

    func testFallbackSkipsBulletsThatAreOnlyATimestamp() {
        let items = EvaluationExport.fallbackActionItems(fromSummary: "## Action Items\n- **Kim** — [12:34]\n")
        XCTAssertEqual(items, [])
    }

    func testNoItemsAnywhereIsNone() {
        let meeting = bareMeeting()
        meeting.summary = "# S\n\nKort overleg.\n\n## Besluiten\n- Niets\n"
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        XCTAssertEqual(document.actionItemsSource, .none)
        XCTAssertEqual(document.actionItems, [])
    }

    // MARK: - Decisions

    func testDecisionsFromSummary() {
        let meeting = bareMeeting()
        meeting.summary = "# S\n\n## Besluiten\n- Door met v2\n"
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        XCTAssertEqual(document.decisions, [EvaluationExport.DecisionInfo(text: "Door met v2", source: "summaryMarkdown")])
        XCTAssertEqual(document.summary.decisions, ["Door met v2"])
        XCTAssertEqual(document.summary.markdown, meeting.summary)
    }

    // MARK: - Transcript

    func testTranscriptLinesUseKnownSpeakers() {
        let meeting = bareMeeting()
        meeting.speakers = [SpeakerInfo(id: "me", displayName: "Youri", source: .microphone, isUser: true, nameConfirmed: true)]
        let text = "[00:10] Youri: ja\n[00:12] Agenda: punt 1\nzonder label"
        meeting.transcript = text
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        let lines = document.transcript.lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].speaker, "Youri")
        XCTAssertEqual(lines[0].text, "ja")
        XCTAssertEqual(lines[0].label, "00:10")
        XCTAssertEqual(lines[0].seconds, 10)
        XCTAssertNil(lines[1].speaker)
        XCTAssertEqual(lines[1].text, "Agenda: punt 1")
        XCTAssertEqual(document.transcript.text, text)
        XCTAssertEqual(document.speakers.map(\.id), ["me"])
    }

    func testCRLFTranscriptLinesAreParsed() {
        let meeting = bareMeeting()
        meeting.transcript = "[00:10] een\r\n[00:12] twee\r\n"
        let document = EvaluationExport.document(for: meeting, exportedAt: .now, appVersion: "1")
        XCTAssertEqual(document.transcript.lines.map(\.text), ["een", "twee"])
    }

    // MARK: - Meeting info

    func testMeetingInfoFields() throws {
        let meeting = Meeting(title: "Refinement", date: meetingDate, endDate: meetingDate.addingTimeInterval(3600),
                              participants: ["Youri", "Kim"])
        meeting.recordingDuration = 3540
        meeting.transcriptionLanguage = "nl-NL"
        meeting.tags = ["link"]
        meeting.summaryTemplateID = "refinement"
        let dict = try json(meeting)
        let info = try XCTUnwrap(dict["meeting"] as? [String: Any])
        XCTAssertEqual(info["id"] as? String, meeting.id.uuidString)
        XCTAssertEqual(info["title"] as? String, "Refinement")
        XCTAssertEqual(info["date"] as? String, "2025-11-03T09:00:00Z")
        XCTAssertEqual(info["endDate"] as? String, "2025-11-03T10:00:00Z")
        XCTAssertEqual(info["durationSeconds"] as? Double, 3540)
        XCTAssertEqual(info["language"] as? String, "nl-NL")
        XCTAssertEqual(info["participants"] as? [String], ["Youri", "Kim"])
        XCTAssertEqual(info["tags"] as? [String], ["link"])
        XCTAssertEqual(info["summaryTemplateID"] as? String, "refinement")
    }

    // MARK: - Encoding

    func testDatesAreISO8601UTC() throws {
        let document = EvaluationExport.document(for: bareMeeting(), exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1")
        let string = try XCTUnwrap(String(data: EvaluationExport.encode(document), encoding: .utf8))
        XCTAssertTrue(string.contains(#""exportedAt" : "1970-01-01T00:00:00Z""#), string)
    }

    func testSlashesAreNotEscaped() throws {
        let document = EvaluationExport.document(for: bareMeeting(title: "Bila: Martijn/Youri"), exportedAt: .now, appVersion: "1")
        let string = try XCTUnwrap(String(data: EvaluationExport.encode(document), encoding: .utf8))
        XCTAssertTrue(string.contains("Martijn/Youri"), string)
    }

    func testRoundTrip() throws {
        let meeting = bareMeeting()
        meeting.actionItems = [structuredItem(owner: nil)]
        meeting.transcript = "[00:10] ja"
        meeting.summary = "## Besluiten\n- Door\n"
        let document = EvaluationExport.document(for: meeting, exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1")
        let data = try EvaluationExport.encode(document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EvaluationExport.Document.self, from: data)
        XCTAssertEqual(decoded, document)
    }

    // MARK: - File name

    func testSuggestedFileName() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 3; components.hour = 12
        let date = Calendar.current.date(from: components)!
        let meeting = Meeting(title: "Bila: Martijn/Youri", date: date)
        let name = EvaluationExport.suggestedFileName(for: meeting)
        XCTAssertTrue(name.hasSuffix(".eval.json"), name)
        XCTAssertTrue(name.hasPrefix("2026-11-03 "), name)
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertFalse(name.contains(":"), name)
    }

    // MARK: - Menu enablement

    func testCanExportRequiresTranscriptOrSummary() {
        XCTAssertFalse(EvaluationExport.canExport(nil))
        XCTAssertFalse(EvaluationExport.canExport(bareMeeting()))

        let withTranscript = bareMeeting()
        withTranscript.transcript = "[00:01] a"
        XCTAssertTrue(EvaluationExport.canExport(withTranscript))

        let summaryOnly = bareMeeting()
        summaryOnly.summary = "## Summary\nShort."
        XCTAssertTrue(EvaluationExport.canExport(summaryOnly))

        let whitespaceTranscript = bareMeeting()
        whitespaceTranscript.transcript = "  \n\t "
        XCTAssertFalse(EvaluationExport.canExport(whitespaceTranscript))
    }
}
