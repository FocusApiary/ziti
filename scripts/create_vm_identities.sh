#!/usr/bin/env bash
set -euo pipefail

# Create Ziti device identities for iGPU VM workstations and store enrollment
# JWTs as Kubernetes secrets in the igpu-vms namespace.
#
# Idempotent: existing identities and secrets are skipped.
#
# Usage:
#   scripts/create_vm_identities.sh             # create all VM identities
#   DRY_RUN=1 scripts/create_vm_identities.sh   # print commands only
#
# Each identity is tagged with #member (core services + VoIP access).
# JWTs are written to out/identities/ and stored as k8s secrets in igpu-vms.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
CTRL_MGMT_PORT="${CTRL_MGMT_PORT:-1280}"
AKV_NAME="${AKV_NAME:-omlab-secrets}"
OUT_DIR="$ROOT_DIR/out/identities"
VM_NAMESPACE="igpu-vms"

# ---------- VM definitions ----------------------------------------------------
# Format: "identity_name|k8s_secret_name|node_desc"
VMS=(
  "sconejos-workstation|ziti-identity-sconejos|node-5 (CC1, 192.168.1.159)"
  "mrh-workstation|ziti-identity-mrh|node-6 (CC3, 192.168.1.169)"
)

# ---------- helpers -----------------------------------------------------------

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

# ---------- prerequisites + login ---------------------------------------------

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

# ---------- create identities + k8s secrets -----------------------------------

mkdir -p "$OUT_DIR"
created=0
skipped=0

for entry in "${VMS[@]}"; do
  IFS='|' read -r identity secret_name node_desc <<< "$entry"
  jwt_file="/tmp/${identity}.jwt"

  log "--- ${identity} (${node_desc}) ---"

  if [[ -n "$DRY_RUN" ]]; then
    log "Would create identity: $identity (tag: #member)"
    echo "  [dry-run] ziti edge create identity device '$identity' -a member -o '$jwt_file'"
    echo "  [dry-run] kubectl -n $VM_NAMESPACE create secret generic '$secret_name' --from-literal=ziti-identity.jwt=<jwt>"
    continue
  fi

  # Check if identity already exists.
  if kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${identity}\"' -j 2>/dev/null" 2>/dev/null \
    | grep -q "\"name\":\"${identity}\""; then
    log "Identity '$identity' already exists (skipping creation)"
    skipped=$((skipped + 1))

    # Still ensure k8s secret exists (identity may have been created without one).
    if kubectl -n "$VM_NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
      log "K8s secret '$secret_name' already exists"
    else
      warn "Identity exists but k8s secret '$secret_name' is missing — re-enroll manually or delete+recreate identity"
    fi
    continue
  fi

  log "Creating identity: $identity (tag: #member)"
  if ! kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge create identity device '${identity}' -a member -o '${jwt_file}'" 2>&1; then
    warn "Failed to create identity '$identity'"
    continue
  fi

  # Extract JWT from the pod.
  jwt_content=$(kubectl -n ziti exec "$CTRL_POD" -- cat "$jwt_file")

  # Write locally.
  printf '%s' "$jwt_content" > "$OUT_DIR/${identity}.jwt"
  log "JWT written to out/identities/${identity}.jwt"

  # Create k8s secret in igpu-vms namespace.
  if kubectl -n "$VM_NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
    log "K8s secret '$secret_name' already exists (updating)"
    kubectl -n "$VM_NAMESPACE" delete secret "$secret_name" >/dev/null 2>&1
  fi

  kubectl -n "$VM_NAMESPACE" create secret generic "$secret_name" \
    --from-literal=ziti-identity.jwt="$jwt_content"
  kubectl -n "$VM_NAMESPACE" label secret "$secret_name" managed-by=gitops
  log "K8s secret '$secret_name' created in namespace $VM_NAMESPACE"

  # Store in AKV if az CLI is available.
  if command -v az >/dev/null 2>&1; then
    local_name="${identity//-workstation/}"
    if az keyvault secret set --vault-name "$AKV_NAME" \
      --name "ziti-identity-${local_name}" \
      --value "$jwt_content" >/dev/null 2>&1; then
      log "JWT stored in AKV as ziti-identity-${local_name}"
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
  echo ""
  log "Next steps:"
  log "  1. If VMs are already running: copy JWTs from out/identities/ and enroll manually:"
  log "       scp out/identities/<name>.jwt user@vm:/tmp/"
  log "       ssh user@vm 'sudo ziti-edge-tunnel enroll -j /tmp/<name>.jwt -i <name>'"
  log "       ssh user@vm 'sudo systemctl restart ziti-edge-tunnel'"
  log "  2. If VMs need rebuild: redeploy overlays to pick up per-node secrets:"
  log "       kubectl apply -k ../kube-powerdesk/working/direct-qemu/overlays/node-159"
  log "       kubectl apply -k ../kube-powerdesk/working/direct-qemu/overlays/node-169"
fi
