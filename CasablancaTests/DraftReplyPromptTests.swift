import SwiftData
import XCTest
@testable import Casablanca

final class DraftReplyPromptTests: XCTestCase {

    // MARK: - Initial prompt

    func testInitialPromptWithSourceAndMeeting() {
        let context = DraftReplyContext(
            todoText: "Send Kim the BgZ spec",
            owner: "Youri",
            dueDate: nil,
            sourceRef: "jira:IO-1234",
            meetingTitle: "Wegiz BgZ refinement",
            meetingDate: nil,
            meetingSummary: "We agreed to share the BgZ spec with partners.",
            transcriptExcerpt: "[12:00] Kim: can you send me the spec?"
        )

        let prompt = DraftReplyPrompt.initial(context)

        XCTAssertTrue(prompt.contains("Send Kim the BgZ spec"))
        XCTAssertTrue(prompt.contains("jira:IO-1234"))
        XCTAssertTrue(prompt.contains("Fetch the source"), prompt)
        XCTAssertTrue(prompt.contains("Wegiz BgZ refinement"))
        XCTAssertTrue(prompt.contains("We agreed to share the BgZ spec with partners."))
        XCTAssertTrue(prompt.contains("[12:00] Kim: can you send me the spec?"))
        XCTAssertTrue(prompt.contains("Do not send"))
        XCTAssertTrue(prompt.contains("language of the source"))
        XCTAssertTrue(prompt.contains("Channel:"))
    }

    func testInitialPromptWithoutMeetingOrSource() {
        let context = DraftReplyContext(
            todoText: "Reply to Kim",
            owner: nil,
            dueDate: nil,
            sourceRef: nil,
            meetingTitle: nil,
            meetingDate: nil,
            meetingSummary: nil,
            transcriptExcerpt: nil
        )

        let prompt = DraftReplyPrompt.initial(context)

        XCTAssertTrue(prompt.contains("Reply to Kim"))
        XCTAssertFalse(prompt.contains("## Meeting"), prompt)
        XCTAssertFalse(prompt.contains("Fetch the source"), prompt)
        XCTAssertTrue(prompt.contains("Do not send"))
    }

    /// No Topdesk tool is reachable from the draft run, so the prompt must not
    /// send the model hunting for one.
    func testTopdeskSourceIsContextOnly() {
        let context = DraftReplyContext(
            todoText: "Answer the customer",
            owner: nil, dueDate: nil,
            sourceRef: "topdesk:MC2604 0291",
            meetingTitle: nil, meetingDate: nil, meetingSummary: nil, transcriptExcerpt: nil
        )

        let prompt = DraftReplyPrompt.initial(context)

        XCTAssertTrue(prompt.contains("topdesk:MC2604 0291"))
        XCTAssertFalse(prompt.contains("Fetch the source"), prompt)
    }

    // MARK: - Revision prompt

    func testRevisionPromptCarriesDraftAndSteer() {
        let context = DraftReplyContext(
            todoText: "Reply to Kim",
            owner: nil, dueDate: nil,
            sourceRef: "jira:IO-1234",
            meetingTitle: nil, meetingDate: nil, meetingSummary: nil, transcriptExcerpt: nil
        )

        let prompt = DraftReplyPrompt.revision(
            draft: "Channel: email\n\nHoi Kim, hierbij de spec.",
            steer: "shorter, more formal",
            context: context
        )

        XCTAssertTrue(prompt.contains("Hoi Kim, hierbij de spec."))
        XCTAssertTrue(prompt.contains("shorter, more formal"))
        XCTAssertTrue(prompt.contains("Reply to Kim"))
        XCTAssertTrue(prompt.contains("Channel:"))
        XCTAssertTrue(prompt.contains("Do not send"))
    }

    // MARK: - Context from a to-do

    @MainActor
    func testContextCopiesTodoAndMeetingFields() throws {
        let (container, todo) = try Self.makeTodo(transcript: "[00:10] Kim: hoi")
        _ = container
        todo.owner = "Youri"
        todo.sourceRef = "teams:19:abc"
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        todo.dueDate = due

        let context = DraftReplyContext(todo: todo)

        XCTAssertEqual(context.todoText, "Send the spec")
        XCTAssertEqual(context.owner, "Youri")
        XCTAssertEqual(context.dueDate, due)
        XCTAssertEqual(context.sourceRef, "teams:19:abc")
        XCTAssertEqual(context.meetingTitle, "Refinement")
        XCTAssertEqual(context.meetingSummary, "Summary text")
        XCTAssertEqual(context.transcriptExcerpt, "[00:10] Kim: hoi")
    }

    @MainActor
    func testTranscriptWindowCentersOnTimestamp() throws {
        let half = String(repeating: "a", count: 200_000)
        let transcript = half + "[45:00] Kim: the key line" + half
        let (container, todo) = try Self.makeTodo(transcript: transcript)
        _ = container
        todo.sourceTimestamp = "45:00"

        let excerpt = try XCTUnwrap(DraftReplyContext(todo: todo).transcriptExcerpt)

        XCTAssertEqual(excerpt.count, 60_000)
        XCTAssertTrue(excerpt.contains("[45:00]"))
    }

    /// `5:00` must not match inside `[45:00]`: the label is searched with its brackets.
    @MainActor
    func testTranscriptWindowFallsBackToTheStartWithoutAMatch() throws {
        let transcript = String(repeating: "b", count: 200_000) + "[45:00] x" + String(repeating: "c", count: 200_000)
        let (container, todo) = try Self.makeTodo(transcript: transcript)
        _ = container
        todo.sourceTimestamp = "5:00"

        let excerpt = try XCTUnwrap(DraftReplyContext(todo: todo).transcriptExcerpt)

        XCTAssertEqual(excerpt, String(repeating: "b", count: 60_000))
    }

    func testShortTranscriptIsKeptWhole() {
        let transcript = String(repeating: "x", count: 300_000)
        XCTAssertEqual(DraftReplyContext.transcriptExcerpt(transcript, around: "45:00"), transcript)
    }

    // MARK: - Fixtures

    /// An in-memory store, so the to-do/meeting relationship behaves as in the app.
    /// The container is returned so it outlives the models.
    @MainActor
    private static func makeTodo(transcript: String) throws -> (ModelContainer, TodoItem) {
        let schema = Schema([Meeting.self, TodoItem.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let meeting = Meeting(title: "Refinement", date: Date())
        meeting.summary = "Summary text"
        meeting.transcript = transcript
        container.mainContext.insert(meeting)
        let todo = TodoItem(text: "Send the spec", meeting: meeting)
        container.mainContext.insert(todo)
        return (container, todo)
    }
}
