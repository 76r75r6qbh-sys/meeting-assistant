import XCTest
@testable import Casablanca

final class ActionItemVerifierTests: XCTestCase {

    // MARK: - Fixtures

    private static let speakers: Set<String> = ["Youri", "Spreker 1"]

    /// Same meeting, with and without `Name: ` prefixes.
    private static let prefixedTranscript = """
    [00:00] Youri: Welkom allemaal bij de wekelijkse sync.
    [00:59] Spreker 1: We moeten nog kijken naar de planning.
    [01:01] Youri: Klopt, laten we dat volgende week doen.
    [02:05] Spreker 1: De klant wil graag een demo zien.
    [03:10] Youri: Ik stuur de offerte vrijdag naar Kim.
    [03:40] Spreker 1: We besluiten om de release uit te stellen tot december.
    [04:15] Youri: En ik plan een overleg
    [04:20] Spreker 1: met het team over de migratie.
    [05:00] Youri: Dan nemen we ook de nieuwe koppeling mee
    en daarna de evaluatie van het project.
    [05:30] Spreker 1: Afgesproken, de demo wordt op dinsdag gegeven.
    """

    private static let plainTranscript = """
    [00:00] Welkom allemaal bij de wekelijkse sync.
    [00:59] We moeten nog kijken naar de planning.
    [01:01] Klopt, laten we dat volgende week doen.
    [02:05] De klant wil graag een demo zien.
    [03:10] Ik stuur de offerte vrijdag naar Kim.
    [03:40] We besluiten om de release uit te stellen tot december.
    [04:15] En ik plan een overleg
    [04:20] met het team over de migratie.
    [05:00] Dan nemen we ook de nieuwe koppeling mee
    en daarna de evaluatie van het project.
    [05:30] Afgesproken, de demo wordt op dinsdag gegeven.
    """

    /// Both variants: prefixed with known speakers, and prefix-free.
    private static var indexes: [(name: String, index: TranscriptIndex)] {
        [("prefixed", TranscriptIndex(transcript: prefixedTranscript, knownSpeakers: speakers)),
         ("plain", TranscriptIndex(transcript: plainTranscript, knownSpeakers: []))]
    }

    private func item(_ task: String, quote: String?, timestamp: String?, owner: String? = nil) -> ExtractedActionItem {
        ExtractedActionItem(task: task, owner: owner, due: nil, dueIsExplicit: false, confidence: 0.9,
                            quote: quote, timestamp: timestamp, verified: .unverified, verificationReason: nil)
    }

    private func facts(items: [ExtractedActionItem] = [], decisions: [ExtractedDecision] = []) -> SummaryFacts {
        SummaryFacts(topics: [], decisions: decisions, actionItems: items, openQuestions: [], facts: [])
    }

    // MARK: - Pre-check

    func testExactQuoteIsFoundAndTimestampCorrected() {
        for (name, index) in Self.indexes {
            let input = facts(items: [item("Offerte naar Kim sturen", quote: "Ik stuur de offerte vrijdag naar Kim",
                                           timestamp: "01:00", owner: "Youri")])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(out.actionItems[0].timestamp, "03:10", name)
            XCTAssertEqual(out.actionItems[0].verified, .unverified, name)
            XCTAssertEqual(claims, [ActionItemVerifier.Claim(
                id: "a1", kind: .actionItem, text: "Offerte naar Kim sturen", owner: "Youri", due: nil,
                quote: "Ik stuur de offerte vrijdag naar Kim", seconds: 190)], name)
        }
    }

    func testExactQuoteIsFoundInOldTranscriptWithoutKnownSpeakers() {
        let index = TranscriptIndex(transcript: Self.prefixedTranscript, knownSpeakers: [])
        XCTAssertEqual(index.lines[4].text, "Youri: Ik stuur de offerte vrijdag naar Kim.")
        let located = index.locate(quote: "ik stuur de offerte vrijdag naar Kim", near: nil)
        XCTAssertEqual(located.score, 1.0)
        XCTAssertEqual(located.line?.label, "03:10")
    }

