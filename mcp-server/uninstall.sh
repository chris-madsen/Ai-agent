#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

TOKEN_BACKUP="/etc/mcp-server-token"
AUTH_TOKEN_FILE="/opt/ssh-mcp-server/.auth_token"
CF_DIR="/etc/cloudflared"

# Preserve auth token across uninstall so it survives reinstall
if [[ -f "$AUTH_TOKEN_FILE" ]]; then
    cp "$AUTH_TOKEN_FILE" "$TOKEN_BACKUP"
    chmod 600 "$TOKEN_BACKUP"
    log "Auth token backed up to $TOKEN_BACKUP"
fi

# Stop and disable services
systemctl stop cloudflared.service ssh-mcp-server.service 2>/dev/null || true
systemctl disable ssh-mcp-server.service cloudflared.service 2>/dev/null || true
rm -f /etc/systemd/system/ssh-mcp-server.service \
       /etc/systemd/system/cloudflared.service \
       /etc/systemd/system/cloudflared.slice
systemctl daemon-reload

# Delete Cloudflare tunnel — only the one that belongs to THIS installation
# Reads tunnel_name, tunnel_id, account_id saved by install.sh
if [[ -n "${CF_TOKEN:-}" ]] && [[ -f "$CF_DIR/tunnel_id" ]] && [[ -f "$CF_DIR/account_id" ]]; then
    TUNNEL_ID=$(cat "$CF_DIR/tunnel_id")
    ACCOUNT_ID=$(cat "$CF_DIR/account_id")
    TUNNEL_NAME=$(cat "$CF_DIR/tunnel_name" 2>/dev/null || echo "unknown")
    log "Deleting Cloudflare tunnel '$TUNNEL_NAME' ($TUNNEL_ID)..."
    RESP=$(curl -sS -w '\n__HTTP_CODE__%{http_code}' \
        -X DELETE \
        "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json")
    HTTP_CODE=$(echo "$RESP" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')
    BODY=$(echo "$RESP" | grep -v '__HTTP_CODE__')
    if echo "$BODY" | jq -e '.success == true' >/dev/null 2>&1; then
        log "Tunnel '$TUNNEL_NAME' deleted from Cloudflare."
    else
        warn "Could not delete tunnel (HTTP $HTTP_CODE): $(echo "$BODY" | jq -r '.errors[0].message // empty' 2>/dev/null || echo "$BODY")"
        warn "Delete it manually: Cloudflare Dashboard → Zero Trust → Networks → Tunnels"
    fi
else
    warn "CF_TOKEN not set or tunnel metadata missing — skipping Cloudflare tunnel deletion."
    warn "Delete the tunnel manually if needed: Cloudflare Dashboard → Zero Trust → Networks → Tunnels"
fi

# Remove local files
rm -rf /opt/ssh-mcp-server /etc/cloudflared
rm -f /etc/sudoers.d/mcpserver
userdel mcpserver 2>/dev/null || true

echo ""
echo -e "${GREEN}Done.${NC}"
