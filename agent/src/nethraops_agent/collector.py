"""Metric collector — turns local psutil readings into wire frames.

Frames match the Phase 2A `/agents/metrics` schema exactly:

    {
        "agent_version": "0.1.0",
        "frames": [
            {
                "category": "cpu",
                "recorded_at": "2026-05-13T07:00:00.000Z",
                "sequence": 42,
                "samples": [{...}]
            },
            ...
        ]
    }

Each `collect_once()` produces one batch — typically one frame per
enabled category, one sample per frame for scalar categories
(cpu, memory, system) and N samples for multi-instance categories
(disk, network, processes).

Collector is intentionally synchronous + side-effect-free apart from
the local sequence counter. The runner calls it in a thread executor
so psutil's blocking calls don't stall the event loop.
"""

from __future__ import annotations

import platform
import time
from datetime import datetime, timezone
from typing import Any

import psutil

from nethraops_agent.config import AgentSettings


class Collector:
    """Stateful psutil collector — keeps the per-batch sequence counter."""

    def __init__(self, settings: AgentSettings, agent_version: str) -> None:
        self._settings = settings
        self._agent_version = agent_version
        self._sequence = 0
        # psutil.cpu_percent and net_io_counters are stateful — the first
        # call returns a meaningless 0 for cpu_percent and a snapshot for
        # net_io. We seed both at construction so the *first* sample the
        # backend sees is real.
        psutil.cpu_percent(interval=None, percpu=False)
        self._last_net_snapshot: dict[str, psutil._common.snetio] = {}
        try:
            self._last_net_snapshot = dict(psutil.net_io_counters(pernic=True))
        except Exception:
            self._last_net_snapshot = {}
        self._last_net_at: float = time.time()

    def collect_once(self) -> dict[str, Any]:
        """Build one ingest batch — call from the runner once per tick."""
        recorded_at = _iso_now()
        frames: list[dict[str, Any]] = []
        sample_kwargs = {"recorded_at": recorded_at}

        if self._settings.enable_cpu:
            frames.append(self._frame("cpu", [self._cpu_sample()], sample_kwargs))
        if self._settings.enable_memory:
            frames.append(self._frame("memory", [self._memory_sample()], sample_kwargs))
        if self._settings.enable_disk:
            frames.append(self._frame("disk", self._disk_samples(), sample_kwargs))
        if self._settings.enable_network:
            frames.append(self._frame("network", self._network_samples(), sample_kwargs))
        if self._settings.enable_processes:
            frames.append(self._frame("processes", self._process_samples(), sample_kwargs))
        if self._settings.enable_temperatures:
            temp = self._temperature_samples()
            if temp:
                frames.append(self._frame("temperatures", temp, sample_kwargs))
        if self._settings.enable_system:
            frames.append(self._frame("system", [self._system_sample()], sample_kwargs))

        # Drop frames with no samples (e.g. disk on a stripped-down container).
        frames = [f for f in frames if f["samples"]]

        return {
            "agent_version": self._agent_version,
            "frames": frames,
        }

    # ----- Frame helper -----------------------------------------------
    def _frame(
        self,
        category: str,
        samples: list[dict[str, Any]],
        kwargs: dict[str, Any],
    ) -> dict[str, Any]:
        self._sequence += 1
        return {
            "category": category,
            "recorded_at": kwargs["recorded_at"],
            "sequence": self._sequence,
            "samples": samples,
        }

    # ----- Per-category samplers --------------------------------------
    def _cpu_sample(self) -> dict[str, Any]:
        cpu_percent = psutil.cpu_percent(interval=None, percpu=False)
        per_core = psutil.cpu_percent(interval=None, percpu=True)
        load1 = load5 = load15 = None
        try:
            load1, load5, load15 = psutil.getloadavg()
        except (AttributeError, OSError):
            pass
        try:
            times = psutil.cpu_times_percent(interval=None)
            user = float(times.user)
            system = float(times.system)
            idle = float(times.idle)
            iowait = float(getattr(times, "iowait", 0.0))
        except Exception:
            user = system = idle = iowait = None  # type: ignore[assignment]

        return {
            "usage_percent": float(cpu_percent),
            "user_percent": user,
            "system_percent": system,
            "iowait_percent": iowait,
            "idle_percent": idle,
            "load_1": load1,
            "load_5": load5,
            "load_15": load15,
            "core_count": psutil.cpu_count(logical=True),
            "per_core": {f"cpu{i}": float(v) for i, v in enumerate(per_core)},
        }

    def _memory_sample(self) -> dict[str, Any]:
        v = psutil.virtual_memory()
        s = psutil.swap_memory()
        return {
            "total_bytes": int(v.total),
            "used_bytes": int(v.used),
            "available_bytes": int(getattr(v, "available", 0)),
            "free_bytes": int(v.free),
            "cached_bytes": int(getattr(v, "cached", 0)),
            "buffers_bytes": int(getattr(v, "buffers", 0)),
            "swap_total_bytes": int(s.total),
            "swap_used_bytes": int(s.used),
            "usage_percent": float(v.percent),
        }

    def _disk_samples(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        try:
            partitions = psutil.disk_partitions(all=False)
        except Exception:
            partitions = []
        for part in partitions:
            try:
                usage = psutil.disk_usage(part.mountpoint)
            except (PermissionError, OSError):
                continue
            out.append(
                {
                    "device_path": part.device,
                    "mount_point": part.mountpoint,
                    "filesystem": part.fstype,
                    "total_bytes": int(usage.total),
                    "used_bytes": int(usage.used),
                    "available_bytes": int(usage.free),
                    "usage_percent": float(usage.percent),
                }
            )
        return out

    def _network_samples(self) -> list[dict[str, Any]]:
        try:
            current = dict(psutil.net_io_counters(pernic=True))
        except Exception:
            return []
        now = time.time()
        dt = max(now - self._last_net_at, 1e-3)
        out: list[dict[str, Any]] = []
        for name, cur in current.items():
            prev = self._last_net_snapshot.get(name)
            if prev is None:
                rx_bps = tx_bps = None
            else:
                # bytes -> bits per second
                rx_bps = max(0.0, (cur.bytes_recv - prev.bytes_recv) * 8.0 / dt)
                tx_bps = max(0.0, (cur.bytes_sent - prev.bytes_sent) * 8.0 / dt)
            out.append(
                {
                    "interface": name,
                    "rx_bytes": int(cur.bytes_recv),
                    "tx_bytes": int(cur.bytes_sent),
                    "rx_packets": int(cur.packets_recv),
                    "tx_packets": int(cur.packets_sent),
                    "rx_errors": int(cur.errin),
                    "tx_errors": int(cur.errout),
                    "rx_drops": int(cur.dropin),
                    "tx_drops": int(cur.dropout),
                    "rx_bps": rx_bps,
                    "tx_bps": tx_bps,
                }
            )
        self._last_net_snapshot = current
        self._last_net_at = now
        return out

    def _process_samples(self) -> list[dict[str, Any]]:
        # Cap to top-20 by cpu+mem; the backend persists summary stats not
        # the entire process table.
        rows: list[tuple[float, dict[str, Any]]] = []
        for proc in psutil.process_iter(
            attrs=["pid", "name", "cpu_percent", "memory_percent", "username"],
        ):
            info = proc.info  # type: ignore[attr-defined]
            cpu = float(info.get("cpu_percent") or 0.0)
            mem = float(info.get("memory_percent") or 0.0)
            score = cpu + mem
            rows.append(
                (
                    score,
                    {
                        "pid": info.get("pid"),
                        "name": info.get("name"),
                        "username": info.get("username"),
                        "cpu_percent": cpu,
                        "memory_percent": mem,
                    },
                )
            )
        rows.sort(key=lambda r: -r[0])
        return [r[1] for r in rows[:20]]

    def _temperature_samples(self) -> list[dict[str, Any]]:
        try:
            sensors = psutil.sensors_temperatures()  # type: ignore[attr-defined]
        except (AttributeError, NotImplementedError):
            return []
        out: list[dict[str, Any]] = []
        for chip, readings in sensors.items():
            for r in readings:
                if r.current is None:
                    continue
                out.append(
                    {
                        "sensor": f"{chip}:{r.label or 'main'}",
                        "temperature_c": float(r.current),
                        "high_c": float(r.high) if r.high else None,
                        "critical_c": float(r.critical) if r.critical else None,
                    }
                )
        return out

    def _system_sample(self) -> dict[str, Any]:
        boot_ts = psutil.boot_time()
        uptime = time.time() - boot_ts
        return {
            "hostname": platform.node(),
            "platform": platform.platform(),
            "kernel": platform.release(),
            "boot_at": _iso_from_epoch(boot_ts),
            "uptime_seconds": float(uptime),
            "process_count": len(psutil.pids()),
        }


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _iso_from_epoch(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