    func testQuoteWithOneTranscriptionErrorStillMatches() {
        for (name, index) in Self.indexes {
            let quote = "Ik stuur de oferte vrijdag naar Kim"
            let located = index.locate(quote: quote, near: 190)
            XCTAssertGreaterThanOrEqual(located.score, FuzzyText.matchThreshold, name)
            XCTAssertLessThan(located.score, 1.0, name)
            XCTAssertEqual(located.line?.label, "03:10", name)

            // Also without a usable timestamp (global pass).
            let input = facts(items: [item("Offerte sturen", quote: quote, timestamp: nil)])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(claims.map(\.id), ["a1"], name)
            XCTAssertEqual(out.actionItems[0].timestamp, "03:10", name)
        }
    }

    func testInventedQuoteIsUnsupportedWithoutAClaim() {
        for (name, index) in Self.indexes {
            let input = facts(items: [item("Kantoor verhuizen", quote: "We gaan het kantoor verhuizen naar Utrecht",
                                           timestamp: "03:10")])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(out.actionItems[0].verified, .unsupported, name)
            XCTAssertEqual(out.actionItems[0].verificationReason, ActionItemVerifier.quoteNotFoundReason, name)
            XCTAssertEqual(out.actionItems[0].timestamp, "03:10", name)
            XCTAssertTrue(claims.isEmpty, name)
        }
    }

    func testNilQuoteStaysUnverified() {
        for (name, index) in Self.indexes {
            let input = facts(items: [item("Notitie van de gebruiker", quote: nil, timestamp: nil),
                                      item("Lege quote", quote: "  ", timestamp: "03:10")])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(out, input, name)
            XCTAssertEqual(out.actionItems.map(\.verified), [.unverified, .unverified], name)
            XCTAssertTrue(claims.isEmpty, name)
        }
    }

    func testQuoteSpanningTwoLinesMatches() {
        for (name, index) in Self.indexes {
            let input = facts(items: [item("Overleg plannen", quote: "ik plan een overleg met het team over de migratie",
                                           timestamp: "04:20")])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(claims.count, 1, name)
            XCTAssertEqual(out.actionItems[0].timestamp, "04:15", name)
            XCTAssertEqual(claims.first?.seconds, 255, name)
        }
    }

    func testUntimedLineAttachesToThePreviousLine() {
        for (name, index) in Self.indexes {
            XCTAssertEqual(index.lines.count, 10, name)
            XCTAssertTrue(index.lines[8].text.hasSuffix("koppeling mee en daarna de evaluatie van het project."), name)
            let located = index.locate(quote: "daarna de evaluatie van het project", near: 300)
            XCTAssertEqual(located.score, 1.0, name)
            XCTAssertEqual(located.line?.label, "05:00", name)
        }
    }

    // MARK: - Windows

    func testWindowIsSixtySecondsEachSide() {
        XCTAssertEqual(ActionItemVerifier.windowRadius, 60)
        for (name, index) in Self.indexes {
            // Lines at 0, 59, 61, 125 s around 60 s.
            let labels = index.window(around: 60, radius: ActionItemVerifier.windowRadius).map(\.label)
            XCTAssertEqual(labels, ["00:00", "00:59", "01:01"], name)
        }
    }

    func testHourLabelsParse() {
        let prefixed = "[59:58] Youri: Bijna een uur.\n[1:02:03] Spreker 1: We ronden de evaluatie vandaag af."
        let plain = "[59:58] Bijna een uur.\n[1:02:03] We ronden de evaluatie vandaag af."
        for (name, index) in [("prefixed", TranscriptIndex(transcript: prefixed, knownSpeakers: Self.speakers)),
                              ("plain", TranscriptIndex(transcript: plain, knownSpeakers: []))] {
            XCTAssertEqual(index.lines.last?.seconds, 3723, name)
            XCTAssertEqual(index.window(around: 3723, radius: 60).map(\.label), ["1:02:03"], name)
            let input = facts(items: [item("Evaluatie afronden", quote: "we ronden de evaluatie vandaag af",
                                           timestamp: "1:02:03")])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(out.actionItems[0].timestamp, "1:02:03", name)
            XCTAssertEqual(claims.first?.seconds, 3723, name)
        }
    }

    func testOutOfRangeItemTimestampIsIgnored() {
        XCTAssertNil(ActionItemVerifier.itemSeconds("99:99"))
        XCTAssertNil(ActionItemVerifier.itemSeconds("1:60:00"))
        XCTAssertNil(ActionItemVerifier.itemSeconds("garbage"))
        XCTAssertEqual(ActionItemVerifier.itemSeconds("03:10"), 190)
        XCTAssertEqual(ActionItemVerifier.itemSeconds("[1:02:03]"), 3723)
        for (name, index) in Self.indexes {
            let input = facts(items: [item("Offerte", quote: "Ik stuur de offerte vrijdag naar Kim", timestamp: "99:99")])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(out.actionItems[0].timestamp, "03:10", name)
            XCTAssertEqual(claims.count, 1, name)
        }
    }

