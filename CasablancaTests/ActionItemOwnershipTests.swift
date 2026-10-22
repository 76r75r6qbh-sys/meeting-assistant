import XCTest
@testable import Casablanca

final class ActionItemOwnershipTests: XCTestCase {
    private let aliases = ["Youri Broekhuizen", "Youri"]

    private func todos(_ items: [String], includeUnassigned: Bool = false, existing: Set<String> = []) -> [String] {
        ActionItemOwnership.todoTexts(
            from: items,
            aliases: aliases,
            includeUnassigned: includeUnassigned,
            existing: existing
        )
    }

    private func makeDefaults(suite: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Parsing

    func testParseSplitsOwnerAndAction() {
        let parsed = ActionItemOwnership.parse("**Youri** \u{2014} Send the spec to QA")
        XCTAssertEqual(parsed, .init(owner: "Youri", action: "Send the spec to QA"))
    }

    func testParseAcceptsColonInsideBold() {
        let parsed = ActionItemOwnership.parse("**Youri:** Send the spec")
        XCTAssertEqual(parsed, .init(owner: "Youri", action: "Send the spec"))
    }

    func testParseTreatsQuestionMarkOwnerAsUnassigned() {
        let parsed = ActionItemOwnership.parse("**?** \u{2014} Book a room")
        XCTAssertEqual(parsed, .init(owner: nil, action: "Book a room"))
    }

    func testParseTreatsLineWithoutOwnerFormatAsUnassigned() {
        let parsed = ActionItemOwnership.parse("Send the spec to QA")
        XCTAssertEqual(parsed, .init(owner: nil, action: "Send the spec to QA"))
    }

    func testParseTreatsBoldEmphasisWithoutSeparatorAsUnassigned() {
        let parsed = ActionItemOwnership.parse("**Urgent** send the spec")
        XCTAssertEqual(parsed, .init(owner: nil, action: "**Urgent** send the spec"))
    }

    // MARK: - Matching

    func testSingleOwnerMatch() {
        XCTAssertEqual(todos(["**Youri** \u{2014} Draft the roadmap"]), ["Draft the roadmap"])
    }

    func testAliasMatchesLongerOwnerName() {
        XCTAssertEqual(todos(["**Youri B.** \u{2014} Draft A", "**Youri Broekhuizen** \u{2014} Draft B"]),
                       ["Draft A", "Draft B"])
    }

    func testCaseAndDiacriticsInsensitive() {
        let result = ActionItemOwnership.todoTexts(
            from: ["**ANDRÉ** \u{2014} Fix the build", "**Zoë** \u{2014} Review"],
            aliases: ["andre", "Zoe"],
            includeUnassigned: false
        )
        XCTAssertEqual(result, ["Fix the build", "Review"])
    }

    func testWholeWordOnly() {
        XCTAssertEqual(todos(["**Yourin** \u{2014} Not mine"]), [])
    }

    func testMultipleOwnersMatchWhenAnyIsMine() {
        let items = [
            "**Youri & Kim** \u{2014} A",
            "**Kim, Youri** \u{2014} B",
            "**Youri en Kim** \u{2014} C",
            "**Kim/Youri** \u{2014} D",
        ]
        XCTAssertEqual(todos(items), ["A", "B", "C", "D"])
    }

    func testOtherOwnerExcluded() {
        XCTAssertEqual(todos(["**Kim** \u{2014} Call the partner", "**Wesley** \u{2014} Investigate"]), [])
    }

    func testMultiWordAliasRequiresAllTokensContiguously() {
        let result = ActionItemOwnership.todoTexts(
            from: ["**Kim Broekhuizen** \u{2014} Not mine"],
            aliases: ["Youri Broekhuizen"],
            includeUnassigned: false
        )
        XCTAssertEqual(result, [])
    }

    func testUnassignedExcludedByDefault() {
        XCTAssertEqual(todos(["**?** \u{2014} Book a room", "No format at all"]), [])
    }

    func testUnassignedIncludedWhenToggleOn() {
        XCTAssertEqual(
            todos(["**?** \u{2014} Book a room", "No format at all", "**Kim** \u{2014} Not mine"], includeUnassigned: true),
            ["Book a room", "No format at all"]
        )
    }

    func testOwnerPrefixIsStripped() {
        XCTAssertEqual(todos(["**Youri** - Plain hyphen separator"]), ["Plain hyphen separator"])
    }

    func testDedupeAgainstLegacyPrefixedTodo() {
        let legacy = "**Youri** \u{2014} Draft the roadmap"
        XCTAssertEqual(todos([legacy], existing: [legacy]), [])
    }

    func testDedupeAgainstStrippedTodo() {
        XCTAssertEqual(todos(["**Youri** \u{2014} Draft the roadmap"], existing: ["Draft the roadmap "]), [])
    }

    func testDedupeWithinBatch() {
        XCTAssertEqual(todos(["**Youri** \u{2014} Same", "**Youri B.** \u{2014} Same"]), ["Same"])
    }

    func testNoAliasesMeansNothingIsMine() {
        let result = ActionItemOwnership.todoTexts(from: ["**Youri** \u{2014} A"], aliases: [], includeUnassigned: false)
        XCTAssertEqual(result, [])
    }

    // MARK: - Preferences

    func testAliasesFallBackToFullUserName() {
        let defaults = makeDefaults()
        let aliases = AppPreferences.userNameAliases(in: defaults, fullNameProvider: { "Jane Q. Doe" })
        XCTAssertEqual(aliases, ["Jane Q. Doe", "Jane"])
    }

    func testAliasesFallBackToSingleWordName() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppPreferences.userNameAliases(in: defaults, fullNameProvider: { "jane" }), ["jane"])
        XCTAssertEqual(AppPreferences.userNameAliases(in: defaults, fullNameProvider: { "  " }), [])
    }

    func testStoredAliasesOverrideFullUserName() {
        let defaults = makeDefaults()
        defaults.set(" Youri Broekhuizen, Youri ,, youri ", forKey: AppPreferenceKey.userNameAliases)
        let aliases = AppPreferences.userNameAliases(in: defaults, fullNameProvider: { "Someone Else" })
        XCTAssertEqual(aliases, ["Youri Broekhuizen", "Youri"])
    }

    func testIncludeUnassignedDefaultsOff() {
        let defaults = makeDefaults()
        XCTAssertFalse(AppPreferences.includeUnassignedActionItems(in: defaults))
        defaults.set(true, forKey: AppPreferenceKey.includeUnassignedActionItems)
        XCTAssertTrue(AppPreferences.includeUnassignedActionItems(in: defaults))
    }

    // MARK: - Prompt identity

    @MainActor
    func testRenderPromptSubstitutesUserName() {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: SummarizationService.defaultPromptTemplate,
            meeting: meeting,
            transcript: "t",
            freeformNotes: "",
            terminologyBlock: "",
            userName: "Youri Broekhuizen"
        )
        XCTAssertFalse(rendered.contains("{{user_name}}"))
        XCTAssertTrue(rendered.contains("The note-taker is Youri Broekhuizen."))
    }

    @MainActor
    func testRenderPromptAppendsIdentityToCustomTemplateWithoutPlaceholder() {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: "Summarize: {{transcript}}",
            meeting: meeting,
            transcript: "t",
            freeformNotes: "",
            terminologyBlock: "",
            userName: "Youri"
        )
        XCTAssertTrue(rendered.hasPrefix("Summarize: t"))
        XCTAssertTrue(rendered.contains("The note-taker is Youri."))
    }

    @MainActor
    func testRenderPromptLeavesCustomTemplateAloneWithoutName() {
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1_700_000_000))
        let rendered = SummarizationService.renderPrompt(
            template: "Summarize: {{transcript}}",
            meeting: meeting,
            transcript: "t",
            freeformNotes: "",
            terminologyBlock: ""
        )
        XCTAssertEqual(rendered, "Summarize: t")
    }
}
