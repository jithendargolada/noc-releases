"""Shared pytest fixtures for the agent test suite."""

from __future__ import annotations

from pathlib import Path

import pytest

from nethraops_agent.config import AgentSettings


@pytest.fixture
def settings(tmp_path: Path) -> AgentSettings:
    """A fully-functional AgentSettings pointing at temp dirs."""
    return AgentSettings(
        backend_url="http://localhost:8000",  # type: ignore[arg-type]
        agent_token="test-agent-token",
        device_slug="test-host",
        collect_interval_seconds=1.0,
        flush_interval_seconds=1.0,
        flush_batch_size=10,
        max_buffer_frames=50,
        request_timeout_seconds=2.0,
        reconnect_initial_seconds=0.1,
        reconnect_max_seconds=1.0,
        buffer_path=tmp_path / "buffer.sqlite",
        state_path=tmp_path / "state.json",
        log_level="WARNING",
        log_format="console",
    )