    func testDecisionsGetDIds() {
        for (name, index) in Self.indexes {
            let input = facts(
                items: [item("Offerte sturen", quote: "Ik stuur de offerte vrijdag naar Kim", timestamp: "03:10")],
                decisions: [
                    ExtractedDecision(text: "Release uitgesteld tot december",
                                      quote: "we besluiten om de release uit te stellen tot december", timestamp: "03:00"),
                    ExtractedDecision(text: "Demo op dinsdag", quote: "de demo wordt op dinsdag gegeven", timestamp: "05:30"),
                ])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(claims.map(\.id), ["a1", "d1", "d2"], name)
            XCTAssertEqual(claims.map(\.kind), [.actionItem, .decision, .decision], name)
            XCTAssertEqual(claims[1].text, "Release uitgesteld tot december", name)
            XCTAssertNil(claims[1].owner, name)
            XCTAssertNil(claims[1].due, name)
            XCTAssertEqual(out.decisions.map(\.timestamp), ["03:40", "05:30"], name)
            XCTAssertEqual(ActionItemVerifier.ClaimKind.actionItem.rawValue, "action item")
            XCTAssertEqual(ActionItemVerifier.ClaimKind.decision.rawValue, "decision")
        }
    }

    func testClaimIdsFollowListPositionSoUnsupportedItemsLeaveGaps() {
        for (name, index) in Self.indexes {
            let input = facts(items: [
                item("Verzonnen", quote: "We gaan het kantoor verhuizen naar Utrecht", timestamp: nil),
                item("Zonder quote", quote: nil, timestamp: nil),
                item("Offerte", quote: "Ik stuur de offerte vrijdag naar Kim", timestamp: nil),
            ], decisions: [
                ExtractedDecision(text: "Verzonnen besluit", quote: "we stoppen met het product"),
                ExtractedDecision(text: "Demo", quote: "de demo wordt op dinsdag gegeven"),
            ])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(claims.map(\.id), ["a3", "d2"], name)
            XCTAssertEqual(out.actionItems.map(\.verified), [.unsupported, .unverified, .unverified], name)
            XCTAssertEqual(out.decisions.map(\.verified), [.unsupported, .unverified], name)
            XCTAssertEqual(out.decisions[0].verificationReason, ActionItemVerifier.quoteNotFoundReason, name)
        }
    }

    // MARK: - Score equivalence

    /// `locate`'s fuzzy score equals the best ``FuzzyText/similarity(_:_:)``
    /// over every `k−1…k+1`-token window, for quotes of about 40, 70, 140 and
    /// 210 characters (one to four 64-bit blocks) inside longer lines that
    /// contain non-ASCII (`ĳ`, `ß`, `één`) and digits.
    func testFuzzyScoreEqualsBruteForceSimilarity() {
        var rng = SplitMix(seed: 42)
        let words = ["de", "het", "offerte", "kim", "plan", "ik", "we", "één", "team", "q3", "migratie",
                     "naar", "stuur", "ĳsbaan", "straße", "2026", "bĳeenkomst", "größe"]
        func randomWords(_ count: Int) -> [String] { (0..<count).map { _ in words[rng.next(words.count)] } }
        var blocksChecked: [Int: Int] = [:]
        for round in 0..<24 {
            let target = [40, 70, 140, 210][round % 4]
            var quoteWords: [String] = []
            while FuzzyText.normalized(quoteWords.joined(separator: " ")).count < target {
                quoteWords += randomWords(1)
            }
            let lineWords = randomWords(2 + rng.next(4)) + quoteWords + randomWords(2 + rng.next(4))
            // Corrupt one character so the exact path is not taken.
            var quote = quoteWords.joined(separator: " ")
            let position = quote.index(quote.startIndex, offsetBy: rng.next(quote.count))
            quote.replaceSubrange(position...position, with: "x")
            let transcript = "[00:05] " + lineWords.joined(separator: " ")
            let index = TranscriptIndex(transcript: transcript, knownSpeakers: [])
            let haystack = " " + FuzzyText.normalized(transcript) + " "
            guard !haystack.contains(" " + FuzzyText.normalized(quote) + " ") else { continue }

            let tokens = FuzzyText.normalized(lineWords.joined(separator: " ")).split(separator: " ").map(String.init)
            let k = FuzzyText.normalized(quote).split(separator: " ").count
            var expected = 0.0
            for start in tokens.indices {
                for size in max(1, k - 1)...(k + 1) where start + size <= tokens.count {
                    expected = max(expected, FuzzyText.similarity(tokens[start..<start + size].joined(separator: " "), quote))
                }
            }
            // near: 5 puts every start in the local pass.
            let located = index.locate(quote: quote, near: 5)
            XCTAssertGreaterThanOrEqual(expected, FuzzyText.matchThreshold, "round \(round)")
            XCTAssertEqual(located.score, expected, accuracy: 1e-12, "round \(round): \(quote) in \(transcript)")
            let blocks = (FuzzyText.normalized(quote).count + 63) / 64
            blocksChecked[blocks, default: 0] += 1
        }
        for blocks in 1...4 { XCTAssertGreaterThan(blocksChecked[blocks] ?? 0, 0, "\(blocks) block(s)") }
    }

