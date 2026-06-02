"""Windows Service wrapper for the NethraOps agent.

Uses `pywin32`'s `win32serviceutil.ServiceFramework` to register the
agent as a Windows Service. The service runs the same `AgentRunner`
the systemd unit runs on Linux - the only difference is who owns the
event loop's stop signal:

- On Linux, SIGTERM is wired into `_stop_event` via
  `loop.add_signal_handler`.
- On Windows, the SCM (Service Control Manager) sends a stop request
  via `SvcStop`; we plug that into `runner.stop()` which sets the
  same `_stop_event` from a thread.

The agent runs the asyncio loop in a dedicated worker thread so the
SCM dispatcher thread stays responsive.

The Win32 service class is defined at *module* scope, not inside a
factory function - `win32serviceutil.HandleCommandLine` resolves the
class through `pickle.whichmodule(cls, cls.__name__)`, which walks
the module's attributes and fails if the class lives in a closure.
"""

from __future__ import annotations

import asyncio
import sys
import threading

from nethraops_agent import __version__
from nethraops_agent.config import load_settings
from nethraops_agent.log import configure_logging, get_logger
from nethraops_agent.runner import AgentRunner


SERVICE_NAME = "NethraOpsAgent"
SERVICE_DISPLAY_NAME = "NethraOps Agent"
SERVICE_DESCRIPTION = (
    "Collects host telemetry and pushes it to the NethraOps backend. "
    "See C:\\ProgramData\\NethraOpsAgent\\agent.env for configuration."
)


log = get_logger("nethraops_agent.windows.service")


# pywin32 is only importable on Windows. The try/except lets this
# module load cleanly on Linux dev boxes; the actual service class is
# only defined when the pywin32 imports succeed.
try:
    import servicemanager  # noqa: F401  (pywin32 - used implicitly)
    import win32event
    import win32service
    import win32serviceutil

    _PYWIN32_AVAILABLE = True
except ImportError:
    _PYWIN32_AVAILABLE = False


if _PYWIN32_AVAILABLE:

    class NethraOpsAgentService(win32serviceutil.ServiceFramework):
        _svc_name_ = SERVICE_NAME
        _svc_display_name_ = SERVICE_DISPLAY_NAME
        _svc_description_ = SERVICE_DESCRIPTION

        def __init__(self, args):  # noqa: D401  (Win32 ServiceFramework hook)
            super().__init__(args)
            self.hWaitStop = win32event.CreateEvent(None, 0, 0, None)
            self._runner: AgentRunner | None = None
            self._loop: asyncio.AbstractEventLoop | None = None
            self._thread: threading.Thread | None = None

        def SvcStop(self) -> None:
            """Called by the SCM when the operator stops the service."""
            self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
            log.info("svc.stopping")
            if self._runner is not None:
                if self._loop is not None and not self._loop.is_closed():
                    self._loop.call_soon_threadsafe(self._runner.stop)
            win32event.SetEvent(self.hWaitStop)

        def SvcDoRun(self) -> None:
            settings = load_settings()
            configure_logging(level=settings.log_level, fmt=settings.log_format)
            log.info("svc.starting", version=__version__)

            self._runner = AgentRunner(settings, agent_version=__version__)

            done = threading.Event()
            exit_code = {"value": 0}

            def _run() -> None:
                try:
                    self._loop = asyncio.new_event_loop()
                    asyncio.set_event_loop(self._loop)
                    exit_code["value"] = self._loop.run_until_complete(
                        self._runner.run()
                    )
                except Exception:  # noqa: BLE001
                    log.exception("svc.runner.crashed")
                    exit_code["value"] = 1
                finally:
                    if self._loop is not None and not self._loop.is_closed():
                        self._loop.close()
                    done.set()

            self._thread = threading.Thread(
                target=_run, name="nethraops-agent-loop", daemon=False
            )
            self._thread.start()

            while not done.is_set():
                rc = win32event.WaitForSingleObject(self.hWaitStop, 1000)
                if rc == win32event.WAIT_OBJECT_0:
                    break

            if self._thread.is_alive():
                self._thread.join(timeout=settings.request_timeout_seconds + 5)
            log.info("svc.stopped", exit_code=exit_code["value"])


def main() -> int:
    """Entry point for the `nethraops-agent-service` console script."""
    if sys.platform != "win32":
        print("ERROR: nethraops-agent-service only runs on Windows", file=sys.stderr)
        return 2
    if not _PYWIN32_AVAILABLE:
        print("ERROR: pywin32 is not installed in this venv", file=sys.stderr)
        return 2
    win32serviceutil.HandleCommandLine(NethraOpsAgentService)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
