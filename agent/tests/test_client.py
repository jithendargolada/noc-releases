"""IngestClient — push semantics, retry classification, registration."""

from __future__ import annotations

import httpx
import pytest
import respx

from nethraops_agent.client import IngestClient


@pytest.fixture
async def client(settings):
    c = IngestClient(settings, agent_version="0.1.0")
    yield c
    await c.close()


@respx.mock
async def test_push_succeeds_on_202(client) -> None:
    respx.post("http://localhost:8000/api/v1/agents/metrics").mock(
        return_value=httpx.Response(202, json={"accepted": 5, "rejected": 0}),
    )
    outcome = await client.push({"agent_version": "0.1.0", "frames": []})
    assert outcome.ok is True
    assert outcome.status_code == 202
    assert outcome.accepted == 5
    assert outcome.transient is False


@respx.mock
async def test_push_classifies_5xx_as_transient(client) -> None:
    respx.post("http://localhost:8000/api/v1/agents/metrics").mock(
        return_value=httpx.Response(503, text="db down"),
    )
    outcome = await client.push({"agent_version": "0.1.0", "frames": []})
    assert outcome.ok is False
    assert outcome.transient is True
    assert outcome.status_code == 503


@respx.mock
async def test_push_classifies_4xx_as_permanent_except_429(client) -> None:
    respx.post("http://localhost:8000/api/v1/agents/metrics").mock(
        return_value=httpx.Response(401, text="bad token"),
    )
    outcome = await client.push({"agent_version": "0.1.0", "frames": []})
    assert outcome.ok is False
    assert outcome.transient is False  # 4xx is permanent

    respx.post("http://localhost:8000/api/v1/agents/metrics").mock(
        return_value=httpx.Response(429, text="rate limited"),
    )
    outcome2 = await client.push({"agent_version": "0.1.0", "frames": []})
    assert outcome2.ok is False
    assert outcome2.transient is True  # 429 retries


@respx.mock
async def test_push_classifies_network_error_as_transient(client) -> None:
    respx.post("http://localhost:8000/api/v1/agents/metrics").mock(
        side_effect=httpx.ConnectError("no route to host"),
    )
    outcome = await client.push({"agent_version": "0.1.0", "frames": []})
    assert outcome.ok is False
    assert outcome.status_code is None
    assert outcome.transient is True


@respx.mock
async def test_push_uses_x_agent_token_header(client) -> None:
    route = respx.post("http://localhost:8000/api/v1/agents/metrics").mock(
        return_value=httpx.Response(202, json={"accepted": 0}),
    )
    await client.push({"agent_version": "0.1.0", "frames": []})
    assert route.called
    request = route.calls.last.request
    assert request.headers["X-Agent-Token"] == "test-agent-token"


@respx.mock
async def test_register_round_trip(settings) -> None:
    settings.agent_token = ""
    settings.enrolment_token = "enrol-tok"
    settings.device_slug = "host-1"
    settings.device_name = "Host One"
    settings.device_type = "linux"

    respx.post("http://localhost:8000/api/v1/agents/register").mock(
        return_value=httpx.Response(
            201,
            json={"agent_token": "long-lived", "device": {"id": "dev-1"}},
        ),
    )
    c = IngestClient(settings, agent_version="0.1.0")
    try:
        outcome = await c.register()
    finally:
        await c.close()
    assert outcome.ok is True
    assert outcome.agent_token == "long-lived"
    assert outcome.device_id == "dev-1"
    assert c.agent_token == "long-lived"


async def test_register_refuses_without_enrolment_token(settings) -> None:
    settings.agent_token = ""
    settings.enrolment_token = ""
    c = IngestClient(settings, agent_version="0.1.0")
    try:
        outcome = await c.register()
    finally:
        await c.close()
    assert outcome.ok is False
    assert "enrolment" in (outcome.error or "")
