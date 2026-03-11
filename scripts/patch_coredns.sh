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
#   auth.focuspass.com        — Keycloak OIDC, needed by Coder/Slidee/ArgoCD/GitLab
#   ziti-router.focuspass.com — OpenZiti edge router (TLS passthrough via Envoy Gateway)
#   argocd.focuscell.org      — ArgoCD, needed by GitLab webhooks
#   longhorn.focuscell.org    — Longhorn UI
#   s3.focuscell.org          — SeaweedFS S3 API endpoint
#   files.focuscell.org       — SeaweedFS UI endpoint
#   kas.developerdojo.org     — GitLab KAS endpoint
#   dev.slidee.net            — Slidee, needs OIDC callback resolution
#   git.developerdojo.org     — GitLab, needed for OIDC callbacks + webhook deliveries
#   chat.focusbuzz.org        — Mattermost, needed by OpenClaw agents (no public DNS)
#   pbx.focuscell.org         — FreeSWITCH WebRTC, VoIP softphone
#   admin.focuscell.org       — VoIP admin panel
#   api.focuscell.org         — VoIP API + SignalWire SMS webhooks
#   chat.hardmagic.com        — Open WebUI (vLLM chat frontend)
#   api.comfy.hardmagic.com   — HardMagic ComfyUI API
#   api.vllm.hardmagic.com    — HardMagic vLLM API
#   agents.focuschef.com      — OpenClaw dashboard
#   admin.focuschef.com       — OpenClaw admin panel
#   *.focuschef.com (25 agents) — Individual OpenClaw agent endpoints

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
INGRESS_NS="${INGRESS_NS:-envoy-gateway-system}"
INGRESS_SVC="${INGRESS_SVC:-envoy-envoy-gateway-system-main-b3b376e9}"

# Custom host entries with non-Envoy-Gateway IPs (service_name:namespace → hostname).
# These are discovered dynamically and added alongside the Envoy Gateway entries.
BACKUP_PROXY_SVC="backup-proxy"
BACKUP_PROXY_NS="ziti"
BACKUP_PROXY_HOST="focusapiarybackups.blob.core.windows.net"

# Hostnames to add (all resolve to the Envoy Gateway proxy ClusterIP).
HOSTS=(
  "auth.focuspass.com"
  "enroll.focuspass.com"
  "ziti-router.focuspass.com"
  "argocd.focuscell.org"
  "domains.focuscell.org"
  "longhorn.focuscell.org"
  "s3.focuscell.org"
  "files.focuscell.org"
  "kas.developerdojo.org"
  "dev.slidee.net"
  "git.developerdojo.org"
  "chat.focusbuzz.org"
  "comfy.hardmagic.com"
  "chat.hardmagic.com"
  "studio.hypersight.net"
  "pbx.focuscell.org"
  "admin.focuscell.org"
  "api.focuscell.org"
  "harbor.focuscell.org"
  "mail.focuscell.org"
  "mail-api.focuscell.org"
  "api.comfy.hardmagic.com"
  "api.vllm.hardmagic.com"
  "agents.focuschef.com"
  "admin.focuschef.com"
  "angie.focuschef.com"
  "asma.focuschef.com"
  "atlas.focuschef.com"
  "candace.focuschef.com"
  "casey.focuschef.com"
  "cody.focuschef.com"
  "dan.focuschef.com"
  "devan.focuschef.com"
  "eddy.focuschef.com"
  "emmy.focuschef.com"
  "finn.focuschef.com"
  "hira.focuschef.com"
  "ian.focuschef.com"
  "karen.focuschef.com"
  "knox.focuschef.com"
  "lee.focuschef.com"
  "maggie.focuschef.com"
  "marisa.focuschef.com"
  "mark.focuschef.com"
  "micky.focuschef.com"
  "miley.focuschef.com"
  "paris.focuschef.com"
  "patty.focuschef.com"
  "sally.focuschef.com"
  "venny.focuschef.com"
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

# ---------- discover backup-proxy ClusterIP -----------------------------------

BACKUP_PROXY_IP=$(kubectl -n "$BACKUP_PROXY_NS" get svc "$BACKUP_PROXY_SVC" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [[ -n "$BACKUP_PROXY_IP" ]]; then
  log "Backup proxy ClusterIP: $BACKUP_PROXY_IP"
else
  log "Backup proxy service not found — skipping $BACKUP_PROXY_HOST"
fi

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

# Check backup-proxy host entry (different IP than Envoy Gateway).
if [[ -n "$BACKUP_PROXY_IP" ]]; then
  if echo "$CURRENT_COREFILE" | grep -qF "$BACKUP_PROXY_HOST"; then
    log "Already present: $BACKUP_PROXY_HOST (skipping)"
  else
    entries_to_add+=("$BACKUP_PROXY_HOST")
    log "Missing: $BACKUP_PROXY_HOST (will add with backup-proxy IP)"
  fi
fi

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
    if [[ "$host" == "$BACKUP_PROXY_HOST" && -n "$BACKUP_PROXY_IP" ]]; then
      new_lines="${new_lines}            ${BACKUP_PROXY_IP} ${host}\n"
    else
      new_lines="${new_lines}            ${INGRESS_IP} ${host}\n"
    fi
  done

  PATCHED_COREFILE=$(echo "$CURRENT_COREFILE" | sed "/hosts {/,/fallthrough/ {
    /fallthrough/i\\
${new_lines%\\n}
  }")
else
  # No hosts block — create one before the kubernetes block.
  hosts_block="        hosts {\n"
  for host in "${entries_to_add[@]}"; do
    if [[ "$host" == "$BACKUP_PROXY_HOST" && -n "$BACKUP_PROXY_IP" ]]; then
      hosts_block="${hosts_block}            ${BACKUP_PROXY_IP} ${host}\n"
    else
      hosts_block="${hosts_block}            ${INGRESS_IP} ${host}\n"
    fi
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
