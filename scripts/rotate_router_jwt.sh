#!/usr/bin/env bash
set -euo pipefail

# Rotate/reconcile the router enrollment JWT and store it in AKV.
# Idempotent:
# - Re-enrolls existing router identity (or creates it if missing)
# - Upserts AKV secret
# - Upserts Kubernetes JWT secret (optional, enabled by default)

AKV_NAME="${AKV_NAME:-omlab-secrets}"
ROUTER_NAME="${ZITI_ROUTER_NAME:-buck-lab-router-01}"
JWT_SECRET_NAME="${JWT_SECRET_NAME:-ziti-router-${ROUTER_NAME}-jwt}"
CTRL_MGMT_PORT="${CTRL_MGMT_PORT:-1280}"
ADMIN_USER="${ZITI_ADMIN_USER:-admin}"
SYNC_K8S_SECRET="${SYNC_K8S_SECRET:-1}"

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

get_admin_password() {
  local pw=""
  if command -v az >/dev/null 2>&1; then
    pw="$(az keyvault secret show \
      --vault-name "$AKV_NAME" \
      --name "ziti-admin-password" \
      --query value -o tsv 2>/dev/null || true)"
  fi

  if [[ -n "$pw" ]]; then
    printf '%s' "$pw"
    return 0
  fi

  kubectl -n ziti get secret ziti-controller-admin-secret \
    -o jsonpath='{.data.admin-password}' | base64 -d
}

log "Locating controller pod"
CTRL_POD="$(kubectl -n ziti get pod -l app.kubernetes.io/name=ziti-controller \
  -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "$CTRL_POD" ]]; then
  echo "Controller pod not found in namespace ziti" >&2
  exit 1
fi

ADMIN_PW="$(get_admin_password)"
if [[ -z "$ADMIN_PW" ]]; then
  echo "Could not resolve Ziti admin password from AKV or Kubernetes secret" >&2
  exit 1
fi

log "Logging into controller"
kubectl -n ziti exec "$CTRL_POD" -- sh -lc \
  "ziti edge login localhost:${CTRL_MGMT_PORT} -u '${ADMIN_USER}' -p '${ADMIN_PW}' --yes >/dev/null"

log "Generating enrollment JWT for edge-router '${ROUTER_NAME}'"
if ! kubectl -n ziti exec "$CTRL_POD" -- sh -lc \
  "ziti edge re-enroll edge-router '${ROUTER_NAME}' --jwt-output-file /tmp/router.jwt >/dev/null 2>&1"; then
  warn "Edge-router '${ROUTER_NAME}' not found for re-enroll; creating it"
  kubectl -n ziti exec "$CTRL_POD" -- sh -lc \
    "ziti edge create edge-router '${ROUTER_NAME}' --jwt-output-file /tmp/router.jwt --tunneler-enabled >/dev/null"
fi

ROUTER_JWT="$(kubectl -n ziti exec "$CTRL_POD" -- cat /tmp/router.jwt)"
if [[ -z "$ROUTER_JWT" ]]; then
  echo "Generated enrollment JWT is empty" >&2
  exit 1
fi

JWT_EXP_ISO="$(JWT="$ROUTER_JWT" python3 - <<'PY'
import base64
import datetime
import json
import os

jwt = os.environ["JWT"]
parts = jwt.split(".")
payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)).decode())
exp = payload.get("exp")
if exp:
  print(datetime.datetime.fromtimestamp(exp, datetime.UTC).isoformat())
PY
)"
if [[ -n "$JWT_EXP_ISO" ]]; then
  log "Generated JWT expiry: $JWT_EXP_ISO"
fi

if command -v az >/dev/null 2>&1; then
  log "Upserting AKV secret '$JWT_SECRET_NAME' in vault '$AKV_NAME'"
  az keyvault secret set \
    --vault-name "$AKV_NAME" \
    --name "$JWT_SECRET_NAME" \
    --value "$ROUTER_JWT" \
    --output none
else
  warn "az CLI not found; skipping AKV update"
fi

if [[ "$SYNC_K8S_SECRET" == "1" ]]; then
  log "Upserting Kubernetes secret '$JWT_SECRET_NAME' in namespace ziti"
  kubectl -n ziti create secret generic "$JWT_SECRET_NAME" \
    --from-literal=enrollmentJwt="$ROUTER_JWT" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

log "Done"
