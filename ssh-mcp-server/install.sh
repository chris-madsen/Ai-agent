#!/usr/bin/env bash
set -euo pipefail
: "${CF_TOKEN:?}"
: "${CF_DOMAIN:?}"
MCP_PORT="${MCP_PORT:-8080}"
INSTALL_DIR=/opt/ssh-mcp-server
SERVICE_USER=mcpserver
CF_DIR=/etc/cloudflared
TUNNEL_NAME=ssh-mcp-tunnel
FULL_HOSTNAME="$CF_DOMAIN"
[[ $EUID -ne 0 ]] && { echo root required; exit 1; }
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl jq openssl
id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
mkdir -p "$INSTALL_DIR" "$CF_DIR"
cp server.py requirements.txt "$INSTALL_DIR/"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip -q
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q
ARCH=$(dpkg --print-architecture)
if ! command -v cloudflared >/dev/null 2>&1; then curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" -o /tmp/cloudflared.deb && dpkg -i /tmp/cloudflared.deb && rm -f /tmp/cloudflared.deb; fi
ZONE_NAME="${CF_DOMAIN#*.}"
ZONE_ID=$(curl -fsSL "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}&status=active" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
ACCOUNT_ID=$(curl -fsSL "https://api.cloudflare.com/client/v4/accounts" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
TUNNEL_ID=$(curl -fsSL "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
if [[ -z "$TUNNEL_ID" ]]; then TUNNEL_ID=$(curl -fsSL -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" --data "{"name":"${TUNNEL_NAME}","tunnel_secret":"$(openssl rand -base64 32)"}" | jq -r '.result.id // empty'); fi
TUNNEL_TOKEN=$(curl -fsSL "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" | jq -r '.result // empty')
echo "$TUNNEL_TOKEN" > "$CF_DIR/token"
chmod 600 "$CF_DIR/token"
DNS_ID=$(curl -fsSL "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${FULL_HOSTNAME}&type=CNAME" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id // empty')
CNAME="${TUNNEL_ID}.cfargotunnel.com"
if [[ -z "$DNS_ID" ]]; then curl -fsSL -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" --data "{"type":"CNAME","name":"${FULL_HOSTNAME}","content":"${CNAME}","proxied":true,"ttl":1}" >/dev/null; else curl -fsSL -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_ID}" -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" --data "{"type":"CNAME","name":"${FULL_HOSTNAME}","content":"${CNAME}","proxied":true,"ttl":1}" >/dev/null; fi
install -m 0644 cloudflared.slice /etc/systemd/system/cloudflared.slice
install -m 0644 cloudflared.service /etc/systemd/system/cloudflared.service
install -m 0644 ssh-mcp-server.service /etc/systemd/system/ssh-mcp-server.service
systemctl daemon-reload
systemctl enable --now ssh-mcp-server.service cloudflared.service
