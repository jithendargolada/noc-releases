"""structlog setup — JSON in production, console-pretty in dev."""

from __future__ import annotations

import logging
import sys
from typing import Literal

import structlog


def configure_logging(level: str = "INFO", fmt: Literal["json", "console"] = "json") -> None:
    """Wire structlog + stdlib so every logger flows through the same pipeline."""
    logging.basicConfig(
        level=getattr(logging, level, logging.INFO),
        format="%(message)s",
        stream=sys.stdout,
    )
    common_processors: list[structlog.types.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
    ]
    if fmt == "json":
        renderer: structlog.types.Processor = structlog.processors.JSONRenderer()
    else:
        renderer = structlog.dev.ConsoleRenderer(colors=True)
    structlog.configure(
        processors=[*common_processors, renderer],
        wrapper_class=structlog.make_filtering_bound_logger(getattr(logging, level, 20)),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str) -> structlog.stdlib.BoundLogger:
    return structlog.get_logger(name)
