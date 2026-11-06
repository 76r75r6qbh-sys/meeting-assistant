"""Tests for casaeval loading, scoring, aggregation and the `score` CLI."""

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
EXAMPLE_GOLD = EVAL_DIR / "examples" / "synthetic-gold.json"

# Same list as `EvaluationExport.topLevelKeys` in Casablanca/Services/EvaluationExport.swift.
CONTRACT_KEYS = {
    "schema", "schemaVersion", "exportedAt", "appVersion", "meeting", "speakers",
    "transcript", "summary", "actionItemsSource", "actionItems", "decisions",
}


def gold_doc(action_items, decisions=(), aliases=None, meeting_id="m1", reviewed=True):
    return {
        "schema": "casablanca.eval-gold", "schemaVersion": 1,
        "meetingId": meeting_id, "title": "T", "date": "2026-01-15",
        "reviewed": reviewed, "notes": "",
        "ownerAliases": aliases or {},
        "decisions": [{"text": d} for d in decisions],
        "actionItems": list(action_items),
    }


def export_doc(action_items, decisions=(), meeting_id="m1"):
    with open(EXAMPLE_EXPORT, encoding="utf-8") as handle:
        doc = json.load(handle)
    doc["meeting"]["id"] = meeting_id
    doc["actionItems"] = [
        dict(doc["actionItems"][0], task=item["task"], owner=item["owner"]) for item in action_items
    ]
    doc["decisions"] = [{"text": d, "source": "summaryMarkdown"} for d in decisions]
    return doc


