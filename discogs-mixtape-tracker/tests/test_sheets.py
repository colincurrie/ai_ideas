import csv
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from discogs_mixtape_tracker.matching import build_match_result, score_candidates
from discogs_mixtape_tracker.models import Track
from discogs_mixtape_tracker.sheets import HEADER, write_csv

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


class WriteCsvTests(unittest.TestCase):
    def test_writes_preamble_header_and_rows(self):
        track = Track(index=1, position="1", raw_title="Gemini – At That Café", artist="Gemini", title="At That Café")
        results = load_fixture("search_results_unambiguous.json")["results"]
        candidates = score_candidates(track, results, threshold=0.55)
        mr = build_match_result(track, candidates)

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "out.csv")
            write_csv("fabric 01", "https://www.discogs.com/master/268442", [mr], path)

            with open(path, newline="", encoding="utf-8") as f:
                rows = list(csv.reader(f))

        self.assertEqual(rows[0], ["Album: fabric 01"])
        self.assertEqual(rows[1], ["Master: https://www.discogs.com/master/268442"])
        self.assertTrue(rows[2][0].startswith("Compiled:"))
        self.assertEqual(rows[3], [])
        self.assertEqual(rows[4], HEADER)
        data_row = rows[5]
        self.assertEqual(data_row[1], "Gemini")
        self.assertEqual(data_row[2], "At That Café")
        self.assertEqual(data_row[5], "master")
        self.assertEqual(data_row[11], "OK")


if __name__ == "__main__":
    unittest.main()