    // MARK: - Word boundaries and short quotes

    func testExactMatchRespectsWordBoundaries() {
        let prefixed = "[00:10] Youri: Het pakket komt morgen.\n[00:20] Spreker 1: Kijk eens naar de planning."
        let plain = "[00:10] Het pakket komt morgen.\n[00:20] Kijk eens naar de planning."
        for (name, index) in [("prefixed", TranscriptIndex(transcript: prefixed, knownSpeakers: Self.speakers)),
                              ("plain", TranscriptIndex(transcript: plain, knownSpeakers: []))] {
            XCTAssertLessThan(index.locate(quote: "pak", near: 10).score, FuzzyText.matchThreshold, name)
            XCTAssertLessThan(index.locate(quote: "ik", near: 20).score, FuzzyText.matchThreshold, name)
            XCTAssertLessThan(index.locate(quote: "pak", near: nil).score, FuzzyText.matchThreshold, name)
            XCTAssertEqual(index.locate(quote: "Het pakket komt", near: nil).score, 1.0, name)
            XCTAssertEqual(index.locate(quote: "Kijk", near: nil).line?.label, "00:20", name)
        }
    }

    func testShortQuoteAloneIsNotSupport() {
        for (name, index) in Self.indexes {
            // "naar kim" occurs, but is shorter than FuzzyText.minimumFuzzyLength.
            let input = facts(items: [item("Kim", quote: "naar Kim", timestamp: "01:00"),
                                      item("Kort verzonnen", quote: "naar Utrecht", timestamp: nil)])
            let (out, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertTrue(claims.isEmpty, name)
            XCTAssertEqual(out.actionItems[0], input.actionItems[0], name)
            XCTAssertEqual(out.actionItems[1].verified, .unsupported, name)
        }
    }

    // MARK: - Untimed text

    func testUntimedLeadInAttachesToASyntheticStartLine() {
        let index = TranscriptIndex(transcript: "Notulen van het overleg\nmet het team\n[00:10] Youri: Ik stuur de offerte vrijdag naar Kim.",
                                    knownSpeakers: Self.speakers)
        XCTAssertEqual(index.lines.map(\.label), ["00:00", "00:10"])
        XCTAssertEqual(index.lines[0].text, "Notulen van het overleg met het team")
        XCTAssertEqual(index.lines[0].seconds, 0)
    }

    func testFullyUntimedTranscriptIsSearchedWhole() {
        let transcript = "Youri: Ik stuur de offerte vrijdag naar Kim.\nWe besluiten om de release uit te stellen tot december."
        let index = TranscriptIndex(transcript: transcript, knownSpeakers: Self.speakers)
        let input = facts(items: [item("Offerte", quote: "ik stuur de offerte vrijdag naar Kim", timestamp: "03:10"),
                                  item("Offerte fuzzy", quote: "ik stuur de oferte vrijdag naar Kim", timestamp: nil),
                                  item("Verzonnen", quote: "We gaan het kantoor verhuizen naar Utrecht", timestamp: nil)],
                          decisions: [ExtractedDecision(text: "Release later", quote: "de release uit te stellen tot december")])
        let (out, claims) = ActionItemVerifier.precheck(input, index: index)
        XCTAssertEqual(claims.map(\.id), ["a1", "a2", "d1"])
        // No real timestamps: cited timestamps are kept, not replaced by the synthetic 00:00.
        XCTAssertEqual(out.actionItems.map(\.timestamp), ["03:10", nil, nil])
        XCTAssertEqual(out.actionItems.map(\.verified), [.unverified, .unverified, .unsupported])
        XCTAssertNil(out.decisions[0].timestamp)
    }

    // MARK: - Re-runs

    func testFoundQuoteResetsAStaleVerdict() {
        for (name, index) in Self.indexes {
            var stale = item("Offerte", quote: "Ik stuur de offerte vrijdag naar Kim", timestamp: "03:10")
            stale.verified = .unsupported
            stale.verificationReason = ActionItemVerifier.quoteNotFoundReason
            let decision = ExtractedDecision(text: "Demo", quote: "de demo wordt op dinsdag gegeven", timestamp: "05:30",
                                             verified: .supported, verificationReason: "Oud oordeel.")
            let (out, claims) = ActionItemVerifier.precheck(facts(items: [stale], decisions: [decision]), index: index)
            XCTAssertEqual(claims.count, 2, name)
            XCTAssertEqual(out.actionItems[0].verified, .unverified, name)
            XCTAssertNil(out.actionItems[0].verificationReason, name)
            XCTAssertEqual(out.decisions[0].verified, .unverified, name)
            XCTAssertNil(out.decisions[0].verificationReason, name)
        }
    }

    // MARK: - Performance

    func testLongTranscriptPrecheckIsFast() {
        let fillers = ["ik denk dat we de planning nog moeten bekijken met het team",
                       "de klant vraagt om een update over de koppeling",
                       "ik weet niet of dat deze sprint nog lukt",
                       "we hebben de testomgeving gisteren opnieuw ingericht"]
        var lines: [String] = []
        var chars = 0
        var second = 0
        while chars < 150_000 {
            let line = "[\(TranscriptLineFormat.timestampLabel(seconds: Double(second)))] Youri: \(fillers[second % fillers.count]) nummer \(second)"
            lines.append(line)
            chars += line.count + 1
            second += 2
        }
        lines.append("[\(TranscriptLineFormat.timestampLabel(seconds: Double(second)))] Spreker 1: ik regel de nieuwe licenties voor het hele team")
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThanOrEqual(transcript.count, 150_000)

        let start = Date()
        let index = TranscriptIndex(transcript: transcript, knownSpeakers: Self.speakers)
        let input = facts(items: [
            item("Licenties", quote: "ik regel de nieuwe licentie voor het hele team", timestamp: "00:10"),
            item("Verzonnen 1", quote: "ik ga het kantoor verhuizen naar Utrecht volgende maand", timestamp: "10:00"),
            item("Verzonnen 2", quote: "de klant wil de koppeling volgende week live hebben", timestamp: nil),
            item("Verzonnen 3", quote: "we hebben besloten om de testomgeving af te sluiten", timestamp: "40:00"),
            item("Verzonnen 4", quote: "ik denk dat we het budget moeten verdubbelen", timestamp: nil),
            item("Veelvoorkomend", quote: "met het team", timestamp: "30:01"),
            item("Verzonnen lang", quote: "ik denk dat we de planning voor het komende kwartaal helemaal opnieuw moeten bekijken met alle teams samen",
                 timestamp: nil),
        ])
        let (out, claims) = ActionItemVerifier.precheck(input, index: index)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(claims.map(\.id), ["a1", "a6"])
        // The exact occurrence nearest the cited 30:01 wins (filler 0 is said every 8 s: 30:00).
        XCTAssertEqual(out.actionItems[5].timestamp, "30:00")
        XCTAssertEqual(out.actionItems[0].timestamp, TranscriptLineFormat.timestampLabel(seconds: Double(second)))
        XCTAssertEqual(out.actionItems.dropFirst().map(\.verified), [.unsupported, .unsupported, .unsupported, .unsupported, .unverified, .unsupported])
        XCTAssertLessThan(elapsed, 3, "pre-check on a 150k-char transcript took \(elapsed) s")
    }

    // MARK: - Verification prompt (Task 7)

    private static let calendar = SummaryFixtures.amsterdamCalendar

    /// The claims the pre-check emits for an action item at 03:10 and a decision at 03:40.
    private func claimsAndFacts(_ index: TranscriptIndex) -> (facts: SummaryFacts, claims: [ActionItemVerifier.Claim]) {
        let input = facts(
            items: [item("Offerte naar Kim sturen", quote: "Ik stuur de offerte vrijdag naar Kim",
                         timestamp: "03:10", owner: "Youri")],
            decisions: [ExtractedDecision(text: "Release uitgesteld tot december",
                                          quote: "we besluiten om de release uit te stellen", timestamp: "03:40")]
        )
        return ActionItemVerifier.precheck(input, index: index)
    }

    func testPromptListsEveryClaimWithItsWindow() throws {
        for (name, index) in Self.indexes {
            let (_, claims) = claimsAndFacts(index)
            XCTAssertEqual(claims.map(\.id), ["a1", "d1"], name)

            let prompt = ActionItemVerifier.prompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                   calendar: Self.calendar, budgetTokens: 25_000)

            XCTAssertTrue(prompt.hasPrefix("You are checking meeting notes against the transcript they were written from.\n"), name)
            XCTAssertTrue(prompt.contains("\nWhen in doubt, answer false.\n\nMeeting date: 2026-11-04\n\nClaims:\n### a1 (action item)\n"), name)
            // ±60 s around 03:10 (190 s): 03:10 and 03:40; around 03:40 (220 s): 03:10 … 04:20.
            XCTAssertTrue(prompt.contains("""
            ### a1 (action item)
            Claim: Offerte naar Kim sturen
            Owner: Youri
            Due: none
            Quote: "Ik stuur de offerte vrijdag naar Kim"
            Transcript excerpt (03:10–03:40):
            """), name)
            XCTAssertTrue(prompt.contains("""
            ### d1 (decision)
            Claim: Release uitgesteld tot december
            Owner: none
            Due: none
            Quote: "we besluiten om de release uit te stellen"
            Transcript excerpt (03:10–04:20):
            """), name)
            let blocks = Array(prompt.components(separatedBy: "\n### ").dropFirst())
            XCTAssertEqual(blocks.count, 2, name)
            for block in blocks {
                XCTAssertFalse(block.contains("[02:05]"), name)
                XCTAssertTrue(block.contains("[03:10]"), name)
                XCTAssertTrue(block.contains("[03:40]"), name)
                XCTAssertFalse(block.contains("[05:00]"), name)
            }
            XCTAssertFalse(blocks[0].contains("[04:15]"), name)
            XCTAssertTrue(blocks[1].contains("[04:20]"), name)
            // Original text: speaker prefixes stay, nothing is normalised.
            let line = name == "prefixed" ? "[03:10] Youri: Ik stuur de offerte vrijdag naar Kim." : "[03:10] Ik stuur de offerte vrijdag naar Kim."
            XCTAssertTrue(prompt.contains("\n" + line + "\n"), name)
        }
    }

