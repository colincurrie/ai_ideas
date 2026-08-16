"""CLI: pull a Discogs mixtape master's tracklist, match each track to a
Discogs release with a confidence score, and write it to CSV/Google Sheets.
"""

from __future__ import annotations

import argparse
import os
import sys

from .discogs_api import DiscogsClient
from .matching import DEFAULT_THRESHOLD, find_best_match
from .sheets import write_csv, write_google_sheet
from .tracklist import parse_master_id, parse_master_tracklist


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Track a Discogs mixtape master's tracklist and link each track to "
            "its most likely Discogs release, with a confidence score."
        )
    )
    parser.add_argument(
        "master",
        help=(
            "Discogs master URL or numeric master id, e.g. "
            "https://www.discogs.com/master/268442-Craig-Richards-Fabric-01 or 268442"
        ),
    )
    parser.add_argument("--token", help="Discogs personal access token (or set DISCOGS_TOKEN)")
    parser.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        help="Minimum artist/title match score (0-1) for a search result to count as a candidate",
    )
    parser.add_argument("--csv-out", help="Write results to this local CSV file")
    parser.add_argument("--spreadsheet-id", help="Existing Google Spreadsheet ID to write into")
    parser.add_argument("--sheet-name", default="Tracklist", help="Worksheet/tab name to write")
    parser.add_argument(
        "--credentials",
        help="Path to a Google service-account JSON key (or set GOOGLE_APPLICATION_CREDENTIALS)",
    )
    parser.add_argument("--share-with", help="Email to share a newly created spreadsheet with")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    client = DiscogsClient(token=args.token)
    master_id = parse_master_id(args.master)
    master_json = client.get_master(master_id)
    album_title, tracks = parse_master_tracklist(master_json)
    master_url = f"https://www.discogs.com/master/{master_id}"

    if not tracks:
        print("No tracks found on this master's tracklist.", file=sys.stderr)
        return 1

    print(f"'{album_title}' — {len(tracks)} tracks", file=sys.stderr)

    results = []
    for track in tracks:
        print(f"[{track.index}/{len(tracks)}] Searching: {track.artist} - {track.title}", file=sys.stderr)
        mr = find_best_match(track, client, threshold=args.threshold)
        results.append(mr)
        print(
            f"    -> confidence {mr.confidence * 100:.0f}% ({mr.review_flag}) {mr.best_link or 'NO MATCH'}",
            file=sys.stderr,
        )

    wrote_something = False

    if args.csv_out:
        path = write_csv(album_title, master_url, results, args.csv_out)
        print(f"Wrote {path}")
        wrote_something = True

    have_google_creds = args.credentials or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if args.spreadsheet_id or have_google_creds:
        url = write_google_sheet(
            album_title,
            master_url,
            results,
            spreadsheet_id=args.spreadsheet_id,
            sheet_name=args.sheet_name,
            credentials_path=args.credentials,
            share_with=args.share_with,
        )
        print(f"Wrote Google Sheet: {url}")
        wrote_something = True

    if not wrote_something:
        path = write_csv(album_title, master_url, results, "tracklist_review.csv")
        print(
            f"No Google Sheets credentials configured; wrote {path} for review instead "
            "(see README for how to set up Google Sheets output)."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
