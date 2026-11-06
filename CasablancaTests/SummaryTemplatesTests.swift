import CryptoKit
import XCTest
@testable import Casablanca

@MainActor
final class SummaryTemplatesTests: XCTestCase {
    /// A scratch suite with both template keys set explicitly (R12): no
    /// legacy prompt, no stored overrides.
    private func makeDefaults() -> UserDefaults {
        let defaults = makeScratchDefaults(label: "SummaryTemplatesTests")
        defaults.removeObject(forKey: AppPreferenceKey.summaryPromptTemplate)
        defaults.set("", forKey: AppPreferenceKey.summaryTemplates)
        return defaults
    }

    // MARK: - Catalog

    func testGeneralComposesToTheDefaultTemplate() {
        XCTAssertEqual(
            SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.generalStructure),
            SummarizationService.defaultPromptTemplate
        )
        // Pinned to the pre-template literal (7a8ba45), byte for byte: the
        // General template must not drift when the catalog is refactored.
        // Change this hash only for a deliberate prompt edit.
        let digest = SHA256.hash(data: Data(SummarizationService.defaultPromptTemplate.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "f125f095f9ee2590b2dcf4697a4bd7ea31704227ccb841cb517f7b379f1a064b")
        let general = SummaryTemplateCatalog.builtIns.first
        XCTAssertEqual(general?.id, SummaryTemplateID.general)
        XCTAssertEqual(general?.prompt, SummarizationService.defaultPromptTemplate)
    }

