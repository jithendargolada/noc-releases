"""Collector — produces a Phase 2A-shaped batch from psutil readings."""

from __future__ import annotations

import time

from nethraops_agent.collector import Collector


def test_collect_once_returns_a_well_formed_batch(settings) -> None:
    c = Collector(settings, agent_version="0.1.0")
    # First cpu_percent call is a no-op; sleep then collect for a real value.
    time.sleep(0.05)
    batch = c.collect_once()

    assert isinstance(batch, dict)
    assert batch["agent_version"] == "0.1.0"
    assert isinstance(batch["frames"], list)
    assert batch["frames"], "expected at least one frame"

    categories = {f["category"] for f in batch["frames"]}
    # Always-on categories that don't depend on optional sensors.
    for required in ("cpu", "memory", "system"):
        assert required in categories

    # Each frame has `recorded_at`, `sequence`, `samples`.
    for frame in batch["frames"]:
        assert "recorded_at" in frame
        assert "sequence" in frame
        assert isinstance(frame["samples"], list)


def test_sequence_increments_monotonically(settings) -> None:
    c = Collector(settings, agent_version="0.1.0")
    time.sleep(0.05)
    a = c.collect_once()
    time.sleep(0.05)
    b = c.collect_once()
    seq_a = [f["sequence"] for f in a["frames"]]
    seq_b = [f["sequence"] for f in b["frames"]]
    assert min(seq_b) > max(seq_a)


def test_disabled_categories_are_skipped(settings) -> None:
    settings.enable_cpu = False
    settings.enable_memory = False
    c = Collector(settings, agent_version="0.1.0")
    batch = c.collect_once()
    cats = {f["category"] for f in batch["frames"]}
    assert "cpu" not in cats
    assert "memory" not in cats
    # system is still on.
    assert "system" in cats
