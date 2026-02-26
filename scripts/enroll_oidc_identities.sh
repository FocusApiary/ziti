#!/usr/bin/env bash
set -euo pipefail

# Enroll OIDC identity JWTs on Curiosity Computer VMs via SSH so the
# ziti-edge-tunnel can load them. Run once per new user or VM rebuild.
#
# Idempotent: identities already enrolled on a VM are skipped.
#
# Usage:
#   scripts/enroll_oidc_identities.sh                # enroll all
#   DRY_RUN=1 scripts/enroll_oidc_identities.sh      # print commands only
#   VERBOSE=1 scripts/enroll_oidc_identities.sh      # show SSH output

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
VERBOSE="${VERBOSE:-}"
AKV_NAME="${AKV_NAME:-omlab-secrets}"
OUT_DIR="$ROOT_DIR/out/identities"
IDENTITY_DIR="/opt/openziti/etc/identities"
TUNNEL_BIN="/opt/openziti/bin/ziti-edge-tunnel"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# ---------- VM targets -------------------------------------------------------
# Format: "ip|ssh_user|label"
VMS=(
  "192.168.1.159|curiosity|CC5"
  "192.168.1.169|curiosity|CC6"
)

# ---------- OIDC identity names ----------------------------------------------
IDENTITIES=(
  seanh-oidc
  sconejos-oidc
  mrh-oidc
  abdulrehman-oidc
  azlankhan-oidc
  mahakhan-oidc
  zaryabayub-oidc
)

# ---------- helpers -----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Retrieve a JWT for the given identity name.
# Tries local file first, then AKV.
get_jwt() {
  local name="$1"
  local local_file="$OUT_DIR/${name}.jwt"

  if [[ -f "$local_file" ]]; then
    cat "$local_file"
    return 0
  fi

  log "  JWT not found locally ($local_file) — trying AKV"
  if command -v az >/dev/null 2>&1; then
    local jwt=""
    jwt="$(az keyvault secret show \
      --vault-name "$AKV_NAME" \
      --name "ziti-oidc-${name}" \
      --query value -o tsv 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$jwt" ]]; then
      printf '%s' "$jwt"
      return 0
    fi
  fi

  return 1
}

# Run a command on a remote VM via SSH.
ssh_exec() {
  local user="$1" ip="$2"
  shift 2

  if [[ -n "$VERBOSE" ]]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${user}@${ip}" "$@"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${user}@${ip}" "$@" >/dev/null 2>&1
  fi
}

# ---------- main loop ---------------------------------------------------------

total_enrolled=0
total_skipped=0
total_failed=0

for vm_entry in "${VMS[@]}"; do
  IFS='|' read -r ip user label <<< "$vm_entry"

  log "=== VM: ${label} (${user}@${ip}) ==="

  # Verify SSH connectivity (skip DRY_RUN).
  if [[ -z "$DRY_RUN" ]]; then
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "${user}@${ip}" "true" 2>/dev/null; then
      warn "Cannot reach ${user}@${ip} — skipping VM"
      total_failed=$((total_failed + ${#IDENTITIES[@]}))
      continue
    fi
  fi

  vm_enrolled=0

  for identity in "${IDENTITIES[@]}"; do
    log "  Identity: ${identity}"

    if [[ -n "$DRY_RUN" ]]; then
      echo "  [dry-run] ssh ${user}@${ip} \"test -f ${IDENTITY_DIR}/${identity}.json\""
      echo "  [dry-run] get JWT from out/identities/${identity}.jwt or AKV ziti-oidc-${identity}"
      echo "  [dry-run] ssh ${user}@${ip} \"sudo ${TUNNEL_BIN} add --jwt '<jwt>' --identity '${identity}'\""
      total_skipped=$((total_skipped + 1))
      continue
    fi

    # Check if already enrolled on this VM.
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS "${user}@${ip}" "test -f ${IDENTITY_DIR}/${identity}.json" 2>/dev/null; then
      log "  Already enrolled on ${label} (skipping)"
      total_skipped=$((total_skipped + 1))
      continue
    fi

    # Retrieve JWT.
    jwt_content=""
    if ! jwt_content="$(get_jwt "$identity")"; then
      warn "  JWT not found for ${identity} (checked out/identities/ and AKV) — skipping"
      total_failed=$((total_failed + 1))
      continue
    fi

    if [[ -z "$jwt_content" ]]; then
      warn "  JWT is empty for ${identity} — skipping"
      total_failed=$((total_failed + 1))
      continue
    fi

    # Copy JWT to VM via stdin pipe and enroll (avoids shell metachar issues).
    log "  Enrolling ${identity} on ${label}"
    # shellcheck disable=SC2086
    if ! printf '%s' "$jwt_content" | ssh $SSH_OPTS "${user}@${ip}" \
      "cat > /tmp/.ziti-enroll-$$.jwt && sudo ${TUNNEL_BIN} add --jwt /tmp/.ziti-enroll-$$.jwt --identity '${identity}'; rm -f /tmp/.ziti-enroll-$$.jwt" 2>&1; then
      warn "  Failed to enroll ${identity} on ${label}"
      total_failed=$((total_failed + 1))
      continue
    fi

    log "  Enrolled ${identity} on ${label}"
    vm_enrolled=$((vm_enrolled + 1))
    total_enrolled=$((total_enrolled + 1))
  done

  # Restart tunneler if any new identities were enrolled on this VM.
  if [[ $vm_enrolled -gt 0 ]]; then
    log "  Restarting ziti-edge-tunnel on ${label} (${vm_enrolled} new identities)"
    if [[ -z "$DRY_RUN" ]]; then
      # shellcheck disable=SC2086
      if ! ssh $SSH_OPTS "${user}@${ip}" "sudo systemctl restart ziti-edge-tunnel" 2>&1; then
        warn "  Failed to restart ziti-edge-tunnel on ${label}"
      fi
    else
      echo "  [dry-run] ssh ${user}@${ip} \"sudo systemctl restart ziti-edge-tunnel\""
    fi
  else
    log "  No new identities on ${label} — tunnel restart not needed"
  fi
done

# ---------- summary -----------------------------------------------------------

echo ""
log "Done — enrolled: ${total_enrolled}, skipped: ${total_skipped}, failed: ${total_failed}"
if [[ $total_failed -gt 0 ]]; then
  warn "Some identities failed — check warnings above"
fi
