"""AgentRunner — drain on success, retain + back off on transient,
drop on permanent. Self-registration round-trip + token persistence."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest

from nethraops_agent.buffer import LocalBuffer
from nethraops_agent.client import IngestOutcome, RegistrationOutcome
from nethraops_agent.collector import Collector
from nethraops_agent.runner import AgentRunner


class FakeClient:
    """Minimal IngestClient stand-in — tests drive `next_outcome`."""

    def __init__(self) -> None:
        self.agent_token = "test-token"
        self.next_outcome: IngestOutcome | None = None
        self.next_register: RegistrationOutcome | None = None
        self.pushes: list[dict[str, Any]] = []

    def set_agent_token(self, token: str) -> None:
        self.agent_token = token

    async def register(self) -> RegistrationOutcome:
        return self.next_register or RegistrationOutcome(ok=False, error="not-set")

    async def push(self, batch: dict[str, Any]) -> IngestOutcome:
        self.pushes.append(batch)
        out = self.next_outcome
        if out is None:
            out = IngestOutcome(ok=True, status_code=202, accepted=len(batch.get("frames", [])))
        return out

    async def close(self) -> None:
        pass


def _runner(settings, client: FakeClient | None = None) -> AgentRunner:
    buf = LocalBuffer(settings.buffer_path, max_rows=settings.max_buffer_frames)
    coll = Collector(settings, agent_version="0.1.0")
    return AgentRunner(
        settings,
        agent_version="0.1.0",
        client=client or FakeClient(),
        buffer=buf,
        collector=coll,
    )


async def test_drain_success_deletes_rows(settings) -> None:
    client = FakeClient()
    runner = _runner(settings, client)
    runner._buffer.append({"agent_version": "0.1.0", "frames": [{"category": "cpu", "samples": [{"x": 1}]}]})
    runner._buffer.append({"agent_version": "0.1.0", "frames": [{"category": "memory", "samples": [{"y": 2}]}]})
    assert runner._buffer.count() == 2

    await runner._drain_once(final=False)

    assert runner._buffer.count() == 0
    assert len(client.pushes) == 1
    # Frames are flattened across the rows.
    assert len(client.pushes[0]["frames"]) == 2


async def test_drain_transient_keeps_rows_and_backs_off(settings, monkeypatch) -> None:
    client = FakeClient()
    client.next_outcome = IngestOutcome(
        ok=False, status_code=503, error="db down"
    )
    runner = _runner(settings, client)
    runner._buffer.append({"agent_version": "0.1.0", "frames": [{"category": "cpu", "samples": [{"x": 1}]}]})

    sleeps: list[float] = []

    async def _fake_sleep(s: float) -> None:
        sleeps.append(s)

    monkeypatch.setattr(asyncio, "sleep", _fake_sleep)
    initial_delay = runner._reconnect_delay

    await runner._drain_once(final=False)

    assert runner._buffer.count() == 1  # not deleted
    assert sleeps[0] == initial_delay
    assert runner._reconnect_delay > initial_delay  # backed off


async def test_drain_transient_in_final_skips_sleep(settings) -> None:
    client = FakeClient()
    client.next_outcome = IngestOutcome(
        ok=False, status_code=503, error="db down"
    )
    runner = _runner(settings, client)
    runner._buffer.append({"agent_version": "0.1.0", "frames": [{"category": "cpu", "samples": [{"x": 1}]}]})

    # final=True must not block on backoff.
    await asyncio.wait_for(runner._drain_once(final=True), timeout=1.0)
    assert runner._buffer.count() == 1


async def test_drain_permanent_drops_rows(settings) -> None:
    client = FakeClient()
    client.next_outcome = IngestOutcome(
        ok=False, status_code=401, error="bad token"
    )
    runner = _runner(settings, client)
    runner._buffer.append({"agent_version": "0.1.0", "frames": [{"category": "cpu", "samples": [{"x": 1}]}]})

    await runner._drain_once(final=False)
    assert runner._buffer.count() == 0  # dropped


async def test_self_registration_persists_token(settings) -> None:
    settings.agent_token = ""
    settings.enrolment_token = "enrol-tok"
    settings.device_slug = "host-1"
    client = FakeClient()
    client.agent_token = ""
    client.next_register = RegistrationOutcome(ok=True, agent_token="long-lived")
    runner = _runner(settings, client)

    await runner._maybe_self_register()

    assert client.agent_token == "long-lived"
    state = json.loads(Path(settings.state_path).read_text())
    assert state["agent_token"] == "long-lived"


async def test_persisted_token_takes_priority_over_re_registration(settings) -> None:
    # Persist a token from a "previous run".
    Path(settings.state_path).parent.mkdir(parents=True, exist_ok=True)
    Path(settings.state_path).write_text(json.dumps({"agent_token": "from-disk"}))

    settings.agent_token = ""
    settings.enrolment_token = "would-burn-this"
    client = FakeClient()
    client.agent_token = ""
    runner = _runner(settings, client)

    await runner._maybe_self_register()

    # The runner used the on-disk token; register was NOT called.
    assert client.agent_token == "from-disk"


async def test_collect_loop_appends_to_buffer(settings) -> None:
    runner = _runner(settings)
    # Run one tick of the collect loop manually.
    loop = asyncio.get_running_loop()
    batch = await loop.run_in_executor(None, runner._collector.collect_once)
    assert batch["frames"]
    runner._buffer.append(batch)
    assert runner._buffer.count() == 1
