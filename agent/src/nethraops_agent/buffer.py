"""Local SQLite buffer for telemetry frames.

The buffer is the agent's offline-tolerance + retry mechanism. Frames
land here from the collector and drain from here when the HTTP push
succeeds. SQLite is used because it's:

- always available (Python stdlib),
- atomic (the agent can crash mid-write without corrupting the file),
- fast enough at our throughput (low thousands of rows/minute),
- a single file we can ship to support if a customer hits a weird bug.

The schema is intentionally minimal — `id` (autoincrement) + `payload`
(JSON blob) + `created_at`. We never query the rows by content; the
service drains FIFO via `id ASC LIMIT N`.

Bounded by `max_rows`: on insert when at-capacity, the oldest rows are
deleted in a single statement so a multi-day outage doesn't fill the
disk.
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


@dataclass(slots=True)
class BufferedFrame:
    """One row pulled out of the buffer."""

    id: int
    created_at: float
    payload: dict


class LocalBuffer:
    """Thread-safe ring buffer backed by SQLite WAL.

    Producer (collector) and consumer (HTTP runner) are separate
    coroutines / threads — we serialise access with a single
    `threading.Lock`. SQLite WAL mode also lets the consumer read
    while the producer writes, but the lock keeps the API obvious.
    """

    def __init__(self, path: Path, *, max_rows: int = 10_000) -> None:
        self._path = path
        self._max_rows = max_rows
        self._lock = threading.Lock()
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(
            str(self._path),
            check_same_thread=False,
            isolation_level=None,  # autocommit
        )
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA temp_store=MEMORY")
        self._init_schema()

    # ----- Schema ------------------------------------------------------
    def _init_schema(self) -> None:
        with self._lock:
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS frames (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at  REAL NOT NULL,
                    payload     TEXT NOT NULL
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS ix_frames_created_at ON frames(created_at)"
            )

    # ----- Producer-side ----------------------------------------------
    def append(self, payload: dict) -> int:
        """Append one frame. Returns the new row id.

        On overflow we trim the oldest rows down to `max_rows - 1` so
        the new row fits — single statement for cost, no batching.
        """
        body = json.dumps(payload, separators=(",", ":"))
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO frames(created_at, payload) VALUES(?, ?)",
                (time.time(), body),
            )
            new_id = int(cur.lastrowid or 0)
            count = self._count_unsafe()
            if count > self._max_rows:
                # Drop the oldest (count - max_rows) rows.
                excess = count - self._max_rows
                self._conn.execute(
                    "DELETE FROM frames WHERE id IN ("
                    "  SELECT id FROM frames ORDER BY id ASC LIMIT ?"
                    ")",
                    (excess,),
                )
            return new_id

    # ----- Consumer-side ----------------------------------------------
    def peek_batch(self, batch_size: int) -> list[BufferedFrame]:
        """Read up to `batch_size` rows in FIFO order without deleting them."""
        with self._lock:
            cur = self._conn.execute(
                "SELECT id, created_at, payload FROM frames "
                "ORDER BY id ASC LIMIT ?",
                (batch_size,),
            )
            return [
                BufferedFrame(
                    id=row[0], created_at=row[1], payload=json.loads(row[2])
                )
                for row in cur
            ]

    def delete(self, ids: list[int]) -> int:
        """Delete frames by id. Used after a successful HTTP push."""
        if not ids:
            return 0
        with self._lock:
            placeholders = ",".join("?" * len(ids))
            cur = self._conn.execute(
                f"DELETE FROM frames WHERE id IN ({placeholders})",
                ids,
            )
            return int(cur.rowcount or 0)

    # ----- Introspection ----------------------------------------------
    def count(self) -> int:
        with self._lock:
            return self._count_unsafe()

    def _count_unsafe(self) -> int:
        cur = self._conn.execute("SELECT COUNT(*) FROM frames")
        return int(cur.fetchone()[0])

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    @contextmanager
    def session(self) -> Iterator["LocalBuffer"]:
        """Context manager — closes the SQLite connection on exit."""
        try:
            yield self
        finally:
            self.close()
