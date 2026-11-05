#!/usr/bin/env python3
"""Score Casablanca's action items and decisions against a hand-made gold file.

Casablanca exports one meeting as JSON ("Export for Evaluation…"); a person
writes down what the meeting really decided and who really owns what (the
gold file). This tool compares the two with fuzzy text matching, because the
model paraphrases: "Youri stuurt de planning naar Kim" and "Planning naar Kim
sturen" are the same action item.

Similarity is the F1 of the content words two texts share (stopwords,
diacritics, case, timestamps and punctuation ignored). F1 is easy to
interpret and does not care about word order; a character-level ratio is not
part of the score because it rewards shared prefixes ("Release notes
schrijven" vs "Release inplannen"). Pairs with F1 >= 0.5 match.
Known limitation: pairs sharing one content word out of two, such as
"Offerte opvragen" vs "Offerte accepteren" (0.5), still match — there is no
stemming or verb awareness.

Usage:
    python3 -I tools/eval/casaeval.py score --gold <file|dir> --export <file|dir>
                                             [--threshold 0.5] [--json] [--strict]
    python3 -I tools/eval/casaeval.py make-gold <export.json> [-o <path>] [--force]

`score` pairs gold and export files by meeting id (gold `meetingId` <-> export
`meeting.id`) when given directories, prints one line per meeting and a TOTAL
line (micro-averaged), or `{"meetings": [...], "total": {...}}` with `--json`.
A gold file with `"reviewed": false` gives a warning; `--strict` makes that
exit 3. Exit codes: 0 ok, 2 usage or format error, 3 strict + unreviewed.

`make-gold` drafts an unreviewed gold file from an export (default
`tools/eval/gold/<meetingId>.json`); it refuses to overwrite without `--force`.
Correct every item by hand, then set `"reviewed": true`.

Real gold files and exports stay out of git (`tools/eval/.gitignore`).

Export format — `casablanca.eval-export` v1 (written by the app's
`EvaluationExport`). Every key is always present; absent values are `null` or
`[]`, never omitted. Dates are ISO 8601 UTC.

    {
      "schema": "casablanca.eval-export", "schemaVersion": 1,
      "exportedAt": "2026-11-05T14:00:00Z", "appVersion": "0.20.0",
      "meeting": {"id": "<UUID>", "title": "Refinement", "date": "2026-11-03T09:00:00Z",
                  "endDate": "2026-11-03T10:00:00Z", "durationSeconds": 3540.0,
                  "language": "nl-NL", "participants": ["Alex Jansen"], "tags": [],
                  "summaryTemplateID": null},
      "speakers": [{"id": "me", "displayName": "Alex", "source": "microphone",
                    "isUser": true, "nameConfirmed": true}],
      "transcript": {"text": "[00:10] Alex: we beginnen",
                     "lines": [{"label": "00:10", "seconds": 10.0,
                                "speaker": "Alex", "text": "we beginnen"}]},
      "summary": {"markdown": "# …", "decisions": ["…"],
                  "actionItemTexts": ["**Sam** — offerte opvragen [12:34]"]},
      "actionItemsSource": "structured",
      "actionItems": [{"task": "Offerte opvragen", "owner": "Sam", "due": "2026-11-07",
                       "dueIsExplicit": true, "confidence": 0.9,
                       "quote": "ik vraag de offerte op", "timestamp": "12:34",
                       "verified": "supported", "verificationReason": null}],
      "decisions": [{"text": "We gaan door met profiel v2", "source": "summaryMarkdown"}]
    }

  `actionItemsSource` is "structured" when the meeting has stored action items
  (including items the summarizer stored from its markdown fallback), else
  "summaryMarkdown" when they were parsed from the summary's action-item
  bullets (confidence 0, verified "unverified", due null), else "none".
  Speaker ids are "me", "others", "S1"….

Gold format — `casablanca.eval-gold` v1 (`tools/eval/gold/<meetingId>.json`):

    {
      "schema": "casablanca.eval-gold", "schemaVersion": 1,
      "meetingId": "<UUID>", "title": "Refinement", "date": "2026-11-03",
      "reviewed": false, "notes": "",
      "ownerAliases": {"Ik": "Alex", "Me": "Alex", "Alex Jansen": "Alex"},
      "decisions": [{"text": "We gaan door met profiel v2"}],
      "actionItems": [{"task": "Offerte opvragen bij leverancier", "owner": "Sam", "due": null}]
    }

  `owner: null` means nobody was explicitly assigned. `ownerAliases` maps name
  variants to one canonical name and applies to gold and predicted owners.

Python 3.9+, standard library only; run with `python3 -I`.
"""

