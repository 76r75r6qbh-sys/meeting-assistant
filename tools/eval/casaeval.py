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

Metrics per meeting (`score_meeting`) and in TOTAL (`aggregate`, which sums
the counts over meetings before dividing): precision = matched / predicted,
recall = matched / gold, F1 their harmonic mean; a ratio with a zero
denominator is None (`n/a`). Matched action items also get owner checks
after `canonical_owner`: `ownerAccuracy` = equal owners / matched (both None
counts as equal), `inventedOwners` = gold owner None but a predicted owner
(the anti-goal: the model must not assign people), `missedOwners` = gold owner
set, predicted None.

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

import argparse
import difflib
import json
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path

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


# ---------------------------------------------------------------------------
# Loading

EXPORT_SCHEMA = "casablanca.eval-export"
GOLD_SCHEMA = "casablanca.eval-gold"
SCHEMA_VERSION = 1

# Same list as `EvaluationExport.topLevelKeys` in the app.
EXPORT_KEYS = (
    "schema", "schemaVersion", "exportedAt", "appVersion", "meeting", "speakers",
    "transcript", "summary", "actionItemsSource", "actionItems", "decisions",
)
GOLD_KEYS = (
    "schema", "schemaVersion", "meetingId", "title", "date", "reviewed",
    "actionItems", "decisions",
)


class FormatError(Exception):
    """A file is not valid JSON or does not follow its schema."""


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as error:
        raise FormatError(f"{path}: not valid JSON ({error})") from None
    except UnicodeDecodeError:
        raise FormatError(f"{path}: not UTF-8 text") from None
    except OSError as error:
        raise FormatError(f"{path}: cannot read ({error.strerror or error})") from None


def _require(condition, path, message):
    if not condition:
        raise FormatError(f"{path}: {message}")


def _check_header(doc, path, schema, keys):
    _require(isinstance(doc, dict), path, "top level is not a JSON object")
    _require(doc.get("schema") == schema, path,
             f'schema is {doc.get("schema")!r}, expected {schema!r}')
    version = doc.get("schemaVersion")
    # `type(...) is int` because JSON `true` is an int subclass in Python.
    _require(type(version) is int and version == SCHEMA_VERSION, path,
             f"schemaVersion is {version!r}, expected {SCHEMA_VERSION}")
    missing = [key for key in keys if key not in doc]
    _require(not missing, path, "missing key(s): " + ", ".join(missing))


def _check_items(items, path, name, text_key, owner):
    _require(isinstance(items, list), path, f"{name} is not a list")
    for index, item in enumerate(items):
        where = f"{name}[{index}]"
        _require(isinstance(item, dict), path, f"{where} is not an object")
        _require(isinstance(item.get(text_key), str), path, f'{where}.{text_key} is not a string')
        if owner:
            _require("owner" in item, path, f"{where}.owner is missing (use null for no owner)")
            _require(item["owner"] is None or isinstance(item["owner"], str), path,
                     f"{where}.owner is not a string or null")


def load_export(path):
    """A `casablanca.eval-export` v1 document from `path`; FormatError otherwise."""
    doc = _read_json(path)
    _check_header(doc, path, EXPORT_SCHEMA, EXPORT_KEYS)
    meeting = doc["meeting"]
    _require(isinstance(meeting, dict), path, "meeting is not an object")
    _require(isinstance(meeting.get("id"), str) and meeting["id"], path, "meeting.id is missing")
    _require(isinstance(meeting.get("title"), str), path, "meeting.title is not a string")
    _check_items(doc["actionItems"], path, "actionItems", "task", owner=True)
    _check_items(doc["decisions"], path, "decisions", "text", owner=False)
    return doc


def load_gold(path):
    """A `casablanca.eval-gold` v1 document from `path`; FormatError otherwise."""
    doc = _read_json(path)
    _check_header(doc, path, GOLD_SCHEMA, GOLD_KEYS)
    _require(isinstance(doc["reviewed"], bool), path, '"reviewed" must be true or false')
    _require(isinstance(doc["meetingId"], str) and doc["meetingId"], path, "meetingId is missing")
    _require(isinstance(doc["title"], str), path, "title is not a string")
    aliases = doc.get("ownerAliases", {})
    _require(isinstance(aliases, dict)
             and all(isinstance(k, str) and isinstance(v, str) for k, v in aliases.items()),
             path, "ownerAliases is not an object of strings")
    _check_items(doc["actionItems"], path, "actionItems", "task", owner=True)
    _check_items(doc["decisions"], path, "decisions", "text", owner=False)
    return doc


