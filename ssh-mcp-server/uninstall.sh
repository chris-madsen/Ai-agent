#!/usr/bin/env bash
set -euo pipefail
systemctl stop cloudflared.service 2>/dev/null || true
systemctl stop ssh-mcp-server.service 2>/dev/null || true
systemctl disable ssh-mcp-server.service cloudflared.service 2>/dev/null || true
rm -f /etc/systemd/system/ssh-mcp-server.service \
       /etc/systemd/system/cloudflared.service \
       /etc/systemd/system/cloudflared.slice
systemctl daemon-reload
rm -rf /opt/ssh-mcp-server /etc/cloudflared
echo "Done."
