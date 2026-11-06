import Foundation

/// A summary prompt for one kind of meeting (spec B5). Built-ins ship with the
/// app and can be overridden; custom ones (`id = "custom-<UUID>"`) are the
/// user's own.
struct SummaryTemplate: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var prompt: String
    var isBuiltIn: Bool
}

/// Ids of the built-in templates. Stored on `Meeting.summaryTemplateID`, so
/// they never change.
enum SummaryTemplateID {
    static let general = "general"
    static let oneOnOne = "one-on-one"
    static let standup = "standup"
    static let refinement = "refinement"
    static let external = "external"
    static let workshop = "workshop"
}

/// The built-in templates. Each is the General prompt with its items 2.–4.
/// (the body structure) swapped for a meeting-type structure; everything the
/// pipeline relies on — the four closing sections and their headings, the
/// action-item format, every placeholder, the transcript last — is shared.
enum SummaryTemplateCatalog {
    /// Everything before item 2.
    private static let head = """
    You are a meeting assistant creating structured, high-signal meeting notes.

    Write the notes in the dominant language of the transcript (Dutch transcript -> Dutch notes, English transcript -> English notes).

    Use only the information provided below. If something is unclear or missing, leave it out instead of guessing.

    The transcript comes from machine speech recognition and may misspell names of people, companies and products. Correct obvious mistranscriptions using the terminology list and the participants list. Never invent names, and never comment on transcript quality in the notes.

    Structure the notes as follows:

    1. Start with a single `# Summary` heading (Dutch: `# Samenvatting`) followed by a 2-4 sentence paragraph: what the meeting was about and its main outcome.
    """

    /// Item 5. onwards: the closing sections, their rules and the placeholders.
    private static let tail = """
    5. End with these four sections, always present, in this order. Use exactly these headings — Dutch notes / English notes:
       `## Besluiten` / `## Decisions`
       `## Actiepunten` / `## Action Items`
       `## Risico's en blockers` / `## Risks and Blockers`
       `## Opvolging` / `## Follow-ups`

    Rules for the four closing sections:
    - Every item is a `- ` bullet. If a section has no items, keep the heading with nothing below it.
    - Decisions include their stated rationale.
    - Each action item is one bullet formatted `- **<owner>** — <action>`. Resolve the owner against the participants list; use the person's name, never "me" or "I". If no owner was stated, use `- **?** — <action>`.
    - The note-taker is {{user_name}}. When the note-taker commits to something ("I will…", "ik pak dat op"), the owner is {{user_name}}.
    - Transcript lines may start with a speaker label (`[12:34] Kim: …`). A labelled speaker's first-person commitment makes that speaker the owner. Generic labels such as "Speaker 1", "Spreker 2", "Others" or "Anderen" are not names.
    - Omit optional sections that have nothing meaningful. Never add sections about the transcript itself.

    {{terminology_list}}

    Meeting title: {{title}}
    Scheduled time: {{scheduled_time}}
    Participants: {{participants}}

    {{user_focus}}

    Transcript:
    {{transcript}}
    """

    /// `SummarizationService.defaultPromptTemplate` with its items 2.–4.
    /// replaced by `structure`.
    static func compose(structure: String) -> String {
        head + "\n" + structure + "\n" + tail
    }

    static let generalStructure = """
    2. Then 2-5 thematic sections, each with a descriptive `## <theme>` heading, containing a short intro sentence and/or `- **subtopic:** detail` bullets. Capture the reasoning behind conclusions, not just the conclusions.
    3. If the meeting discussed planning across dates, weeks or months, add a `## Planning` section with chronological bullets: `- **<period>** — <milestone or activity>`.
    4. If hiring or staffing was discussed, add a `## Personele zaken` (English: `## Personnel`) section.
    """

    static let oneOnOneStructure = """
    2. Then these sections, each only when it has content: `## Hoe gaat het` / `## Check-in` (wellbeing, workload, energy), `## Voortgang` / `## Progress` (what moved since last time), `## Feedback` (given and received, both directions, in neutral wording), `## Ontwikkeling` / `## Growth` (career, learning, goals).
    3. Keep personal remarks factual and brief; leave out anything that reads as private gossip.
    4. If the date or topics of the next 1:1 were agreed, put them under `## Opvolging` / `## Follow-ups`.
    """

