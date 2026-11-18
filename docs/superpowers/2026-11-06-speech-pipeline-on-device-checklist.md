# Speech pipeline — on-device checklist

Branch `76r75r6qbh-sys/speech-pipeline-best-practices`. Run these checks on the signed test build before release. The full suite passed with the Mac unlocked (2051 tests, 0 failures). A copy of the real store opens on V3 with identical counts. Everything below is what tests cannot cover.

**Before you start:**
- Use a scratch vault, or back up the real one.
- Keep Console.app open and filtered on "Casablanca" so you see any "Update Constraints in Window" warnings.
- Voice-profile tests need the Mac unlocked; locked writes fail by design.

## 1. Benchmarks (fill in the CHANGELOG numbers)
- [ ] **Model comparison.** Run the same long Dutch meeting twice on `large-v3` and twice on `large-v3 turbo`, with `-whisperPromptTerms NO`. Turbo is acceptable if it is at least 1.25× faster and agreement is comparable. Record the WER/agreement and the speed in the CHANGELOG.
- [ ] **Whisper prompt A/B.** Run `-whisperPromptTerms NO` and `YES` twice each. Count how often the canonical spellings of names and jargon appear.
- [ ] **Word timestamps.** Compare transcription time with `-wordTimestampsEnabled NO/YES`.
- [ ] **Diarization speed.** Time a 2.5 h meeting on macOS 15+ and note how long speaker recognition takes.
- [ ] **Default model.** On a fresh account (or after `defaults delete`), check that `whisperModel` is written as `large-v3`. An existing install must keep its own model.

## 2. Speakers
- [ ] Record a Teams call. The speakers bar appears above the transcript ("Me" plus "Speaker 1…") and the percentages add up to 100.
- [ ] Press ▶ on a speaker: about 5 s of their voice plays and stops by itself. ■ stops it early.
- [ ] Rename "Speaker 1". Every prefix changes, and hand edits and terminology fixes stay.
- [ ] Rename one speaker to another speaker's confirmed name: the two merge. Renaming to another speaker's unconfirmed placeholder is refused.
- [ ] Press "Suggest names". Suggestions show with a quote, and nothing changes until you accept one.
- [ ] Room meeting with one microphone: everyone is a room speaker, and "This is me" marks you.
- [ ] Offline first run: the caption says speaker recognition is unavailable, and the transcript is unchanged.
- [ ] An old meeting looks exactly as before, with no speakers bar.

## 3. Regenerate after renaming
- [ ] Rename a speaker on a meeting that has a summary. The banner "Speakers changed — regenerate the summary?" shows above the tabs, on both the Transcript and Summary tabs.
- [ ] Press "Regenerate summary": names and owners update, accepted and rejected to-dos are kept, and an explicit template stays. ✕ hides the banner without regenerating.
- [ ] Renaming on a meeting without a summary shows no banner.

## 4. Summaries and templates
- [ ] Settings → AI → Summary Templates lists six templates; "Customize Prompt…" is gone. Editing General marks it "Modified", and Reset restores it.
- [ ] Add, rename and delete a custom template.
- [ ] A meeting titled "Daily …" shows "Template: Stand-up (auto)". "Regenerate with… → Workshop" changes the header to "Template: Workshop".
- [ ] A long meeting (Claude and Ollama): the summary covers the middle too, and every action item has an owner, date, quote and `[mm:ss]`.

## 5. To-do review (scratch vault!)
- [ ] After a summary, the strip shows proposals with ✓/⚠/? badges. Your bullets show "In review" and have no checkbox.
- [ ] **Accept one.** The to-do file gets exactly one line ending in ` — owner 📅 yyyy-MM-dd [mm:ss]`, and the sidebar count goes up by 1.
- [ ] **Accept the same one again, then refresh.** Still one line, and the text is unchanged.
- [ ] **Tick a summary bullet** that has no proposal, of the form `**Youri** — … [mm:ss]`, twice. The file must still hold one line, and the row text must be unchanged.
- [ ] **Reject one.** No file changes. **Edit one.** It stays proposed.
- [ ] **Accept all verified** accepts only the ✓ items.
- [ ] **To-dos → Review (N)** lists the proposals. Open, Done and All show no proposals and no rejected to-dos.
- [ ] **Auto-accept on.** Verified items are accepted and reach Apple Notes or the summary file without another save.
- [ ] **Accept several quickly, then press ⌘Q at once.** The export completes and no duplicate Apple Note appears.
- [ ] **Settings → To-do Review → Delete decision log.** Pressing Return in the dialog must not delete. Only "Delete" deletes.
- [ ] **Delete a meeting right after editing it.** No note or file reappears.

## 6. Clickable timestamps
- [ ] Clicking a `[mm:ss]` opens the transcript at that line, highlights it and starts playback. Test from the summary, a bullet, the review strip, the inspector panel and To-dos.
- [ ] Jump into a chapter, collapse it, and click the same timestamp again: the chapter expands again.
- [ ] Jump in meeting A, then open meeting B: B does not scroll or highlight.
- [ ] The transport bar stays visible while you scroll. Audio keeps playing when you switch tabs and stops when you leave the meeting.
- [ ] A meeting whose recording is deleted: the link scrolls, with no transport and no error.
- [ ] The gutter times are grey and clickable.

## 7. Ask
- [ ] Ask a question about a known meeting. The citations render, and a citation with a time jumps there; one without a time only opens the meeting.
- [ ] Switch Dashboard ↔ Ask ↔ a meeting several times: the detail column never goes blank.

## 8. Voice profiles (Mac unlocked, macOS 15+)
- [ ] Settings → Privacy: "Remember voices (biometric data)" is off by default and the explanation is shown.
- [ ] Toggle it on. On a named speaker with a kept track, right-click and choose "Remember voice…". Save stays disabled until consent is ticked. Saving takes seconds, and Cancel works while it runs.
- [ ] The profile is listed. In a later meeting with the same person, ✨ "Voice profile match" is suggested, and nothing is renamed automatically.
- [ ] Turn the setting off. Cancel keeps it on. "Delete profiles" removes the list and the voice suggestions. Check that `~/Library/Application Support/Casablanca/VoiceProfiles` is gone.
- [ ] Watch for a keychain prompt on the first save and after a re-sign.

## 9. Layout (every new view)
- [ ] Narrow the window and the inspector to their minimum on the summary with the strip, on the transcript with the transport and banner, and on Ask. Check for no console constraint warning and no crash.

## 10. Evaluation
- [ ] Run File → "Export Meeting for Evaluation…". Then `python3 tools/eval/casaeval.py score …` against a hand-made gold file.
