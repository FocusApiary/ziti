#!/usr/bin/env bash
set -euo pipefail

# Create Ziti device identities for team members and store enrollment JWTs.
#
# Idempotent: existing identities are skipped (not re-created).
#
# Usage:
#   scripts/create_identities.sh alice bob       # create named identities
#   DRY_RUN=1 scripts/create_identities.sh alice  # print commands only
#
# Each identity is named "<name>-laptop", tagged with #employees.
# JWTs are written to out/identities/ and optionally stored in AKV.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
CTRL_MGMT_PORT="${CTRL_MGMT_PORT:-1280}"
AKV_NAME="${AKV_NAME:-omlab-secrets}"
OUT_DIR="$ROOT_DIR/out/identities"

# ---------- helpers ----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

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

# ---------- parse args -------------------------------------------------------

NAMES=("$@")

if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "Usage: scripts/create_identities.sh <name1> [name2] ..."
  echo ""
  echo "Creates Ziti device identities with #employees attribute."
  echo "JWTs stored in out/identities/ and AKV ($AKV_NAME)."
  exit 1
fi

# ---------- prerequisites + login --------------------------------------------

if [[ -n "$DRY_RUN" ]]; then
  CTRL_POD="(dry-run)"
  log "DRY_RUN mode — printing commands only"
else
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

# ---------- create identities ------------------------------------------------

mkdir -p "$OUT_DIR"
created=0
skipped=0

for name in "${NAMES[@]}"; do
  identity="${name}-laptop"
  jwt_file="/tmp/${identity}.jwt"

  if [[ -n "$DRY_RUN" ]]; then
    log "Would create identity: $identity (tag: #employees)"
    echo "  [dry-run] ziti edge create identity device '$identity' -a employees -o '$jwt_file'"
    continue
  fi

  # Check if identity already exists.
  if kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${identity}\"' -j 2>/dev/null" 2>/dev/null \
    | grep -q "\"name\":\"${identity}\""; then
    log "Identity '$identity' already exists (skipping)"
    skipped=$((skipped + 1))
    continue
  fi

  log "Creating identity: $identity"
  if ! kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge create identity device '${identity}' -a employees -o '${jwt_file}'" 2>&1; then
    warn "Failed to create identity '$identity'"
    continue
  fi

  # Extract JWT from the pod (printf avoids trailing newline).
  jwt_content=$(kubectl -n ziti exec "$CTRL_POD" -- cat "$jwt_file")

  # Write locally.
  printf '%s' "$jwt_content" > "$OUT_DIR/${identity}.jwt"
  log "JWT written to out/identities/${identity}.jwt"

  # Store in AKV if az CLI is available.
  if command -v az >/dev/null 2>&1; then
    if az keyvault secret set --vault-name "$AKV_NAME" \
      --name "ziti-identity-${name}" \
      --value "$jwt_content" >/dev/null 2>&1; then
      log "JWT stored in AKV as ziti-identity-${name}"
    else
      warn "Failed to store JWT in AKV (continuing)"
    fi
  else
    log "az CLI not found — skipping AKV storage"
  fi

  created=$((created + 1))
done

log "Done — created: $created, skipped: $skipped"
if [[ $created -gt 0 ]]; then
  log "Distribute .jwt files securely — each JWT is single-use"
fi
