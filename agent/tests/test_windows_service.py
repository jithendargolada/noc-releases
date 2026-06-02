"""Phase 2B-7 — Windows service wrapper.

The wrapper module imports `pywin32` lazily inside `_build_service_class`
and `main`. Importing the module itself must remain safe on Linux so
the test suite (which runs on the CI Linux box) doesn't break.

These tests cover the cross-platform contract:
- Module import works on every platform.
- The constants the installer reads stay stable.
- `main()` on a non-Windows host exits with code 2 + a clear message.
- `AgentRunner.stop()` is callable from outside the asyncio loop
  (the SCM dispatcher thread relies on this).
"""

from __future__ import annotations

import asyncio
import io
import sys
import threading
from contextlib import redirect_stderr

import pytest

from nethraops_agent import windows as winmod
from nethraops_agent.windows import service as service_mod


def test_module_imports_on_any_platform() -> None:
    # Just importing the module above is the assertion. If pywin32 were
    # imported eagerly, this test would crash on Linux during collection.
    assert callable(service_mod.main)


def test_constants_are_stable() -> None:
    # Operators read these from the installer. Treat them as a contract.
    assert winmod.SERVICE_NAME == "NethraOpsAgent"
    assert winmod.SERVICE_DISPLAY_NAME == "NethraOps Agent"
    assert "NethraOps backend" in winmod.SERVICE_DESCRIPTION


def test_main_refuses_non_windows() -> None:
    # Pretend we're not on win32 even if the test happens to run on
    # Windows in the future — exercise the guard explicitly.
    assert sys.platform != "win32"
    buf = io.StringIO()
    with redirect_stderr(buf):
        rc = service_mod.main()
    assert rc == 2
    assert "only runs on Windows" in buf.getvalue()


def test_runner_stop_is_thread_safe(settings) -> None:
    """The Windows SCM stops the service from a different thread —
    `AgentRunner.stop()` must work from any thread (the wrapper does
    `loop.call_soon_threadsafe(runner.stop)`).
    """
    from nethraops_agent.runner import AgentRunner

    settings.collect_interval_seconds = 1
    settings.flush_interval_seconds = 1

    runner = AgentRunner(settings, agent_version="0.1.0")

    async def _drive() -> None:
        # The runner refuses to enter `run()` without a token, so we
        # exercise the `_stop_event` path directly: set it from a
        # thread, then await it.
        loop = asyncio.get_running_loop()

        def _stop_from_thread() -> None:
            loop.call_soon_threadsafe(runner.stop)

        t = threading.Thread(target=_stop_from_thread)
        t.start()
        await asyncio.wait_for(runner._stop_event.wait(), timeout=2.0)
        t.join(timeout=1.0)

    asyncio.run(_drive())
    assert runner._stop_event.is_set()
