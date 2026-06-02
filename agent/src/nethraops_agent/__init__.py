"""NethraOps agent package.

Cross-platform telemetry collector — pushes batched metrics to the
NethraOps backend via the Phase 2A `/agents/metrics` API.

Public surface intentionally kept small. Most users run the agent via
the `nethraops-agent` CLI installed by `pyproject.toml` `[project.scripts]`;
the modules below are exposed for in-process embedding (e.g. unit
tests, integration testbeds).
"""

from nethraops_agent.buffer import LocalBuffer
from nethraops_agent.client import IngestClient
from nethraops_agent.collector import Collector
from nethraops_agent.config import AgentSettings
from nethraops_agent.runner import AgentRunner

__all__ = [
    "AgentRunner",
    "AgentSettings",
    "Collector",
    "IngestClient",
    "LocalBuffer",
]

__version__ = "0.1.0"
