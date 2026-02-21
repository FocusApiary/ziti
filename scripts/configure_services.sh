#!/usr/bin/env bash
set -euo pipefail

# Create Ziti configs, services, and policies for routing all internal
# services through the OpenZiti overlay via Envoy Gateway.
#
# Idempotent: safe to re-run. Existing resources are skipped (not updated).
#
# Usage:
#   scripts/configure_services.sh                        # full setup
#   DRY_RUN=1 scripts/configure_services.sh              # print commands only
#   VERBOSE=1 scripts/configure_services.sh              # show ziti CLI output

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
VERBOSE="${VERBOSE:-}"
CTRL_MGMT_PORT="${CTRL_MGMT_PORT:-1280}"
ROUTER_IDENTITY="${ZITI_ROUTER_IDENTITY:-buck-lab-router-01}"

# ---------- helpers ----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Run a ziti edge command inside the controller pod.
# Returns the command's exit code. Stderr is captured and shown on failure
# (unless the failure is "already exists", which is expected and logged).
ziti_exec() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "  [dry-run] ziti edge $*"
    return 0
  fi

  local stderr_file
  stderr_file=$(mktemp)

  local rc=0
  if [[ -n "$VERBOSE" ]]; then
    kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge $*" 2>"$stderr_file" || rc=$?
  else
    kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge $*" >/dev/null 2>"$stderr_file" || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    local err
    err=$(cat "$stderr_file")
    rm -f "$stderr_file"
    if echo "$err" | grep -qiE "already exists|must be unique"; then
      log "  (already exists — skipping)"
      return 0
    fi
    warn "ziti edge $* failed (rc=$rc): $err"
    return "$rc"
  fi

  rm -f "$stderr_file"
  return 0
}

# ---------- prerequisites ----------------------------------------------------

if [[ -z "$DRY_RUN" ]]; then
  log "Checking prerequisites"

  if ! kubectl -n ziti get pods >/dev/null 2>&1; then
    warn "Cannot reach ziti namespace — is kubectl configured?"
    exit 1
  fi

  CTRL_POD=$(kubectl -n ziti get pod -l app.kubernetes.io/name=ziti-controller \
    -o jsonpath='{.items[0].metadata.name}')

  if [[ -z "$CTRL_POD" ]]; then
    warn "Controller pod not found"
    exit 1
  fi

  ADMIN_PW=$(kubectl -n ziti get secret ziti-controller-admin-secret \
    -o jsonpath='{.data.admin-password}' | base64 -d)

  log "Logging in to controller ($CTRL_POD)"
  if ! kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge login localhost:${CTRL_MGMT_PORT} -u admin -p '${ADMIN_PW}' --yes" \
    >/dev/null 2>&1; then
    warn "Admin password login failed; continuing with existing CLI identity context"
  fi

  # Verify the router identity exists before we try to tag it.
  if ! kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${ROUTER_IDENTITY}\"' -j" 2>/dev/null \
    | grep -q "$ROUTER_IDENTITY"; then
    warn "Router identity '$ROUTER_IDENTITY' not found — is the router enrolled?"
    exit 1
  fi
else
  CTRL_POD="(dry-run)"
  log "DRY_RUN mode — printing commands only"
fi

# ============================================================================
# Phase 1: Configs
# ============================================================================

log "--- Phase 1: Configs ---"

# 1a. Shared host.v1 — all HTTPS services route through Envoy Gateway proxy.
log "Creating host.v1 config: ingress-host"
ziti_exec "create config ingress-host host.v1 '{
  \"protocol\": \"tcp\",
  \"address\": \"envoy-main-lan-vip.envoy-gateway-system.svc\",
  \"port\": 443
}'"

# ============================================================================
# Phase 2: Intercept configs + services
# ============================================================================

log "--- Phase 2: Intercept configs + services ---"