# ---------------------------------------------------------------------------
# Scoring


def _ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def _f1(precision, recall):
    if precision is None or recall is None:
        return None
    if precision + recall == 0:
        return 0.0
    return 2 * precision * recall / (precision + recall)


def _action_metrics(gold, predicted, matched, owner_correct, invented, missed):
    precision, recall = _ratio(matched, predicted), _ratio(matched, gold)
    return {
        "gold": gold, "predicted": predicted, "matched": matched,
        "precision": precision, "recall": recall, "f1": _f1(precision, recall),
        "ownerCorrect": owner_correct, "ownerAccuracy": _ratio(owner_correct, matched),
        "inventedOwners": invented, "missedOwners": missed,
    }


def _decision_metrics(gold, predicted, matched):
    return {
        "gold": gold, "predicted": predicted, "matched": matched,
        "recall": _ratio(matched, gold), "precision": _ratio(matched, predicted),
    }


def score_meeting(gold, export, threshold=DEFAULT_THRESHOLD):
    """Scores of one export against its gold file (metrics: module docstring)."""
    aliases = gold.get("ownerAliases") or {}
    gold_items, pred_items = gold["actionItems"], export["actionItems"]
    pairs = match([g["task"] for g in gold_items], [p["task"] for p in pred_items], threshold)

    owner_correct = invented = missed = 0
    for gi, pi, _ in pairs:
        gold_owner = canonical_owner(gold_items[gi]["owner"], aliases)
        pred_owner = canonical_owner(pred_items[pi]["owner"], aliases)
        owner_correct += gold_owner == pred_owner
        invented += gold_owner is None and pred_owner is not None
        missed += gold_owner is not None and pred_owner is None

    gold_decisions, pred_decisions = gold["decisions"], export["decisions"]
    decision_pairs = match(
        [d["text"] for d in gold_decisions], [d["text"] for d in pred_decisions], threshold
    )

    matched_gold_items = {gi for gi, _, _ in pairs}
    matched_pred_items = {pi for _, pi, _ in pairs}
    matched_gold_decisions = {gi for gi, _, _ in decision_pairs}
    matched_pred_decisions = {pi for _, pi, _ in decision_pairs}

    def leftovers(items, matched, kind, key):
        return [
            {"kind": kind, key: item[key], **({"owner": item["owner"]} if kind == "actionItem" else {})}
            for index, item in enumerate(items) if index not in matched
        ]

    return {
        "meetingId": gold["meetingId"],
        "title": gold.get("title") or export["meeting"]["title"],
        "reviewed": gold["reviewed"],
        "actionItems": _action_metrics(
            len(gold_items), len(pred_items), len(pairs), owner_correct, invented, missed
        ),
        "decisions": _decision_metrics(
            len(gold_decisions), len(pred_decisions), len(decision_pairs)
        ),
        "unmatchedGold": leftovers(gold_items, matched_gold_items, "actionItem", "task")
        + leftovers(gold_decisions, matched_gold_decisions, "decision", "text"),
        "unmatchedPredicted": leftovers(pred_items, matched_pred_items, "actionItem", "task")
        + leftovers(pred_decisions, matched_pred_decisions, "decision", "text"),
    }


def aggregate(results):
    """Micro-average over meetings: sum the counts, then divide."""
    def total(section, key):
        return sum(result[section][key] for result in results)

    return {
        "meetings": len(results),
        "reviewed": all(result["reviewed"] for result in results),
        "actionItems": _action_metrics(
            total("actionItems", "gold"), total("actionItems", "predicted"),
            total("actionItems", "matched"), total("actionItems", "ownerCorrect"),
            total("actionItems", "inventedOwners"), total("actionItems", "missedOwners"),
        ),
        "decisions": _decision_metrics(
            total("decisions", "gold"), total("decisions", "predicted"),
            total("decisions", "matched"),
        ),
    }