def run_main(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = casaeval.main(argv)
    return code, out.getvalue(), err.getvalue()


def write_json(path, doc):
    Path(path).write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")


class ExampleTests(unittest.TestCase):
    def test_example_files_validate(self):
        export = casaeval.load_export(EXAMPLE_EXPORT)
        gold = casaeval.load_gold(EXAMPLE_GOLD)
        self.assertEqual(set(export.keys()), CONTRACT_KEYS)
        self.assertEqual(export["actionItemsSource"], "structured")
        self.assertIs(gold["reviewed"], True)
        self.assertEqual(gold["meetingId"], export["meeting"]["id"])

    def test_example_scores(self):
        result = casaeval.score_meeting(
            casaeval.load_gold(EXAMPLE_GOLD), casaeval.load_export(EXAMPLE_EXPORT)
        )
        items = result["actionItems"]
        self.assertEqual(items["gold"], 4)
        self.assertEqual(items["predicted"], 4)
        self.assertEqual(items["matched"], 3)
        self.assertEqual(items["precision"], 0.75)
        self.assertEqual(items["recall"], 0.75)
        self.assertEqual(items["f1"], 0.75)
        self.assertEqual(items["ownerCorrect"], 2)
        self.assertEqual(items["inventedOwners"], 1)
        self.assertEqual(items["missedOwners"], 0)
        self.assertEqual(result["decisions"]["recall"], 1.0)
        self.assertEqual(result["decisions"]["precision"], 1.0)
        self.assertEqual(len(result["unmatchedGold"]), 1)
        self.assertEqual(len(result["unmatchedPredicted"]), 1)


class MetricTests(unittest.TestCase):
    def test_owner_accuracy_and_invented(self):
        gold = gold_doc([
            {"task": "offerte opvragen", "owner": None, "due": None},
            {"task": "planning sturen", "owner": "Kim", "due": None},
        ])
        export = export_doc([
            {"task": "offerte opvragen", "owner": "Youri"},
            {"task": "planning sturen", "owner": "kim"},
        ])
        items = casaeval.score_meeting(gold, export)["actionItems"]
        self.assertEqual(items["matched"], 2)
        self.assertEqual(items["ownerCorrect"], 1)
        self.assertEqual(items["ownerAccuracy"], 0.5)
        self.assertEqual(items["inventedOwners"], 1)
        self.assertEqual(items["missedOwners"], 0)

    def test_missed_owner_and_aliases(self):
        gold = gold_doc(
            [
                {"task": "planning sturen", "owner": "Kim", "due": None},
                {"task": "notulen delen", "owner": "Alex", "due": None},
                {"task": "zaal reserveren", "owner": None, "due": None},
            ],
            aliases={"Ik": "Alex"},
        )
        export = export_doc([
            {"task": "planning sturen", "owner": None},
            {"task": "notulen delen", "owner": "ik"},
            {"task": "zaal reserveren", "owner": None},
        ])
        items = casaeval.score_meeting(gold, export)["actionItems"]
        self.assertEqual(items["ownerCorrect"], 2)  # alias hit + both None
        self.assertEqual(items["missedOwners"], 1)
        self.assertEqual(items["inventedOwners"], 0)

    def test_zero_denominators_are_none(self):
        gold = gold_doc([{"task": "offerte opvragen", "owner": None, "due": None}])
        items = casaeval.score_meeting(gold, export_doc([]))["actionItems"]
        self.assertIsNone(items["precision"])
        self.assertEqual(items["recall"], 0.0)
        self.assertIsNone(items["f1"])
        self.assertIsNone(items["ownerAccuracy"])

        items = casaeval.score_meeting(
            gold_doc([]), export_doc([{"task": "offerte opvragen", "owner": None}])
        )["actionItems"]
        self.assertIsNone(items["recall"])
        self.assertEqual(items["precision"], 0.0)

    def test_aggregate_is_micro_average(self):
        first = casaeval.score_meeting(
            gold_doc([{"task": "offerte opvragen", "owner": None, "due": None}]),
            export_doc([{"task": "offerte opvragen", "owner": None}]),
        )
        second = casaeval.score_meeting(
            gold_doc([
                {"task": "zaal reserveren", "owner": None, "due": None},
                {"task": "notulen delen", "owner": None, "due": None},
                {"task": "planning sturen", "owner": None, "due": None},
            ]),
            export_doc([]),
        )
        total = casaeval.aggregate([first, second])
        self.assertEqual(total["actionItems"]["gold"], 4)
        self.assertEqual(total["actionItems"]["matched"], 1)
        self.assertEqual(total["actionItems"]["recall"], 0.25)  # not (1.0 + 0.0) / 2
        self.assertEqual(total["actionItems"]["precision"], 1.0)
        self.assertEqual(total["meetings"], 2)
        self.assertNotIn("unmatchedGold", total)

    def test_threshold_is_the_module_default(self):
        gold = gold_doc([{"task": "offerte opvragen", "owner": None, "due": None}])
        export = export_doc([{"task": "offerte accepteren", "owner": None}])  # F1 exactly 0.5
        self.assertEqual(casaeval.DEFAULT_THRESHOLD, 0.5)
        self.assertEqual(casaeval.score_meeting(gold, export)["actionItems"]["matched"], 1)
        self.assertEqual(
            casaeval.score_meeting(gold, export, threshold=0.6)["actionItems"]["matched"], 0
        )


class LoadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def load_export_variant(self, mutate):
        doc = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        mutate(doc)
        path = self.tmp / "e.json"
        write_json(path, doc)
        return casaeval.load_export(path)

    def test_export_rejects_wrong_schema_version_and_missing_keys(self):
        with self.assertRaises(casaeval.FormatError):
            self.load_export_variant(lambda d: d.update(schemaVersion=2))
        with self.assertRaises(casaeval.FormatError):
            self.load_export_variant(lambda d: d.update(schemaVersion=True))
        with self.assertRaises(casaeval.FormatError):
            self.load_export_variant(lambda d: d.pop("decisions"))
        with self.assertRaises(casaeval.FormatError):
            self.load_export_variant(lambda d: d["meeting"].pop("id"))
        with self.assertRaises(casaeval.FormatError):
            self.load_export_variant(lambda d: d["actionItems"].append({"owner": None}))

    def test_invalid_json_is_format_error(self):
        path = self.tmp / "bad.json"
        path.write_text("{not json", encoding="utf-8")
        with self.assertRaises(casaeval.FormatError):
            casaeval.load_export(path)
        with self.assertRaises(casaeval.FormatError):
            casaeval.load_gold(path)

    def test_gold_requires_boolean_reviewed(self):
        doc = json.loads(EXAMPLE_GOLD.read_text(encoding="utf-8"))
        doc["reviewed"] = "yes"
        path = self.tmp / "g.json"
        write_json(path, doc)
        with self.assertRaises(casaeval.FormatError):
            casaeval.load_gold(path)

    def test_gold_rejects_export_file(self):
        with self.assertRaises(casaeval.FormatError):
            casaeval.load_gold(EXAMPLE_EXPORT)


class CLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_example_prints_meeting_and_total_lines(self):
        code, out, err = run_main(["score", "--gold", str(EXAMPLE_GOLD), "--export", str(EXAMPLE_EXPORT)])
        self.assertEqual(code, 0, err)
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith("Refinement Demo-team  AI P=0.75 R=0.75 F1=0.75"), lines[0])
        self.assertIn("owner=0.67 invented=1  DEC R=1.00", lines[0])
        self.assertTrue(lines[1].startswith("TOTAL  AI P=0.75"), lines[1])
        self.assertEqual(err, "")

    def test_unreviewed_warns(self):
        doc = json.loads(EXAMPLE_GOLD.read_text(encoding="utf-8"))
        doc["reviewed"] = False
        gold = self.tmp / "gold.json"
        write_json(gold, doc)
        argv = ["score", "--gold", str(gold), "--export", str(EXAMPLE_EXPORT)]

        code, _, err = run_main(argv)
        self.assertEqual(code, 0)
        self.assertIn("unreviewed", err)
        self.assertIn(str(gold), err)

        code, _, err = run_main(argv + ["--strict"])
        self.assertEqual(code, 3)
        self.assertIn("unreviewed", err)

    def test_bad_schema_exits_2(self):
        doc = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        doc["schema"] = "other"
        export = self.tmp / "export.json"
        write_json(export, doc)
        code, _, err = run_main(["score", "--gold", str(EXAMPLE_GOLD), "--export", str(export)])
        self.assertEqual(code, 2)
        self.assertIn("schema", err)

    def test_usage_errors_exit_2(self):
        code, _, _ = run_main(["score", "--gold", str(EXAMPLE_GOLD)])
        self.assertEqual(code, 2)
        code, _, _ = run_main(["score", "--gold", str(self.tmp / "missing.json"), "--export", str(EXAMPLE_EXPORT)])
        self.assertEqual(code, 2)
        code, _, _ = run_main(["score", "--gold", str(EXAMPLE_GOLD), "--export", str(EXAMPLE_EXPORT), "--threshold", "1.5"])
        self.assertEqual(code, 2)
        code, _, _ = run_main([])
        self.assertEqual(code, 2)

    def test_directory_pairing(self):
        gold_dir, export_dir = self.tmp / "gold", self.tmp / "exports"
        gold_dir.mkdir()
        export_dir.mkdir()
        shutil.copy(EXAMPLE_GOLD, gold_dir / "synthetic.json")
        shutil.copy(EXAMPLE_EXPORT, export_dir / "synthetic.json")
        extra = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        extra["meeting"]["id"] = "00000000-0000-4000-8000-0000000000FF"
        write_json(export_dir / "lonely.json", extra)

        code, out, err = run_main(["score", "--gold", str(gold_dir), "--export", str(export_dir), "--json"])
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertEqual(len(report["meetings"]), 1)
        self.assertIn("lonely.json", err)

    def test_pairing_ignores_uuid_case(self):
        export_dir = self.tmp / "exports"
        export_dir.mkdir()
        doc = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        doc["meeting"]["id"] = doc["meeting"]["id"].lower()
        write_json(export_dir / "e.json", doc)
        code, out, err = run_main(["score", "--gold", str(EXAMPLE_GOLD), "--export", str(export_dir), "--json"])
        self.assertEqual(code, 0, err)
        self.assertEqual(len(json.loads(out)["meetings"]), 1)

    def test_no_pairs_exits_2(self):
        export_dir = self.tmp / "exports"
        export_dir.mkdir()
        doc = json.loads(EXAMPLE_EXPORT.read_text(encoding="utf-8"))
        doc["meeting"]["id"] = "other"
        write_json(export_dir / "e.json", doc)
        code, _, err = run_main(["score", "--gold", str(EXAMPLE_GOLD), "--export", str(export_dir)])
        self.assertEqual(code, 2)
        self.assertIn("e.json", err)

    def test_json_output_shape(self):
        code, out, err = run_main(
            ["score", "--gold", str(EXAMPLE_GOLD), "--export", str(EXAMPLE_EXPORT), "--json"]
        )
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertEqual(set(report.keys()), {"meetings", "total"})
        self.assertEqual(report["meetings"][0]["actionItems"]["matched"], 3)
        self.assertEqual(report["total"]["actionItems"]["recall"], 0.75)


if __name__ == "__main__":
    unittest.main()
