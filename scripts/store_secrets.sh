#!/usr/bin/env bash
set -euo pipefail

# Extract OpenZiti secrets from k8s and store in Azure Key Vault.
# Idempotent — overwrites existing AKV secrets on each run.
#
# Prerequisites:
#   - az cli logged in with write access to the vault
#   - Controller deployed and running in the ziti namespace

AKV_NAME="${AKV_NAME:-omlab-secrets}"
ROUTER_JWT_SECRET="${ROUTER_JWT_SECRET:-ziti-router-buck-lab-router-01-jwt}"

log() { echo "==> $*"; }

get_akv_secret_value() {
  local name="$1"
  az keyvault secret show \
    --vault-name "$AKV_NAME" \
    --name "$name" \
    --query value -o tsv 2>/dev/null || true
}

# ---------- admin password ---------------------------------------------------

log "Extracting admin password"
K8S_ADMIN_PW="$(kubectl -n ziti get secret ziti-controller-admin-secret \
  -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || true)"
AKV_ADMIN_PW="$(get_akv_secret_value "ziti-admin-password")"

if [[ -n "$AKV_ADMIN_PW" ]]; then
  ADMIN_PW="$AKV_ADMIN_PW"
  if [[ -n "$K8S_ADMIN_PW" && "$K8S_ADMIN_PW" != "$AKV_ADMIN_PW" ]]; then
    log "Detected drift: Kubernetes admin password differs from AKV; syncing Kubernetes secret from AKV"
    kubectl -n ziti create secret generic ziti-controller-admin-secret \
      --from-literal=admin-user=admin \
      --from-literal=admin-password="$AKV_ADMIN_PW" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
elif [[ -n "$K8S_ADMIN_PW" ]]; then
  ADMIN_PW="$K8S_ADMIN_PW"
else
  echo "Could not resolve ziti admin password from Kubernetes or AKV" >&2
  exit 1
fi

log "Storing ziti-admin-password in AKV ($AKV_NAME)"
az keyvault secret set \
  --vault-name "$AKV_NAME" \
  --name "ziti-admin-password" \
  --value "$ADMIN_PW" \
  --output none

# ---------- controller root CA -----------------------------------------------

log "Extracting controller root CA (edge-root-secret)"
ROOT_CA=$(kubectl -n ziti get secret ziti-controller-edge-root-secret \
  -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null || echo "EXTRACT_FAILED")

if [[ "$ROOT_CA" == "EXTRACT_FAILED" ]]; then
  log "WARNING: Could not extract root CA — check controller PKI"
else
  log "Storing ziti-ctrl-root-ca in AKV ($AKV_NAME)"
  az keyvault secret set \
    --vault-name "$AKV_NAME" \
    --name "ziti-ctrl-root-ca" \
    --value "$ROOT_CA" \
    --output none
fi

# ---------- controller signing cert ------------------------------------------

log "Extracting controller signing cert (edge-signer-secret)"
SIGNING_CERT=$(kubectl -n ziti get secret ziti-controller-edge-signer-secret \
  -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null || echo "EXTRACT_FAILED")

if [[ "$SIGNING_CERT" == "EXTRACT_FAILED" ]]; then
  log "WARNING: Could not extract signing cert — check controller PKI paths"
else
  log "Storing ziti-ctrl-signing-cert in AKV ($AKV_NAME)"
  az keyvault secret set \
    --vault-name "$AKV_NAME" \
    --name "ziti-ctrl-signing-cert" \
    --value "$SIGNING_CERT" \
    --output none
fi

# ---------- router enrollment jwt --------------------------------------------

log "Extracting router enrollment JWT ($ROUTER_JWT_SECRET)"
ROUTER_JWT="$(kubectl -n ziti get secret "$ROUTER_JWT_SECRET" \
  -o jsonpath='{.data.enrollmentJwt}' | base64 -d 2>/dev/null || true)"

if [[ -z "$ROUTER_JWT" ]]; then
  log "WARNING: Could not extract router JWT secret '$ROUTER_JWT_SECRET' — skipping AKV sync"
else
  JWT_EXP_EPOCH="$(JWT="$ROUTER_JWT" python3 - <<'PY'
import base64
import json
import os

jwt = os.environ["JWT"]
parts = jwt.split(".")
try:
  payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)).decode())
  exp = payload.get("exp")
  if exp:
    print(exp)
except Exception:
  pass
PY
)"
  NOW_EPOCH="$(date +%s)"
  if [[ -n "$JWT_EXP_EPOCH" && "$JWT_EXP_EPOCH" -le "$NOW_EPOCH" ]]; then
    log "WARNING: Router JWT is expired; not writing stale token to AKV"
  else
    log "Storing $ROUTER_JWT_SECRET in AKV ($AKV_NAME)"
    az keyvault secret set \
      --vault-name "$AKV_NAME" \
      --name "$ROUTER_JWT_SECRET" \
      --value "$ROUTER_JWT" \
      --output none
  fi
fi

log "Done — secrets stored in AKV ($AKV_NAME)"