    static let standupStructure = """
    2. Then one `## Per persoon` / `## Per person` section with one bullet per speaker: `- **<name>:** <yesterday> · <today> · <blockers>`. Use only what each person said.
    3. Keep it short: the opening paragraph has at most 2 sentences and there are no thematic sections.
    4. Put every blocker, with its owner, under `## Risico's en blockers` / `## Risks and Blockers`.
    """

    static let refinementStructure = """
    2. Then one `## <item>` section per backlog item or story discussed (start with its key, e.g. `IO-1234`, when it was said), with bullets for the agreed scope, open questions, acceptance criteria, the estimate (`- **Estimate:** 5 SP`) and whether it is ready for a sprint.
    3. If a sprint goal or capacity was discussed, add a `## Sprintdoel` / `## Sprint goal` section.
    4. Put items that were explicitly not ready, with the reason, under `## Risico's en blockers` / `## Risks and Blockers`.
    """

    static let externalStructure = """
    2. Then the sections `## Context` (who the other party is and why the meeting took place, only as stated), `## Hun vraag` / `## Their ask`, `## Ons standpunt` / `## Our position` and `## Afspraken` / `## Agreements` (commitments in both directions, each with the party that made it).
    3. Mark anything the other party asked to keep confidential with `(vertrouwelijk)` / `(confidential)`.
    4. If planning or the next contact was discussed, add a `## Planning` section with chronological bullets: `- **<period>** — <milestone or activity>`.
    """

    static let workshopStructure = """
    2. Then `## Doel` / `## Goal` (one sentence), followed by one `## <theme>` section per cluster of ideas, with the ideas as bullets and who raised them when that was said.
    3. Add `## Keuzes` / `## Choices` for options that were chosen or dropped, with the reason.
    4. Add `## Parkeerplaats` / `## Parking lot` for ideas deferred to later.
    """

    /// Order: General, 1:1 / bilateral, Stand-up, Refinement / planning,
    /// External / partner, Workshop.
    static let builtIns: [SummaryTemplate] = [
        builtIn(SummaryTemplateID.general, "General", generalStructure),
        builtIn(SummaryTemplateID.oneOnOne, "1:1 / bilateral", oneOnOneStructure),
        builtIn(SummaryTemplateID.standup, "Stand-up", standupStructure),
        builtIn(SummaryTemplateID.refinement, "Refinement / planning", refinementStructure),
        builtIn(SummaryTemplateID.external, "External / partner", externalStructure),
        builtIn(SummaryTemplateID.workshop, "Workshop", workshopStructure),
    ]

    static func builtIn(id: String) -> SummaryTemplate? {
        builtIns.first { $0.id == id }
    }

    private static func builtIn(_ id: String, _ name: String, _ structure: String) -> SummaryTemplate {
        SummaryTemplate(id: id, name: name, prompt: compose(structure: structure), isBuiltIn: true)
    }
}

/// Reads and writes templates in `UserDefaults`.
///
/// General's prompt lives in the legacy `summaryPromptTemplate` key (still
/// edited by today's Settings prompt editor), so a user's existing customised
/// prompt *is* the General template — nothing is copied or lost. Overrides of
/// the other built-ins and custom templates are a JSON `[SummaryTemplate]` in
/// `summaryTemplates`; `""` or unreadable JSON means built-ins only.
enum SummaryTemplateStore {
    /// Built-ins in catalog order (overrides applied), then custom templates by
    /// name (case-insensitive, id as tie-break).
    static func all(in defaults: UserDefaults) -> [SummaryTemplate] {
        let stored = storedTemplates(in: defaults)
        let builtIns = SummaryTemplateCatalog.builtIns.map { resolvedBuiltIn($0, stored: stored, defaults: defaults) }
        let custom = stored
            .filter { SummaryTemplateCatalog.builtIn(id: $0.id) == nil }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        return builtIns + custom
    }

    /// The template with `id`; nil, empty or unknown is General.
    static func template(id: String?, in defaults: UserDefaults) -> SummaryTemplate {
        let templates = all(in: defaults)
        return templates.first { $0.id == id } ?? templates[0]
    }

