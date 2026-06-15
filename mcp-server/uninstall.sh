#!/usr/bin/env bash
set -euo pipefail

TOKEN_BACKUP="/etc/mcp-server-token"
AUTH_TOKEN_FILE="/opt/ssh-mcp-server/.auth_token"

# Preserve auth token across uninstall so it survives reinstall
if [[ -f "$AUTH_TOKEN_FILE" ]]; then
    cp "$AUTH_TOKEN_FILE" "$TOKEN_BACKUP"
    chmod 600 "$TOKEN_BACKUP"
fi

systemctl stop cloudflared.service ssh-mcp-server.service 2>/dev/null || true
systemctl disable ssh-mcp-server.service cloudflared.service 2>/dev/null || true
rm -f /etc/systemd/system/ssh-mcp-server.service \
       /etc/systemd/system/cloudflared.service \
       /etc/systemd/system/cloudflared.slice
systemctl daemon-reload
rm -rf /opt/ssh-mcp-server /etc/cloudflared
rm -f /etc/sudoers.d/mcpserver
userdel mcpserver 2>/dev/null || true
echo "Done."
