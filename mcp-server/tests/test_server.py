"""
Tests for SSH MCP Server.

Unit tests (ASGI in-process): use MCP_AUTH_TOKEN from env — same token the server runs with.
E2e tests (live HTTP):        hit the running server at MCP_BASE_URL (default 127.0.0.1:8080).

Run:
    MCP_AUTH_TOKEN=$(cat /opt/ssh-mcp-server/.auth_token) \
    PYTHONPATH=$(pwd) \
    pytest tests/ -v
"""
import os
import sys

import httpx
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from starlette.testclient import TestClient

from server import create_app


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _token() -> str:
    token = os.getenv("MCP_AUTH_TOKEN", "")
    if not token:
        pytest.fail(
            "MCP_AUTH_TOKEN is not set.\n"
            "Run: export MCP_AUTH_TOKEN=$(cat /opt/ssh-mcp-server/.auth_token)"
        )
    return token


def _headers(token: str) -> dict:
    return {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}",
    }


def _headers_no_auth() -> dict:
    return {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }


INIT_PAYLOAD = {
    "jsonrpc": "2.0",
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "1"},
    },
    "id": 1,
}

TOOLS_LIST_PAYLOAD = {
    "jsonrpc": "2.0",
    "method": "tools/list",
    "params": {},
    "id": 2,
}

EXPECTED_TOOLS = {"ssh_execute", "sftp_upload", "sftp_download", "local_execute"}


# ---------------------------------------------------------------------------
# Unit tests — in-process ASGI, no network
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def unit_client():
    app = create_app()
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


def test_unit_unauthorized_returns_401(unit_client):
    r = unit_client.post("/mcp", json=INIT_PAYLOAD, headers=_headers_no_auth())
    assert r.status_code == 401, f"Expected 401, got {r.status_code}: {r.text}"


def test_unit_initialize_returns_200(unit_client):
    r = unit_client.post("/mcp", json=INIT_PAYLOAD, headers=_headers(_token()))
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"


def test_unit_list_tools(unit_client):
    r = unit_client.post("/mcp", json=TOOLS_LIST_PAYLOAD, headers=_headers(_token()))
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"
    for tool in EXPECTED_TOOLS:
        assert tool in r.text, f"Tool {tool!r} missing from response"


def test_unit_local_execute(unit_client):
    payload = {
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {"name": "local_execute", "arguments": {"command": "echo hello"}},
        "id": 3,
    }
    r = unit_client.post("/mcp", json=payload, headers=_headers(_token()))
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"
    assert "hello" in r.text, f"Expected 'hello' in response: {r.text}"


# ---------------------------------------------------------------------------
# E2e tests — live HTTP against the running server
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def e2e_client():
    base_url = os.getenv("MCP_BASE_URL", "http://127.0.0.1:8080")
    with httpx.Client(base_url=base_url, timeout=10) as c:
        yield c


def test_e2e_unauthorized_returns_401(e2e_client):
    r = e2e_client.post("/mcp", json=INIT_PAYLOAD, headers=_headers_no_auth())
    assert r.status_code == 401, f"Expected 401, got {r.status_code}: {r.text}"


def test_e2e_initialize_returns_200(e2e_client):
    r = e2e_client.post("/mcp", json=INIT_PAYLOAD, headers=_headers(_token()))
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"


def test_e2e_list_tools(e2e_client):
    r = e2e_client.post("/mcp", json=TOOLS_LIST_PAYLOAD, headers=_headers(_token()))
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"
    for tool in EXPECTED_TOOLS:
        assert tool in r.text, f"Tool {tool!r} missing from response"


def test_e2e_local_execute(e2e_client):
    payload = {
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": {"name": "local_execute", "arguments": {"command": "echo hello"}},
        "id": 3,
    }
    r = e2e_client.post("/mcp", json=payload, headers=_headers(_token()))
    assert r.status_code == 200, f"Expected 200, got {r.status_code}: {r.text}"
    assert "hello" in r.text, f"Expected 'hello' in response: {r.text}"
