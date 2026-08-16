"""Minimal client for the parts of the Discogs API this tool needs.

Docs: https://www.discogs.com/developers
"""

from __future__ import annotations

import os
import time
from typing import Any, Dict, List, Optional

import requests

API_ROOT = "https://api.discogs.com"
USER_AGENT = "DiscogsMixtapeTracker/0.1 +https://github.com/colincurrie/ai_ideas"

# Discogs rate limits unauthenticated requests to 25/min and authenticated
# (token) requests to 60/min. We stay comfortably under either.
UNAUTH_MIN_INTERVAL = 2.5
AUTH_MIN_INTERVAL = 1.05


class DiscogsAPIError(RuntimeError):
    pass


class DiscogsClient:
    def __init__(
        self,
        token: Optional[str] = None,
        session: Optional[requests.Session] = None,
        min_interval: Optional[float] = None,
    ):
        self.token = token or os.environ.get("DISCOGS_TOKEN")
        self.session = session or requests.Session()
        self.min_interval = min_interval or (
            AUTH_MIN_INTERVAL if self.token else UNAUTH_MIN_INTERVAL
        )
        self._last_request_time = 0.0

    def _headers(self) -> Dict[str, str]:
        return {"User-Agent": USER_AGENT}

    def _params(self, extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        params = dict(extra or {})
        if self.token:
            params["token"] = self.token
        return params

    def _throttle(self) -> None:
        elapsed = time.monotonic() - self._last_request_time
        wait = self.min_interval - elapsed
        if wait > 0:
            time.sleep(wait)
        self._last_request_time = time.monotonic()

    def _get(self, path: str, params: Optional[Dict[str, Any]] = None, _retried: bool = False) -> Dict[str, Any]:
        self._throttle()
        resp = self.session.get(
            f"{API_ROOT}{path}", headers=self._headers(), params=self._params(params), timeout=30
        )
        if resp.status_code == 429 and not _retried:
            time.sleep(5)
            return self._get(path, params, _retried=True)
        if resp.status_code == 404:
            raise DiscogsAPIError(f"Not found: {API_ROOT}{path}")
        resp.raise_for_status()
        return resp.json()

    def get_master(self, master_id: int) -> Dict[str, Any]:
        return self._get(f"/masters/{master_id}")

    def get_release(self, release_id: int) -> Dict[str, Any]:
        return self._get(f"/releases/{release_id}")

    def search_release(self, query: str, per_page: int = 50) -> List[Dict[str, Any]]:
        data = self._get(
            "/database/search",
            {"q": query, "type": "release", "per_page": per_page},
        )
        return data.get("results", [])
