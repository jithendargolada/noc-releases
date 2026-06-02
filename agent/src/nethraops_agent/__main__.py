"""Allow `python -m nethraops_agent` to invoke the CLI."""

from nethraops_agent.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