# Format: "service_name|intercept_hostname|port|host_config"
# host_config defaults to ingress-host (routes to Envoy Gateway) when empty.
SERVICES=(
  "harbor|harbor.focuscell.org|443|"
  "keycloak|auth.focuspass.com|443|"
  "longhorn|longhorn.focuscell.org|443|"
  "mattermost|chat.focusbuzz.org|443|"
  "seaweedfs-api|s3.focuscell.org|443|"
  "seaweedfs-console|files.focuscell.org|443|"
  "slidee|dev.slidee.net|443|"
  "vaultwarden|vault.focuspass.com|443|"
  "coder|developerdojo.org|443|"
  "coder-wildcard|*.developerdojo.org|443|"
  "argocd|argocd.focuscell.org|443|"
  "gitlab|git.developerdojo.org|443|"
  "fleet|fleet.focuspass.com|443|"
  "studio-hardmagic|studio.hardmagic.com|443|"
  "api-studio-hardmagic|api.studio.hardmagic.com|443|"
  "studio-hypersight|studio.hypersight.net|443|"
  "pbx-admin|admin.focuscell.org|443|"
  "pbx-webrtc|pbx.focuscell.org|443|"
  "pbx-api|api.focuscell.org|443|"
)

# OpenClaw services — restricted to #openclaw-admin only, NOT #internal-services.
# Format: "service_name|intercept_hostname|port|host_config|service_attribute"
OPENCLAW_SERVICES=(
  "openclaw-dashboard|agents.focuschef.com|443||openclaw-services"
  "openclaw-admin|admin.focuschef.com|443||openclaw-services"
  "openclaw-hira|hira.focuschef.com|443||openclaw-services"
  "openclaw-lisa|lisa.focuschef.com|443||openclaw-services"
  "openclaw-cody|cody.focuschef.com|443||openclaw-services"
)

# Service-to-group mapping for role-based access:
#   core-services:    member group — everyone gets these
#   dev-services:     engineering group — dev tools
#   cluster-services: infra-admin group — cluster management
declare -A SERVICE_GROUP=(
  [harbor]=dev-services
  [keycloak]=core-services
  [longhorn]=cluster-services
  [mattermost]=core-services
  [seaweedfs-api]=cluster-services
  [seaweedfs-console]=cluster-services
  [slidee]=core-services
  [vaultwarden]=core-services
  [coder]=core-services
  [coder-wildcard]=core-services
  [argocd]=dev-services
  [gitlab]=dev-services
  [fleet]=core-services
  [studio-hardmagic]=core-services
  [api-studio-hardmagic]=core-services
  [studio-hypersight]=core-services
  [pbx-admin]=voip-services
  [pbx-webrtc]=voip-services
  [pbx-api]=voip-services
)

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name hostname port host_cfg <<< "$entry"
  host_cfg="${host_cfg:-ingress-host}"
  intercept_cfg="${name}-intercept"
  svc_group="${SERVICE_GROUP[$name]:-core-services}"

  log "Creating intercept config + service: $name ($hostname:$port) [#${svc_group}]"

  ziti_exec "create config ${intercept_cfg} intercept.v1 '{
    \"protocols\": [\"tcp\"],
    \"addresses\": [\"${hostname}\"],
    \"portRanges\": [{\"low\": ${port}, \"high\": ${port}}]
  }'"

  ziti_exec "create service ${name} \
    -c ${intercept_cfg},${host_cfg} \
    -a ${svc_group}"
done

for entry in "${OPENCLAW_SERVICES[@]}"; do
  IFS='|' read -r name hostname port host_cfg svc_attr <<< "$entry"
  host_cfg="${host_cfg:-ingress-host}"
  intercept_cfg="${name}-intercept"

  log "Creating intercept config + service: $name ($hostname:$port) [restricted: #$svc_attr]"

  ziti_exec "create config ${intercept_cfg} intercept.v1 '{
    \"protocols\": [\"tcp\"],
    \"addresses\": [\"${hostname}\"],
    \"portRanges\": [{\"low\": ${port}, \"high\": ${port}}]
  }'"

  ziti_exec "create service ${name} \
    -c ${intercept_cfg},${host_cfg} \
    -a ${svc_attr}"
done

# ============================================================================
# Phase 3: Identity tagging
# ============================================================================

log "--- Phase 3: Identity tagging ---"
log "Tagging router identity '$ROUTER_IDENTITY' with #routers"
ziti_exec "update identity ${ROUTER_IDENTITY} -a routers"

# ============================================================================
# Phase 4: Policies
# ============================================================================

log "--- Phase 4: Policies ---"

# --- Bind policies (router → services) ---
log "Creating service-policy: bind-core-services (Bind)"
ziti_exec "create service-policy bind-core-services Bind \
  --identity-roles '#routers' \
  --service-roles '#core-services' \
  --semantic AnyOf"

