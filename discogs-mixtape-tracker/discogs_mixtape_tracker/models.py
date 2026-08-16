"""Data structures shared across the tracker."""

from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class Track:
    """One track parsed off a mixtape master's tracklist."""

    index: int
    position: str
    raw_title: str
    artist: str
    title: str
    duration: Optional[str] = None


@dataclass
class Candidate:
    """One Discogs release search result that plausibly matches a track."""

    release_id: int
    master_id: Optional[int]
    resource_url: str
    discogs_url: str
    display_title: str
    candidate_artist: str
    candidate_title: str
    year: Optional[str]
    format: Optional[str]
    country: Optional[str]
    have: int = 0
    want: int = 0
    artist_score: float = 0.0
    title_score: float = 0.0
    match_score: float = 0.0


@dataclass
class MatchResult:
    """The outcome of matching one Track against Discogs search results."""

    track: Track
    candidates: List[Candidate]
    best: Optional[Candidate]
    best_link: Optional[str]
    best_link_type: str  # "master" | "release" | "none"
    confidence: float  # 0.0-1.0
    num_release_matches: int
    num_distinct_recordings: int
    review_flag: str
    notes: str
