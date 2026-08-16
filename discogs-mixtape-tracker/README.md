# Discogs Mixtape Tracker

Pulls a DJ-mix / mixtape master's tracklist from Discogs, finds the most
likely Discogs release for each individual track, scores how confident that
match is, and writes it all to a Google Sheet (or a local CSV) for review.

Built for something like [Craig Richards – fabric 01](https://www.discogs.com/master/268442-Craig-Richards-Fabric-01),
where the master's tracklist is one continuous mix, e.g. track 1 is
`Gemini – At That Café`, and each track needs to be resolved to its own
Discogs release (the way you'd search
[`Gemini – At That Café` on Discogs](https://www.discogs.com/search?q=Gemini%E2%80%93%09At+That+Caf%C3%A9&type=release)).

## ⚠️ Status: built, not yet run against live Discogs data

This was built in a sandbox whose network egress policy blocks
`api.discogs.com` and `www.discogs.com` entirely (a 403 at the proxy level,
not a bug in this code). So: the Discogs client, tracklist parser, matching
engine, and sheet writer are all implemented and unit-tested against
hand-built fixtures shaped like the real Discogs API responses — but nobody
has run this against fabric 01 for real yet. Run it once you have network
access (locally, or from an environment with discogs.com allow-listed) and
treat the first real run as a calibration pass — see
[Calibrating the confidence score](#calibrating-the-confidence-score).

## Setup

```bash
cd discogs-mixtape-tracker
pip install -r requirements.txt
cp .env.example .env   # then fill in the values below
```

### Discogs

1. Get a personal access token: https://www.discogs.com/settings/developers
2. Set `DISCOGS_TOKEN` (env var, or `--token`). This isn't strictly required
   — unauthenticated search works — but it raises the rate limit from
   25 req/min to 60 req/min, which matters once you're doing one search per
   track on a 12+ track mix.

### Google Sheets

1. In Google Cloud Console, create (or reuse) a project and enable the
   **Google Sheets API** and **Google Drive API**.
2. Create a **service account**, then create a JSON key for it and download
   it. Set `GOOGLE_APPLICATION_CREDENTIALS` to that file's path (or pass
   `--credentials`).
3. Either:
   - **Write into a spreadsheet you already own**: share that spreadsheet
     with the service account's `client_email` (found in the JSON key) as
     an Editor, then pass its id via `--spreadsheet-id` (the long id in the
     sheet's URL).
   - **Let the tool create a new spreadsheet**: pass `--share-with
     you@example.com` (or set `SHARE_WITH`) so the newly-created sheet gets
     shared with your own account — otherwise it's only visible to the
     service account and won't show up in your Google Drive.

## Usage

```bash
# Fabric 01, writing to a Google Sheet you already share with the service account:
python -m discogs_mixtape_tracker \
  "https://www.discogs.com/master/268442-Craig-Richards-Fabric-01" \
  --spreadsheet-id 1AbCdEfGhIjKlMnOpQrStUvWxYz \
  --sheet-name "fabric 01"

# Or just write a CSV to review locally first:
python -m discogs_mixtape_tracker \
  "https://www.discogs.com/master/268442-Craig-Richards-Fabric-01" \
  --csv-out fabric01_review.csv
```

If no `--csv-out`, `--spreadsheet-id`, or Google credentials are supplied at
all, it falls back to writing `tracklist_review.csv` in the current
directory so a run always produces something you can look at.

Progress and per-track results are logged to stderr as it runs, e.g.:

```
'fabric 01' — 14 tracks
[1/14] Searching: Gemini - At That Café
    -> confidence 92% (OK) https://www.discogs.com/master/12345
[2/14] Searching: Ray Kajioka - Elevation
    -> confidence 60% (CHECK VERSION) https://www.discogs.com/master/67890
```

## What ends up in the sheet

One row per track:

| Column | Meaning |
|---|---|
| `#` | Track number on the mix |
| `Track Artist` / `Track Title` | Parsed from the master's tracklist |
| `Duration` | If Discogs has it |
| `Discogs Link` | Best-match URL — a **master** page when available (version-agnostic), else a specific **release** page |
| `Link Type` | `master`, `release`, or `none` |
| `Confidence` | See below |
| `Artist Match %` / `Title Match %` | Text-similarity scores for the chosen candidate |
| `# Release Matches` | How many search results passed the similarity threshold |
| `# Distinct Recordings` | Of those, how many are actually *different* recordings (grouped by Discogs `master_id`) rather than just different pressings of the same one |
| `Review Flag` | `OK`, `REVIEW`, `CHECK VERSION`, `LOW CONFIDENCE`, or `NOT FOUND` |
| `Notes` | Short explanation |

## How the confidence score works

The hard part, as expected: searching Discogs for `artist + title` returns
a pile of releases, and a lot of those hits are either the same recording
released on five different pressings, or a completely different track that
happens to share a name. Raw match count alone doesn't tell you which
situation you're in — so the score doesn't use raw match count.

1. **Text match.** Each search result's `title` field (Discogs formats it
   as `"Artist - Release Title"`) is split and compared against the
   track's artist and title independently, using normalized
   (accent-/punctuation-/case-insensitive) string similarity. These are
   averaged 50/50 into a `match_score` per candidate.
2. **Threshold filter.** Candidates below `--threshold` (default `0.55`)
   are dropped as noise — e.g. a track by a different artist that just
   happens to share a word.
3. **Group by recording, not by release.** Surviving candidates are
   grouped by Discogs `master_id`. Multiple pressings of the *same*
   recording collapse into one group — that's not ambiguity, that's just
   Discogs having a UK 12", a US CD reissue, etc. The number of **groups**
   is `# Distinct Recordings`; that's the real ambiguity signal.
4. **Pick the best.** Within the best-scoring group, the specific pressing
   with the highest match score (ties broken by Discogs "have" count, as a
   popularity proxy) becomes the chosen candidate. If it has a
   `master_id`, the link points at the **master** page rather than that one
   pressing — deliberately version-agnostic, since we usually can't know
   which exact pressing a DJ actually played.
5. **Confidence.** `best_candidate.match_score × ambiguity_factor`, where
   `ambiguity_factor` is `1.0` for one distinct recording and decays
   (`1 − 0.15` per extra distinct recording, floored at `0.35`) as more
   non-equivalent versions compete for the same title.

This is a starting formula, not a validated model — the weights (`0.5/0.5`
text split, `0.55` threshold, `0.15` ambiguity decay) are reasonable
defaults, not something tuned against real Discogs data yet, since this
sandbox couldn't reach Discogs to check. See below for how to calibrate it.

## Calibrating the confidence score

Once you can actually run this:

1. Run it against fabric 01 with `--csv-out` and open the result.
2. For each row, sanity-check the `Discogs Link` yourself, especially any
   row flagged `CHECK VERSION` or below ~70% confidence.
3. Decide whether the *number* roughly matches your own trust in the link.
   Two easy knobs to adjust in `discogs_mixtape_tracker/matching.py` if not:
   - `DEFAULT_THRESHOLD` — raise it if obviously-wrong tracks are sneaking
     through as candidates; lower it if correct tracks are being dropped
     entirely (`NOT FOUND`) because of how Discogs phrases the title.
   - `_ambiguity_factor()` — steepen the decay if `CHECK VERSION` rows are
     still showing confidence too high to distinguish from genuinely
     unambiguous ones.
4. Re-run on a second, different mix master to make sure the tuning wasn't
   overfit to fabric 01's specific tracklist quirks.

## Known limitations

- Discogs' tracklist for mix masters is one string per track (no reliable
  per-track duration/artist metadata beyond what's embedded in the title),
  so parsing relies on splitting on `" – "` / `" — "` / `" - "`. An artist
  or title with an unusual separator, or no separator at all, will show up
  in the sheet with an empty `Track Artist` and get flagged `NOT FOUND` —
  worth a manual glance at the raw tracklist for anything like that.
- The search query is just `f"{artist} {title}"` against Discogs'
  `/database/search?type=release`. It's the same query strategy the task
  was scoped around (see the fabric 01 example search in the task), but it
  won't help if Discogs' own search ranking buries the right release past
  `--per_page` (default 50) results for an extremely common title.
- Rate limiting is a fixed delay between requests (1.05s authenticated /
  2.5s unauthenticated) — fine for a single mix, but a very long tracklist
  will take a few minutes.
