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
AKV_NAME="${AKV_NAME:-omlab-secrets}"

# ---------- inventory --------------------------------------------------------

INVENTORY_FILE="${INVENTORY_FILE:-}"
if [[ -z "$INVENTORY_FILE" ]]; then
  # Default: sibling talos repo (relative to ROOT_DIR)
  if [[ -f "$ROOT_DIR/../talos/datacenter/usb-creator/inventory.conf" ]]; then
    INVENTORY_FILE="$ROOT_DIR/../talos/datacenter/usb-creator/inventory.conf"
  elif [[ -f "$ROOT_DIR/inventory.conf" ]]; then
    INVENTORY_FILE="$ROOT_DIR/inventory.conf"
  else
    echo "ERROR: inventory.conf not found. Set INVENTORY_FILE or create symlink." >&2
    exit 1
  fi
fi

# Parse inventory.conf into parallel arrays.
# Optional arg: site filter (only include nodes from that site).
INV_NAMES=()
INV_IPS=()
INV_ROLES=()
INV_SITES=()
INV_INSTALLERS=()
parse_inventory() {
  local site_filter="${1:-}"
  INV_NAMES=(); INV_IPS=(); INV_ROLES=(); INV_SITES=(); INV_INSTALLERS=()
  while IFS=: read -r name ip role site installer; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ -n "$site_filter" && "$site" != "$site_filter" ]]; then
      continue
    fi
    INV_NAMES+=("$name")
    INV_IPS+=("$ip")
    INV_ROLES+=("$role")
    INV_SITES+=("$site")
    INV_INSTALLERS+=("$installer")
  done < "$INVENTORY_FILE"
}

parse_inventory "${SITE_FILTER:-}"
NODE_COUNT=${#INV_NAMES[@]}

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

  ADMIN_PW="$(get_admin_password)"

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

log "Loaded ${NODE_COUNT} nodes from inventory (${INVENTORY_FILE})"

# ============================================================================
# Phase 1: Configs
# ============================================================================

log "--- Phase 1: Configs ---"

# 1a. Shared host.v1 — all HTTPS services route through Envoy Gateway proxy.
# listenOptions.connectTimeoutSeconds raised to 30s (from default 5s) to prevent
# SDK-side "timeout waiting for message reply" under concurrent circuit creation.
# precedence=required ensures this is the authoritative host config.
log "Creating/updating host.v1 config: ingress-host"
ziti_exec "create config ingress-host host.v1 '{
  \"protocol\": \"tcp\",
  \"address\": \"envoy-main-lan-vip.envoy-gateway-system.svc\",
  \"port\": 443,
  \"listenOptions\": {
    \"connectTimeoutSeconds\": 30,
    \"precedence\": \"required\"
  }
}'"

# Update existing host.v1 configs to ensure address and listenOptions stay current (create skips existing).
ziti_exec "update config ingress-host -d '{
  \"protocol\": \"tcp\",
  \"address\": \"envoy-main-lan-vip.envoy-gateway-system.svc\",
  \"port\": 443,
  \"listenOptions\": {
    \"connectTimeoutSeconds\": 30,
    \"precedence\": \"required\"
  }
}'"

# 1b. K8s API host.v1 — each control-plane node binds localhost:6443 directly.
log "Creating/updating host.v1 config: k8s-api-host"
ziti_exec "create config k8s-api-host host.v1 '{
  \"protocol\": \"tcp\",
  \"address\": \"localhost\",
  \"port\": 6443
}'"

ziti_exec "update config k8s-api-host -d '{
  \"protocol\": \"tcp\",
  \"address\": \"localhost\",
  \"port\": 6443
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
  "grafana|grafana.focuscell.org|443|"
  "draw-hardmagic|draw.hardmagic.com|443|"
  "excalidraw-collab|collab.hardmagic.com|443|"
  "studio-hardmagic|studio.hardmagic.com|443|"
  "comfy-hardmagic|comfy.hardmagic.com|443|"
  "api-comfy-hardmagic|api.comfy.hardmagic.com|443|"
  "api-vllm-hardmagic|api.vllm.hardmagic.com|443|"
  "studio-hypersight|studio.hypersight.net|443|"
  "pbx-admin|admin.focuscell.org|443|"
  "pbx-webrtc|pbx.focuscell.org|443|"
  "pbx-api|api.focuscell.org|443|"
  "k8s-api|api.buck-lab.ziti.focuscell.org|6443|k8s-api-host"
  "focusmail-web|mail.focuscell.org|443|"
  "focusmail-api|mail-api.focuscell.org|443|"
  "domainsearch|domains.focuscell.org|443|"
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
  [grafana]=core-services
  [draw-hardmagic]=core-services
  [excalidraw-collab]=core-services
  [comfy-hardmagic]=core-services
  [api-comfy-hardmagic]=core-services
  [api-vllm-hardmagic]=core-services
  [studio-hypersight]=core-services
  [pbx-admin]=voip-services
  [pbx-webrtc]=voip-services
  [pbx-api]=voip-services
  [k8s-api]=cluster-services
  [focusmail-web]=core-services
  [focusmail-api]=core-services
  [domainsearch]=core-services
)

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name hostname port host_cfg <<< "$entry"
  host_cfg="${host_cfg:-ingress-host}"
  intercept_cfg="${name}-intercept"
  svc_group="${SERVICE_GROUP[$name]:-core-services}"

  log "Creating/updating intercept config + service: $name ($hostname:$port) [#${svc_group}]"

  ziti_exec "create config ${intercept_cfg} intercept.v1 '{
    \"protocols\": [\"tcp\"],
    \"addresses\": [\"${hostname}\"],
    \"portRanges\": [{\"low\": ${port}, \"high\": ${port}}]
  }'"

  # Update existing configs to ensure hostnames stay current (create skips existing).
  ziti_exec "update config ${intercept_cfg} -d '{
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

  log "Creating/updating intercept config + service: $name ($hostname:$port) [restricted: #$svc_attr]"

  ziti_exec "create config ${intercept_cfg} intercept.v1 '{
    \"protocols\": [\"tcp\"],
    \"addresses\": [\"${hostname}\"],
    \"portRanges\": [{\"low\": ${port}, \"high\": ${port}}]
  }'"

  # Update existing configs to ensure hostnames stay current.
  ziti_exec "update config ${intercept_cfg} -d '{
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