import difflib
import re
import unicodedata
from collections import Counter

# Pairs whose content-token F1 is at least this count as the same item.
DEFAULT_THRESHOLD = 0.5

# Function words that carry no meaning for matching (small Dutch + English set).
STOPWORDS = frozenset(
    "de het een en van naar op te in is dat die we ik je "
    "the a an to of and for on".split()
)

# `[mm:ss]` or `[h:mm:ss]` anywhere in the text (summary bullets end with one).
TIMESTAMP = re.compile(r"\[\d{1,2}:\d{2}(?::\d{2})?\]")
# Runs of anything that is not a letter, digit or underscore.
NON_WORD = re.compile(r"\W+")


def normalize(text):
    """Comparable form of `text`: no diacritics, case, markdown bold,
    timestamps or punctuation; single spaces."""
    decomposed = unicodedata.normalize("NFKD", text or "")
    # Drop combining marks so "geïnteresseerd" equals "geinteresseerd".
    stripped = "".join(char for char in decomposed if unicodedata.category(char) != "Mn")
    folded = stripped.casefold().replace("**", "")
    folded = TIMESTAMP.sub(" ", folded)
    return " ".join(NON_WORD.sub(" ", folded).split())


def tokens(text):
    """The meaningful words of `text`: normalised, stopwords removed."""
    return [word for word in normalize(text).split() if word not in STOPWORDS]


def token_f1(a, b):
    """F1 of the multiset overlap between the tokens of `a` and `b`."""
    ta, tb = Counter(tokens(a)), Counter(tokens(b))
    overlap = sum((ta & tb).values())
    if overlap == 0:
        return 0.0
    precision = overlap / sum(tb.values())
    recall = overlap / sum(ta.values())
    return 2 * precision * recall / (precision + recall)


def similarity(a, b):
    """How alike two item texts are, 0.0–1.0: the content-token F1.

    Both texts empty after normalising -> 1.0; one empty -> 0.0. No shared
    content word -> 0.0.
    """
    na, nb = normalize(a), normalize(b)
    if not na and not nb:
        return 1.0
    if not na or not nb:
        return 0.0
    return token_f1(a, b)


def char_ratio(a, b):
    """Character-level likeness of the normalised texts (difflib ratio).
    Only breaks ties in `match`; never part of the score."""
    return difflib.SequenceMatcher(None, normalize(a), normalize(b)).ratio()


def match(gold, predicted, threshold=DEFAULT_THRESHOLD):
    """One-to-one pairs `[(gold_index, pred_index, score)]` between two lists
    of texts.

    Deterministic greedy: score every pair, keep those at or above
    `threshold`, take them best-first while neither side is already used.
    Equal scores are ordered by higher `char_ratio`, then lowest gold, then
    lowest predicted index.
    """
    candidates = []
    for gi, g in enumerate(gold):
        for pi, p in enumerate(predicted):
            score = similarity(g, p)
            if score >= threshold:
                candidates.append((-score, -char_ratio(g, p), gi, pi))
    candidates.sort()

    used_gold, used_pred, pairs = set(), set(), []
    for neg_score, _, gi, pi in candidates:
        score = -neg_score
        if gi in used_gold or pi in used_pred:
            continue
        used_gold.add(gi)
        used_pred.add(pi)
        pairs.append((gi, pi, score))
    return pairs


def canonical_owner(owner, aliases):
    """The normalised canonical name for `owner`, or None for no owner.

    `aliases` maps variants to canonical names; keys and values are compared
    in normalised form, so "ik", "Ik" and "**Ik**" all hit an "Ik" alias.
    """
    if owner is None:
        return None
    key = normalize(owner)
    if not key:  # "", "?", "—": nothing left once normalised
        return None
    lookup = {normalize(k): normalize(v) for k, v in (aliases or {}).items()}
    return lookup.get(key, key) or None