# ---------------------------------------------------------------------------
# Drafting gold files

GOLD_DIR = Path(__file__).resolve().parent / "gold"


def draft_gold(export):
    """An unreviewed `casablanca.eval-gold` v1 draft from an export document.

    Every action item and decision is copied, unsupported and unverified ones
    included: the reviewer deletes the wrong ones and adds the missing ones.
    """
    meeting = export["meeting"]
    date = meeting.get("date")
    return {
        "schema": GOLD_SCHEMA,
        "schemaVersion": SCHEMA_VERSION,
        "meetingId": meeting["id"],
        "title": meeting["title"],
        "date": date[:10] if isinstance(date, str) else None,
        "reviewed": False,
        "notes": f"Draft from Casablanca export ({export.get('actionItemsSource')}) "
                 "— correct every item, then set reviewed to true.",
        "ownerAliases": {},
        "decisions": [{"text": d["text"]} for d in export["decisions"]],
        "actionItems": [
            {"task": item["task"], "owner": item["owner"], "due": item.get("due")}
            for item in export["actionItems"]
        ],
    }


def default_gold_path(meeting_id):
    """`tools/eval/gold/<meetingId>.json`, next to this script."""
    return GOLD_DIR / f"{meeting_id}.json"


# ---------------------------------------------------------------------------
# Command line


def _fmt(value):
    return "n/a" if value is None else f"{value:.2f}"


def format_line(label, result):
    """`<label>  AI P=… R=… F1=… owner=… invented=…  DEC R=…`."""
    items, decisions = result["actionItems"], result["decisions"]
    return (
        f"{label}  AI P={_fmt(items['precision'])} R={_fmt(items['recall'])} "
        f"F1={_fmt(items['f1'])} owner={_fmt(items['ownerAccuracy'])} "
        f"invented={items['inventedOwners']}  DEC R={_fmt(decisions['recall'])}"
    )


def _json_files(path):
    """`path` itself, or the `*.json` files directly inside a directory."""
    path = Path(path)
    if path.is_dir():
        return sorted(p for p in path.glob("*.json") if p.is_file() and not p.name.startswith("."))
    if path.is_file():
        return [path]
    raise FormatError(f"{path}: no such file or directory")


def _meeting_key(meeting_id):
    # Swift writes upper-case UUIDs; a hand-edited gold file may not.
    return meeting_id.strip().casefold()


def _by_meeting(entries, meeting_id, label):
    """`{key: (path, doc)}` for `[(path, doc)]`; a repeated meeting id is a FormatError."""
    by_id = {}
    for path, doc in entries:
        key = _meeting_key(meeting_id(doc))
        if key in by_id:
            raise FormatError(f"{path}: same meeting id as {by_id[key][0]} ({label})")
        by_id[key] = (path, doc)
    return by_id


def _pairs(gold_arg, export_arg):
    """`[(gold_path, gold, export_path, export)]` plus warnings for unpaired files."""
    golds = [(path, load_gold(path)) for path in _json_files(gold_arg)]
    exports = [(path, load_export(path)) for path in _json_files(export_arg)]
    warnings = []

    if Path(gold_arg).is_file() and Path(export_arg).is_file():
        (gold_path, gold), (export_path, export) = golds[0], exports[0]
        if _meeting_key(gold["meetingId"]) != _meeting_key(export["meeting"]["id"]):
            warnings.append(
                f"WARNING: {gold_path} (meetingId {gold['meetingId']}) and {export_path} "
                f"(meeting.id {export['meeting']['id']}) are different meetings; scoring them anyway."
            )
        return [(gold_path, gold, export_path, export)], warnings

    gold_by_id = _by_meeting(golds, lambda g: g["meetingId"], "gold")
    export_by_id = _by_meeting(exports, lambda e: e["meeting"]["id"], "export")
    pairs = [
        gold_by_id[key] + export_by_id[key]
        for key in sorted(gold_by_id, key=lambda k: str(gold_by_id[k][0]))
        if key in export_by_id
    ]
    for key, (path, _) in sorted(gold_by_id.items(), key=lambda kv: str(kv[1][0])):
        if key not in export_by_id:
            warnings.append(f"WARNING: no export for gold file {path}")
    for key, (path, _) in sorted(export_by_id.items(), key=lambda kv: str(kv[1][0])):
        if key not in gold_by_id:
            warnings.append(f"WARNING: no gold file for export {path}")
    return pairs, warnings


