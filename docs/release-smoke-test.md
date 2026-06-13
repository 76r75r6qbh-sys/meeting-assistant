# Release smoke test (fresh user account)

Manual pre-release checklist. The goal is to exercise the **first-run experience**
as a brand-new user would see it — including TCC permission prompts, which only
appear once per app identity per macOS account. Run this on a **fresh macOS user
account** (System Settings → Users & Groups → add a throwaway user) so the
permission state is clean and you actually see the system prompts.

> Casablanca is unsigned beyond Apple Development / ad-hoc (no paid Apple
> Developer account). On a machine that has never run this build, Gatekeeper may
> require a right-click → Open the first time. That is expected; it is not a bug
> in this checklist.

## 0. Pre-flight

- [ ] Build the release bundle: `./scripts/build-release.sh`
- [ ] Copy `Casablanca.app` to `/Applications` (the auto-updater requires this).
- [ ] Have a local LLM running (Ollama default, e.g. `ollama serve` with a model
      pulled) so the summarize step can be exercised.
- [ ] Have an Obsidian vault folder ready, and Apple Notes signed in.

## 1. Launch & onboarding

- [ ] First launch shows the onboarding sheet (4 steps).
- [ ] **Step 1 (Welcome)** explains local-first / nothing-in-cloud.
- [ ] **Step 2 (Storage)** lets you pick export destination + Obsidian vault.
      Verify the vault picker (Browse…) writes a valid path.
- [ ] **Step 3 (Permissions)** lists Microphone, Screen Recording (system audio),
      Calendar — each with a one-line explanation of what it captures and whether
      it's optional.
- [ ] **Step 4 (LLM)** probes the configured provider and shows reachable / model
      count (or a clear unreachable message + Retry).
- [ ] You can move forward with **Skip** at any non-final step — onboarding never
      hard-blocks.

## 2. Permissions — grant path

- [ ] **Microphone → Grant**: system prompt appears; granting flips the row to
      "Granted".
- [ ] **Screen Recording → Grant**: system prompt + System Settings → Privacy &
      Security → Screen Recording opens. Enable Casablanca. (macOS typically
      requires a relaunch before the grant reads back as authorized.)
- [ ] **Calendar → Grant**: system prompt appears; granting flips the row.
- [ ] With **mic + screen both granted**, the capture banner reads
      **"Full capture ready"** (green check).

## 3. Permissions — deny / graceful degradation

This is the important regression surface for this release.

- [ ] **Deny Screen Recording** (leave it off in System Settings). With
      microphone granted, the onboarding capture banner reads
      **"Microphone-only recording"** and explains that the other participants
      are not captured. Onboarding still lets you continue/finish.
- [ ] Start a recording in this mic-only state: **it must succeed** and capture
      your own voice (system audio simply absent). It must NOT error out on the
      missing Screen Recording permission.
- [ ] **Deny Microphone**: the banner reads **"Microphone needed to record"**
      (amber warning). Attempting to record should surface a clear mic-permission
      error rather than crashing.
- [ ] **Deny Calendar**: app still works; the upcoming-meetings UI is empty /
      shows a prompt to grant, manual meetings still work.

## 4. Record → transcribe → summarize

- [ ] Create a manual meeting (or start from a calendar event).
- [ ] Record ~30–60s of speech (talk, and if testing full capture, play some
      audio so system-audio has signal).
- [ ] Stop the recording — finalize completes, a recording file is produced.
- [ ] Transcribe — WhisperKit produces a transcript (first run may download a
      model; allow time).
- [ ] Summarize with the local LLM running — a summary draft is produced. Confirm
      a clear error (not a hang) if the LLM endpoint is down.

## 5. Export

- [ ] **Export to Obsidian**: the summary + notes files land in the configured
      vault with the expected `YYYY-MM-DD Meeting Name.md` naming.
- [ ] **Export to Apple Notes**: requires the Apple Events (automation) prompt —
      grant it. Verify a note is created. Denying automation should give a clear
      error, not a silent failure.

## 6. Recovery from denied permissions

- [ ] Re-run onboarding from Settings, or open System Settings and toggle a
      previously-denied permission ON, relaunch, and confirm the corresponding
      row/banner now reflects the grant and the capability works.
- [ ] Confirm that going from mic-only → full capture (after enabling Screen
      Recording + relaunch) now records both sides.

## 7. About panel / metadata

- [ ] **Casablanca → About Casablanca** shows the version and the **Credits**
      (third-party attributions: WhisperKit, TOAST UI Editor).
- [ ] Copyright string is present (`© 2026 Casablanca`), visible in About and in
      `Casablanca.app/Contents/Info.plist` (`NSHumanReadableCopyright`).