log "Creating service-policy: dial-cluster-watcher (Dial — devops watchers, k8s-api only)"
ziti_exec "create service-policy dial-cluster-watcher Dial \
  --identity-roles '#devops-watcher' \
  --service-roles '@k8s-api' \
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
# Phase 5: Per-Node Talos API Services
# ============================================================================

log "--- Phase 5: Per-Node Talos API Services ---"

# Each node gets a dedicated Talos API service so operators can reach
# nodes via Ziti hostnames (e.g., talos-t460-119.ziti.focuscell.org:50000)
# instead of hardcoded IPs. Each node's ziti-edge-tunnel binds its own service.
# Node list is driven by inventory.conf.

for node in "${INV_NAMES[@]}"; do
  log "Creating Talos API service for ${node}"

  # host.v1 — forward to localhost:50000 (Talos API on the node itself)
  ziti_exec "create config ${node}-talosapi-host host.v1 '{
    \"protocol\": \"tcp\",
    \"address\": \"localhost\",
    \"port\": 50000
  }'"

  # intercept.v1 — operator intercepts <node>.ziti.focuscell.org:50000
  ziti_exec "create config ${node}-talosapi-intercept intercept.v1 '{
    \"protocols\": [\"tcp\"],
    \"addresses\": [\"${node}.ziti.focuscell.org\"],
    \"portRanges\": [{\"low\": 50000, \"high\": 50000}]
  }'"

  # Service with attribute #node-services
  ziti_exec "create service ${node}-talosapi \
    -c ${node}-talosapi-intercept,${node}-talosapi-host \
    -a node-services"

  # Bind policy — only the node's own identity binds its service
  ziti_exec "create service-policy bind-node-${node} Bind \
    --identity-roles '@${node}-node' \
    --service-roles '@${node}-talosapi' \
    --semantic AnyOf"
done

# Shared dial policy — infra-admin can dial all node services
log "Creating service-policy: dial-node-services (Dial — infra admins)"
ziti_exec "create service-policy dial-node-services Dial \
  --identity-roles '#infra-admin' \
  --service-roles '#node-services' \
  --semantic AnyOf"

# Edge router policy — node identities can reach routers (needed to bind)
log "Creating edge-router-policy: nodes-all-routers"
ziti_exec "create edge-router-policy nodes-all-routers \
  --identity-roles '#nodes' \
  --edge-router-roles '#all'"

# Service edge router policy — node services use all routers
log "Creating service-edge-router-policy: node-all-routers"
ziti_exec "create service-edge-router-policy node-all-routers \
  --service-roles '#node-services' \
  --edge-router-roles '#all'"

# ============================================================================
# Phase 6: Kubernetes API — Control-Plane Node Binding
# ============================================================================

log "--- Phase 6: K8s API control-plane node binding ---"

# The k8s-api service is defined in Phase 2 (cluster-services group).
# Unlike HTTPS services that route via Envoy Gateway, the K8s API is bound
# directly by each control-plane node identity (localhost:6443). Ziti
# load-balances across all 3 terminators automatically.

log "Creating service-policy: bind-kube-api (Bind — control-plane nodes)"
ziti_exec "create service-policy bind-kube-api Bind \
  --identity-roles '#controlplanes' \
  --service-roles '@k8s-api' \
  --semantic AnyOf"

# All nodes need to dial the K8s API via Ziti in a multi-site topology.
# ext-openziti in "run" mode intercepts connections to api.buck-lab.ziti.focuscell.org
# and routes them through the Ziti overlay to the control plane terminators.
log "Creating service-policy: dial-nodes-kube-api (Dial — all nodes)"
ziti_exec "create service-policy dial-nodes-kube-api Dial \
  --identity-roles '#nodes' \
  --service-roles '@k8s-api' \
  --semantic AnyOf"

# ============================================================================
# Phase 7: Verification
# ============================================================================

log "--- Phase 7: Verification ---"

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

# Dynamic counts based on inventory:
#   Configs:  32 static (ingress-host, k8s-api-host, 25 intercept, 5 openclaw-intercept)
#             + NODE_COUNT * 2 (host + intercept per node)
#   Services: 30 static (25 + 5 openclaw) + NODE_COUNT
#   Service-policies: 13 static + NODE_COUNT (per-node bind) + 1 dial-node-services
#   Edge-router-policies: 2 (all-members + nodes)
#   Service-edge-router-policies: 6
EXPECTED_CONFIGS=$((32 + NODE_COUNT * 2))
EXPECTED_SERVICES=$((30 + NODE_COUNT))
EXPECTED_SP=$((14 + NODE_COUNT))

echo ""
log "Done — expected: ${EXPECTED_CONFIGS} configs, ${EXPECTED_SERVICES} services, ${EXPECTED_SP} service-policies, 2 edge-router-policies, 6 service-edge-router-policies (${NODE_COUNT} nodes)"
