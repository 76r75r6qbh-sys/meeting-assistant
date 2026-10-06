#!/usr/bin/env python3
"""Word-level disagreement between two Casablanca transcripts.

Speed tuning is only interesting if quality holds, so a benchmark run's
transcript has to be comparable against a transcript that is trusted. This
compares two files in the format `TranscriptionService.saveTranscriptLocally`
writes — a header, `---`, a blank line, then `[mm:ss] text` lines — and reports
the word-level Levenshtein distance as a percentage of the reference length.

Usage:
    scripts/transcript-agreement.py <reference.txt> <candidate.txt>
    scripts/transcript-agreement.py --self-test

Output (one line):
    disagreement=4.21% ref_words=6021 cand_words=6010 edits=253

The comparison ignores everything Whisper is allowed to differ on without
changing meaning: the header, timestamps, letter case, and punctuation. It does
not ignore word order or wording — those are the differences worth seeing.

Note this is a plain O(n*m) edit distance: a 45-minute transcript is ~6k words
and takes tens of seconds. That is once per benchmark run, so it stays simple
rather than approximate.
"""

import re
import sys
import unicodedata

# The header is everything up to and including the first `---` line.
HEADER_TERMINATOR = "---"
# `[mm:ss] ` or `[h:mm:ss] ` at the start of a transcript line.
TIMESTAMP = re.compile(r"^\[\d{1,2}:\d{2}(?::\d{2})?\]\s*")


def strip_header(text):
    """Drop the transcript header, if the file has one."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == HEADER_TERMINATOR:
            return lines[index + 1:]
    # No header (a bare transcript body, or an empty file): compare as-is.
    return lines


def words(text):
    """The comparable words of a transcript: no header, timestamps, case or
    punctuation."""
    out = []
    for line in strip_header(text):
        line = TIMESTAMP.sub("", line)
        for token in line.lower().split():
            # Keep letters, digits and marks; drop punctuation and symbols. This
            # is Unicode-aware on purpose — the corpus is Dutch, and stripping
            # by an ASCII class would mangle "café" or "'t".
            cleaned = "".join(
                char for char in token if unicodedata.category(char)[0] in ("L", "N", "M")
            )
            if cleaned:
                out.append(cleaned)
    return out


def levenshtein(reference, candidate):
    """Word-level edit distance (equal-cost insert, delete, substitute)."""
    # Identical prefixes and suffixes cannot be part of any cheaper alignment,
    # so trimming them is exact — and on two transcripts of the same recording
    # it usually removes most of the work.
    start = 0
    while start < len(reference) and start < len(candidate) and reference[start] == candidate[start]:
        start += 1
    reference = reference[start:]
    candidate = candidate[start:]
    end = 0
    while (
        end < len(reference)
        and end < len(candidate)
        and reference[len(reference) - 1 - end] == candidate[len(candidate) - 1 - end]
    ):
        end += 1
    if end:
        reference = reference[: len(reference) - end]
        candidate = candidate[: len(candidate) - end]

    if not reference:
        return len(candidate)
    if not candidate:
        return len(reference)

    previous = list(range(len(candidate) + 1))
    for i, ref_word in enumerate(reference, start=1):
        current = [i] + [0] * len(candidate)
        for j, cand_word in enumerate(candidate, start=1):
            current[j] = min(
                previous[j] + 1,                                        # deletion
                current[j - 1] + 1,                                     # insertion
                previous[j - 1] + (0 if ref_word == cand_word else 1),  # substitution
            )
        previous = current
    return previous[-1]


def compare(reference_text, candidate_text):
    """The one-line report for two transcript file contents."""
    reference = words(reference_text)
    candidate = words(candidate_text)
    edits = levenshtein(reference, candidate)
    # An empty reference has nothing to disagree with: 0% when the candidate is
    # empty too, 100% once the candidate says anything at all.
    if reference:
        disagreement = 100.0 * edits / len(reference)
    else:
        disagreement = 100.0 if candidate else 0.0
    return "disagreement=%.2f%% ref_words=%d cand_words=%d edits=%d" % (
        disagreement,
        len(reference),
        len(candidate),
        edits,
    )


# --- Self-test ---------------------------------------------------------------

HEADER = "Transcription: t\nDate: 12:00 - 13:00\nDuration: 1m 0s\n---\n\n"


def self_test():
    cases = []

    def check(name, actual, expected):
        cases.append((name, actual, expected))

    check(
        "identical",
        compare(HEADER + "[00:00] Hallo daar.", HEADER + "[00:00] Hallo daar."),
        "disagreement=0.00% ref_words=2 cand_words=2 edits=0",
    )
    check(
        "case, punctuation and timestamp width are ignored",
        compare(HEADER + "[00:00] Hallo, daar!", HEADER + "[1:00:00] hallo daar"),
        "disagreement=0.00% ref_words=2 cand_words=2 edits=0",
    )
    check(
        "one substitution",
        compare(HEADER + "[00:00] a b c d", HEADER + "[00:00] a x c d"),
        "disagreement=25.00% ref_words=4 cand_words=4 edits=1",
    )
    check(
        "one deletion",
        compare(HEADER + "[00:00] a b c d", HEADER + "[00:00] a c d"),
        "disagreement=25.00% ref_words=4 cand_words=3 edits=1",
    )
    check(
        "one insertion",
        compare(HEADER + "[00:00] a b c d", HEADER + "[00:00] a b x c d"),
        "disagreement=25.00% ref_words=4 cand_words=5 edits=1",
    )
    check(
        "empty candidate",
        compare(HEADER + "[00:00] a b c d", ""),
        "disagreement=100.00% ref_words=4 cand_words=0 edits=4",
    )
    check(
        "candidate with a header but no transcript",
        compare(HEADER + "[00:00] a b", HEADER),
        "disagreement=100.00% ref_words=2 cand_words=0 edits=2",
    )
    check(
        "both empty",
        compare("", ""),
        "disagreement=0.00% ref_words=0 cand_words=0 edits=0",
    )
    check(
        "header is never counted as words",
        compare(HEADER + "[00:00] a", "[00:00] a"),
        "disagreement=0.00% ref_words=1 cand_words=1 edits=0",
    )
    check(
        "accented and elided Dutch words survive cleaning",
        compare(HEADER + "[00:00] café 't is", HEADER + "[00:00] café 't is"),
        "disagreement=0.00% ref_words=3 cand_words=3 edits=0",
    )

    failures = [(name, actual, expected) for name, actual, expected in cases if actual != expected]
    for name, actual, expected in failures:
        print("FAIL %s\n  expected: %s\n  actual:   %s" % (name, expected, actual), file=sys.stderr)
    if failures:
        print("%d of %d self-tests failed" % (len(failures), len(cases)), file=sys.stderr)
        return 1
    print("%d self-tests passed" % len(cases))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 3:
        print(
            "usage: %s <reference.txt> <candidate.txt>\n       %s --self-test"
            % (argv[0], argv[0]),
            file=sys.stderr,
        )
        return 2
    try:
        with open(argv[1], encoding="utf-8") as handle:
            reference_text = handle.read()
        with open(argv[2], encoding="utf-8") as handle:
            candidate_text = handle.read()
    except OSError as error:
        print("cannot read transcript: %s" % error, file=sys.stderr)
        return 2
    print(compare(reference_text, candidate_text))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