    func testPromptShowsGappedIdsAsTheyAre() {
        for (name, index) in Self.indexes {
            let input = facts(items: [item("Verzonnen", quote: "ik verhuis het kantoor naar Utrecht", timestamp: nil),
                                      item("Demo", quote: "De klant wil graag een demo zien", timestamp: "02:05")])
            let (_, claims) = ActionItemVerifier.precheck(input, index: index)
            let prompt = ActionItemVerifier.prompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                   calendar: Self.calendar, budgetTokens: 25_000)
            XCTAssertTrue(prompt.contains("### a2 (action item)"), name)
            XCTAssertFalse(prompt.contains("### a1 "), name)
            XCTAssertFalse(prompt.contains("verhuis"), name)
        }
    }

    /// A long, dense transcript: one long line every 2 s.
    private func denseTranscript(speakers: Bool) -> String {
        (0..<600).map { n in
            let label = TranscriptLineFormat.timestampLabel(seconds: Double(n * 2))
            let body: String
            switch n {
            case 150: body = "Ik stuur de offerte vrijdag naar Kim."
            case 450: body = "We besluiten om de release uit te stellen tot december."
            default: body = "We bespreken punt \(n) van de agenda uitgebreid met iedereen in de ruimte erbij."
            }
            return "[\(label)] " + (speakers ? (n.isMultiple(of: 2) ? "Youri: " : "Spreker 1: ") : "") + body
        }.joined(separator: "\n")
    }

    func testPromptShrinksWindowsToFitTheBudget() throws {
        for speakers in [true, false] {
            let index = TranscriptIndex(transcript: denseTranscript(speakers: speakers),
                                        knownSpeakers: speakers ? Self.speakers : [])
            let input = facts(
                items: [item("Offerte", quote: "Ik stuur de offerte vrijdag naar Kim", timestamp: "05:00", owner: "Youri")],
                decisions: [ExtractedDecision(text: "Release later", quote: "we besluiten om de release uit te stellen",
                                              timestamp: "15:00")]
            )
            let (_, claims) = ActionItemVerifier.precheck(input, index: index)
            XCTAssertEqual(claims.map(\.id), ["a1", "d1"])

            let roomy = ActionItemVerifier.prompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                  calendar: Self.calendar, budgetTokens: 25_000)
            XCTAssertGreaterThan(LLMPromptSupport.budgetTokens(roomy), 3_000, "±60 s of this transcript is large")
            XCTAssertTrue(roomy.contains("Transcript excerpt (04:00–06:00):"))

            // ±30 s fits in 3,000 tokens.
            let narrower = ActionItemVerifier.prompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                     calendar: Self.calendar, budgetTokens: 3_000)
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(narrower), 3_000)
            XCTAssertTrue(narrower.contains("Transcript excerpt (04:30–05:30):"))
            XCTAssertFalse(narrower.contains("truncated"))

            // 800 tokens: the ±30 s excerpts are middle-elided to an equal share.
            let tight = ActionItemVerifier.prompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                  calendar: Self.calendar, budgetTokens: 800)
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(tight), 800)
            XCTAssertTrue(tight.contains("### a1 (action item)"))
            XCTAssertTrue(tight.contains("### d1 (decision)"))
            XCTAssertTrue(tight.contains("Claim: Offerte"))
            XCTAssertTrue(tight.contains("Claim: Release later"))
            XCTAssertTrue(tight.contains("Transcript excerpt (04:30–05:30):"))
            XCTAssertTrue(tight.contains("truncated"))
        }
    }

    // MARK: - Applying the verdicts (Task 7)

    func testApplyMapsSupportedAndUnsupported() throws {
        for (name, index) in Self.indexes {
            let (checked, claims) = claimsAndFacts(index)
            let response = """
            ```json
            [{"id": "a1", "supported": true, "reason": "Youri zegt het zelf."},
             {"id": "d1", "supported": false, "reason": "Er is alleen over gesproken."}]
            ```
            """
            let out = try XCTUnwrap(ActionItemVerifier.apply(response: response, claims: claims, to: checked), name)
            XCTAssertEqual(out.actionItems[0].verified, .supported, name)
            XCTAssertEqual(out.actionItems[0].verificationReason, "Youri zegt het zelf.", name)
            XCTAssertEqual(out.decisions[0].verified, .unsupported, name)
            XCTAssertEqual(out.decisions[0].verificationReason, "Er is alleen over gesproken.", name)
            XCTAssertEqual(out.actionItems[0].timestamp, "03:10", name)
        }
    }

    func testApplyMissingIdStaysUnverified() throws {
        for (name, index) in Self.indexes {
            let (checked, claims) = claimsAndFacts(index)
            let response = #"[{"id": "d1", "supported": "true", "reason": "ok"}, {"id": "a7", "supported": false}, {"id": "x"}]"#
            let out = try XCTUnwrap(ActionItemVerifier.apply(response: response, claims: claims, to: checked), name)
            XCTAssertEqual(out.actionItems[0].verified, .unverified, name)
            XCTAssertNil(out.actionItems[0].verificationReason, name)
            XCTAssertEqual(out.decisions[0].verified, .supported, name)
            XCTAssertEqual(out.actionItems.count, 1, name)
        }
    }

    func testApplyIgnoresIdsThatAreNotClaims() throws {
        // a1 has no quote, so it is no claim: a verdict for it is ignored.
        let input = facts(items: [item("Geen bewijs", quote: nil, timestamp: nil)])
        let out = try XCTUnwrap(ActionItemVerifier.apply(response: #"[{"id":"a1","supported":true,"reason":"ja"}]"#,
                                                         claims: [], to: input))
        XCTAssertEqual(out.actionItems[0].verified, .unverified)
    }

    func testApplyUnreadableIsNil() {
        for (name, index) in Self.indexes {
            let (checked, claims) = claimsAndFacts(index)
            XCTAssertNil(ActionItemVerifier.apply(response: "Both claims are supported.", claims: claims, to: checked), name)
            XCTAssertNil(ActionItemVerifier.apply(response: #"[{"id": "a1", "supported": tru"#, claims: claims, to: checked), name)
            XCTAssertNil(ActionItemVerifier.apply(response: #"{"id": "a1", "supported": true}"#, claims: claims, to: checked), name)
        }
    }

    // MARK: - Review fixes (Task 7)

    /// `count` claims with long texts, all at 03:10.
    private func longClaims(_ count: Int, textLength: Int = 400) -> [ActionItemVerifier.Claim] {
        (1...count).map { n in
            ActionItemVerifier.Claim(id: "a\(n * 2)", kind: .actionItem,
                                     text: "Taak \(n) " + String(repeating: "x", count: textLength), owner: nil, due: nil,
                                     quote: "Ik stuur de offerte vrijdag naar Kim", seconds: 190)
        }
    }

    func testFittedPromptKeepsOnlyTheLeadingClaimsThatFit() {
        for (name, index) in Self.indexes {
            let claims = longClaims(30)
            let fitted = ActionItemVerifier.fittedPrompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                         calendar: Self.calendar, budgetTokens: 800)
            XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(fitted.text), 800, name)
            XCTAssertGreaterThan(fitted.claims.count, 0, name)
            XCTAssertLessThan(fitted.claims.count, 30, name)
            XCTAssertEqual(fitted.claims, Array(claims.prefix(fitted.claims.count)), name)
            for claim in claims {
                XCTAssertEqual(fitted.text.contains("### \(claim.id) ("), fitted.claims.contains(claim), "\(name) \(claim.id)")
            }
            XCTAssertEqual(ActionItemVerifier.prompt(claims: claims, index: index, meetingDate: SummaryFixtures.meetingDate,
                                                     calendar: Self.calendar, budgetTokens: 800), fitted.text, name)
        }
    }

    func testFittedPromptWithNoRoomKeepsNoClaims() {
        for (name, index) in Self.indexes {
            let fitted = ActionItemVerifier.fittedPrompt(claims: longClaims(1, textLength: 5_000), index: index,
                                                         meetingDate: SummaryFixtures.meetingDate, calendar: Self.calendar,
                                                         budgetTokens: 800)
            XCTAssertTrue(fitted.claims.isEmpty, name)
        }
    }

    func testRepairPromptFitsTheBudget() {
        let broken = "[" + String(repeating: #"{"id": "a1", "supported": true, "reason": "ja"} "#, count: 1_000)
        let prompt = ActionItemVerifier.repairPrompt(broken: broken, budgetTokens: 1_000)
        XCTAssertLessThanOrEqual(LLMPromptSupport.budgetTokens(prompt), 1_000)
        XCTAssertTrue(prompt.hasPrefix("The text below was meant to be one JSON array of objects"))
        XCTAssertTrue(prompt.contains("Text:\n[{\"id\""))
        XCTAssertTrue(prompt.contains("truncated"))
        XCTAssertEqual(ActionItemVerifier.repairPrompt(broken: "[oops", budgetTokens: 1_000).components(separatedBy: "Text:\n").last, "[oops")
    }

    func testExtractJSONArraySkipsABracketedTimestampInProse() throws {
        let reply = "Bij [00:30] zegt Kim het.\n[{\"id\": \"a1\", \"supported\": true, \"reason\": \"ja\"}]\nKlaar [01:00]."
        XCTAssertEqual(SummaryFactsParser.extractJSONArray(reply), #"[{"id": "a1", "supported": true, "reason": "ja"}]\#nKlaar [01:00]"#)
        XCTAssertEqual(SummaryFactsParser.extractJSONArray("[ \n {\"id\": 1}]"), "[ \n {\"id\": 1}]")
        XCTAssertEqual(SummaryFactsParser.extractJSONArray("Geen claims: []"), "[]", "an empty array still reads")
        for (name, index) in Self.indexes {
            let (checked, claims) = claimsAndFacts(index)
            let clean = "Bij [00:30] zegt Kim het.\n[{\"id\": \"a1\", \"supported\": true, \"reason\": \"ja\"}]"
            let out = try XCTUnwrap(ActionItemVerifier.apply(response: clean, claims: claims, to: checked), name)
            XCTAssertEqual(out.actionItems[0].verified, .supported, name)
        }
    }
}

/// Deterministic pseudo-random numbers for the equivalence test.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ upperBound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(upperBound))
    }
}
