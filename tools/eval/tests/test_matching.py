"""Tests for casaeval normalisation, similarity, matching and owner aliases."""

import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "casaeval", Path(__file__).resolve().parents[1] / "casaeval.py"
)
casaeval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(casaeval)


class NormalizeTests(unittest.TestCase):
    def test_normalize_folds_diacritics_and_case(self):
        self.assertEqual(
            casaeval.normalize("Café-overleg  GEÏNTERESSEERD"),
            "cafe overleg geinteresseerd",
        )

    def test_normalize_strips_timestamps_and_bold(self):
        self.assertEqual(casaeval.normalize("**Kim** — offerte [12:34]"), "kim offerte")
        self.assertEqual(casaeval.normalize("**Kim** — offerte [1:02:03]"), "kim offerte")

    def test_tokens_drop_stopwords(self):
        self.assertEqual(
            casaeval.tokens("Youri stuurt de planning naar Kim"),
            ["youri", "stuurt", "planning", "kim"],
        )


class SimilarityTests(unittest.TestCase):
    def test_similarity_identical_is_one(self):
        self.assertEqual(casaeval.similarity("Offerte opvragen", "offerte  opvragen!"), 1.0)

    def test_similarity_paraphrase_passes_default(self):
        self.assertGreaterEqual(
            casaeval.similarity("Youri stuurt de planning naar Kim", "Planning naar Kim sturen"),
            0.55,
        )
        self.assertEqual(casaeval.DEFAULT_THRESHOLD, 0.55)

    def test_similarity_unrelated_is_low(self):
        self.assertLess(casaeval.similarity("Budget goedkeuren", "Planning naar Kim sturen"), 0.4)
        self.assertLess(casaeval.similarity("Release notes schrijven", "Retro inplannen"), 0.4)

    def test_similarity_empty_inputs(self):
        self.assertEqual(casaeval.similarity("", "  "), 1.0)
        self.assertEqual(casaeval.similarity("", "offerte"), 0.0)
        self.assertEqual(casaeval.similarity("offerte", "!!"), 0.0)

    def test_token_f1(self):
        self.assertEqual(casaeval.token_f1("offerte opvragen", "Offerte opvragen"), 1.0)
        self.assertEqual(casaeval.token_f1("offerte", "planning"), 0.0)
        # Multiset: "kim kim" vs "kim" -> overlap 1, P=1/1, R=1/2 -> F1=2/3.
        self.assertAlmostEqual(casaeval.token_f1("kim kim", "kim"), 2 / 3)


class MatchTests(unittest.TestCase):
    def test_match_is_one_to_one(self):
        gold = ["offerte opvragen", "planning sturen"]
        predicted = ["offerte opvragen", "offerte opvragen bij leverancier"]
        pairs = casaeval.match(gold, predicted)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0], (0, 0, 1.0))
        self.assertNotIn(1, [g for g, _, _ in pairs])

    def test_match_is_deterministic_on_ties(self):
        gold = ["offerte opvragen", "offerte opvragen"]
        predicted = ["offerte opvragen", "offerte opvragen"]
        first = casaeval.match(gold, predicted)
        self.assertEqual(first, [(0, 0, 1.0), (1, 1, 1.0)])
        for _ in range(5):
            self.assertEqual(casaeval.match(gold, predicted), first)

    def test_match_tie_prefers_lowest_pred_index(self):
        pairs = casaeval.match(["offerte opvragen"], ["planning", "offerte opvragen", "offerte opvragen"])
        self.assertEqual(pairs, [(0, 1, 1.0)])

    def test_match_respects_threshold(self):
        self.assertEqual(casaeval.match(["budget goedkeuren"], ["retro inplannen"]), [])
        self.assertEqual(len(casaeval.match(["budget goedkeuren"], ["retro inplannen"], threshold=0.0)), 1)

    def test_match_empty_inputs(self):
        self.assertEqual(casaeval.match([], ["x"]), [])
        self.assertEqual(casaeval.match(["x"], []), [])


class CanonicalOwnerTests(unittest.TestCase):
    def test_canonical_owner_aliases(self):
        a = {"Ik": "Youri", "Youri Broekhuizen": "Youri"}
        self.assertEqual(casaeval.canonical_owner("ik", a), "youri")
        self.assertEqual(casaeval.canonical_owner("Youri Broekhuizen", a), "youri")
        self.assertEqual(casaeval.canonical_owner("?", a), None)
        self.assertIsNone(casaeval.canonical_owner(None, a))

    def test_canonical_owner_without_alias_is_normalized(self):
        self.assertEqual(casaeval.canonical_owner("**Kim**", {}), "kim")
        self.assertIsNone(casaeval.canonical_owner("", {}))
        self.assertIsNone(casaeval.canonical_owner("  ? ", {}))


if __name__ == "__main__":
    unittest.main()
