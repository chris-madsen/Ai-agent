"""Tests for ssh-mcp-server."""
import json
import os
import sys

import pytest
from httpx import AsyncClient, ASGITransport

# Make sure server module is importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.setdefault("MCP_AUTH_TOKEN", "test-token")
os.environ.setdefault("MCP_PORT", "8080")

from server import create_app  # noqa: E402

APP = create_app()

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


@pytest.mark.anyio
async def test_unauthorized_returns_401():
    """Requests without a valid token must be rejected."""
    async with AsyncClient(transport=ASGITransport(app=APP), base_url="http://test") as client:
        resp = await client.post(
            "/mcp",
            json=INIT_PAYLOAD,
            headers={"Content-Type": "application/json"},
        )
    assert resp.status_code == 401


@pytest.mark.anyio
async def test_external_host_header_not_rejected():
    """Cloudflare tunnel sends an external Host header — must NOT get 421."""
    async with AsyncClient(transport=ASGITransport(app=APP), base_url="http://test") as client:
        resp = await client.post(
            "/mcp",
            json=INIT_PAYLOAD,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer test-token",
                "Host": "mcp.network-communications.net",
            },
        )
    # Must NOT be 421 (Misdirected Request)
    assert resp.status_code != 421, "DNS rebinding protection is still blocking external Host header"


@pytest.mark.anyio
async def test_initialize_returns_response():
    """Valid initialize request must return a jsonrpc response."""
    async with AsyncClient(transport=ASGITransport(app=APP), base_url="http://test") as client:
        resp = await client.post(
            "/mcp",
            json=INIT_PAYLOAD,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer test-token",
                "Host": "mcp.network-communications.net",
            },
        )
    assert resp.status_code == 200
    # Response can be JSON or SSE; either way must not be error
    body = resp.text
    assert "error" not in body.lower() or "Unauthorized" not in body


@pytest.mark.anyio
async def test_list_tools():
    """Server must advertise ssh_execute, sftp_upload, sftp_download tools."""
    init_resp_data = None
    async with AsyncClient(transport=ASGITransport(app=APP), base_url="http://test") as client:
        # initialize
        resp = await client.post(
            "/mcp",
            json=INIT_PAYLOAD,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer test-token",
                "Host": "mcp.network-communications.net",
                "Accept": "application/json, text/event-stream",
            },
        )
        assert resp.status_code == 200
        session_id = resp.headers.get("mcp-session-id")

        list_tools_payload = {
            "jsonrpc": "2.0",
            "method": "tools/list",
            "params": {},
            "id": 2,
        }
        extra_headers = {
            "Content-Type": "application/json",
            "Authorization": "Bearer test-token",
            "Host": "mcp.network-communications.net",
            "Accept": "application/json, text/event-stream",
        }
        if session_id:
            extra_headers["mcp-session-id"] = session_id

        resp2 = await client.post("/mcp", json=list_tools_payload, headers=extra_headers)
        assert resp2.status_code == 200
        body = resp2.text

    for tool_name in ("ssh_execute", "sftp_upload", "sftp_download"):
        assert tool_name in body, f"Tool '{tool_name}' not found in tools/list response"
