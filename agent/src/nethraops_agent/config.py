"""Agent settings.

Loaded from environment variables with `NETHRAOPS_` prefix, an optional
`/etc/nethraops-agent/agent.env` (Linux) / `C:\\ProgramData\\NethraOpsAgent\\
agent.env` (Windows), or a `--config` CLI flag pointing at any `.env`
file. Validation runs at import time — malformed config fails fast at
service start, not deep in the metric loop.
"""

from __future__ import annotations

import os
import platform
from pathlib import Path
from typing import Literal

from pydantic import Field, HttpUrl, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


def _default_config_path() -> Path:
    """OS-specific default path for the .env-style config file."""
    if platform.system() == "Windows":
        return Path(os.environ.get("PROGRAMDATA", r"C:\\ProgramData")) / "NethraOpsAgent" / "agent.env"
    return Path("/etc/nethraops-agent/agent.env")


def _default_buffer_path() -> Path:
    if platform.system() == "Windows":
        base = Path(os.environ.get("PROGRAMDATA", r"C:\\ProgramData")) / "NethraOpsAgent"
    else:
        base = Path("/var/lib/nethraops-agent")
    return base / "buffer.sqlite"


class AgentSettings(BaseSettings):
    """Single source of truth for the agent runtime."""

    model_config = SettingsConfigDict(
        env_prefix="NETHRAOPS_",
        env_file=str(_default_config_path()) if _default_config_path().exists() else None,
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # ----- Backend connection -----
    backend_url: HttpUrl = Field(default="http://localhost:8000")
    """Base URL of the backend, e.g. https://monitor.acme.com."""

    agent_token: str = Field(default="")
    """Long-lived agent token (from `/agents/register`).

    The agent refuses to start if this is empty unless `enrolment_token`
    is present (in which case it self-registers on the first run and
    persists the agent token to disk).
    """

    enrolment_token: str = Field(default="")
    """One-shot enrolment token. Consumed at first registration."""

    device_slug: str = Field(default="")
    """Stable device slug (lower-case, hyphens). Required when
    self-registering. Ignored when `agent_token` is already set."""

    device_name: str | None = None
    device_type: Literal["windows", "linux"] | None = None

    # ----- Collection cadence -----
    collect_interval_seconds: float = Field(default=15.0, ge=1.0, le=3600.0)
    """How often the collector samples local metrics."""

    flush_interval_seconds: float = Field(default=15.0, ge=1.0, le=3600.0)
    """How often we attempt to ship the buffer to the backend."""

    flush_batch_size: int = Field(default=200, ge=1, le=2000)
    """Maximum frames per HTTP push. Bigger = fewer round-trips,
    smaller = faster recovery from a stuck buffer."""

    # ----- Reliability -----
    max_buffer_frames: int = Field(default=10_000, ge=10, le=1_000_000)
    """Hard cap on frames retained in the local buffer.

    On overflow the oldest frames are dropped — better to lose the
    oldest minute than to fill the disk."""

    request_timeout_seconds: float = Field(default=10.0, ge=1.0, le=120.0)
    reconnect_initial_seconds: float = Field(default=2.0, ge=0.05, le=300.0)
    reconnect_max_seconds: float = Field(default=120.0, ge=0.1, le=3600.0)

    # ----- Storage -----
    buffer_path: Path = Field(default_factory=_default_buffer_path)
    """Local SQLite file backing the offline buffer."""

    state_path: Path = Field(default=Path("/var/lib/nethraops-agent/state.json"))
    """Persistent state — currently used to store the agent token if
    the agent self-registered."""

    # ----- Telemetry / logging -----
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    log_format: Literal["json", "console"] = "json"

    # ----- Categories -----
    enable_cpu: bool = True
    enable_memory: bool = True
    enable_disk: bool = True
    enable_network: bool = True
    enable_processes: bool = True
    enable_temperatures: bool = True
    enable_system: bool = True

    @field_validator("backend_url")
    @classmethod
    def _strip_trailing_slash(cls, v: HttpUrl) -> HttpUrl:
        # Pydantic adds a trailing slash; route paths in `client.py` start
        # with `/`, so we live with it. This validator is a stub for
        # symmetry with the backend's URL validator.
        return v

    @field_validator("device_slug")
    @classmethod
    def _slug_lowercase(cls, v: str) -> str:
        if v and v != v.lower():
            return v.lower()
        return v

    def has_credentials(self) -> bool:
        return bool(self.agent_token) or bool(self.enrolment_token)


def load_settings(config_file: Path | None = None) -> AgentSettings:
    """Build settings, optionally overriding the env-file path."""
    if config_file is not None and config_file.exists():
        return AgentSettings(_env_file=str(config_file))  # type: ignore[call-arg]
    return AgentSettings()
