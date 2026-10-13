"""Generic on-disk JSON cache with TTL and stale-fallback on fetch failure."""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable
from pathlib import Path

log = logging.getLogger(__name__)


class CacheMissError(RuntimeError):
    pass


class PathCache:
    def __init__(self, path: str | Path, ttl_seconds: int, fetch: Callable[[], dict]):
        self.path = Path(path)
        self.ttl_seconds = ttl_seconds
        self._fetch = fetch

    def load(self) -> dict:
        fresh = self._read_fresh()
        if fresh is not None:
            return fresh

        try:
            data = self._fetch()
        except Exception as e:
            stale = self._read_any()
            if stale is not None:
                log.warning("fetch failed (%s); using stale cache at %s", e, self.path)
                return stale
            raise CacheMissError(
                f"fetch failed and no cache exists at {self.path}: {e}"
            ) from e

        self._write(data)
        return data

    def _read_fresh(self) -> dict | None:
        if not self.path.exists():
            return None
        if time.time() - self.path.stat().st_mtime > self.ttl_seconds:
            return None
        return self._read_any()

    def _read_any(self) -> dict | None:
        if not self.path.exists():
            return None
        try:
            return json.loads(self.path.read_text())
        except (OSError, json.JSONDecodeError) as e:
            log.warning("cache at %s is unreadable (%s)", self.path, e)
            return None

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(self.path)