    func testBuiltInsAreTheSixTypesInOrder() {
        XCTAssertEqual(
            SummaryTemplateCatalog.builtIns.map(\.id),
            [SummaryTemplateID.general, SummaryTemplateID.oneOnOne, SummaryTemplateID.standup,
             SummaryTemplateID.refinement, SummaryTemplateID.external, SummaryTemplateID.workshop]
        )
        XCTAssertTrue(SummaryTemplateCatalog.builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(Set(SummaryTemplateCatalog.builtIns.map(\.prompt)).count, 6, "every type has its own prompt")
    }

    /// The renderer, the JSON instruction and SummaryResponseParser all rely on
    /// these: the closing sections in both languages and the placeholders.
    func testEveryBuiltInKeepsTheFourClosingHeadingsAndPlaceholders() {
        let required = [
            "`## Besluiten` / `## Decisions`",
            "`## Actiepunten` / `## Action Items`",
            "`## Risico's en blockers` / `## Risks and Blockers`",
            "`## Opvolging` / `## Follow-ups`",
            "{{transcript}}", "{{user_focus}}", "{{participants}}", "{{user_name}}",
            "{{terminology_list}}", "{{title}}",
            "`- **<owner>** — <action>`",
            "Transcript:\n{{transcript}}",
        ]
        for template in SummaryTemplateCatalog.builtIns {
            for needle in required {
                XCTAssertTrue(template.prompt.contains(needle), "\(template.id) lacks \(needle)")
            }
            XCTAssertTrue(template.prompt.hasSuffix("Transcript:\n{{transcript}}"), "\(template.id): the transcript stays last")
        }
    }

    func testTypeStructuresReplaceItemsTwoToFour() {
        let oneOnOne = SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.oneOnOneStructure)
        XCTAssertTrue(oneOnOne.contains("\n2. Then these sections, each only when it has content: `## Hoe gaat het`"))
        XCTAssertFalse(oneOnOne.contains("2-5 thematic sections"))
        XCTAssertTrue(oneOnOne.contains("\n5. End with these four sections"))
        XCTAssertTrue(SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.standupStructure).contains("## Per persoon"))
        XCTAssertTrue(SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.refinementStructure).contains("- **Estimate:** 5 SP"))
        XCTAssertTrue(SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.externalStructure).contains("## Hun vraag"))
        XCTAssertTrue(SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.workshopStructure).contains("## Parkeerplaats"))
    }

    // MARK: - Store

    func testGeneralUsesLegacyPromptKey() {
        let defaults = makeDefaults()
        defaults.set("X {{transcript}}", forKey: AppPreferenceKey.summaryPromptTemplate)

        XCTAssertEqual(SummaryTemplateStore.template(id: "general", in: defaults).prompt, "X {{transcript}}")
        XCTAssertEqual(SummaryTemplateStore.template(id: nil, in: defaults).prompt, "X {{transcript}}")
        XCTAssertTrue(SummaryTemplateStore.isModified(id: "general", in: defaults))
    }

    func testGeneralIsNotModifiedWhenTheLegacyKeyHoldsTheDefault() {
        let defaults = makeDefaults()
        XCTAssertFalse(SummaryTemplateStore.isModified(id: "general", in: defaults))
        // Today's Settings editor stores the default text on Reset.
        defaults.set(SummarizationService.defaultPromptTemplate, forKey: AppPreferenceKey.summaryPromptTemplate)
        XCTAssertFalse(SummaryTemplateStore.isModified(id: "general", in: defaults))
    }

    func testSavingGeneralWritesTheLegacyKeyAndResetRemovesIt() {
        let defaults = makeDefaults()
        var general = SummaryTemplateStore.template(id: "general", in: defaults)
        general.prompt = "Mine {{transcript}}"

        SummaryTemplateStore.save(general, in: defaults)

        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.summaryPromptTemplate), "Mine {{transcript}}")
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.summaryTemplates), "", "General never goes into the JSON")
        SummaryTemplateStore.reset(id: "general", in: defaults)
        XCTAssertNil(defaults.string(forKey: AppPreferenceKey.summaryPromptTemplate))
        XCTAssertEqual(SummaryTemplateStore.template(id: "general", in: defaults).prompt, SummarizationService.defaultPromptTemplate)
    }

    func testSaveOverrideResetBuiltIn() {
        let defaults = makeDefaults()
        var standup = SummaryTemplateStore.template(id: "standup", in: defaults)
        XCTAssertEqual(standup.prompt, SummaryTemplateCatalog.compose(structure: SummaryTemplateCatalog.standupStructure))
        XCTAssertFalse(SummaryTemplateStore.isModified(id: "standup", in: defaults))

        standup.prompt = "Short {{transcript}}"
        SummaryTemplateStore.save(standup, in: defaults)

        let saved = SummaryTemplateStore.template(id: "standup", in: defaults)
        XCTAssertEqual(saved.prompt, "Short {{transcript}}")
        XCTAssertEqual(saved.name, SummaryTemplateCatalog.builtIns[2].name)
        XCTAssertTrue(saved.isBuiltIn)
        XCTAssertTrue(SummaryTemplateStore.isModified(id: "standup", in: defaults))
        XCTAssertEqual(SummaryTemplateStore.all(in: defaults).map(\.id).prefix(6), SummaryTemplateCatalog.builtIns.map(\.id).prefix(6))
        XCTAssertEqual(SummaryTemplateStore.all(in: defaults)[2].prompt, "Short {{transcript}}", "all() applies the override")

        SummaryTemplateStore.reset(id: "standup", in: defaults)

        XCTAssertEqual(SummaryTemplateStore.template(id: "standup", in: defaults), SummaryTemplateCatalog.builtIns[2])
        XCTAssertFalse(SummaryTemplateStore.isModified(id: "standup", in: defaults))
    }

    func testCustomTemplateAddDelete() {
        let defaults = makeDefaults()
        let zebra = SummaryTemplate(id: "custom-\(UUID().uuidString)", name: "Zebra", prompt: "Z {{transcript}}", isBuiltIn: false)
        let alpha = SummaryTemplate(id: "custom-\(UUID().uuidString)", name: "alpha", prompt: "A {{transcript}}", isBuiltIn: false)

        SummaryTemplateStore.save(zebra, in: defaults)
        SummaryTemplateStore.save(alpha, in: defaults)

        let all = SummaryTemplateStore.all(in: defaults)
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all.suffix(2).map(\.name), ["alpha", "Zebra"], "custom templates follow the built-ins, by name")
        XCTAssertEqual(SummaryTemplateStore.template(id: zebra.id, in: defaults), zebra)

        var renamed = zebra
        renamed.name = "Yak"
        SummaryTemplateStore.save(renamed, in: defaults)
        XCTAssertEqual(SummaryTemplateStore.all(in: defaults).count, 8, "saving an existing id replaces it")
        XCTAssertEqual(SummaryTemplateStore.template(id: zebra.id, in: defaults).name, "Yak")

        SummaryTemplateStore.delete(id: zebra.id, in: defaults)

        XCTAssertEqual(SummaryTemplateStore.all(in: defaults).count, 7)
        XCTAssertEqual(SummaryTemplateStore.template(id: zebra.id, in: defaults).id, "general", "a deleted id falls back to General")
    }

    func testDeleteIgnoresBuiltIn() {
        let defaults = makeDefaults()
        var external = SummaryTemplateStore.template(id: "external", in: defaults)
        external.prompt = "E {{transcript}}"
        SummaryTemplateStore.save(external, in: defaults)
        defaults.set("G {{transcript}}", forKey: AppPreferenceKey.summaryPromptTemplate)

        SummaryTemplateStore.delete(id: "external", in: defaults)
        SummaryTemplateStore.delete(id: "general", in: defaults)

        XCTAssertEqual(SummaryTemplateStore.template(id: "external", in: defaults).prompt, "E {{transcript}}")
        XCTAssertEqual(SummaryTemplateStore.template(id: "general", in: defaults).prompt, "G {{transcript}}")
        XCTAssertEqual(SummaryTemplateStore.all(in: defaults).count, 6)
    }

    func testGarbageJSONFallsBackToBuiltIns() {
        let defaults = makeDefaults()
        defaults.set("{not json", forKey: AppPreferenceKey.summaryTemplates)

        XCTAssertEqual(SummaryTemplateStore.all(in: defaults), SummaryTemplateCatalog.builtIns)
        XCTAssertEqual(SummaryTemplateStore.template(id: "workshop", in: defaults), SummaryTemplateCatalog.builtIns[5])
    }

    func testUnknownIdIsGeneral() {
        let defaults = makeDefaults()
        XCTAssertEqual(SummaryTemplateStore.template(id: "nope", in: defaults), SummaryTemplateCatalog.builtIns[0])
        XCTAssertEqual(SummaryTemplateStore.template(id: nil, in: defaults).id, "general")
    }

    // MARK: - Selector

    private func select(
        _ title: String,
        participants: [String] = [],
        attendees: [MeetingAttendee] = [],
        aliases: [String] = ["Youri"]
    ) -> String {
        SummaryTemplateSelector.templateID(title: title, participants: participants, attendees: attendees, userAliases: aliases)
    }

    private let me = MeetingAttendee(name: "Youri Broekhuizen", email: "youri@medicore.nl", isCurrentUser: true)

    func testVersionAndDateTitlesAreNotOneOnOne() {
        XCTAssertNotEqual(select("Sprint 1.1 review"), "one-on-one")
        XCTAssertNotEqual(select("Wegiz 1.1"), "one-on-one")
        XCTAssertNotEqual(select("Release 1-1-2026"), "one-on-one")
        XCTAssertEqual(select("1:1 Martijn"), "one-on-one")
        XCTAssertEqual(select("1-1 Martijn"), "one-on-one")
        XCTAssertEqual(select("1op1 Martijn"), "one-on-one")
    }

    func testTwoPeopleDedupeByNamePrefix() {
        let martijn = MeetingAttendee(name: "Martijn de Hoogh", email: "martijn@medicore.nl", isCurrentUser: false)
        XCTAssertEqual(select("Afstemming", participants: ["Youri Broekhuizen", "Martijn"], attendees: [me, martijn]), "one-on-one")
        XCTAssertEqual(select("Afstemming", participants: ["Youri", "Martijn"], attendees: [me, martijn]), "one-on-one")
    }

    func testSameFirstNameWithDifferentSurnamesAreTwoPeople() {
        let hoogh = MeetingAttendee(name: "Martijn de Hoogh", email: "a@medicore.nl", isCurrentUser: false)
        let jansen = MeetingAttendee(name: "Martijn Jansen", email: "b@medicore.nl", isCurrentUser: false)
        XCTAssertEqual(select("Afstemming", attendees: [me, hoogh, jansen]), "general")
    }

    func testBilaTitleIsOneOnOne() {
        XCTAssertEqual(select("Bila Martijn"), "one-on-one")
        XCTAssertEqual(select("1-op-1 Arriejanne"), "one-on-one")
        XCTAssertEqual(select("Bilateral with Marcel"), "one-on-one")
        XCTAssertEqual(select("Marcel / Youri 1:1"), "one-on-one")
        XCTAssertEqual(select("One-on-one Kim"), "one-on-one")
    }

    func testDailyIsStandup() {
        XCTAssertEqual(select("Daily Team Link"), "standup")
        XCTAssertEqual(select("Stand-up Integrations"), "standup")
        XCTAssertEqual(select("Team standup"), "standup")
        XCTAssertEqual(select("Dagstart"), "standup")
    }

    func testRefinement() {
        XCTAssertEqual(select("Refinement IO"), "refinement")
        XCTAssertEqual(select("Sprint planning 2026.3.3"), "refinement")
        XCTAssertEqual(select("Backlog grooming"), "refinement")
        XCTAssertEqual(select("Stories refinen"), "refinement")
    }

    func testWorkshopTitle() {
        XCTAssertEqual(select("Workshop AI-adoptie"), "workshop")
        XCTAssertEqual(select("Brainstorm partnerstrategie"), "workshop")
        XCTAssertEqual(select("Hackathon kick-off"), "workshop")
    }

    func testExternalDomain() {
        let kim = MeetingAttendee(name: "Kim", email: "kim@partner.nl", isCurrentUser: false)
        let colleague = MeetingAttendee(name: "Jeroen", email: "jeroen@medicore.nl", isCurrentUser: false)
        XCTAssertEqual(select("Afstemming", attendees: [me, colleague, kim]), "external")
        XCTAssertEqual(select("Alignment", attendees: [me, colleague, kim]), "external")
        // Domains compare case-insensitively.
        let shouting = MeetingAttendee(name: "Jeroen", email: "Jeroen@MEDICORE.NL", isCurrentUser: false)
        let third = MeetingAttendee(name: "Kim Owen-Jones", email: "kim@medicore.nl", isCurrentUser: false)
        XCTAssertEqual(select("Afstemming", attendees: [me, shouting, third]), "general")
    }

    /// No `isCurrentUser` attendee: the most common domain is the user's.
    func testExternalWithoutCurrentUserUsesTheMostCommonDomain() {
        let attendees = [
            MeetingAttendee(name: "A", email: "a@medicore.nl", isCurrentUser: false),
            MeetingAttendee(name: "B", email: "b@medicore.nl", isCurrentUser: false),
            MeetingAttendee(name: "C", email: "c@ziekenhuis.nl", isCurrentUser: false),
        ]
        XCTAssertEqual(select("Overleg", attendees: attendees), "external")
        XCTAssertEqual(select("Overleg", attendees: Array(attendees.prefix(2)) + [
            MeetingAttendee(name: "D", email: "d@medicore.nl", isCurrentUser: false),
        ]), "general")
    }

    func testTwoPeopleIsOneOnOne() {
        XCTAssertEqual(select("Afstemming", participants: ["Youri", "Martijn"]), "one-on-one")
        let martijn = MeetingAttendee(name: "Martijn de Hoogh", email: "martijn@medicore.nl", isCurrentUser: false)
        XCTAssertEqual(select("Catch-up", attendees: [me, martijn]), "one-on-one")
        // The user's alias in participants and the user's attendee are one person.
        XCTAssertEqual(select("Catch-up", participants: ["Youri", "Martijn de Hoogh"], attendees: [me, martijn]), "one-on-one")
        XCTAssertEqual(select("Sync", participants: ["Youri", "Kim", "Arriejanne"]), "general")
    }

    func testTitleBeatsAttendeeHeuristics() {
        let kim = MeetingAttendee(name: "Kim", email: "kim@partner.nl", isCurrentUser: false)
        XCTAssertEqual(select("Daily", attendees: [me, kim]), "standup")
        XCTAssertEqual(select("Refinement", participants: ["Youri", "Kim"]), "refinement")
        // Stand-up wins over a 1:1 keyword in the same title.
        XCTAssertEqual(select("Daily bila"), "standup")
    }

    func testDefaultIsGeneral() {
        XCTAssertEqual(select(""), "general")
        XCTAssertEqual(select("Wegiz BgZ voortgang", participants: ["Youri", "Kim", "Jeroen"]), "general")
        XCTAssertEqual(select("Release review", participants: ["Youri"]), "general")
    }

    func testDailyInsideAWordDoesNotMatch() {
        XCTAssertEqual(select("Dailymotion review"), "general")
        XCTAssertEqual(select("Bilan Q3"), "general")
        XCTAssertEqual(select("Replanning"), "general")
    }

    func testFoldingIgnoresCaseAndDiacritics() {
        XCTAssertEqual(select("DAILY"), "standup")
        XCTAssertEqual(select("Bìla Martijn"), "one-on-one")
    }

    // MARK: - "Regenerate with…" menu (Task 9)

    func testMenuPresentationMarksCurrent() {
        let presentation = SummaryTemplateMenuPresentation(
            templates: SummaryTemplateCatalog.builtIns,
            currentID: SummaryTemplateID.oneOnOne,
            autoID: SummaryTemplateID.standup
        )
        XCTAssertEqual(presentation.currentName, "1:1 / bilateral")
        XCTAssertEqual(presentation.items.map(\.id), SummaryTemplateCatalog.builtIns.map(\.id))
        XCTAssertEqual(presentation.items.map(\.name), SummaryTemplateCatalog.builtIns.map(\.name))
        XCTAssertEqual(presentation.items.filter(\.isCurrent).map(\.id), [SummaryTemplateID.oneOnOne])
    }

    func testMenuPresentationShowsAutoWhenNoOverride() {
        let general = SummaryTemplateMenuPresentation(
            templates: SummaryTemplateCatalog.builtIns, currentID: nil, autoID: SummaryTemplateID.general)
        XCTAssertEqual(general.currentName, "General (auto)")
        XCTAssertEqual(general.items.filter(\.isCurrent).map(\.id), [SummaryTemplateID.general])

        let standup = SummaryTemplateMenuPresentation(
            templates: SummaryTemplateCatalog.builtIns, currentID: nil, autoID: SummaryTemplateID.standup)
        XCTAssertEqual(standup.currentName, "Stand-up (auto)")
        XCTAssertEqual(standup.items.filter(\.isCurrent).map(\.id), [SummaryTemplateID.standup])
    }

    /// The service treats a blank stored id as no override.
    func testMenuPresentationTreatsABlankOverrideAsAuto() {
        let presentation = SummaryTemplateMenuPresentation(
            templates: SummaryTemplateCatalog.builtIns, currentID: "  ", autoID: SummaryTemplateID.workshop)
        XCTAssertEqual(presentation.currentName, "Workshop (auto)")
        XCTAssertEqual(presentation.items.filter(\.isCurrent).map(\.id), [SummaryTemplateID.workshop])
    }

    /// A stored id whose custom template was deleted summarizes with General
    /// (the store's fallback), so the menu says General, without "(auto)".
    func testMenuPresentationFallsBackToGeneralForAnUnknownOverride() {
        let presentation = SummaryTemplateMenuPresentation(
            templates: SummaryTemplateCatalog.builtIns, currentID: "custom-gone", autoID: SummaryTemplateID.standup)
        XCTAssertEqual(presentation.currentName, "General")
        XCTAssertEqual(presentation.items.filter(\.isCurrent).map(\.id), [SummaryTemplateID.general])
    }

    func testMenuPresentationListsCustomTemplatesAndCanMarkThem() {
        let defaults = makeDefaults()
        let custom = SummaryTemplate(id: "custom-1", name: "Klantdemo", prompt: "p {{transcript}}", isBuiltIn: false)
        SummaryTemplateStore.save(custom, in: defaults)
        let presentation = SummaryTemplateMenuPresentation(
            templates: SummaryTemplateStore.all(in: defaults), currentID: "custom-1", autoID: SummaryTemplateID.general)
        XCTAssertEqual(presentation.items.last?.name, "Klantdemo")
        XCTAssertEqual(presentation.currentName, "Klantdemo")
        XCTAssertEqual(presentation.items.filter(\.isCurrent).map(\.id), ["custom-1"])
    }

    // MARK: - Settings editing (Task 9)

    /// Add copies General's current (possibly customised) prompt.
    func testNewTemplateCopiesGeneral() {
        let defaults = makeDefaults()
        defaults.set("Mijn eigen prompt {{transcript}}", forKey: AppPreferenceKey.summaryPromptTemplate)

        let new = SummaryTemplateSettingsEditing.newTemplate(in: defaults)
        XCTAssertTrue(new.id.hasPrefix("custom-"))
        XCTAssertGreaterThan(new.id.count, "custom-".count)
        XCTAssertEqual(new.name, "New template")
        XCTAssertEqual(new.prompt, "Mijn eigen prompt {{transcript}}")
        XCTAssertFalse(new.isBuiltIn)
        XCTAssertNotEqual(SummaryTemplateSettingsEditing.newTemplate(in: defaults).id, new.id)
    }

    func testOnlyCustomTemplatesCanBeDeletedAndOnlyBuiltInsReset() {
        let builtIn = SummaryTemplateCatalog.builtIns[2]
        let custom = SummaryTemplate(id: "custom-1", name: "X", prompt: "p", isBuiltIn: false)
        XCTAssertFalse(SummaryTemplateSettingsEditing.canDelete(builtIn))
        XCTAssertTrue(SummaryTemplateSettingsEditing.canDelete(custom))
        XCTAssertTrue(SummaryTemplateSettingsEditing.canReset(builtIn))
        XCTAssertFalse(SummaryTemplateSettingsEditing.canReset(custom))
    }

    /// Editing General in the section writes the legacy key the old prompt
    /// editor reads, so both editors show the same text.
    func testEditingGeneralWritesTheLegacyPromptKey() {
        let defaults = makeDefaults()
        var general = SummaryTemplateStore.template(id: SummaryTemplateID.general, in: defaults)
        general.prompt = "Aangepast {{transcript}}"
        SummaryTemplateSettingsEditing.apply(general, in: defaults)
        XCTAssertEqual(defaults.string(forKey: AppPreferenceKey.summaryPromptTemplate), "Aangepast {{transcript}}")
        XCTAssertTrue(SummaryTemplateStore.isModified(id: SummaryTemplateID.general, in: defaults))
    }

    /// A blank name on a custom template is not saved as blank: the list and
    /// the menu would show an empty row.
    func testApplyKeepsACustomTemplateNamed() {
        let defaults = makeDefaults()
        var custom = SummaryTemplateSettingsEditing.newTemplate(in: defaults)
        custom.name = "   "
        SummaryTemplateSettingsEditing.apply(custom, in: defaults)
        XCTAssertEqual(SummaryTemplateStore.template(id: custom.id, in: defaults).name, "New template")
    }
}
