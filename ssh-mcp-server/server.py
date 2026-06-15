#!/usr/bin/env python3
import json
import logging
import os
import subprocess

import paramiko
import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

HOST = os.getenv("MCP_HOST", "127.0.0.1")
PORT = int(os.getenv("MCP_PORT", "8080"))

mcp = FastMCP(
    "ssh-mcp-server",
    stateless_http=True,
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


# ---------- SSH/SFTP helpers ----------

def _connect(host, port, username, key_path):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    key = paramiko.RSAKey.from_private_key_file(key_path)
    client.connect(hostname=host, port=int(port), username=username, pkey=key)
    return client


# ---------- MCP Tools ----------

@mcp.tool()
def local_execute(
    command: str,
    timeout: int = 30,
) -> str:
    """Execute a shell command locally on the MCP server itself."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return json.dumps({
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": result.returncode,
        }, ensure_ascii=False, indent=2)
    except subprocess.TimeoutExpired:
        return json.dumps({"error": f"Command timed out after {timeout}s"})
    except Exception as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
def ssh_execute(
    host: str,
    username: str,
    private_key_path: str,
    command: str,
    port: int = 22,
    timeout: int = 30,
) -> str:
    """Execute a shell command on a remote server via SSH."""
    client = _connect(host, port, username, private_key_path)
    try:
        _, stdout, stderr = client.exec_command(command, timeout=timeout)
        result = {
            "stdout": stdout.read().decode("utf-8", errors="replace"),
            "stderr": stderr.read().decode("utf-8", errors="replace"),
            "exit_code": stdout.channel.recv_exit_status(),
        }
    except Exception as e:
        result = {"error": str(e)}
    finally:
        client.close()
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
def sftp_upload(
    host: str,
    username: str,
    private_key_path: str,
    local_path: str,
    remote_path: str,
    port: int = 22,
) -> str:
    """Upload a local file to a remote server via SFTP."""
    client = _connect(host, port, username, private_key_path)
    try:
        sftp = client.open_sftp()
        sftp.put(local_path, remote_path)
        sftp.close()
        result = {"status": "ok", "message": f"Uploaded {local_path} -> {remote_path}"}
    except Exception as e:
        result = {"error": str(e)}
    finally:
        client.close()
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
def sftp_download(
    host: str,
    username: str,
    private_key_path: str,
    remote_path: str,
    local_path: str,
    port: int = 22,
) -> str:
    """Download a file from a remote server via SFTP."""
    client = _connect(host, port, username, private_key_path)
    try:
        sftp = client.open_sftp()
        sftp.get(remote_path, local_path)
        sftp.close()
        result = {"status": "ok", "message": f"Downloaded {remote_path} -> {local_path}"}
    except Exception as e:
        result = {"error": str(e)}
    finally:
        client.close()
    return json.dumps(result, ensure_ascii=False, indent=2)


# ---------- Auth middleware ----------

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        auth_token = os.getenv("MCP_AUTH_TOKEN", "")
        if auth_token and request.headers.get("Authorization") != f"Bearer {auth_token}":
            return JSONResponse({"error": "Unauthorized"}, status_code=401)
        return await call_next(request)


# ---------- App factory ----------

def create_app():
    app = mcp.streamable_http_app()
    app.add_middleware(AuthMiddleware)
    return app


# ---------- Entry point ----------

if __name__ == "__main__":
    logger.info(f"Starting SSH MCP Server on {HOST}:{PORT}/mcp")
    app = create_app()
    uvicorn.run(app, host=HOST, port=PORT)
