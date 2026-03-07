#!/usr/bin/env bash
set -euo pipefail

# Enroll the backup tunnel Ziti identities and store them in AKV.
#
# Run ONCE after terraform creates the identities (azure-tunneler, backup-proxy).
# The identities must exist in Ziti but not yet be enrolled.
#
# Prerequisites:
#   - kubectl access to the ziti namespace
#   - az CLI authenticated with Key Vault Secrets Officer role
#   - ziti-edge-tunnel binary installed locally (for enrollment)
#
# Usage:
#   scripts/enroll_backup_identities.sh
#   DRY_RUN=1 scripts/enroll_backup_identities.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
CTRL_MGMT_PORT="${CTRL_MGMT_PORT:-1280}"
AKV_NAME="${AKV_NAME:-omlab-secrets}"
OUT_DIR="$ROOT_DIR/out/identities"
CTRL_HOST="ziti.focuspass.com"

IDENTITIES=(
  "azure-tunneler"
  "backup-proxy"
)

# ---------- helpers ----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

get_admin_password() {
  local pw=""
  if command -v az >/dev/null 2>&1; then
    pw="$(az keyvault secret show \
      --vault-name "$AKV_NAME" \
      --name "ziti-admin-password" \
      --query value -o tsv 2>/dev/null | tr -d '\r' || true)"
  fi

  if [[ -n "$pw" ]]; then
    printf '%s' "$pw"
    return 0
  fi

  kubectl -n ziti get secret ziti-controller-admin-secret \
    -o jsonpath='{.data.admin-password}' | base64 -d
}

# ---------- prerequisites ----------------------------------------------------

if [[ -n "$DRY_RUN" ]]; then
  log "DRY_RUN mode — printing commands only"
else
  if ! command -v ziti-edge-tunnel >/dev/null 2>&1; then
    warn "ziti-edge-tunnel not found — install it first"
    warn "  https://openziti.io/docs/downloads"
    exit 1
  fi

  if ! command -v az >/dev/null 2>&1; then
    warn "az CLI not found — required for AKV storage"
    exit 1
  fi

  log "Checking prerequisites"
  CTRL_POD=$(kubectl -n ziti get pod -l app.kubernetes.io/name=ziti-controller \
    -o jsonpath='{.items[0].metadata.name}')

  if [[ -z "$CTRL_POD" ]]; then
    warn "Controller pod not found"
    exit 1
  fi

  ADMIN_PW="$(get_admin_password)"

  log "Logging in to controller ($CTRL_POD)"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge login localhost:${CTRL_MGMT_PORT} -u admin -p '${ADMIN_PW}' --yes" \
    >/dev/null 2>&1
fi

# ---------- enroll identities ------------------------------------------------

mkdir -p "$OUT_DIR"

for identity in "${IDENTITIES[@]}"; do
  jwt_file="/tmp/${identity}.jwt"
  json_file="$OUT_DIR/${identity}.json"

  if [[ -n "$DRY_RUN" ]]; then
    log "Would enroll identity: $identity"
    echo "  [dry-run] Get JWT from controller → enroll → store in AKV"
    continue
  fi

  # Check if already enrolled (identity file exists in AKV with valid content).
  existing=$(az keyvault secret show --vault-name "$AKV_NAME" \
    --name "ziti-identity-${identity}" \
    --query value -o tsv 2>/dev/null | tr -d '\r' || true)

  if [[ -n "$existing" && "$existing" != "PLACEHOLDER-RUN-ENROLL-SCRIPT" ]]; then
    log "Identity '$identity' already enrolled in AKV (skipping)"
    continue
  fi

  # Get the enrollment JWT from the controller.
  log "Fetching enrollment JWT for '$identity'"
  jwt_content=$(kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${identity}\"' -j 2>/dev/null" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('data', []):
    enrollment = item.get('enrollment', {})
    ott = enrollment.get('ott', {})
    jwt_val = ott.get('jwt', '')
    if jwt_val:
        print(jwt_val)
        break
" 2>/dev/null || true)

  if [[ -z "$jwt_content" ]]; then
    warn "No enrollment JWT found for '$identity' — is it already enrolled?"
    warn "If re-enrollment needed, delete and recreate the identity via Terraform"
    continue
  fi

  # Write JWT to temp file.
  printf '%s' "$jwt_content" > "$jwt_file"
  log "JWT retrieved, enrolling..."

  # Enroll the identity.
  ziti-edge-tunnel enroll --jwt "$jwt_file" --identity "$json_file"
  log "Enrolled to $json_file"

  # Store the identity JSON in AKV.
  identity_json=$(cat "$json_file")
  az keyvault secret set --vault-name "$AKV_NAME" \
    --name "ziti-identity-${identity}" \
    --value "$identity_json" >/dev/null 2>&1
  log "Identity stored in AKV as ziti-identity-${identity}"

  # Clean up JWT.
  rm -f "$jwt_file"
done

log "Done. Next steps:"
log "  1. ArgoCD will sync the backup-proxy pod (reads identity from ESO)"
log "  2. Update ACI secret volume with azure-tunneler identity"
log "  3. Run scripts/patch_coredns.sh to add blob storage DNS entry"
