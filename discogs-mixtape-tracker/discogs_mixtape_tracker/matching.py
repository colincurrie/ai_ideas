"""Confidence-scored matching between a mixtape Track and Discogs releases.

The hard part described in the brief: a search on artist+title will often
return several releases — different pressings of the same recording (same
`master_id`, e.g. a 12" and its later CD reissue) as well as genuinely
different tracks that happen to share a name. We need a confidence score
that reflects both:

1. How well the text matches (artist/title string similarity), and
2. How *ambiguous* the result set is — not raw hit count, but the number
   of distinct recordings (grouped by master_id) among the good matches.
   Five pressings of the same master is not ambiguous; five different
   masters sharing a title is.

Scoring, in order:

- Each search result is normalized and scored against the track's artist
  and title independently (0-1 each, via difflib.SequenceMatcher on
  normalized text). `match_score = 0.5*artist_score + 0.5*title_score`.
- Results below `threshold` are discarded as noise.
- Remaining candidates are grouped by `master_id` (releases without a
  master_id are their own group, keyed by release id) — this is the
  "distinct recordings" count.
- The best candidate is the highest `match_score` (ties broken by
  Discogs "have" count, as a proxy for it being the well-known pressing)
  within the group with the best combination of match quality and
  popularity.
- `confidence = best_candidate.match_score * ambiguity_factor`, where
  `ambiguity_factor` is 1.0 for a single distinct recording and decays as
  more distinct (non-equivalent) recordings compete for the same title.
- The link we hand back points at the *master* page when the best
  candidate has one (a master page is version-agnostic — the right call
  when we can't be sure which pressing was actually used — falling back
  to the specific release page otherwise.

These weights and thresholds are a starting point, not a calibrated
model — the intent is for you to run this against a few known mixtapes,
review the sheet it produces, and tune `THRESHOLD` / the ambiguity decay
below once you've seen how the scores line up with reality.
"""

from __future__ import annotations

import re
import unicodedata
from difflib import SequenceMatcher
from typing import Any, Dict, List

from .discogs_api import DiscogsClient
from .models import Candidate, MatchResult, Track
from .tracklist import split_artist_title

DEFAULT_THRESHOLD = 0.55

_NON_ALNUM_RE = re.compile(r"[^a-z0-9 ]+")
_WHITESPACE_RE = re.compile(r"\s+")


def normalize(text: str) -> str:
    """Lowercase, strip accents/punctuation, collapse whitespace."""

    if not text:
        return ""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.lower().replace("&", "and")
    text = _NON_ALNUM_RE.sub(" ", text)
    text = _WHITESPACE_RE.sub(" ", text).strip()
    return text


def similarity(a: str, b: str) -> float:
    a_n, b_n = normalize(a), normalize(b)
    if not a_n or not b_n:
        return 0.0
    return SequenceMatcher(None, a_n, b_n).ratio()


def _score_result(track: Track, result: Dict[str, Any]) -> Candidate:
    display_title = result.get("title", "")
    cand_artist, cand_title = split_artist_title(display_title)
    artist_score = similarity(track.artist, cand_artist)
    title_score = similarity(track.title, cand_title)
    match_score = 0.5 * artist_score + 0.5 * title_score

    release_id = result.get("id")
    uri = result.get("uri") or ""
    discogs_url = f"https://www.discogs.com{uri}" if uri else f"https://www.discogs.com/release/{release_id}"
    community = result.get("community") or {}

    return Candidate(
        release_id=release_id,
        master_id=result.get("master_id") or None,
        resource_url=result.get("resource_url", ""),
        discogs_url=discogs_url,
        display_title=display_title,
        candidate_artist=cand_artist,
        candidate_title=cand_title,
        year=result.get("year"),
        format=", ".join(result.get("format") or []) or None,
        country=result.get("country"),
        have=community.get("have", 0) or 0,
        want=community.get("want", 0) or 0,
        artist_score=artist_score,
        title_score=title_score,
        match_score=match_score,
    )


def score_candidates(track: Track, results: List[Dict[str, Any]], threshold: float = DEFAULT_THRESHOLD) -> List[Candidate]:
    scored = [_score_result(track, r) for r in results]
    return [c for c in scored if c.match_score >= threshold]


def _ambiguity_factor(num_distinct_recordings: int) -> float:
    if num_distinct_recordings <= 1:
        return 1.0
    return max(0.35, 1 - 0.15 * (num_distinct_recordings - 1))


def _review_flag(confidence: float, num_distinct_recordings: int) -> str:
    if confidence >= 0.85 and num_distinct_recordings == 1:
        return "OK"
    if num_distinct_recordings > 1 and confidence >= 0.5:
        return "CHECK VERSION"
    if confidence >= 0.6:
        return "REVIEW"
    return "LOW CONFIDENCE"


def build_match_result(track: Track, candidates: List[Candidate]) -> MatchResult:
    num_release_matches = len(candidates)

    if not candidates:
        return MatchResult(
            track=track,
            candidates=[],
            best=None,
            best_link=None,
            best_link_type="none",
            confidence=0.0,
            num_release_matches=0,
            num_distinct_recordings=0,
            review_flag="NOT FOUND",
            notes="No release matched artist/title above the similarity threshold.",
        )

    groups: Dict[Any, List[Candidate]] = {}
    for c in candidates:
        key = c.master_id if c.master_id else f"release:{c.release_id}"
        groups.setdefault(key, []).append(c)

    num_distinct_recordings = len(groups)

    def group_rank(items: List[Candidate]):
        best_in_group = max(items, key=lambda c: c.match_score)
        popularity = sum(c.have for c in items)
        return (round(best_in_group.match_score, 6), popularity)

    best_key = max(groups, key=lambda k: group_rank(groups[k]))
    best_group = groups[best_key]
    best_candidate = max(best_group, key=lambda c: (round(c.match_score, 6), c.have))

    if best_candidate.master_id:
        best_link = f"https://www.discogs.com/master/{best_candidate.master_id}"
        best_link_type = "master"
    else:
        best_link = best_candidate.discogs_url
        best_link_type = "release"

    ambiguity_factor = _ambiguity_factor(num_distinct_recordings)
    confidence = round(best_candidate.match_score * ambiguity_factor, 3)
    review_flag = _review_flag(confidence, num_distinct_recordings)

    notes = f"{num_release_matches} release match(es) across {num_distinct_recordings} distinct recording(s)."
    if num_distinct_recordings > 1:
        notes += " Multiple non-equivalent versions found; linked to the best-matching / most popular one — verify."

    return MatchResult(
        track=track,
        candidates=sorted(candidates, key=lambda c: c.match_score, reverse=True),
        best=best_candidate,
        best_link=best_link,
        best_link_type=best_link_type,
        confidence=confidence,
        num_release_matches=num_release_matches,
        num_distinct_recordings=num_distinct_recordings,
        review_flag=review_flag,
        notes=notes,
    )


def find_best_match(
    track: Track,
    client: DiscogsClient,
    threshold: float = DEFAULT_THRESHOLD,
    per_page: int = 50,
) -> MatchResult:
    query = f"{track.artist} {track.title}".strip()
    results = client.search_release(query, per_page=per_page)
    candidates = score_candidates(track, results, threshold=threshold)
    return build_match_result(track, candidates)
