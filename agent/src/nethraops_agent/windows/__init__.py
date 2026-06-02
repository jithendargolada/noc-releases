"""Windows-specific runtime for the NethraOps agent.

The shared collector / buffer / client / runner code lives in
`nethraops_agent`; this subpackage adds a `pywin32`-based Windows
Service wrapper so the agent can be installed via `sc.exe` or the
provided MSI/PS1 installer.

Imports here are guarded — `import nethraops_agent.windows` is safe on
non-Windows hosts as long as you don't actually invoke the service
class. The `nethraops-agent-service` console script is gated by a
`sys_platform == 'win32'` marker in `pyproject.toml`.
"""

from nethraops_agent.windows.service import (
    SERVICE_DESCRIPTION,
    SERVICE_DISPLAY_NAME,
    SERVICE_NAME,
)

__all__ = ["SERVICE_DESCRIPTION", "SERVICE_DISPLAY_NAME", "SERVICE_NAME"]
