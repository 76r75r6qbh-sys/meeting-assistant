# Transcription benchmarks

**Point-in-time measurement.** Everything below was measured on one machine, with one
pinned WhisperKit revision, on one recording. It is a record of what was true on
2026-09-04 and 2026-09-07 — not a standing claim about the pipeline. Any change to the
model, the WhisperKit revision, macOS, or the hardware invalidates these numbers; re-run
the harness (see [Reproducing](#reproducing)) rather than reasoning from this page.

## Setup

| | |
|---|---|
| Hardware | Apple M4 Pro |
| OS | macOS 27 |
| Engine | WhisperKit, pinned revision `d447d308` |
| Model | `openai_whisper-large-v3` |
| Audio | `Benchmarks/vzvz-44min.m4a` — a 44-minute Dutch meeting, 2650 s, AAC |
| Reference | `vzvz-44min.reference.txt` — the app's own earlier transcript of this meeting, made from the WAV before compression. Not human ground truth. |

Each variant was run twice. `transcribeWall` is wall-clock transcription time excluding
model load; `speed ×` is 2650 s of audio divided by that. `enc`/`dec` counters are summed
across concurrent workers, so with 16 workers they are far larger than the wall clock.

## Campaign, 2026-09-04

Release build of `934f477`. Concurrent `xcodebuild` runs in other worktrees added CPU
noise; the metric is ANE-bound, so the effect is small but non-zero.

| variant | run | modelLoad s | transcribeWall s | speed × | windows | fallback windows | vs baseline-r2 % | vs reference % |
|---|---|---|---|---|---|---|---|---|
| baseline ane/ane w16 fb5 | r1 | 26.0 (cold) | 660.9 | 4.01 | 127 | 1 | 0.56 (noise floor) | 10.66 |
| baseline | r2 | 3.8 | 667.6 | 3.97 | 127 | 1 | — | 10.37 |
| A ane/ane w4 | r1 | 3.7 | 671.6 | 3.95 | 127 | 1 | 0.33 | 10.25 |
| A | r2 | 3.6 | 667.5 | 3.97 | 127 | 1 | 0.56 | 10.67 |
| B gpu-enc/ane-dec w4 | r1 | 6.9 | 649.5 | 4.08 | 127 | 1 | 3.38 | 10.41 |
| B | r2 | 5.4 | 674.9 | 3.93 | 127 | 1 | 3.26 | 10.62 |
| C gpu-enc/ane-dec w8 | r1 | 5.7 | 705.0 | 3.76 | 127 | 1 | 3.06 | 10.22 |
| C | r2 | 6.7 | 984.8 | 2.69 | 127 | 1 | 3.12 | 10.29 |
| D ane-enc/gpu-dec w4 | r1 | 10.6 | 1051.4 | 2.52 | 127 | 1 | 2.01 | 10.34 |
| D | r2 | 6.3 | 958.5 | 2.77 | 127 | 1 | 2.05 | 10.26 |
| E ane-enc/gpu-dec w8 | r1 | 8.6 | 993.9 | 2.67 | 127 | 1 | 4.74 | 12.76 |
| E | r2 | 6.9 | 955.5 | 2.77 | 127 | 1 | 4.98 | 12.85 |
| F = B + fb2 | r1 | 6.4 | 640.2 | 4.14 | 127 | 1 | 3.26 | 10.58 |
| F | r2 | 5.6 | 8532.4 (invalid) | 0.31 | 127 | 1 | 3.27 | 10.63 |

In the 4-worker baseline-equivalent run the encoder accounts for ≈ 185 s of work against
≈ 2140 s in the decoder: **decoding dominates**, and the pipeline is ANE-bound.

**Noise floor: 0.56 % word disagreement** between two identical baseline runs. Every
variant except E sits at 10.2–10.7 % from the reference, so that ~10 % offset is the
AAC/pipeline difference against the reference transcript, not a regression.

**F-r2 is an outlier and is discarded.** `pmset -g log` shows a Clamshell Sleep at
15:32:30 during the run. The transcription power assertion prevents *idle* sleep, not
lid-close sleep — that is by design, so the run is a measurement error, not a bug.

## Follow-up runs, 2026-09-07

Release build of `dfed67e` (the commit that adds the `whisperChunking` /
`whisperDropSilentChunks` keys), same file, same Mac. `base2` is a fresh baseline on that
build so variant H is compared like-for-like; it reproduces the 2026-09-04 baseline to
within the noise floor (666 s vs 667.6 s, 0.41 % disagreement), so the build itself did
not move the metric.

| variant | run | modelLoad s | transcribeWall s | speed × | windows | fallback windows | vs baseline-r2 % | vs reference % |
|---|---|---|---|---|---|---|---|---|
| base2 vad ane/ane w16 fb5 | r1 | 12.0 | 666 | 3.98 | 127 | 1 | 0.41 | 10.20 |
| H `chunking none` ane/ane fb5 | r1 | 4.0 | 974 | 2.72 | 97 | 0 | 17.91 | 18.17 |
| H | r2 | — | discarded | — | — | — | — | — |
| I vad + `dropSilentChunks` | — | not run | — | — | — | — | — | — |

Extra counters: base2 `tokens=13697 enc=616s dec=8961s` (both summed across 16 concurrent
workers, hence ≫ wall clock); H `tokens=13264 enc=82s dec=973s` (serial, so `dec` ≈ wall).
H-r1 against base2 directly: 17.84 % disagreement. H needed no temperature fallback at all
(`fbHist=0:97`).

H-r2 was accidentally launched twice ~40 s apart (a detached-shell retry that turned out to
have survived), so its timing was contended and invalid; both processes were killed and the
run discarded. Variant I was not run: with `none` rejected on speed, `vad` stays the
default, and I was only ever expected to shave the handful of silent chunks on this dense
file.

## Findings

1. **The pipeline is ANE-bound at ≈ 4.0× realtime for `large-v3` on this Mac, and none of
   the tested knobs move it.** Decoding dominates (encoder ≈ 185 s vs decoder ≈ 2140 s of
   work in the 4-worker run).
2. **Workers 16 → 4: no change.** Same wall clock, less memory.
3. **Encoder on GPU: no change in speed.** Numerically different output (3.3 % from
   baseline) but the same distance to the reference, so no quality change either.
4. **Decoder on GPU: 1.4–1.6× SLOWER.** With 8 workers it is also measurably worse in
   quality (E: 12.8 % disagreement from the reference vs ~10.4 % for everything else).
5. **Temperature fallback is not a lever on real meeting audio.** 126 of 127 windows decode
   at t = 0. `temperatureFallbackCount 5 → 2` changes nothing measurable (F ≈ B).
6. **`chunkingStrategy none` is slower, not faster.** WhisperKit's sequential seek loop
   produced 97 windows instead of 127 (‑24 %, exactly as predicted from the window-padding
   arithmetic: 127 windows × 30 s of padded audio against 2650 s of real audio is 44 %
   padding), and its encoder time collapsed from 616 s of summed worker time to 82 s
   serial. But the run was **46 % slower in wall clock** (974 s vs 666 s) because the seek
   loop decodes one window at a time: 973 s of serial decoding replaces 8961 s of decoding
   spread over 16 workers. Concurrency saturates somewhere around 4 workers, but *one*
   in-flight window is far worse — the ANE is not saturated by a single decode stream, so
   the padding overhead is more than paid for by keeping it fed.
7. **Noise floor between two identical runs is 0.56 % word disagreement.** Any comparison
   inside that band says nothing.
8. **Model keep-alive saves 20–25 s per meeting on a cold load** (26.0 s cold vs 3.8 s
   warm).

H's quality was spot-checked (first 20 transcript lines against base2): no dropped or
duplicated sentences, same timestamps to within a second or two, close word counts (7458
vs 7569). The 18 % distance is rewording, not loss — H is sometimes better on proper nouns
and vocabulary (prompt context carrying between windows) and worse elsewhere. Since the
reference is itself a VAD-chunked transcript of this meeting, the 10.2 % vs 18.2 % gap
partly measures similarity-to-VAD rather than accuracy. There is no human ground truth for
this file.

## Decision: defaults stay as measured

`TranscriptionOptionsBuilder` keeps:

| default | value |
|---|---|
| encoder compute | `ane` (`.cpuAndNeuralEngine`) |
| decoder compute | `ane` (`.cpuAndNeuralEngine`) |
| workers | 16 |
| temperature fallback count | 5 |
| chunking | `vad` |
| silent-chunk filter | off |

Nothing measured beat the shipped configuration, so nothing was flipped. Variant H failed
its gate ("≥ 1.25× baseline with disagreement ≤ noise floor + 1 point") by a wide margin:
0.68× and 17.9 %. Workers could drop to 4 for the same speed and less memory, but that is
not a speed win and 16 is WhisperKit's own macOS default, so it stays.

The hidden `whisper…` keys remain in the builder for future tuning, and the harness makes
any proposed change measurable in a single run.

**What did land for perceived speed**, all outside the decoding options:

- **Model keep-alive** — saves the 20–25 s cold model load per meeting when Claude Code is
  the LLM provider.
- **Compression moved after export** — the transcript appears before the `.m4a` is written,
  so the useful output is not waiting behind the encode.
- **An idle-sleep power assertion during transcription** — a long run no longer stalls
  because the Mac went to sleep. (It does not, and cannot, prevent clamshell sleep; see the
  F-r2 outlier.)

**The honest ceiling.** With `large-v3` on this WhisperKit build, ~4× realtime is close to
the hardware limit on this Mac. A 2–3× jump needs a decoder change, not a setting — the
obvious candidate is `openai_whisper-large-v3_turbo`, which keeps the same encoder and
swaps in a distilled 4-layer decoder. That is out of scope here (the constraint was to keep
the model), and it is measurable with the harness in one run whenever it is in scope.

## Reproducing

Build a Release binary (`scripts/build-release.sh`) and run it against a benchmark file in
`~/Library/Application Support/Casablanca/Benchmarks/`. Any of the hidden keys can be
passed on the command line, so no rebuild is needed between variants:

```bash
/Applications/Casablanca.app/Contents/MacOS/Casablanca \
  --benchmark-transcription "$HOME/Library/Application Support/Casablanca/Benchmarks/vzvz-44min.m4a" \
  --benchmark-variant baseline \
  -whisperFallbackCount 5 -whisperWorkers 16
```

The run writes `<yyyyMMdd-HHmmss>-<variant>.json` (timings plus the resolved decoding
options) and `<yyyyMMdd-HHmmss>-<variant>.txt` (the transcript) next to the audio. Then
score the transcript against the reference:

```bash
scripts/transcript-agreement.py \
  "$HOME/Library/Application Support/Casablanca/Benchmarks/vzvz-44min.reference.txt" \
  "$HOME/Library/Application Support/Casablanca/Benchmarks/20260904-140501-baseline.txt"
# disagreement=10.37% ref_words=6021 cand_words=6010 edits=624
```

Run every variant twice, and treat anything inside the 0.56 % noise floor as no change. See
the README section "Benchmarking transcription" for the full list of keys and the pinned
WhisperKit revision policy.
