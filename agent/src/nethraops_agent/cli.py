"""Command-line entry point for the nethraops-agent binary.

Subcommands:
  run             Start the agent (default).
  collect-once    Print one collected batch as JSON and exit (debug).
  show-config     Print the resolved settings and exit.

Most operators only need `nethraops-agent run`. The other commands are
for incident response and CI smoke checks.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

from nethraops_agent import __version__
from nethraops_agent.collector import Collector
from nethraops_agent.config import AgentSettings, load_settings
from nethraops_agent.log import configure_logging
from nethraops_agent.runner import AgentRunner


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="nethraops-agent", description="NethraOps agent")
    p.add_argument("--config", type=Path, help="Path to .env-style config file")
    p.add_argument(
        "--version", action="version", version=f"nethraops-agent {__version__}"
    )

    sub = p.add_subparsers(dest="command")
    sub.add_parser("run", help="Run the agent in the foreground (systemd Type=simple)")
    sub.add_parser("collect-once", help="Print one batch as JSON and exit")
    sub.add_parser("show-config", help="Print resolved settings (secrets redacted)")

    return p


def _redact(settings: AgentSettings) -> dict:
    data = settings.model_dump(mode="json")
    for k in ("agent_token", "enrolment_token"):
        if data.get(k):
            data[k] = f"<redacted {len(data[k])} chars>"
    return data


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    settings = load_settings(args.config)
    configure_logging(level=settings.log_level, fmt=settings.log_format)

    cmd = args.command or "run"

    if cmd == "show-config":
        print(json.dumps(_redact(settings), indent=2, default=str))
        return 0

    if cmd == "collect-once":
        collector = Collector(settings, agent_version=__version__)
        # The first cpu_percent call is meaningless — psutil needs a
        # real interval to compute. Sleep once then collect.
        import time

        time.sleep(0.5)
        batch = collector.collect_once()
        print(json.dumps(batch, indent=2, default=str))
        return 0

    if cmd == "run":
        if not settings.has_credentials():
            print(
                "ERROR: NETHRAOPS_AGENT_TOKEN or NETHRAOPS_ENROLMENT_TOKEN must be set",
                file=sys.stderr,
            )
            return 2
        runner = AgentRunner(settings, agent_version=__version__)
        try:
            return asyncio.run(runner.run())
        except KeyboardInterrupt:
            return 0

    print(f"ERROR: unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
