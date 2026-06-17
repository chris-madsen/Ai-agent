#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

cf_api() {
    local METHOD="$1"; local URL="$2"; shift 2
    local RESP HTTP_CODE
    RESP=$(curl -sS -w '\n__HTTP_CODE__%{http_code}' \
        -X "$METHOD" "https://api.cloudflare.com/client/v4${URL}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" "$@")
    HTTP_CODE=$(echo "$RESP" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')
    RESP=$(echo "$RESP" | grep -v '__HTTP_CODE__')
    if ! echo "$RESP" | jq -e '.success == true' >/dev/null 2>&1; then
        die "CF API ${METHOD} ${URL} failed (HTTP ${HTTP_CODE}): $(echo "$RESP" | jq -r '.errors[0].message // .errors // empty' 2>/dev/null || echo "$RESP")"
    fi
    echo "$RESP"
}

: "${CF_TOKEN:?CF_TOKEN required}"
: "${CF_DOMAIN:?CF_DOMAIN required}"
MCP_PORT="${MCP_PORT:-8080}"
INSTALL_DIR="/opt/ssh-mcp-server"
SERVICE_USER="mcpserver"
CF_DIR="/etc/cloudflared"
TUNNEL_NAME="ssh-mcp-tunnel"
TOKEN_BACKUP="/etc/mcp-server-token"
SUDOERS_FILE="/etc/sudoers.d/mcpserver"

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
    HTTP_CODE=$(curl -sSL -o /tmp/cloudflared.deb -w "%{http_code}" "$CF_DEB_URL")
    [[ "$HTTP_CODE" == "200" ]] || die "Failed to download cloudflared (HTTP $HTTP_CODE)"
    dpkg -i /tmp/cloudflared.deb && rm -f /tmp/cloudflared.deb
else
    log "cloudflared already installed: $(cloudflared --version)"
fi

id "$SERVICE_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"

# Give mcpserver passwordless sudo
log "Configuring sudoers for $SERVICE_USER..."
echo "${SERVICE_USER} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
log "Sudoers configured."

log "Installing MCP server..."
mkdir -p "$INSTALL_DIR" "$CF_DIR"
cp server.py requirements.txt "$INSTALL_DIR/"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip -q
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Restore token from backup (survives uninstall), else reuse existing, else generate new
AUTH_TOKEN_FILE="$INSTALL_DIR/.auth_token"
if [[ -f "$TOKEN_BACKUP" ]]; then
    MCP_AUTH_TOKEN=$(cat "$TOKEN_BACKUP")
    cp "$TOKEN_BACKUP" "$AUTH_TOKEN_FILE"
    chmod 600 "$AUTH_TOKEN_FILE"
    chown "$SERVICE_USER:$SERVICE_USER" "$AUTH_TOKEN_FILE"
    rm -f "$TOKEN_BACKUP"
    log "Restored auth token from backup."
elif [[ -f "$AUTH_TOKEN_FILE" ]]; then
    MCP_AUTH_TOKEN=$(cat "$AUTH_TOKEN_FILE")
    log "Reusing existing auth token."
else
    MCP_AUTH_TOKEN=$(openssl rand -hex 32)
    echo "$MCP_AUTH_TOKEN" > "$AUTH_TOKEN_FILE"
    chmod 600 "$AUTH_TOKEN_FILE"
    chown "$SERVICE_USER:$SERVICE_USER" "$AUTH_TOKEN_FILE"
    log "Generated new auth token."
fi

log "Fetching Cloudflare Zone ID for $ZONE_NAME..."
ZONE_RESP=$(cf_api GET "/zones?name=${ZONE_NAME}&status=active")
ZONE_ID=$(echo "$ZONE_RESP" | jq -r '.result[0].id // empty')
[[ -n "$ZONE_ID" ]] || die "Zone '$ZONE_NAME' not found. Check CF_TOKEN has Zone:Read permission."
log "Zone ID: $ZONE_ID"

ACCOUNT_ID=$(echo "$ZONE_RESP" | jq -r '.result[0].account.id // empty')
[[ -n "$ACCOUNT_ID" ]] || die "Could not extract Account ID from zone response"
log "Account ID: $ACCOUNT_ID"

log "Setting up tunnel '$TUNNEL_NAME'..."
EXISTING=$(curl -sS \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")
TUNNEL_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')
TUNNEL_TOKEN=$(echo "$EXISTING" | jq -r '.result[0].token // empty')
TUNNEL_IS_NEW=false

if [[ -z "$TUNNEL_ID" ]]; then
    log "Creating new tunnel..."
    CREATE=$(cf_api POST "/accounts/${ACCOUNT_ID}/cfd_tunnel" \
        --data "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"$(openssl rand -base64 32)\"}")
    TUNNEL_ID=$(echo "$CREATE" | jq -r '.result.id')
    TUNNEL_TOKEN=$(echo "$CREATE" | jq -r '.result.token')
    TUNNEL_IS_NEW=true
else
    warn "Tunnel '$TUNNEL_NAME' already exists (ID: $TUNNEL_ID), reusing."
    warn "Skipping ingress reconfiguration to avoid overwriting other installations sharing this tunnel."
    warn "To force ingress update, delete the tunnel first or set FORCE_INGRESS=1."
    if [[ -z "$TUNNEL_TOKEN" ]]; then
        TUNNEL_TOKEN=$(cf_api GET "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" | jq -r '.result')
    fi
fi
[[ -n "$TUNNEL_TOKEN" ]] || die "Could not obtain tunnel token"

echo "$TUNNEL_TOKEN" > "$CF_DIR/token"
chmod 600 "$CF_DIR/token"

# Configure ingress only for new tunnels OR when explicitly forced
if [[ "$TUNNEL_IS_NEW" == true ]] || [[ "${FORCE_INGRESS:-0}" == "1" ]]; then
    log "Configuring tunnel ingress rules for $CF_DOMAIN -> localhost:$MCP_PORT ..."
    INGRESS_PAYLOAD=$(jq -n \
        --arg hostname "$CF_DOMAIN" \
        --arg service "http://localhost:$MCP_PORT" \
        '{
            config: {
                ingress: [
                    { hostname: $hostname, service: $service },
                    { service: "http_status:404" }
                ]
            }
        }')
    cf_api PUT "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
        --data "$INGRESS_PAYLOAD" >/dev/null
    log "Ingress rules configured."
else
    log "Ingress rules left unchanged (tunnel already existed)."
fi

log "Configuring DNS for $CF_DOMAIN..."
CNAME="${TUNNEL_ID}.cfargotunnel.com"
DNS_RESP=$(curl -sS \
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
sed "s|__MCP_PORT__|${MCP_PORT}|g; s|__INSTALL_DIR__|${INSTALL_DIR}|g; s|__SERVICE_USER__|${SERVICE_USER}|g; s|__MCP_AUTH_TOKEN__|${MCP_AUTH_TOKEN}|g" \
    ssh-mcp-server.service > /etc/systemd/system/ssh-mcp-server.service
install -m644 cloudflared.slice   /etc/systemd/system/cloudflared.slice
install -m644 cloudflared.service /etc/systemd/system/cloudflared.service

systemctl daemon-reload
systemctl enable --now ssh-mcp-server.service
systemctl enable --now cloudflared.service

echo ""
echo -e "${GREEN}=== Done! ===${NC}"
echo -e "  Transport: Streamable HTTP"
echo -e "  URL:       ${YELLOW}https://${CF_DOMAIN}/mcp${NC}"
echo -e "  Token:     ${YELLOW}${MCP_AUTH_TOKEN}${NC}"
