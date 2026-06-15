"""Tests for SSH MCP Server."""
import pytest
from httpx import AsyncClient, ASGITransport

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("MCP_AUTH_TOKEN", "testtoken123")
os.environ.setdefault("MCP_HOST", "127.0.0.1")
os.environ.setdefault("MCP_PORT", "8080")

from server import create_app

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

HEADERS_OK = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "Authorization": "Bearer testtoken123",
}


@pytest.fixture
def app():
    return create_app()


@pytest.mark.anyio
async def test_unauthorized_returns_401(app):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.post("/mcp", json=INIT_PAYLOAD, headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        })
    assert r.status_code == 401


@pytest.mark.anyio
async def test_initialize_returns_200(app):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.post("/mcp", json=INIT_PAYLOAD, headers=HEADERS_OK)
    assert r.status_code == 200


@pytest.mark.anyio
async def test_list_tools(app):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # First initialize
        init_r = await client.post("/mcp", json=INIT_PAYLOAD, headers=HEADERS_OK)
        assert init_r.status_code == 200

        # Then list tools
        r = await client.post("/mcp", json={
            "jsonrpc": "2.0",
            "method": "tools/list",
            "params": {},
            "id": 2,
        }, headers=HEADERS_OK)
    assert r.status_code == 200
    body = r.text
    assert "ssh_execute" in body
    assert "sftp_upload" in body
    assert "sftp_download" in body
