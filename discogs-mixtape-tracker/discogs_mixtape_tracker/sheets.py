"""Write match results to a local CSV and/or a Google Sheet."""

from __future__ import annotations

import csv
import os
from datetime import datetime, timezone
from typing import List, Optional

from .models import MatchResult

HEADER = [
    "#",
    "Track Artist",
    "Track Title",
    "Duration",
    "Discogs Link",
    "Link Type",
    "Confidence",
    "Artist Match %",
    "Title Match %",
    "# Release Matches",
    "# Distinct Recordings",
    "Review Flag",
    "Notes",
]


def match_result_to_row(mr: MatchResult) -> list:
    best = mr.best
    return [
        mr.track.index,
        mr.track.artist,
        mr.track.title,
        mr.track.duration or "",
        mr.best_link or "",
        mr.best_link_type,
        f"{mr.confidence * 100:.0f}%",
        f"{best.artist_score * 100:.0f}%" if best else "",
        f"{best.title_score * 100:.0f}%" if best else "",
        mr.num_release_matches,
        mr.num_distinct_recordings,
        mr.review_flag,
        mr.notes,
    ]


def _preamble_rows(album_title: str, master_url: str) -> list:
    return [
        [f"Album: {album_title}"],
        [f"Master: {master_url}"],
        [f"Compiled: {datetime.now(timezone.utc).isoformat(timespec='seconds')}"],
        [],
    ]


def write_csv(album_title: str, master_url: str, results: List[MatchResult], path: str) -> str:
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        for row in _preamble_rows(album_title, master_url):
            writer.writerow(row)
        writer.writerow(HEADER)
        for mr in results:
            writer.writerow(match_result_to_row(mr))
    return path


def write_google_sheet(
    album_title: str,
    master_url: str,
    results: List[MatchResult],
    spreadsheet_id: Optional[str] = None,
    sheet_name: str = "Tracklist",
    credentials_path: Optional[str] = None,
    share_with: Optional[str] = None,
) -> str:
    """Writes results into a Google Sheet, returning the spreadsheet URL.

    Requires a service-account JSON key (`credentials_path` or the
    GOOGLE_APPLICATION_CREDENTIALS env var) with the Sheets API enabled.
    If `spreadsheet_id` is omitted a new spreadsheet is created; if
    `share_with` is set on creation, it's shared to that address as an
    editor (service accounts can't otherwise be seen in your Drive UI).
    To write into a sheet you already own, share that sheet with the
    service account's `client_email` and pass its id via `spreadsheet_id`.
    """

    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError as e:  # pragma: no cover - exercised only when deps missing
        raise RuntimeError(
            "gspread and google-auth are required for Google Sheets output. "
            "Install with `pip install -r requirements.txt`."
        ) from e

    credentials_path = credentials_path or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not credentials_path:
        raise RuntimeError(
            "No Google service-account credentials configured. Set "
            "GOOGLE_APPLICATION_CREDENTIALS to the path of a service-account JSON "
            "key, or use --csv-out to write a local file instead."
        )

    scopes = [
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
    ]
    creds = Credentials.from_service_account_file(credentials_path, scopes=scopes)
    gc = gspread.authorize(creds)

    if spreadsheet_id:
        sh = gc.open_by_key(spreadsheet_id)
    else:
        sh = gc.create(f"Discogs Mixtape Tracker — {album_title}")
        if share_with:
            sh.share(share_with, perm_type="user", role="writer")

    try:
        ws = sh.worksheet(sheet_name)
        ws.clear()
    except gspread.WorksheetNotFound:
        ws = sh.add_worksheet(title=sheet_name, rows=str(len(results) + 10), cols=str(len(HEADER)))

    rows = _preamble_rows(album_title, master_url) + [HEADER] + [match_result_to_row(mr) for mr in results]
    ws.update("A1", rows)
    return sh.url
