"""Parse a Discogs *master* release's tracklist into Track objects.

Discogs stores DJ-mix / mixtape masters as a single tracklist where each
entry's ``title`` is typically ``"Artist – Track Title"`` (the mix is one
continuous recording, so there's no per-track ``artists`` field the way a
various-artists compilation would have one). Some masters do supply a
per-entry ``artists`` list though, so we prefer that when present.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Tuple

from .models import Track

# Ordered so multi-character dash separators are tried before a bare "-",
# which can otherwise false-split artist/title names that legitimately
# contain a hyphen (e.g. "Add N to X").
_SEPARATORS = [" – ", " — ", " -- ", " - "]

_MASTER_ID_RE = re.compile(r"/master/(\d+)")


def parse_master_id(master_url_or_id: str) -> int:
    """Accepts a full discogs.com master URL or a bare numeric id."""

    s = str(master_url_or_id).strip()
    match = _MASTER_ID_RE.search(s)
    if match:
        return int(match.group(1))
    if s.isdigit():
        return int(s)
    raise ValueError(f"Could not parse a Discogs master id from: {master_url_or_id!r}")


def split_artist_title(raw: str) -> Tuple[str, str]:
    for sep in _SEPARATORS:
        if sep in raw:
            artist, _, title = raw.partition(sep)
            return artist.strip(), title.strip()
    return "", raw.strip()


def parse_master_tracklist(master_json: Dict[str, Any]) -> Tuple[str, List[Track]]:
    """Returns (album_title, tracks) from a GET /masters/{id} response."""

    album_title = master_json.get("title", "")
    tracks: List[Track] = []
    idx = 0

    for entry in master_json.get("tracklist", []):
        if entry.get("type_") == "heading":
            continue

        raw_title = (entry.get("title") or "").strip()
        if not raw_title:
            continue

        entry_artists = entry.get("artists") or []
        if entry_artists:
            artist = ", ".join(a.get("name", "").strip() for a in entry_artists if a.get("name"))
            title = raw_title
        else:
            artist, title = split_artist_title(raw_title)

        if not artist or not title:
            # Couldn't confidently split this entry (no separator found) —
            # still record it so it shows up in the sheet as NOT FOUND
            # rather than silently disappearing.
            artist, title = artist or "", title or raw_title

        idx += 1
        tracks.append(
            Track(
                index=idx,
                position=entry.get("position", ""),
                raw_title=raw_title,
                artist=artist,
                title=title,
                duration=entry.get("duration") or None,
            )
        )

    return album_title, tracks
