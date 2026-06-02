"""AgentRunner — main async loop.

Two coroutines run concurrently:

1. **Collect loop**: every `collect_interval_seconds` calls
   `Collector.collect_once()` (in a thread executor) and appends
   the resulting batch to the local buffer. Always succeeds — local
   write only.

2. **Flush loop**: every `flush_interval_seconds` drains up to
   `flush_batch_size` rows from the buffer and pushes them via
   `IngestClient.push()`. On success: deletes them. On transient
   failure: leaves them, sleeps with exponential backoff, retries.
   On permanent failure (4xx that isn't 429 or 408): drops the rows
   and logs — they would never succeed regardless.

Graceful shutdown: SIGINT/SIGTERM cancels both coroutines. The
collect loop drains its in-flight collection; the flush loop attempts
one final drain before exiting so a clean shutdown doesn't lose the
last sample.

Self-registration: if `agent_token` is empty but `enrolment_token`
is set, the runner calls `IngestClient.register()` once at startup,
persists the resulting token to `state.json`, and proceeds. On any
re-start, the token is re-read from `state.json` so we don't try to
re-register (and burn the one-shot enrolment token).
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import time
from contextlib import suppress
from pathlib import Path
from typing import Any

from nethraops_agent.buffer import LocalBuffer
from nethraops_agent.client import IngestClient
from nethraops_agent.collector import Collector
from nethraops_agent.config import AgentSettings
from nethraops_agent.log import get_logger

log = get_logger("nethraops_agent.runner")


class AgentRunner:
    def __init__(
        self,
        settings: AgentSettings,
        *,
        agent_version: str,
        client: IngestClient | None = None,
        buffer: LocalBuffer | None = None,
        collector: Collector | None = None,
    ) -> None:
        self._settings = settings
        self._agent_version = agent_version
        self._client = client or IngestClient(settings, agent_version)
        self._buffer = buffer or LocalBuffer(
            settings.buffer_path, max_rows=settings.max_buffer_frames
        )
        self._collector = collector or Collector(settings, agent_version)
        self._stop_event = asyncio.Event()
        self._reconnect_delay = settings.reconnect_initial_seconds

    # ----- Lifecycle ---------------------------------------------------
    async def run(self) -> int:
        """Run until SIGINT/SIGTERM. Returns the process exit code."""
        await self._maybe_self_register()
        if not self._client.agent_token:
            log.error("agent.no_token")
            return 2

        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, self._stop_event.set)
            except NotImplementedError:
                # Windows event loops don't support add_signal_handler;
                # the OS sends KeyboardInterrupt which the outer try
                # handles. Phase 2B-7 wires the Windows Service stop
                # event into _stop_event explicitly.
                pass

        log.info(
            "agent.starting",
            backend=str(self._settings.backend_url),
            collect_s=self._settings.collect_interval_seconds,
            flush_s=self._settings.flush_interval_seconds,
            buffer_path=str(self._settings.buffer_path),
        )

        collect_task = asyncio.create_task(self._collect_loop(), name="collect-loop")
        flush_task = asyncio.create_task(self._flush_loop(), name="flush-loop")
        try:
            await self._stop_event.wait()
        finally:
            log.info("agent.shutting_down")
            collect_task.cancel()
            flush_task.cancel()
            for t in (collect_task, flush_task):
                with suppress(asyncio.CancelledError):
                    await t
            # Final drain: best-effort, single attempt.
            await self._drain_once(final=True)
            await self._client.close()
            self._buffer.close()
            log.info("agent.stopped")
        return 0

    def stop(self) -> None:
        """External stop signal — used by the Windows Service wrapper."""
        self._stop_event.set()

    # ----- Self-registration ------------------------------------------
    async def _maybe_self_register(self) -> None:
        # 1. Already have a token from settings or persisted state?
        token = self._client.agent_token or self._read_persisted_token()
        if token:
            self._client.set_agent_token(token)
            return
        # 2. Try to self-register.
        if not self._settings.enrolment_token:
            return
        outcome = await self._client.register(agent_id=self._read_or_create_agent_id())
        if not outcome.ok or not outcome.agent_token:
            log.error("agent.register_failed", error=outcome.error)
            return
        # Make the post-register contract explicit — a fake client used
        # in tests doesn't have to set the token itself.
        self._client.set_agent_token(outcome.agent_token)
        self._persist_token(outcome.agent_token)

    def _read_state(self) -> dict[str, Any]:
        try:
            data = json.loads(Path(self._settings.state_path).read_text())
            return data if isinstance(data, dict) else {}
        except (FileNotFoundError, json.JSONDecodeError, PermissionError):
            return {}

    def _read_persisted_token(self) -> str | None:
        token = self._read_state().get("agent_token")
        return token if isinstance(token, str) and token else None

    def _read_or_create_agent_id(self) -> str:
        state = self._read_state()
        existing = state.get("agent_id")
        if isinstance(existing, str) and len(existing) >= 8:
            return existing
        import uuid as _uuid

        state["agent_id"] = _uuid.uuid4().hex
        self._write_state(state)
        return state["agent_id"]

    def _persist_token(self, token: str) -> None:
        state = self._read_state()
        state["agent_token"] = token
        self._write_state(state)
        log.info("agent.token_persisted", path=str(self._settings.state_path))

    def _write_state(self, state: dict[str, Any]) -> None:
        path = Path(self._settings.state_path)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(state))
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
        except OSError as exc:
            log.warning("agent.state_persist_failed", error=str(exc))

    # ----- Collect loop -----------------------------------------------
    async def _collect_loop(self) -> None:
        loop = asyncio.get_running_loop()
        while True:
            try:
                batch = await loop.run_in_executor(None, self._collector.collect_once)
                if batch and batch.get("frames"):
                    self._buffer.append(batch)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("agent.collect_failed")
            await asyncio.sleep(self._settings.collect_interval_seconds)

    # ----- Flush loop --------------------------------------------------
    async def _flush_loop(self) -> None:
        while True:
            try:
                await self._drain_once(final=False)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("agent.flush_failed")
            await asyncio.sleep(self._settings.flush_interval_seconds)

    async def _drain_once(self, *, final: bool) -> None:
        """Pull one batch from the buffer and push it.

        If push fails transiently and `final=False`, we apply
        exponential backoff and let the next tick retry. If `final=True`
        (shutdown path) we only do one attempt.
        """
        rows = self._buffer.peek_batch(self._settings.flush_batch_size)
        if not rows:
            return
        # Combine the per-collect batches into one payload — frames is
        # already a list, so we splat them.
        combined: dict[str, Any] = {
            "agent_version": self._agent_version,
            "frames": [],
        }
        for row in rows:
            frames = row.payload.get("frames") or []
            combined["frames"].extend(frames)
        outcome = await self._client.push(combined)
        if outcome.ok:
            deleted = self._buffer.delete([r.id for r in rows])
            self._reconnect_delay = self._settings.reconnect_initial_seconds
            log.info(
                "agent.flushed",
                rows=len(rows),
                deleted=deleted,
                accepted=outcome.accepted,
                rejected=outcome.rejected,
            )
            return
        if outcome.transient:
            log.warning(
                "agent.flush_transient",
                error=outcome.error,
                status=outcome.status_code,
                backoff_s=self._reconnect_delay,
                buffered=self._buffer.count(),
            )
            if not final:
                await asyncio.sleep(self._reconnect_delay)
                self._reconnect_delay = min(
                    self._reconnect_delay * 2,
                    self._settings.reconnect_max_seconds,
                )
            return
        # Permanent failure — drop the rows. They would never succeed.
        log.error(
            "agent.flush_permanent_failure",
            error=outcome.error,
            status=outcome.status_code,
            dropped=len(rows),
        )
        self._buffer.delete([r.id for r in rows])