def _threshold(text):
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {text!r}") from None
    if not 0.0 < value <= 1.0:
        raise argparse.ArgumentTypeError(f"must be in (0, 1], got {value}")
    return value


def _parser():
    parser = argparse.ArgumentParser(
        prog="casaeval.py",
        description="Score Casablanca evaluation exports against gold files.",
    )
    commands = parser.add_subparsers(dest="command", metavar="command")
    commands.required = True

    score = commands.add_parser("score", help="score exports against gold files")
    score.add_argument("--gold", required=True, help="gold file or directory of gold files")
    score.add_argument("--export", required=True, help="export file or directory of exports")
    score.add_argument("--threshold", type=_threshold, default=DEFAULT_THRESHOLD,
                       help=f"match threshold for content-token F1 (default {DEFAULT_THRESHOLD})")
    score.add_argument("--json", action="store_true", help="print JSON instead of text")
    score.add_argument("--strict", action="store_true",
                       help="exit 3 when any gold file is unreviewed")

    make_gold = commands.add_parser("make-gold", help="draft an unreviewed gold file from an export")
    make_gold.add_argument("export", help="export file")
    make_gold.add_argument("-o", "--output",
                           help="gold file to write (default tools/eval/gold/<meetingId>.json)")
    make_gold.add_argument("--force", action="store_true", help="overwrite an existing file")
    return parser


def _run_make_gold(args):
    try:
        export = load_export(args.export)
    except FormatError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    meeting_id = export["meeting"]["id"]
    if args.output:
        output = Path(args.output)
    else:
        # The id becomes a file name: refuse anything that could leave gold/.
        if Path(meeting_id).name != meeting_id or meeting_id in (".", ".."):
            print(f"ERROR: {args.export}: meeting.id {meeting_id!r} is not usable as a "
                  "file name; pass -o.", file=sys.stderr)
            return 2
        output = default_gold_path(meeting_id)
    if output.exists() and not args.force:
        print(f"ERROR: {output} already exists; pass --force to overwrite it.", file=sys.stderr)
        return 2
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(draft_gold(export), ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    except OSError as error:
        print(f"ERROR: {output}: cannot write ({error.strerror or error})", file=sys.stderr)
        return 2
    print(f'Wrote {output} ("reviewed": false) — correct every item, then set reviewed to true.')
    return 0


def _run_score(args):
    try:
        pairs, warnings = _pairs(args.gold, args.export)
    except FormatError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    for warning in warnings:
        print(warning, file=sys.stderr)
    if not pairs:
        print("ERROR: no gold file and export share a meeting id.", file=sys.stderr)
        return 2

    unreviewed = False
    results = []
    for gold_path, gold, _, export in pairs:
        if not gold["reviewed"]:
            unreviewed = True
            print(f'WARNING: {gold_path} is unreviewed ("reviewed": false) '
                  "— scores against it are provisional.", file=sys.stderr)
        results.append(score_meeting(gold, export, args.threshold))
    total = aggregate(results)

    if args.json:
        print(json.dumps({"meetings": results, "total": total}, ensure_ascii=False, indent=2))
    else:
        for result in results:
            print(format_line(result["title"], result))
        print(format_line("TOTAL", total))
    return 3 if args.strict and unreviewed else 0


def main(argv=None):
    """Command-line entry point; returns the exit code."""
    parser = _parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:  # argparse exits 2 on usage errors, 0 on --help
        return exit_.code if isinstance(exit_.code, int) else 2
    if args.command == "score":
        return _run_score(args)
    if args.command == "make-gold":
        return _run_make_gold(args)
    parser.error(f"unknown command {args.command!r}")  # pragma: no cover


if __name__ == "__main__":
    sys.exit(main())
