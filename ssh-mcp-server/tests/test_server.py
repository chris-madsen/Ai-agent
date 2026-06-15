"""Tests for SSH MCP Server."""
import os
import sys

# Force a known test token so tests are self-contained and repeatable,
# regardless of what MCP_AUTH_TOKEN is set to in the environment.
os.environ["MCP_AUTH_TOKEN"] = "testtoken123"
os.environ.setdefault("MCP_HOST", "127.0.0.1")
os.environ.setdefault("MCP_PORT", "8080")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest
from starlette.testclient import TestClient

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

HEADERS_NO_AUTH = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


@pytest.fixture(scope="module")
def client():
    app = create_app()
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


def test_unauthorized_returns_401(client):
    r = client.post("/mcp", json=INIT_PAYLOAD, headers=HEADERS_NO_AUTH)
    assert r.status_code == 401


def test_initialize_returns_200(client):
    r = client.post("/mcp", json=INIT_PAYLOAD, headers=HEADERS_OK)
    assert r.status_code == 200


def test_list_tools(client):
    r = client.post("/mcp", json={
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
