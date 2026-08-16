import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from discogs_mixtape_tracker.tracklist import (
    parse_master_id,
    parse_master_tracklist,
    split_artist_title,
)

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return json.load(f)


class ParseMasterIdTests(unittest.TestCase):
    def test_full_url(self):
        url = "https://www.discogs.com/master/268442-Craig-Richards-Fabric-01"
        self.assertEqual(parse_master_id(url), 268442)

    def test_bare_id_string(self):
        self.assertEqual(parse_master_id("268442"), 268442)

    def test_bare_id_int(self):
        self.assertEqual(parse_master_id(268442), 268442)

    def test_invalid_raises(self):
        with self.assertRaises(ValueError):
            parse_master_id("not a url")


class SplitArtistTitleTests(unittest.TestCase):
    def test_en_dash(self):
        self.assertEqual(
            split_artist_title("Gemini – At That Café"),
            ("Gemini", "At That Café"),
        )

    def test_hyphen_in_title_after_artist(self):
        # First separator match wins; artist itself contains no dash here.
        self.assertEqual(
            split_artist_title("Someone With A Hyphen-Name - Track - With Dash In Title"),
            ("Someone With A Hyphen-Name", "Track - With Dash In Title"),
        )

    def test_no_separator(self):
        self.assertEqual(split_artist_title("No Separator Here"), ("", "No Separator Here"))


class ParseMasterTracklistTests(unittest.TestCase):
    def setUp(self):
        self.master_json = load_fixture("master_sample.json")

    def test_album_title(self):
        title, _ = parse_master_tracklist(self.master_json)
        self.assertEqual(title, "fabric 01")

    def test_skips_headings_and_reindexes(self):
        _, tracks = parse_master_tracklist(self.master_json)
        # 4 real tracks, "Mixed By" heading skipped
        self.assertEqual([t.index for t in tracks], [1, 2, 3, 4])

    def test_first_track_matches_worked_example(self):
        _, tracks = parse_master_tracklist(self.master_json)
        first = tracks[0]
        self.assertEqual(first.artist, "Gemini")
        self.assertEqual(first.title, "At That Café")

    def test_entry_with_no_separator_falls_back_to_raw_title(self):
        _, tracks = parse_master_tracklist(self.master_json)
        last = tracks[-1]
        self.assertEqual(last.artist, "")
        self.assertEqual(last.title, "No Separator Here")


if __name__ == "__main__":
    unittest.main()