    /// General writes the legacy prompt key (removed when it equals the
    /// default). Another built-in stores its prompt as an override (dropped when
    /// it equals the built-in); its name and `isBuiltIn` stay the catalog's. A
    /// custom template is added, or replaced by id.
    static func save(_ template: SummaryTemplate, in defaults: UserDefaults) {
        if template.id == SummaryTemplateID.general {
            if template.prompt == SummaryTemplateCatalog.builtIns[0].prompt {
                defaults.removeObject(forKey: AppPreferenceKey.summaryPromptTemplate)
            } else {
                defaults.set(template.prompt, forKey: AppPreferenceKey.summaryPromptTemplate)
            }
            return
        }
        var stored = storedTemplates(in: defaults).filter { $0.id != template.id }
        if let builtIn = SummaryTemplateCatalog.builtIn(id: template.id) {
            if template.prompt != builtIn.prompt {
                stored.append(SummaryTemplate(id: builtIn.id, name: builtIn.name, prompt: template.prompt, isBuiltIn: true))
            }
        } else {
            var custom = template
            custom.isBuiltIn = false
            stored.append(custom)
        }
        write(stored, to: defaults)
    }

    /// Removes a custom template; built-ins are ignored (use `reset`).
    static func delete(id: String, in defaults: UserDefaults) {
        guard SummaryTemplateCatalog.builtIn(id: id) == nil else { return }
        let stored = storedTemplates(in: defaults)
        guard stored.contains(where: { $0.id == id }) else { return }
        write(stored.filter { $0.id != id }, to: defaults)
    }

    /// Built-in: drops its override; General: removes `summaryPromptTemplate`.
    /// Custom templates are left alone.
    static func reset(id: String, in defaults: UserDefaults) {
        if id == SummaryTemplateID.general {
            defaults.removeObject(forKey: AppPreferenceKey.summaryPromptTemplate)
            return
        }
        guard SummaryTemplateCatalog.builtIn(id: id) != nil else { return }
        let stored = storedTemplates(in: defaults)
        guard stored.contains(where: { $0.id == id }) else { return }
        write(stored.filter { $0.id != id }, to: defaults)
    }

    /// Whether a built-in's prompt differs from the shipped one. Custom
    /// templates are never "modified".
    static func isModified(id: String, in defaults: UserDefaults) -> Bool {
        guard let builtIn = SummaryTemplateCatalog.builtIn(id: id) else { return false }
        return template(id: id, in: defaults).prompt != builtIn.prompt
    }

    // MARK: - Storage

    private static func resolvedBuiltIn(_ builtIn: SummaryTemplate, stored: [SummaryTemplate], defaults: UserDefaults) -> SummaryTemplate {
        var resolved = builtIn
        if builtIn.id == SummaryTemplateID.general {
            if let legacy = defaults.string(forKey: AppPreferenceKey.summaryPromptTemplate) {
                resolved.prompt = legacy
            }
        } else if let override = stored.first(where: { $0.id == builtIn.id }) {
            resolved.prompt = override.prompt
        }
        return resolved
    }

    /// Overrides and custom templates; `[]` for `""`, a missing key or JSON
    /// that does not decode. General is never stored here (an entry is ignored).
    private static func storedTemplates(in defaults: UserDefaults) -> [SummaryTemplate] {
        guard let raw = defaults.string(forKey: AppPreferenceKey.summaryTemplates),
              !raw.isEmpty,
              let decoded = try? JSONDecoder().decode([SummaryTemplate].self, from: Data(raw.utf8)) else {
            return []
        }
        return decoded.filter { $0.id != SummaryTemplateID.general }
    }

    private static func write(_ templates: [SummaryTemplate], to defaults: UserDefaults) {
        guard !templates.isEmpty else {
            defaults.set("", forKey: AppPreferenceKey.summaryTemplates)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(templates), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: AppPreferenceKey.summaryTemplates)
    }
}

/// Picks a template from the meeting's title and who was invited. Pure and
/// deterministic; the first matching rule wins:
/// 1. title words (case- and diacritic-folded, whole words only):
///    stand-up → refinement/planning → workshop → 1:1;
/// 2. an attendee e-mail outside the user's domain → External;
/// 3. exactly two people → 1:1;
/// 4. otherwise General.
enum SummaryTemplateSelector {
    private static let titleRules: [(id: String, keywords: [String])] = [
        (SummaryTemplateID.standup, ["stand-up", "standup", "daily", "dagstart"]),
        (SummaryTemplateID.refinement, ["refinement", "refinen", "planning", "sprintplanning", "grooming", "backlog"]),
        (SummaryTemplateID.workshop, ["workshop", "brainstorm", "hackathon"]),
        (SummaryTemplateID.oneOnOne, ["bila", "bilateral", "bilateraal", "1-op-1", "1:1", "1on1", "1op1", "1-1", "one-on-one"]),
    ]

