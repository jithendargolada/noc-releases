"""LocalBuffer — append, peek, delete, FIFO semantics, ring overflow."""

from __future__ import annotations

from pathlib import Path

import pytest

from nethraops_agent.buffer import LocalBuffer


def _frame(i: int) -> dict:
    return {"agent_version": "0.1.0", "frames": [{"category": "cpu", "n": i}]}


def test_appends_and_counts(tmp_path: Path) -> None:
    buf = LocalBuffer(tmp_path / "b.sqlite", max_rows=100)
    assert buf.count() == 0
    for i in range(5):
        buf.append(_frame(i))
    assert buf.count() == 5
    buf.close()


def test_peek_is_fifo_and_does_not_delete(tmp_path: Path) -> None:
    buf = LocalBuffer(tmp_path / "b.sqlite", max_rows=100)
    for i in range(3):
        buf.append(_frame(i))
    rows = buf.peek_batch(10)
    assert [r.payload["frames"][0]["n"] for r in rows] == [0, 1, 2]
    # Still 3 rows in the buffer.
    assert buf.count() == 3


def test_delete_removes_only_listed_ids(tmp_path: Path) -> None:
    buf = LocalBuffer(tmp_path / "b.sqlite", max_rows=100)
    ids = [buf.append(_frame(i)) for i in range(5)]
    deleted = buf.delete(ids[:3])
    assert deleted == 3
    remaining = buf.peek_batch(10)
    assert [r.payload["frames"][0]["n"] for r in remaining] == [3, 4]


def test_overflow_drops_oldest(tmp_path: Path) -> None:
    buf = LocalBuffer(tmp_path / "b.sqlite", max_rows=3)
    for i in range(5):
        buf.append(_frame(i))
    rows = buf.peek_batch(10)
    # Only the 3 newest survive.
    assert [r.payload["frames"][0]["n"] for r in rows] == [2, 3, 4]


def test_survives_reopen(tmp_path: Path) -> None:
    path = tmp_path / "b.sqlite"
    buf = LocalBuffer(path, max_rows=100)
    buf.append(_frame(42))
    buf.close()

    reopened = LocalBuffer(path, max_rows=100)
    rows = reopened.peek_batch(10)
    assert len(rows) == 1
    assert rows[0].payload["frames"][0]["n"] == 42
    reopened.close()
