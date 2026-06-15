#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

cf_api() {
    local METHOD="$1"; local URL="$2"; shift 2
    local RESP
    RESP=$(curl -fsSL --fail-with-body -X "$METHOD" "https://api.cloudflare.com/client/v4$URL" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" "$@")
    echo "$RESP" | jq -e '.success == true' >/dev/null \
        || die "CF API error: $(echo "$RESP" | jq -r '.errors[0].message // .errors')"
    echo "$RESP"
}

: "${CF_TOKEN:?CF_TOKEN required}"
: "${CF_DOMAIN:?CF_DOMAIN required}"
MCP_PORT="${MCP_PORT:-8080}"
INSTALL_DIR="/opt/ssh-mcp-server"
SERVICE_USER="mcpserver"
CF_DIR="/etc/cloudflared"
TUNNEL_NAME="ssh-mcp-tunnel"

[[ $EUID -ne 0 ]] && die "Run as root: sudo -E bash install.sh"

IFS='.' read -ra PARTS <<< "$CF_DOMAIN"
(( ${#PARTS[@]} >= 3 )) || die "CF_DOMAIN must be a full hostname like mcp.example.com (got: $CF_DOMAIN)"
ZONE_NAME="${CF_DOMAIN#*.}"

log "Hostname : $CF_DOMAIN"
log "Zone     : $ZONE_NAME"
log "Port     : $MCP_PORT"

log "Installing packages..."
apt-get update -qq
apt-get install -y -qq python3 python3-venv curl jq openssl

if ! command -v cloudflared >/dev/null 2>&1; then
    log "Installing cloudflared..."
    ARCH=$(dpkg --print-architecture)
    CF_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
    HTTP_CODE=$(curl -fsSL -o /tmp/cloudflared.deb -w "%{http_code}" "$CF_DEB_URL")
    [[ "$HTTP_CODE" == "200" ]] || die "Failed to download cloudflared (HTTP $HTTP_CODE): $CF_DEB_URL"
    dpkg -i /tmp/cloudflared.deb && rm -f /tmp/cloudflared.deb
else
    log "cloudflared already installed: $(cloudflared --version)"
fi

id "$SERVICE_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"

log "Installing MCP server..."
mkdir -p "$INSTALL_DIR" "$CF_DIR"
cp server.py requirements.txt "$INSTALL_DIR/"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip -q
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

log "Fetching Cloudflare Zone ID for $ZONE_NAME..."
ZONE_ID=$(cf_api GET "/zones?name=${ZONE_NAME}&status=active" | jq -r '.result[0].id // empty')
[[ -n "$ZONE_ID" ]] || die "Zone not found: $ZONE_NAME"

log "Fetching Cloudflare Account ID..."
ACCOUNT_ID=$(cf_api GET "/accounts" | jq -r '.result[0].id // empty')
[[ -n "$ACCOUNT_ID" ]] || die "Could not get Account ID"

log "Setting up tunnel '$TUNNEL_NAME'..."
EXISTING=$(curl -fsSL \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")
TUNNEL_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')
TUNNEL_TOKEN=$(echo "$EXISTING" | jq -r '.result[0].token // empty')

if [[ -z "$TUNNEL_ID" ]]; then
    log "Creating new tunnel..."
    CREATE=$(cf_api POST "/accounts/${ACCOUNT_ID}/cfd_tunnel" \
        --data "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"$(openssl rand -base64 32)\"}")
    TUNNEL_ID=$(echo "$CREATE" | jq -r '.result.id')
    TUNNEL_TOKEN=$(echo "$CREATE" | jq -r '.result.token')
else
    warn "Tunnel '$TUNNEL_NAME' already exists (ID: $TUNNEL_ID), reusing."
    if [[ -z "$TUNNEL_TOKEN" ]]; then
        TUNNEL_TOKEN=$(cf_api GET "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
            | jq -r '.result')
    fi
fi
[[ -n "$TUNNEL_TOKEN" ]] || die "Could not obtain tunnel token"

echo "$TUNNEL_TOKEN" > "$CF_DIR/token"
chmod 600 "$CF_DIR/token"

log "Configuring DNS for $CF_DOMAIN..."
CNAME="${TUNNEL_ID}.cfargotunnel.com"
DNS_RESP=$(curl -fsSL \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${CF_DOMAIN}&type=CNAME" \
    -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json")
DNS_ID=$(echo "$DNS_RESP" | jq -r '.result[0].id // empty')
DNS_PAYLOAD="{\"type\":\"CNAME\",\"name\":\"${CF_DOMAIN}\",\"content\":\"${CNAME}\",\"proxied\":true,\"ttl\":1}"

if [[ -z "$DNS_ID" ]]; then
    cf_api POST "/zones/${ZONE_ID}/dns_records" --data "$DNS_PAYLOAD" >/dev/null
    log "DNS record created."
else
    cf_api PUT "/zones/${ZONE_ID}/dns_records/${DNS_ID}" --data "$DNS_PAYLOAD" >/dev/null
    log "DNS record updated."
fi

log "Installing systemd units..."
sed "s|__MCP_PORT__|${MCP_PORT}|g; s|__INSTALL_DIR__|${INSTALL_DIR}|g; s|__SERVICE_USER__|${SERVICE_USER}|g" \
    ssh-mcp-server.service > /etc/systemd/system/ssh-mcp-server.service
install -m644 cloudflared.slice   /etc/systemd/system/cloudflared.slice
install -m644 cloudflared.service /etc/systemd/system/cloudflared.service

systemctl daemon-reload
systemctl enable --now ssh-mcp-server.service
systemctl enable --now cloudflared.service

echo ""
echo -e "${GREEN}Done! Add this URL to Perplexity connectors:${NC}"
echo -e "  ${YELLOW}https://${CF_DOMAIN}/sse${NC}"
