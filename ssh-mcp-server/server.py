#!/usr/bin/env python3
import json
import logging
import os
import uuid
from typing import Any

import paramiko
import uvicorn
from mcp.server import Server
from mcp.server.streamable_http import StreamableHTTPServerTransport
from mcp.types import TextContent, Tool
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

AUTH_TOKEN = os.getenv("MCP_AUTH_TOKEN", "")

mcp = Server("ssh-mcp-server")


# --- SSH/SFTP helpers ---

def _connect(host, port, username, key_path):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = paramiko.RSAKey.from_private_key_file(key_path)
    client.connect(hostname=host, port=int(port), username=username, pkey=key)
    return client


def ssh_execute(host, port, username, key_path, command, timeout=30):
    client = _connect(host, port, username, key_path)
    try:
        _, stdout, stderr = client.exec_command(command, timeout=int(timeout))
        return {
            "stdout": stdout.read().decode("utf-8", errors="replace"),
            "stderr": stderr.read().decode("utf-8", errors="replace"),
            "exit_code": stdout.channel.recv_exit_status(),
        }
    finally:
        client.close()


def sftp_upload(host, port, username, key_path, local_path, remote_path):
    client = _connect(host, port, username, key_path)
    try:
        sftp = client.open_sftp()
        sftp.put(local_path, remote_path)
        sftp.close()
        return {"status": "ok", "message": f"Uploaded {local_path} -> {remote_path}"}
    finally:
        client.close()


def sftp_download(host, port, username, key_path, remote_path, local_path):
    client = _connect(host, port, username, key_path)
    try:
        sftp = client.open_sftp()
        sftp.get(remote_path, local_path)
        sftp.close()
        return {"status": "ok", "message": f"Downloaded {remote_path} -> {local_path}"}
    finally:
        client.close()


# --- MCP tool definitions ---

@mcp.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="ssh_execute",
            description="Execute a shell command on a remote server via SSH",
            inputSchema={
                "type": "object",
                "properties": {
                    "host": {"type": "string"},
                    "port": {"type": "integer", "default": 22},
                    "username": {"type": "string"},
                    "private_key_path": {"type": "string"},
                    "command": {"type": "string"},
                    "timeout": {"type": "integer", "default": 30},
                },
                "required": ["host", "username", "private_key_path", "command"],
            },
        ),
        Tool(
            name="sftp_upload",
            description="Upload a local file to a remote server via SFTP",
            inputSchema={
                "type": "object",
                "properties": {
                    "host": {"type": "string"},
                    "port": {"type": "integer", "default": 22},
                    "username": {"type": "string"},
                    "private_key_path": {"type": "string"},
                    "local_path": {"type": "string"},
                    "remote_path": {"type": "string"},
                },
                "required": ["host", "username", "private_key_path", "local_path", "remote_path"],
            },
        ),
        Tool(
            name="sftp_download",
            description="Download a file from a remote server via SFTP",
            inputSchema={
                "type": "object",
                "properties": {
                    "host": {"type": "string"},
                    "port": {"type": "integer", "default": 22},
                    "username": {"type": "string"},
                    "private_key_path": {"type": "string"},
                    "remote_path": {"type": "string"},
                    "local_path": {"type": "string"},
                },
                "required": ["host", "username", "private_key_path", "remote_path", "local_path"],
            },
        ),
    ]


@mcp.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    try:
        if name == "ssh_execute":
            result = ssh_execute(
                arguments["host"], arguments.get("port", 22),
                arguments["username"], arguments["private_key_path"],
                arguments["command"], arguments.get("timeout", 30),
            )
        elif name == "sftp_upload":
            result = sftp_upload(
                arguments["host"], arguments.get("port", 22),
                arguments["username"], arguments["private_key_path"],
                arguments["local_path"], arguments["remote_path"],
            )
        elif name == "sftp_download":
            result = sftp_download(
                arguments["host"], arguments.get("port", 22),
                arguments["username"], arguments["private_key_path"],
                arguments["remote_path"], arguments["local_path"],
            )
        else:
            result = {"error": f"Unknown tool: {name}"}
    except Exception as e:
        result = {"error": str(e)}
    return [TextContent(type="text", text=json.dumps(result, ensure_ascii=False, indent=2))]


# --- Auth check ---

def _check_auth(request: Request) -> bool:
    if not AUTH_TOKEN:
        return True
    return request.headers.get("Authorization", "") == f"Bearer {AUTH_TOKEN}"


# --- Starlette app ---

async def handle_mcp(request: Request) -> Response:
    if not _check_auth(request):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    transport = StreamableHTTPServerTransport(mcp_session_id=str(uuid.uuid4()))

    async with transport.connect() as (read_stream, write_stream):
        await mcp.run(
            read_stream,
            write_stream,
            mcp.create_initialization_options(),
        )
        # handle_request is a proper ASGI callable
        response = Response()
        await transport.handle_request(request.scope, request.receive, response.raw_path_send)
        return response


def create_app() -> Starlette:
    return Starlette(
        routes=[
            Route("/mcp", endpoint=handle_mcp, methods=["GET", "POST", "DELETE"]),
        ]
    )


if __name__ == "__main__":
    host = os.getenv("MCP_HOST", "127.0.0.1")
    port = int(os.getenv("MCP_PORT", "8080"))
    logger.info(f"Starting SSH MCP Server on {host}:{port}/mcp")
    uvicorn.run(create_app(), host=host, port=port)
