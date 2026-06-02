"""IngestClient — wraps the backend `/agents/metrics` push endpoint.

Two responsibilities:

1. **Authenticated POST** with the agent token in the `X-Agent-Token`
   header. Exposes a simple `push(batch)` returning a structured
   `IngestOutcome`.
2. **Self-registration** (optional). When the agent has only an
   `enrolment_token`, `register()` calls `POST /agents/register` once
   and returns the long-lived agent token; the runner persists it to
   disk so subsequent restarts skip the enrolment.

The runner (`runner.py`) is responsible for:
- Calling `register()` on first start when `agent_token` is empty.
- Calling `push()` for each drained batch and applying retry / backoff
  on transport failures.

Retries are NOT done inside the client — the runner already has a
buffer-driven retry loop, and double-retrying causes the dreaded
"thundering herd after backend recovers" pattern.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx

from nethraops_agent.config import AgentSettings
from nethraops_agent.log import get_logger

log = get_logger("nethraops_agent.client")


@dataclass(slots=True)
class IngestOutcome:
    """Result of one push attempt."""

    ok: bool
    status_code: int | None
    accepted: int = 0
    rejected: int = 0
    error: str | None = None

    @property
    def transient(self) -> bool:
        """True for retryable failures (network, 5xx, 429)."""
        if self.ok:
            return False
        if self.status_code is None:
            return True  # network / DNS / TLS — retry
        return self.status_code >= 500 or self.status_code == 429


def _collect_host_facts() -> dict[str, Any]:
    """Best-effort host facts for the register body. Each field is
    optional in the backend schema; we drop anything that raises."""
    import platform as _platform
    import socket as _socket

    facts: dict[str, Any] = {}
    try:
        facts["hostname"] = _socket.gethostname()
    except OSError:
        pass
    try:
        uname = _platform.uname()
        facts["os_name"] = uname.system or None
        facts["os_version"] = uname.release or None
        facts["architecture"] = uname.machine or None
    except Exception:  # noqa: BLE001
        pass
    try:
        import psutil as _psutil

        facts["cpu_cores"] = _psutil.cpu_count(logical=True)
        vm = _psutil.virtual_memory()
        facts["memory_bytes"] = int(vm.total)
    except Exception:  # noqa: BLE001
        pass
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("model name"):
                    facts["cpu_model"] = line.split(":", 1)[1].strip()[:255]
                    break
    except OSError:
        pass
    try:
        with _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM) as s:
            s.connect(("1.1.1.1", 80))
            facts["primary_ip"] = s.getsockname()[0]
    except OSError:
        pass
    return {k: v for k, v in facts.items() if v is not None and v != ""}


@dataclass(slots=True)
class RegistrationOutcome:
    """Result of a `/agents/register` call."""

    ok: bool
    agent_token: str | None = None
    device_id: str | None = None
    error: str | None = None


class IngestClient:
    def __init__(self, settings: AgentSettings, agent_version: str) -> None:
        self._settings = settings
        self._agent_version = agent_version
        self._base_url = str(settings.backend_url).rstrip("/")
        # One client lifetime for the whole agent; httpx pools connections.
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(settings.request_timeout_seconds),
            headers={
                "User-Agent": f"nethraops-agent/{agent_version}",
                "Accept": "application/json",
            },
        )
        # Mutable so `register()` can swap in the freshly-issued token.
        self._agent_token = settings.agent_token

    # ----- Token / registration ---------------------------------------
    @property
    def agent_token(self) -> str:
        return self._agent_token

    def set_agent_token(self, token: str) -> None:
        self._agent_token = token

    async def register(self, *, agent_id: str) -> RegistrationOutcome:
        """Self-register using the stored enrolment token.

        Returns the long-lived agent token on success. The runner
        persists it to `state.json` so subsequent starts skip this.
        """
        if not self._settings.enrolment_token:
            return RegistrationOutcome(ok=False, error="no enrolment token configured")
        if not self._settings.device_slug:
            return RegistrationOutcome(ok=False, error="device_slug required for self-registration")

        body: dict[str, Any] = {
            "slug": self._settings.device_slug,
            "agent_id": agent_id,
            "agent_version": self._agent_version,
        }
        if self._settings.device_name:
            body["name"] = self._settings.device_name
        if self._settings.device_type:
            body["type"] = self._settings.device_type
        body.update(_collect_host_facts())

        try:
            r = await self._client.post(
                f"{self._base_url}/api/v1/agents/register",
                json=body,
                headers={"X-Enrolment-Token": self._settings.enrolment_token},
            )
        except httpx.HTTPError as exc:
            return RegistrationOutcome(ok=False, error=f"transport: {exc!r}")

        if r.status_code >= 400:
            return RegistrationOutcome(
                ok=False, error=f"http {r.status_code}: {r.text[:200]}"
            )
        try:
            data = r.json()
        except ValueError as exc:
            return RegistrationOutcome(ok=False, error=f"non-json response: {exc!r}")

        token = data.get("agent_token")
        if not token:
            return RegistrationOutcome(
                ok=False, error="register succeeded but no agent_token in body"
            )
        device_id = data.get("device", {}).get("id") or data.get("device_id")
        self._agent_token = token
        log.info(
            "agent.registered",
            device_id=device_id,
            slug=self._settings.device_slug,
        )
        return RegistrationOutcome(ok=True, agent_token=token, device_id=device_id)

    # ----- Metric push -------------------------------------------------
    async def push(self, batch: dict[str, Any]) -> IngestOutcome:
        """POST one ingest batch. The caller has already drained it from
        the local buffer; we don't retry here — the buffer-loop does.
        """
        if not self._agent_token:
            return IngestOutcome(
                ok=False,
                status_code=None,
                error="no agent_token configured; cannot push",
            )
        try:
            r = await self._client.post(
                f"{self._base_url}/api/v1/agents/metrics",
                json=batch,
                headers={"X-Agent-Token": self._agent_token},
            )
        except httpx.HTTPError as exc:
            return IngestOutcome(
                ok=False, status_code=None, error=f"transport: {exc!r}"
            )

        if r.status_code in (200, 202):
            try:
                data = r.json()
            except ValueError:
                data = {}
            return IngestOutcome(
                ok=True,
                status_code=r.status_code,
                accepted=int(data.get("accepted", 0) or 0),
                rejected=int(data.get("rejected", 0) or 0),
            )
        return IngestOutcome(
            ok=False,
            status_code=r.status_code,
            error=f"http {r.status_code}: {r.text[:200]}",
        )

    async def close(self) -> None:
        await self._client.aclose()
