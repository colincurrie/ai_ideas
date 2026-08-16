import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from discogs_mixtape_tracker.matching import build_match_result, normalize, score_candidates, similarity
from discogs_mixtape_tracker.models import Track

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


class NormalizeSimilarityTests(unittest.TestCase):
    def test_normalize_strips_accents_and_punctuation(self):
        self.assertEqual(normalize("At That Café!"), "at that cafe")

    def test_similarity_accent_insensitive(self):
        self.assertGreater(similarity("At That Café", "At That Cafe"), 0.99)

    def test_similarity_empty_is_zero(self):
        self.assertEqual(similarity("", "Something"), 0.0)


class UnambiguousMatchTests(unittest.TestCase):
    """Two pressings of the same recording (same master_id) + one decoy."""

    def setUp(self):
        self.track = Track(index=1, position="1", raw_title="Gemini – At That Café", artist="Gemini", title="At That Café")
        self.results = load_fixture("search_results_unambiguous.json")["results"]

    def test_decoy_filtered_by_threshold(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        ids = {c.release_id for c in candidates}
        self.assertNotIn(2002, ids)  # unrelated track filtered out
        self.assertEqual(ids, {1001, 1002})

    def test_grouped_as_single_distinct_recording(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        mr = build_match_result(self.track, candidates)
        self.assertEqual(mr.num_distinct_recordings, 1)
        self.assertEqual(mr.num_release_matches, 2)

    def test_high_confidence_and_master_link(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        mr = build_match_result(self.track, candidates)
        self.assertGreaterEqual(mr.confidence, 0.85)
        self.assertEqual(mr.review_flag, "OK")
        self.assertEqual(mr.best_link_type, "master")
        self.assertEqual(mr.best_link, "https://www.discogs.com/master/555")

    def test_prefers_more_popular_pressing_when_scores_tie(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        mr = build_match_result(self.track, candidates)
        self.assertEqual(mr.best.release_id, 1001)  # higher "have" count


class AmbiguousMatchTests(unittest.TestCase):
    """Two different recordings (different master_id) both match the title."""

    def setUp(self):
        self.track = Track(index=2, position="2", raw_title="Ray Kajioka – Elevation", artist="Ray Kajioka", title="Elevation")
        self.results = load_fixture("search_results_ambiguous.json")["results"]

    def test_both_candidates_pass_threshold(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        self.assertEqual(len(candidates), 2)

    def test_flagged_as_multiple_distinct_recordings(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        mr = build_match_result(self.track, candidates)
        self.assertEqual(mr.num_distinct_recordings, 2)
        self.assertEqual(mr.review_flag, "CHECK VERSION")

    def test_confidence_lower_than_unambiguous_case(self):
        candidates = score_candidates(self.track, self.results, threshold=0.55)
        mr = build_match_result(self.track, candidates)
        self.assertLess(mr.confidence, 1.0)
        # exact title match on the non-remix candidate, discounted by ambiguity
        self.assertAlmostEqual(mr.confidence, 0.85, delta=0.01)


class NoMatchTests(unittest.TestCase):
    def test_no_results_yields_not_found(self):
        track = Track(index=3, position="3", raw_title="X", artist="Totally Obscure Artist Xyz", title="Totally Obscure Title Xyz")
        mr = build_match_result(track, [])
        self.assertEqual(mr.review_flag, "NOT FOUND")
        self.assertEqual(mr.confidence, 0.0)
        self.assertIsNone(mr.best_link)


if __name__ == "__main__":
    unittest.main()
