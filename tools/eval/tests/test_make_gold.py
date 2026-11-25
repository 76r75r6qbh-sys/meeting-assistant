"""Tests for `draft_gold` and the `make-gold` CLI."""

import contextlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("casaeval", EVAL_DIR / "casaeval.py")
casaeval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(casaeval)

EXAMPLE_EXPORT = EVAL_DIR / "examples" / "synthetic-export.json"


def run_main(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = casaeval.main(argv)
    return code, out.getvalue(), err.getvalue()


class DraftGoldTests(unittest.TestCase):
    def setUp(self):
        self.export = casaeval.load_export(EXAMPLE_EXPORT)

    def test_draft_is_unreviewed(self):
        self.assertIs(casaeval.draft_gold(self.export)["reviewed"], False)

    def test_draft_copies_items_and_decisions(self):
        draft = casaeval.draft_gold(self.export)
        self.assertEqual(len(draft["actionItems"]), len(self.export["actionItems"]))
        self.assertEqual(len(draft["decisions"]), len(self.export["decisions"]))
        self.assertEqual(draft["actionItems"][0]["task"], self.export["actionItems"][0]["task"])

    def test_draft_header_and_fields(self):
        draft = casaeval.draft_gold(self.export)
        self.assertEqual(draft["schema"], "casablanca.eval-gold")
        self.assertEqual(draft["schemaVersion"], 1)
        self.assertEqual(draft["meetingId"], self.export["meeting"]["id"])
        self.assertEqual(draft["title"], self.export["meeting"]["title"])
        self.assertEqual(draft["date"], "2026-01-15")
        self.assertEqual(draft["ownerAliases"], {})
        self.assertEqual(
            draft["notes"],
            "Draft from Casablanca export (structured) — correct every item, then set reviewed to true.",
        )
        for item, source in zip(draft["actionItems"], self.export["actionItems"]):
            self.assertEqual(set(item), {"task", "owner", "due"})
            self.assertEqual(item, {k: source[k] for k in ("task", "owner", "due")})
        self.assertEqual(draft["decisions"], [{"text": d["text"]} for d in self.export["decisions"]])

    def test_draft_keeps_unsupported_items(self):
        export = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        export["actionItems"][0]["verified"] = "unsupported"
        self.assertEqual(len(casaeval.draft_gold(export)["actionItems"]), len(export["actionItems"]))

    def test_draft_null_date(self):
        export = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        export["meeting"]["date"] = None
        self.assertIsNone(casaeval.draft_gold(export)["date"])

    def test_default_path_is_gold_dir(self):
        self.assertEqual(
            casaeval.default_gold_path("abc"), EVAL_DIR / "gold" / "abc.json"
        )


class MakeGoldCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_draft_validates_as_gold(self):
        out = self.tmp / "draft.json"
        code, stdout, err = run_main(["make-gold", str(EXAMPLE_EXPORT), "-o", str(out)])
        self.assertEqual(code, 0, err)
        self.assertIn(str(out), stdout)
        gold = casaeval.load_gold(out)
        self.assertIs(gold["reviewed"], False)

    def test_creates_output_directory(self):
        out = self.tmp / "nested" / "dir" / "draft.json"
        code, _, err = run_main(["make-gold", str(EXAMPLE_EXPORT), "-o", str(out)])
        self.assertEqual(code, 0, err)
        self.assertTrue(out.is_file())

    def test_refuses_overwrite(self):
        existing = self.tmp / "existing.json"
        existing.write_text("keep me", encoding="utf-8")

        code, _, err = run_main(["make-gold", str(EXAMPLE_EXPORT), "-o", str(existing)])
        self.assertEqual(code, 2)
        self.assertIn("--force", err)
        self.assertEqual(existing.read_text(encoding="utf-8"), "keep me")

        code, _, err = run_main(["make-gold", str(EXAMPLE_EXPORT), "-o", str(existing), "--force"])
        self.assertEqual(code, 0, err)
        self.assertEqual(casaeval.load_gold(existing)["reviewed"], False)

    def test_bad_export_exits_2(self):
        bad = self.tmp / "bad.json"
        bad.write_text("{", encoding="utf-8")
        code, _, err = run_main(["make-gold", str(bad), "-o", str(self.tmp / "out.json")])
        self.assertEqual(code, 2)
        self.assertIn("ERROR", err)
        self.assertFalse((self.tmp / "out.json").exists())

    def test_unsafe_meeting_id_exits_2(self):
        export = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        export["meeting"]["id"] = "../escape"
        path = self.tmp / "export.json"
        path.write_text(json.dumps(export), encoding="utf-8")
        code, _, err = run_main(["make-gold", str(path)])
        self.assertEqual(code, 2)
        self.assertIn("meeting.id", err)

    def test_roundtrip_score_is_perfect(self):
        out = self.tmp / "draft.json"
        self.assertEqual(run_main(["make-gold", str(EXAMPLE_EXPORT), "-o", str(out)])[0], 0)

        code, stdout, err = run_main(
            ["score", "--gold", str(out), "--export", str(EXAMPLE_EXPORT), "--json"]
        )
        self.assertEqual(code, 0, err)
        items = json.loads(stdout)["total"]["actionItems"]
        self.assertEqual(items["precision"], 1.0)
        self.assertEqual(items["recall"], 1.0)
        self.assertIn("unreviewed", err)


if __name__ == "__main__":
    unittest.main()
