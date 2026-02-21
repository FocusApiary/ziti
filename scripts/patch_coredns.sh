#!/usr/bin/env bash
set -euo pipefail

# Patch CoreDNS hosts block with entries needed for in-cluster resolution.
#
# Discovers the Envoy Gateway proxy ClusterIP dynamically (not hardcoded) so
# this works across DCs. Merges entries into the existing Corefile — does NOT
# replace the entire ConfigMap.
#
# Idempotent: entries that already exist in the hosts block are skipped.
#
# Usage:
#   scripts/patch_coredns.sh                # patch CoreDNS
#   DRY_RUN=1 scripts/patch_coredns.sh      # show diff only
#
# Required entries (all point to Envoy Gateway proxy ClusterIP):
#   auth-buck.omlabs.org      — Keycloak OIDC, needed by Coder/Slidee/ArgoCD/GitLab
#   argocd.focuscell.org      — ArgoCD, needed by GitLab webhooks
#   longhorn.focuscell.org    — Longhorn UI
#   s3.focuscell.org          — SeaweedFS S3 API endpoint
#   files.focuscell.org       — SeaweedFS UI endpoint
#   kas.developerdojo.org     — GitLab KAS endpoint
#   dev.slidee.net            — Slidee, needs OIDC callback resolution
#   gitlab-buck.omlabs.org    — GitLab, needed for OIDC callbacks + webhook deliveries
#   chat.focusjam.com         — Mattermost, needed by OpenClaw agents (no public DNS)
#   pbx.focuscell.org         — FreeSWITCH WebRTC, VoIP softphone
#   admin.focuscell.org       — VoIP admin panel
#   api.focuscell.org         — VoIP API + SignalWire SMS webhooks

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
INGRESS_NS="${INGRESS_NS:-envoy-gateway-system}"
INGRESS_SVC="${INGRESS_SVC:-envoy-envoy-gateway-system-main-b3b376e9}"

# Hostnames to add (all resolve to the Envoy Gateway proxy ClusterIP).
HOSTS=(
  "auth-buck.omlabs.org"
  "argocd.focuscell.org"
  "longhorn.focuscell.org"
  "s3.focuscell.org"
  "files.focuscell.org"
  "kas.developerdojo.org"
  "dev.slidee.net"
  "gitlab-buck.omlabs.org"
  "chat.focusjam.com"
  "studio.hardmagic.com"
  "studio.hypersight.net"
  "pbx.focuscell.org"
  "admin.focuscell.org"
  "api.focuscell.org"
  "harbor.focuscell.org"
)

# ---------- helpers ----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# ---------- discover Envoy Gateway proxy ClusterIP ---------------------------

log "Discovering Envoy Gateway proxy ClusterIP"
INGRESS_IP=$(kubectl -n "$INGRESS_NS" get svc "$INGRESS_SVC" \
  -o jsonpath='{.spec.clusterIP}')

if [[ -z "$INGRESS_IP" ]]; then
  warn "Could not find ClusterIP for $INGRESS_SVC in $INGRESS_NS"
  exit 1
fi

log "Envoy Gateway proxy ClusterIP: $INGRESS_IP"

# ---------- read current Corefile --------------------------------------------

log "Reading current CoreDNS ConfigMap"
CURRENT_COREFILE=$(kubectl -n kube-system get configmap coredns \
  -o jsonpath='{.data.Corefile}')

if [[ -z "$CURRENT_COREFILE" ]]; then
  warn "Could not read Corefile from coredns ConfigMap"
  exit 1
fi

# ---------- check which entries are missing ----------------------------------

entries_to_add=()
for host in "${HOSTS[@]}"; do
  if echo "$CURRENT_COREFILE" | grep -qF "$host"; then
    log "Already present: $host (skipping)"
  else
    entries_to_add+=("$host")
    log "Missing: $host (will add)"
  fi
done

if [[ ${#entries_to_add[@]} -eq 0 ]]; then
  log "All entries already present — nothing to do"
  exit 0
fi

# ---------- build patched Corefile -------------------------------------------

# Strategy: find the "hosts {" block and insert new entries before "fallthrough".
# If there's no hosts block, create one before the kubernetes block.

PATCHED_COREFILE="$CURRENT_COREFILE"

if echo "$CURRENT_COREFILE" | grep -q "hosts {"; then
  # Hosts block exists — insert entries before "fallthrough".
  new_lines=""
  for host in "${entries_to_add[@]}"; do
    new_lines="${new_lines}            ${INGRESS_IP} ${host}\n"
  done

  PATCHED_COREFILE=$(echo "$CURRENT_COREFILE" | sed "/hosts {/,/fallthrough/ {
    /fallthrough/i\\
${new_lines%\\n}
  }")
else
  # No hosts block — create one before the kubernetes block.
  hosts_block="        hosts {\n"
  for host in "${entries_to_add[@]}"; do
    hosts_block="${hosts_block}            ${INGRESS_IP} ${host}\n"
  done
  hosts_block="${hosts_block}            fallthrough\n        }"

  PATCHED_COREFILE=$(echo "$CURRENT_COREFILE" | sed "/kubernetes cluster.local/i\\
${hosts_block}")
fi

# ---------- show diff --------------------------------------------------------

echo ""
echo "--- Diff ---"
diff <(echo "$CURRENT_COREFILE") <(echo "$PATCHED_COREFILE") || true
echo ""

# ---------- apply or dry-run -------------------------------------------------

if [[ -n "$DRY_RUN" ]]; then
  log "DRY_RUN mode — not applying. Patched Corefile:"
  echo "$PATCHED_COREFILE"
  exit 0
fi

log "Applying patched CoreDNS ConfigMap"
kubectl -n kube-system create configmap coredns \
  --from-literal="Corefile=${PATCHED_COREFILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Restarting CoreDNS to pick up changes"
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=60s

log "Done — added ${#entries_to_add[@]} host entries to CoreDNS"
