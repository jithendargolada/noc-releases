# NethraOps Agent

Cross-platform telemetry collector for the NethraOps platform.

Phase 2B-6 ships the **Linux production runtime** (systemd unit + install
script + offline buffering). Phase 2B-7 will extend the same Python
package with a Windows Service wrapper.

## What it does

- Collects host telemetry every `NETHRAOPS_COLLECT_INTERVAL_SECONDS`
  (CPU, memory, disk, network, processes, temperatures, system).
- Writes each batch to a local SQLite ring buffer
  (`/var/lib/nethraops-agent/buffer.sqlite`, capped at
  `NETHRAOPS_MAX_BUFFER_FRAMES`).
- Pushes batches to `POST /api/v1/agents/metrics` every
  `NETHRAOPS_FLUSH_INTERVAL_SECONDS` with `X-Agent-Token`. On transient
  failure (network, 5xx, 429) the rows stay in the buffer; the agent
  retries with exponential backoff. On permanent failure (4xx that
  isn't 429) the rows are dropped.
- Self-registers via the one-shot enrolment token if no agent token
  is configured. The long-lived token is persisted to
  `/var/lib/nethraops-agent/state.json` (`0600`).

## Install (Linux, systemd)

```bash
sudo NETHRAOPS_BACKEND_URL=https://monitor.acme.com \
     NETHRAOPS_ENROLMENT_TOKEN=<one-shot-token> \
     NETHRAOPS_DEVICE_SLUG=db-east-01 \
     ./packaging/linux/install.sh
```

## Install (Windows, Service)

Open an **elevated** PowerShell prompt:

```powershell
PS> .\packaging\windows\Install-NethraOpsAgent.ps1 `
        -BackendUrl https://monitor.acme.com `
        -EnrolmentToken <one-shot-token> `
        -DeviceSlug db-east-01
```

This:
1. Creates `C:\Program Files\NethraOpsAgent\venv` and installs the
   agent + Windows extras (`pywin32`).
2. Writes `C:\ProgramData\NethraOpsAgent\agent.env` (config template,
   ACL'd to SYSTEM + Administrators).
3. Registers the `NethraOpsAgent` Windows Service via the
   `nethraops-agent-service` console script (a `pywin32`
   `ServiceFramework` wrapper around the same `AgentRunner` the
   Linux unit runs).
4. Configures recovery (restart on first/second/third failure with
   60s backoff via `sc.exe failure`).

Status / logs:

```powershell
PS> Get-Service NethraOpsAgent
PS> Get-WinEvent -LogName Application -ProviderName 'Python Service Manager'
```

Uninstall:

```powershell
PS> .\packaging\windows\Uninstall-NethraOpsAgent.ps1            # keep config + buffer
PS> .\packaging\windows\Uninstall-NethraOpsAgent.ps1 -Purge     # remove everything
```

This:
1. Creates the `nethraops-agent` system user.
2. Installs `/opt/nethraops-agent/venv` from the source tree (or PyPI in
   the future).
3. Writes `/etc/nethraops-agent/agent.env` with the supplied env vars.
4. Installs and enables `nethraops-agent.service`.

Status / logs:

```bash
systemctl status nethraops-agent
journalctl -u nethraops-agent -f
```

Uninstall:

```bash
sudo ./packaging/linux/uninstall.sh             # keep config + buffer
sudo ./packaging/linux/uninstall.sh --purge     # also remove user, /etc, /var/lib
```

## Configuration

All settings are read from environment variables with the `NETHRAOPS_`
prefix, an optional `/etc/nethraops-agent/agent.env`, or a
`--config <path>` CLI flag.

| Variable | Default | Description |
|---|---|---|
| `NETHRAOPS_BACKEND_URL` | `http://localhost:8000` | Backend base URL |
| `NETHRAOPS_AGENT_TOKEN` | `""` | Long-lived agent token (skip if using enrolment) |
| `NETHRAOPS_ENROLMENT_TOKEN` | `""` | One-shot enrolment token |
| `NETHRAOPS_DEVICE_SLUG` | `""` | Stable device slug (required for enrolment) |
| `NETHRAOPS_DEVICE_NAME` | `null` | Operator-friendly name |
| `NETHRAOPS_DEVICE_TYPE` | `null` | `linux` or `windows` |
| `NETHRAOPS_COLLECT_INTERVAL_SECONDS` | `15` | Local sample cadence |
| `NETHRAOPS_FLUSH_INTERVAL_SECONDS` | `15` | HTTP push cadence |
| `NETHRAOPS_FLUSH_BATCH_SIZE` | `200` | Max frames per push |
| `NETHRAOPS_MAX_BUFFER_FRAMES` | `10000` | Local buffer ceiling (FIFO drop) |
| `NETHRAOPS_REQUEST_TIMEOUT_SECONDS` | `10` | Per-request HTTP timeout |
| `NETHRAOPS_RECONNECT_INITIAL_SECONDS` | `2` | Initial backoff after a transient failure |
| `NETHRAOPS_RECONNECT_MAX_SECONDS` | `120` | Backoff cap |
| `NETHRAOPS_BUFFER_PATH` | `/var/lib/nethraops-agent/buffer.sqlite` | Buffer file |
| `NETHRAOPS_STATE_PATH` | `/var/lib/nethraops-agent/state.json` | Persisted token |
| `NETHRAOPS_LOG_LEVEL` | `INFO` | DEBUG/INFO/WARNING/ERROR |
| `NETHRAOPS_LOG_FORMAT` | `json` | json or console |
| `NETHRAOPS_ENABLE_*` | `true` | Per-category toggles (`enable_cpu`, etc.) |

## CLI

```bash
nethraops-agent run            # default — start the loop
nethraops-agent collect-once   # print one batch as JSON and exit (debug)
nethraops-agent show-config    # print resolved settings (secrets redacted)
nethraops-agent --version
```

On Windows, an extra script is installed for SCM integration:

```powershell
nethraops-agent-service install    # register the service
nethraops-agent-service start
nethraops-agent-service stop
nethraops-agent-service remove
```

These are pass-through to `pywin32`'s `HandleCommandLine` — the
PowerShell installer wraps them.

## Development

```bash
python3 -m venv .venv
.venv/bin/pip install -e ".[test]"
.venv/bin/pytest
```

The test suite is hermetic — no network, no real SQLite location, no
psutil mocking required (psutil readings are tolerated as long as
they're well-formed).

## Layout

```
agent/
├── pyproject.toml
├── README.md
├── packaging/
│   ├── linux/
│   │   ├── nethraops-agent.service     # systemd unit
│   │   ├── install.sh                # idempotent installer
│   │   └── uninstall.sh
│   └── windows/
│       ├── Install-NethraOpsAgent.ps1
│       └── Uninstall-NethraOpsAgent.ps1
├── src/
│   └── nethraops_agent/
│       ├── __init__.py
│       ├── __main__.py               # python -m nethraops_agent
│       ├── cli.py                    # argparse entry point
│       ├── config.py                 # AgentSettings (pydantic-settings)
│       ├── log.py                    # structlog wiring
│       ├── buffer.py                 # SQLite ring buffer
│       ├── collector.py              # psutil → wire frames
│       ├── client.py                 # httpx wrapper for /agents/metrics
│       ├── runner.py                 # main asyncio loop
│       └── windows/
│           ├── __init__.py
│           └── service.py            # pywin32 ServiceFramework wrapper
└── tests/
    ├── conftest.py
    ├── test_buffer.py
    ├── test_collector.py
    ├── test_client.py
    ├── test_runner.py
    └── test_windows_service.py
```

## What this PR (2B-7) does NOT do

- PyInstaller / single-binary packaging — the install script uses a
  venv on the target host. PyInstaller artefacts are tracked for the
  release-engineering pass.
- Auto-update channel — out of Phase 2B scope (planned for 2C+).