log "Creating service-policy: bind-dev-services (Bind)"
ziti_exec "create service-policy bind-dev-services Bind \
  --identity-roles '#routers' \
  --service-roles '#dev-services' \
  --semantic AnyOf"

log "Creating service-policy: bind-cluster-services (Bind)"
ziti_exec "create service-policy bind-cluster-services Bind \
  --identity-roles '#routers' \
  --service-roles '#cluster-services' \
  --semantic AnyOf"

log "Creating service-policy: bind-openclaw (Bind)"
ziti_exec "create service-policy bind-openclaw Bind \
  --identity-roles '#routers' \
  --service-roles '#openclaw-services' \
  --semantic AnyOf"

log "Creating service-policy: bind-voip-services (Bind)"
ziti_exec "create service-policy bind-voip-services Bind \
  --identity-roles '#routers' \
  --service-roles '#voip-services' \
  --semantic AnyOf"

# --- Dial policies (group → services) ---
log "Creating service-policy: dial-core-services (Dial — all members)"
ziti_exec "create service-policy dial-core-services Dial \
  --identity-roles '#member' \
  --service-roles '#core-services' \
  --semantic AnyOf"

log "Creating service-policy: dial-dev-services (Dial — engineers)"
ziti_exec "create service-policy dial-dev-services Dial \
  --identity-roles '#engineering' \
  --service-roles '#dev-services' \
  --semantic AnyOf"

log "Creating service-policy: dial-cluster-services (Dial — infra admins)"
ziti_exec "create service-policy dial-cluster-services Dial \
  --identity-roles '#infra-admin' \
  --service-roles '#cluster-services' \
  --semantic AnyOf"

log "Creating service-policy: dial-openclaw (Dial — openclaw admins)"
ziti_exec "create service-policy dial-openclaw Dial \
  --identity-roles '#openclaw-admin' \
  --service-roles '#openclaw-services' \
  --semantic AnyOf"

log "Creating service-policy: dial-voip-services (Dial — all members)"
ziti_exec "create service-policy dial-voip-services Dial \
  --identity-roles '#member' \
  --service-roles '#voip-services' \
  --semantic AnyOf"

# --- Edge router policies ---
log "Creating edge-router-policy: all-members-all-routers"
ziti_exec "create edge-router-policy all-members-all-routers \
  --identity-roles '#member' \
  --edge-router-roles '#all'"

# --- Service edge router policies ---
log "Creating service-edge-router-policy: core-all-routers"
ziti_exec "create service-edge-router-policy core-all-routers \
  --service-roles '#core-services' \
  --edge-router-roles '#all'"

log "Creating service-edge-router-policy: dev-all-routers"
ziti_exec "create service-edge-router-policy dev-all-routers \
  --service-roles '#dev-services' \
  --edge-router-roles '#all'"

log "Creating service-edge-router-policy: cluster-all-routers"
ziti_exec "create service-edge-router-policy cluster-all-routers \
  --service-roles '#cluster-services' \
  --edge-router-roles '#all'"

log "Creating service-edge-router-policy: openclaw-all-routers"
ziti_exec "create service-edge-router-policy openclaw-all-routers \
  --service-roles '#openclaw-services' \
  --edge-router-roles '#all'"

log "Creating service-edge-router-policy: voip-all-routers"
ziti_exec "create service-edge-router-policy voip-all-routers \
  --service-roles '#voip-services' \
  --edge-router-roles '#all'"

# ============================================================================
# Phase 5: Verification
# ============================================================================

log "--- Phase 5: Verification ---"

if [[ -z "$DRY_RUN" ]]; then
  echo ""
  echo "Configs:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list configs 'true'" 2>/dev/null || true
  echo ""
  echo "Services:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list services 'true'" 2>/dev/null || true
  echo ""
  echo "Service Policies:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list service-policies 'true'" 2>/dev/null || true
  echo ""
  echo "Edge Router Policies:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list edge-router-policies 'true'" 2>/dev/null || true
  echo ""
  echo "Service Edge Router Policies:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list service-edge-router-policies 'true'" 2>/dev/null || true
else
  log "(verification skipped in dry-run mode)"
fi

echo ""
log "Done — expected: 25 configs, 24 services, 10 service-policies, 1 edge-router-policy, 5 service-edge-router-policies"