    static func templateID(
        title: String,
        participants: [String],
        attendees: [MeetingAttendee],
        userAliases: [String]
    ) -> String {
        // Padded so a keyword only matches whole words ("daily" ≠ "dailymotion").
        let foldedTitle = " " + FuzzyText.normalized(protectingVersionsAndDates(title)) + " "
        for rule in titleRules where rule.keywords.contains(where: { keyword in
            let folded = FuzzyText.normalized(keyword)
            return !folded.isEmpty && foldedTitle.contains(" " + folded + " ")
        }) {
            return rule.id
        }
        if hasExternalAttendee(attendees) {
            return SummaryTemplateID.external
        }
        if peopleCount(participants: participants, attendees: attendees, userAliases: userAliases) == 2 {
            return SummaryTemplateID.oneOnOne
        }
        return SummaryTemplateID.general
    }

    /// The user's domain is the `isCurrentUser` attendee's, else the most
    /// common attendee domain (alphabetically first on a tie). Any attendee
    /// with another domain makes the meeting external.
    private static func hasExternalAttendee(_ attendees: [MeetingAttendee]) -> Bool {
        let domains = attendees.compactMap { domain(of: $0.email) }
        guard !domains.isEmpty else { return false }
        let userDomain: String
        if let own = attendees.first(where: \.isCurrentUser).flatMap({ domain(of: $0.email) }) {
            userDomain = own
        } else {
            let counts = Dictionary(domains.map { ($0, 1) }, uniquingKeysWith: +)
            userDomain = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }[0].key
        }
        return domains.contains { $0 != userDomain }
    }

    private static func domain(of email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// "1.1" (a version) and "1-1-2026" (a date) would fold to "1 1" and match the
    /// "1:1"/"1-1" keywords; spell their separators out so they stay distinct.
    private static func protectingVersionsAndDates(_ title: String) -> String {
        var result = title.replacingOccurrences(
            of: #"(?<=\d)\.(?=\d)"#, with: "dot", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?<=\d)[-/](?=\d{1,4}[-/]\d)|(?<=\d[-/]\d{1,4})[-/](?=\d)"#, with: "dash", options: .regularExpression)
        return result
    }

    /// Distinct people in participants ∪ attendees. Names are folded to word
    /// sets; one name is the same person as another when its words are a subset
    /// of the other's ("Martijn" ⊂ "Martijn de Hoogh"), while "Martijn de Hoogh"
    /// and "Martijn Jansen" stay two. The user (an `isCurrentUser` attendee, or a
    /// name matching one of the user's aliases or the current user's full name
    /// this way) counts once; a nameless attendee counts by e-mail.
    private static func peopleCount(participants: [String], attendees: [MeetingAttendee], userAliases: [String]) -> Int {
        func words(_ name: String) -> Set<String> {
            Set(FuzzyText.normalized(name).split(separator: " ").map(String.init))
        }
        func related(_ a: Set<String>, _ b: Set<String>) -> Bool {
            a.isSubset(of: b) || b.isSubset(of: a)
        }
        var mine = userAliases.map(words).filter { !$0.isEmpty }
        mine += attendees.filter(\.isCurrentUser).map { words($0.name) }.filter { !$0.isEmpty }

        var userSeen = attendees.contains(where: \.isCurrentUser)
        var others: [Set<String>] = []
        func add(_ name: String) {
            let w = words(name)
            guard !w.isEmpty else { return }
            if mine.contains(where: { related($0, w) }) {
                userSeen = true
            } else if let i = others.firstIndex(where: { related($0, w) }) {
                if w.count > others[i].count { others[i] = w }
            } else {
                others.append(w)
            }
        }
        participants.forEach(add)
        for attendee in attendees where !attendee.isCurrentUser {
            let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            add(name.isEmpty ? (attendee.email ?? "") : name)
        }
        return others.count + (userSeen ? 1 : 0)
    }
}
