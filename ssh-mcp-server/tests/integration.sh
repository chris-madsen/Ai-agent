#!/usr/bin/env bash
# Live integration tests against localhost:8080
# Usage: bash tests/integration.sh <MCP_AUTH_TOKEN>
set -euo pipefail

TOKEN="${1:-}"
[[ -n "$TOKEN" ]] || { echo "Usage: $0 <token>"; exit 1; }

BASE="http://127.0.0.1:8080/mcp"
PASS=0; FAIL=0

check() {
    local name="$1" cond="$2" detail="${3:-}"
    if [[ "$cond" == "0" ]]; then
        echo "[PASS ✓] $name"
        ((PASS++))
    else
        echo "[FAIL ✗] $name  →  $detail"
        ((FAIL++))
    fi
}

INIT='{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}},"id":1}'

# T1: unauthorized → 401
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer wrong-token" \
    -d "$INIT")
check "T1: unauthorized → 401" "$([ "$CODE" = '401' ] && echo 0 || echo 1)" "got HTTP $CODE"

# T2: initialize → 200
RESP=$(curl -s -D /tmp/resp_headers.txt -X POST "$BASE" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$INIT")
CODE=$(head -1 /tmp/resp_headers.txt | awk '{print $2}')
check "T2: initialize → 200" "$([ "$CODE" = '200' ] && echo 0 || echo 1)" "got HTTP $CODE | ${RESP:0:100}"

# T3: тело содержит serverInfo или result
check "T3: body содержит result" \
    "$(echo "$RESP" | grep -q '"result"\|serverInfo' && echo 0 || echo 1)" \
    "body: ${RESP:0:150}"

# T4: session_id в заголовке
SESSION=$(grep -i 'mcp-session-id' /tmp/resp_headers.txt | awk '{print $2}' | tr -d '\r')
check "T4: mcp-session-id в ответе" "$([ -n "$SESSION" ] && echo 0 || echo 1)" "session=$SESSION"

# T5: tools/list содержит все 3 тула
EXTRA=""
[[ -n "$SESSION" ]] && EXTRA="-H 'mcp-session-id: $SESSION'"
TOOLS=$(curl -s -X POST "$BASE" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    ${SESSION:+-H "mcp-session-id: $SESSION"} \
    -d '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":2}')

for TOOL in ssh_execute sftp_upload sftp_download; do
    check "T5: tool '$TOOL' в lists" \
        "$(echo "$TOOLS" | grep -q "$TOOL" && echo 0 || echo 1)" \
        "${TOOLS:0:100}"
done

# T6: ping
PING=$(curl -s -X POST "$BASE" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $TOKEN" \
    ${SESSION:+-H "mcp-session-id: $SESSION"} \
    -d '{"jsonrpc":"2.0","method":"ping","params":{},"id":3}')
check "T6: ping отвечает" \
    "$(echo "$PING" | grep -q '"result"\|"id":3' && echo 0 || echo 1)" \
    "${PING:0:100}"

echo ""
echo "============================="
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
