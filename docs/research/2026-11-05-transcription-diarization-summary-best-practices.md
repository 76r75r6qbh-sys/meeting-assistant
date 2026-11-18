# Casablanca: best practices en verbeterpunten voor transcriptie, sprekers en samenvatting

## Context
Youri wilde weten hoe andere speech-to-text-meetingapps (Granola, Otter, Fireflies, Fathom, Teams Copilot, Zoom, Gemini, Notion, Jamie, Krisp) transcriptie, sprekerherkenning en samenvatting aanpakken. Het doel is een lijst best practices en verbeterpunten voor Casablanca. Het onderzoek is gedaan door drie agents: een kaart van de code en twee webonderzoeken. Dit plan bevat het resultaat. **De enige uitvoerstap is het rapport als bestand vastleggen. Er wordt geen code gewijzigd.**

## Waar Casablanca nu staat (uit de code)
- **Opname.** De microfoon (AVAudioEngine) en de systeemaudio (ScreenCaptureKit) worden **apart** opgenomen. Daarna worden ze **gemengd tot één mono-WAV** (`RecordingMixdownRenderer.swift:137-156`) en worden de losse sporen verwijderd (`:127,130`). Het gratis onderscheid tussen "ik" en "de anderen" gaat zo verloren.
- **Transcriptie.** WhisperKit draait on-device. Het standaardmodel is `base` (`Models/Meeting.swift:51`). Er is één taal per meeting en geen automatische taaldetectie. Timestamps zijn er alleen per segment (`wordTimestamps: false`), en Whisper krijgt geen prompt met vakjargon mee.
- **Sprekers.** Er is **geen** diarization, er zijn geen sprekerlabels en het onderscheid ik/zij ontbreekt ook. De eigenaar van een actie wordt door de LLM afgeleid uit de inhoud, met jouw naam als hint.
- **Samenvatting.**
  - Een sjabloon met vaste secties (Summary, thema's, Decisions, Action Items `**owner** — actie`, Risks, Follow-ups).
  - Map-reduce wordt alleen gebruikt als de tekst het budget overschrijdt (v0.19.1).
  - To-do's worden **na afloop uit de markdown van de samenvatting geparsed**. Alleen jouw eigen items worden een TodoItem.
  - TodoItem heeft **geen** eigenaar, deadline, timestamp of bronverwijzing.
- **Overig.** Prepnotities gaan **niet** mee in de samenvattingsprompt. Van de deelnemers worden alleen namen meegestuurd, zonder e-mail en zonder markering wie "ik" is. Er is geen kwaliteitsmeting van samenvattingen.

## Best practices uit de markt en de literatuur

### Sprekerherkenning
1. **Scheid de kanalen.** Granola labelt de microfoon als "Me" en de systeemaudio als "Them". Platforms als Teams en Zoom kennen per stream de deelnemer. Dit is betrouwbaar en vraagt geen ML. [Granola](https://docs.granola.ai/help-center/taking-notes/speaker-attribution), [Recall](https://docs.recall.ai/docs/diarization)
2. **Gebruik akoestische diarization voor de rest.** De standaard is pyannote-achtig: segmentatie, embeddings en clustering, met een DER van ongeveer 15-20%. On-device in Swift kan dat met **FluidAudio** (Apache-2.0, CoreML, ongeveer 122× realtime). De offline variant is beter dan streaming. [FluidAudio](https://docs.fluidinference.com/diarization/getting-started.md)
3. **Laat sprekers corrigeren.** Overal is dat standaard: een spreker hernoemen, met per spreker een geluidsfragment zoals bij Jamie. Zo'n correctie traint het systeem bij Otter en Jamie.
4. **Laat de LLM namen afleiden.** Geef de LLM de deelnemerslijst uit de agenda en vraag om bewijs, zoals "Jan, kun jij…" of een voorstelronde. Zonder bewijs is het antwoord "Unknown". [arXiv 2509.15082](https://arxiv.org/html/2509.15082v1)
5. **Voiceprints kunnen alleen op basis van opt-in.** Een stemprofiel geldt als biometrisch gegeven (AVG art. 9), dus er zijn expliciete toestemming en een DPIA nodig. De AP is kritisch op toestemming tussen werkgever en werknemer. Teams heeft dit om die reden standaard uit staan. [Teams voice recognition](https://learn.microsoft.com/microsoftteams/rooms/voice-recognition)
6. **Valkuilen.**
   - Echo: bij een process tap lekken stemmen van de systeemaudio in de microfoon, dus echo-onderdrukking is nodig.
   - Overlap en korte beurten ("ja", "klopt").
   - Meerdere mensen in één ruimte op één microfoon.
   - Modellen zijn vooral op Engels getraind, dus het moet op eigen Nederlandse opnames getest worden.

### Van transcript naar samenvatting
7. **Haal eerst feiten eruit, schrijf daarna de samenvatting.** Haal per chunk gestructureerde feiten op (besluiten, toezeggingen, open vragen, steeds met `[mm:ss]`) en schrijf daar de samenvatting van. Dat geeft minder hallucinatie en minder omissie (FRAME, EMNLP 2025). [arXiv 2509.15901](https://arxiv.org/html/2509.15901v1)
8. **Vertrouw niet blind op één lange pass.** Bij "lost in the middle" krijgt het midden van een meeting minder aandacht. Chunken helpt ook bij grote contextvensters. [arXiv 2307.03172](https://arxiv.org/abs/2307.03172v3), [Interspeech 2025](https://www.cs.columbia.edu/speech/PaperFiles/2025/comparison_gong25c_interspeech.pdf)
9. **Segmenteer op onderwerp en haal acties per segment op.** Dat werkt beter dan lineair chunken. [arXiv 2312.17581](https://arxiv.org/pdf/2312.17581)
10. **Gebruik een strikt schema voor actiepunten:** `{task, owner|null, due|null, due_is_explicit, confidence, quote, timestamp}`.
    - Een eigenaar alleen bij expliciet bewijs, anders null.
    - "Vrijdag" omrekenen naar een datum ten opzichte van de meetingdatum.
    - Altijd een letterlijk citaat meegeven.
11. **Draai een controlepass.** Een tweede LLM-stap toetst elk actiepunt en besluit aan het citaat of de transcriptpassage en markeert onjuiste of verzonnen items. [COLING 2025](https://aclanthology.org/2025.coling-main.143)
12. **Verwijs naar de bron.** Granola, Otter en Gemini linken elk punt naar een timestamp in het transcript. Dat maakt de samenvatting controleerbaar en bouwt vertrouwen op.
13. **Gebruik de notities van de gebruiker als stuur.** Granola gebruikt je ruwe notities als "wat vind ik belangrijk". **Templates per soort meeting** (1-op-1, standup, partnergesprek) zijn overal standaard.
14. **Corrigeer ASR-fouten gericht.** Gebruik woordenlijst-prompting in Whisper (maximaal 224 tokens) en een deterministische vervangingsstap. Laat de LLM niet alles herschrijven.
15. **De gebruiker keurt to-do's goed vóór de sync.** Toon het citaat, de timestamp en de confidence, en noem een deadline "voorgesteld".
16. **Meet de kwaliteit.**
    - ROUGE zegt weinig. Gebruik een foutentaxonomie (omissie, hallucinatie, verkeerde persoon) en QA-checks.
    - Bouw een kleine Nederlandse gold-set uit eigen meetings.
    - Log wat er met to-do's gebeurt (geaccepteerd, aangepast, verwijderd) als precisiesignaal.

## Verbeterpunten voor Casablanca (geprioriteerd)

| # | Verbeterpunt | Waarom | Grootte |
|---|---|---|---|
| 1 | **Microfoon- en systeemspoor apart bewaren en apart transcriberen.** Zet in het transcript `Ik:` / `Anderen:` per regel. | Grootste winst voor het toewijzen van acties. De sporen bestaan al en worden nu weggegooid (`RecordingMixdownRenderer`). De gemengde m4a blijft bestaan voor afspelen. | M |
| 2 | **Echo-onderdrukking of een bleed-check** tussen de microfoon en het systeemspoor. | Zonder dit belanden de stemmen van anderen in "Ik". | M |
| 3 | **Diarization van het systeemspoor met FluidAudio** (offline, na afloop). Voor gesprekken in een ruimte ook het microfoonspoor. Dat geeft labels "Spreker A/B…". | Onderscheid tussen meerdere externe deelnemers. | L |
| 4 | **Sprekers hernoemen in de UI**, met een geluidsfragment per spreker. Daarna **LLM-voorstel voor namen** op basis van de agendadeelnemers, door jou te bevestigen. | Zo worden labels namen. | M |
| 5 | **Actiepunten als gestructureerde data**, niet geparsed uit markdown. Een JSON-schema met owner, due, citaat, timestamp en confidence. TodoItem krijgt de velden `owner`, `dueDate`, `sourceTimestamp`, `quote`. | Bronverwijzing, deadlines en acties van anderen zichtbaar. | M |
| 6 | **De map-stap altijd gebruiken voor feitenextractie** (ook bij Claude, met grotere chunks). Haal to-do's uit de chunks, niet uit de eindsamenvatting. | "Lost in the middle" en acties die laat in de meeting vallen. | M |
| 7 | **Een verificatiepass** die elk actiepunt en besluit naast het citaat legt, met een vlag als het niet onderbouwd is. | Minder verzonnen of verkeerd toegewezen acties. | S |
| 8 | **Klikbare timestamps** in de samenvatting die naar de transcriptregel en de audio springen. | Controleerbaarheid. | S-M |
| 9 | **Prepnotities en jouw notities als stuur** in de prompt, met "wat ik belangrijk vind" voorop. Markeer in de deelnemerslijst wie jij bent en neem e-mailadressen mee. | Relevantie, en jij als eigenaar herkenbaar. | S |
| 10 | **Templates per soort meeting** (bilateraal, standup, refinement, partner, extern) met automatische keuze op basis van titel of agenda. Plus **opnieuw genereren met een ander template**. | Een vast sjabloon past niet op elke meeting. | M |
| 11 | **Whisper-prompt met de terminologielijst** (de belangrijkste termen, maximaal 224 tokens), en **controleren of het standaardmodel `base` nog klopt**. De benchmarks zijn op large-v3 gedaan. | Minder fouten in namen en vakjargon bij de bron. | S |
| 12 | **Woord-timestamps aan** (nodig om diarization goed uit te lijnen met de tekst). | Voorwaarde voor #3. | S |
| 13 | **Goedkeurstap voor to-do's** vóór de sync naar Obsidian: tonen met citaat en confidence, accepteren, aanpassen of weggooien. Log die keuzes. | Vertrouwen, en gratis kwaliteitsdata. | M |
| 14 | **Evaluatieset:** 10-15 eigen Nederlandse meetings met handmatige "gouden" besluiten en acties, plus een script dat recall en precisie van actiepunten meet. Zo te gebruiken bij elke prompt- of modelwijziging. | Nu is kwaliteit niet meetbaar. | M |
| 15 | **Vragen over meerdere meetings** ("wat spraken we met Prakikon af?") met bronverwijzingen. | Veelgevraagde functie bij concurrenten. | L |
| 16 | *(Optioneel, alleen na DPIA)* Een **lokale stemprofiel-optie per persoon**, versleuteld, met expliciete toestemming. Standaard uit. | Namen herkennen over meetings heen. Juridisch gevoelig. | L |

**Aanbevolen volgorde:** eerst 1, 2, 12 en 11 (de basis voor sprekers). Daarna 5, 6 en 7 (betrouwbare acties). Dan 4, 8, 9 en 13 (UX). Als laatste 3, 10, 14 en 15. 16 alleen als er een bewuste keuze is gemaakt.

