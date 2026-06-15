#!/usr/bin/env python3
import json, logging, os
from typing import Any
import paramiko
from mcp.server import Server
from mcp.types import Tool, TextContent
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.routing import Route, Mount
from mcp.server.sse import SseServerTransport
import uvicorn

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
app = Server("ssh-mcp-server")

def _connect(host, port, username, key_path):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = paramiko.RSAKey.from_private_key_file(key_path)
    client.connect(hostname=host, port=port, username=username, pkey=key)
    return client

def ssh_execute(host, port, username, private_key_path, command, timeout=30):
    client = _connect(host, port, username, private_key_path)
    try:
        _, stdout, stderr = client.exec_command(command, timeout=timeout)
        return {
            "stdout": stdout.read().decode("utf-8", errors="replace"),
            "stderr": stderr.read().decode("utf-8", errors="replace"),
            "exit_code": stdout.channel.recv_exit_status(),
        }
    finally:
        client.close()

def sftp_upload(host, port, username, private_key_path, local_path, remote_path):
    client = _connect(host, port, username, private_key_path)
    try:
        sftp = client.open_sftp()
        sftp.put(local_path, remote_path)
        sftp.close()
        return {"status": "ok", "message": f"Uploaded {local_path} -> {remote_path}"}
    finally:
        client.close()

def sftp_download(host, port, username, private_key_path, remote_path, local_path):
    client = _connect(host, port, username, private_key_path)
    try:
        sftp = client.open_sftp()
        sftp.get(remote_path, local_path)
        sftp.close()
        return {"status": "ok", "message": f"Downloaded {remote_path} -> {local_path}"}
    finally:
        client.close()

@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(name="ssh_execute", description="Execute a shell command on a remote server via SSH",
             inputSchema={"type":"object","properties":{"host":{"type":"string"},"port":{"type":"integer","default":22},"username":{"type":"string"},"private_key_path":{"type":"string"},"command":{"type":"string"},"timeout":{"type":"integer","default":30}},"required":["host","username","private_key_path","command"]}),
        Tool(name="sftp_upload", description="Upload a local file to a remote server via SFTP",
             inputSchema={"type":"object","properties":{"host":{"type":"string"},"port":{"type":"integer","default":22},"username":{"type":"string"},"private_key_path":{"type":"string"},"local_path":{"type":"string"},"remote_path":{"type":"string"}},"required":["host","username","private_key_path","local_path","remote_path"]}),
        Tool(name="sftp_download", description="Download a file from a remote server via SFTP",
             inputSchema={"type":"object","properties":{"host":{"type":"string"},"port":{"type":"integer","default":22},"username":{"type":"string"},"private_key_path":{"type":"string"},"remote_path":{"type":"string"},"local_path":{"type":"string"}},"required":["host","username","private_key_path","remote_path","local_path"]}),
    ]

@app.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    try:
        if name == "ssh_execute": result = ssh_execute(arguments["host"], arguments.get("port",22), arguments["username"], arguments["private_key_path"], arguments["command"], arguments.get("timeout",30))
        elif name == "sftp_upload": result = sftp_upload(arguments["host"], arguments.get("port",22), arguments["username"], arguments["private_key_path"], arguments["local_path"], arguments["remote_path"])
        elif name == "sftp_download": result = sftp_download(arguments["host"], arguments.get("port",22), arguments["username"], arguments["private_key_path"], arguments["remote_path"], arguments["local_path"])
        else: result = {"error": f"Unknown tool: {name}"}
    except Exception as e:
        result = {"error": str(e)}
    return [TextContent(type="text", text=json.dumps(result, ensure_ascii=False, indent=2))]

def create_starlette_app(mcp_server: Server) -> Starlette:
    sse = SseServerTransport("/messages/")
    async def handle_sse(request: Request):
        async with sse.connect_sse(request.scope, request.receive, request._send) as streams:
            await mcp_server.run(streams[0], streams[1], mcp_server.create_initialization_options())
    return Starlette(routes=[Route("/sse", endpoint=handle_sse), Mount("/messages/", app=sse.handle_post_message)])

if __name__ == "__main__":
    host = os.getenv("MCP_HOST", "127.0.0.1")
    port = int(os.getenv("MCP_PORT", "8080"))
    logger.info(f"Starting SSH MCP Server on {host}:{port}")
    uvicorn.run(create_starlette_app(app), host=host, port=port)
