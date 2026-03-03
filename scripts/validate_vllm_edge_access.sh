#!/usr/bin/env bash
set -euo pipefail

# Validate vLLM API reachability through OpenZiti edge client identity.
#
# Usage:
#   scripts/validate_vllm_edge_access.sh \
#     --identity /etc/ziti/identities/matthew-laptop.json
#
# Optional:
#   --service api-vllm-hardmagic
#   --host api.vllm.hardmagic.com
#   --port 18443
#   --ziti-url ziti.focuspass.com:443
#
# Exit codes:
#   0 = service visible + health/model checks passed
#   2 = service not visible for identity (role/policy gap)
#   3 = proxy started but endpoint checks failed

IDENTITY=""
SERVICE="api-vllm-hardmagic"
HOSTNAME="api.vllm.hardmagic.com"
LOCAL_PORT="18443"
ZITI_URL="ziti.focuspass.com:443"
LOG_FILE="/tmp/vllm_edge_proxy.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --host) HOSTNAME="$2"; shift 2 ;;
    --port) LOCAL_PORT="$2"; shift 2 ;;
    --ziti-url) ZITI_URL="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$IDENTITY" ]]; then
  echo "Missing required --identity path" >&2
  exit 1
fi

if [[ ! -f "$IDENTITY" ]]; then
  echo "Identity file not found: $IDENTITY" >&2
  exit 1
fi

echo "[1/5] Authenticating with edge identity"
ziti edge login "$ZITI_URL" -f "$IDENTITY" --yes >/dev/null
TOKEN="$(jq -r '.edgeIdentities.default.token' "$HOME/.config/ziti/ziti-cli.json")"
API="https://${ZITI_URL}/edge/client/v1"

echo "[2/5] Resolving identity + service visibility"
SESSION_JSON="$(curl -sk -H "zt-session: ${TOKEN}" "${API}/current-api-session")"
IDENTITY_NAME="$(jq -r '.data.identity.name // "<unknown>"' <<<"$SESSION_JSON")"
IDENTITY_ATTRS="$(jq -c '.data.identity.roleAttributes' <<<"$SESSION_JSON")"

SERVICES_JSON="$(curl -sk -H "zt-session: ${TOKEN}" "${API}/services")"
if ! jq -e --arg svc "$SERVICE" '.data[] | select(.name == $svc)' <<<"$SERVICES_JSON" >/dev/null; then
  echo "Identity: ${IDENTITY_NAME}"
  echo "Role attributes: ${IDENTITY_ATTRS}"
  echo "Service '${SERVICE}' is not visible for this identity."
  echo "Accessible services:"
  jq -r '.data[].name' <<<"$SERVICES_JSON" | sort
  exit 2
fi

echo "[3/5] Starting ziti tunnel proxy for ${SERVICE}:${LOCAL_PORT}"
rm -f "$LOG_FILE"
ziti tunnel proxy "${SERVICE}:${LOCAL_PORT}" -i "$IDENTITY" --verbose >"$LOG_FILE" 2>&1 &
PROXY_PID=$!
cleanup() {
  kill "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  if ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q ":${LOCAL_PORT}"; then
    break
  fi
  sleep 1
done

if ! ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q ":${LOCAL_PORT}"; then
  echo "Proxy listener did not come up on port ${LOCAL_PORT}" >&2
  echo "Log excerpt:"
  tail -n 60 "$LOG_FILE" || true
  exit 3
fi

echo "[4/5] Running endpoint checks over Ziti"
HEALTH="$(curl -sk --max-time 20 --resolve "${HOSTNAME}:${LOCAL_PORT}:127.0.0.1" "https://${HOSTNAME}:${LOCAL_PORT}/health" || true)"
MODELS="$(curl -sk --max-time 20 --resolve "${HOSTNAME}:${LOCAL_PORT}:127.0.0.1" "https://${HOSTNAME}:${LOCAL_PORT}/v1/models" || true)"

HEALTH_OK=0
MODELS_OK=0
if jq -e '.status == "healthy"' >/dev/null 2>&1 <<<"$HEALTH"; then HEALTH_OK=1; fi
if jq -e '.object == "list"' >/dev/null 2>&1 <<<"$MODELS"; then MODELS_OK=1; fi

echo "Identity: ${IDENTITY_NAME}"
echo "Role attributes: ${IDENTITY_ATTRS}"
echo "Health response: ${HEALTH}"
echo "Models response: ${MODELS}"

if [[ "$HEALTH_OK" -ne 1 || "$MODELS_OK" -ne 1 ]]; then
  echo "Endpoint checks failed."
  echo "Log excerpt:"
  tail -n 80 "$LOG_FILE" || true
  exit 3
fi

echo "[5/5] Validation passed"
