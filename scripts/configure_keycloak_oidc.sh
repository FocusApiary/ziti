#!/usr/bin/env bash
set -euo pipefail

# Configure Keycloak OIDC client, mappers, realm roles, and user-role
# assignments for OpenZiti tunneler authentication.
#
# Idempotent: safe to re-run. Existing resources are skipped (not updated).
#
# Usage:
#   scripts/configure_keycloak_oidc.sh                        # full setup
#   DRY_RUN=1 scripts/configure_keycloak_oidc.sh              # print commands only

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak}"
KC_POD="${KC_POD:-slidee-kc-0}"
KC_REALM="${KC_REALM:-omlabs}"
KCADM="/opt/keycloak/bin/kcadm.sh"

# ---------- helpers ----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Run a kcadm.sh command inside the Keycloak pod.
kc_exec() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "  [dry-run] kcadm.sh $*"
    return 0
  fi

  local stderr_file
  stderr_file=$(mktemp)

  local rc=0
  kubectl -n "$KC_NAMESPACE" exec "$KC_POD" -- "$KCADM" "$@" 2>"$stderr_file" || rc=$?

  if [[ $rc -ne 0 ]]; then
    local err
    err=$(cat "$stderr_file")
    rm -f "$stderr_file"
    warn "kcadm.sh $* failed (rc=$rc): $err"
    return "$rc"
  fi

  rm -f "$stderr_file"
  return 0
}

# Run a kcadm.sh command and capture stdout (for queries).
kc_query() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "  [dry-run] kcadm.sh $*"
    return 0
  fi

  kubectl -n "$KC_NAMESPACE" exec "$KC_POD" -- "$KCADM" "$@" 2>/dev/null
}

# ---------- prerequisites ----------------------------------------------------

if [[ -z "$DRY_RUN" ]]; then
  log "Checking prerequisites"

  if ! kubectl -n "$KC_NAMESPACE" get pod "$KC_POD" >/dev/null 2>&1; then
    warn "Keycloak pod '$KC_POD' not found in namespace '$KC_NAMESPACE'"
    exit 1
  fi

  log "Retrieving admin credentials"
  KC_USER="$(kubectl -n "$KC_NAMESPACE" get secret slidee-kc-initial-admin \
    -o jsonpath='{.data.username}' | base64 -d)"
  KC_PASS="$(kubectl -n "$KC_NAMESPACE" get secret slidee-kc-initial-admin \
    -o jsonpath='{.data.password}' | base64 -d)"

  log "Authenticating to Keycloak admin CLI ($KC_POD)"
  # Login directly (not via kc_exec) to avoid logging credentials on failure.
  if ! kubectl -n "$KC_NAMESPACE" exec "$KC_POD" -- "$KCADM" config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KC_USER" \
    --password "$KC_PASS" 2>/dev/null; then
    warn "Keycloak admin login failed (check credentials in slidee-kc-initial-admin secret)"
    exit 1
  fi
else
  log "DRY_RUN mode — printing commands only"
fi

# ============================================================================
# Phase 1: OIDC Client
# ============================================================================

log "--- Phase 1: OIDC Client ---"

# The controller's OIDC handler only accepts client_id=openziti or native
# (hardcoded in controller/oidc_auth/provider.go). ZDE sends client_id=openziti
# to both the controller and Keycloak, so the Keycloak client must match.
CLIENT_ID="openziti"

client_exists=false
if [[ -z "$DRY_RUN" ]]; then
  existing=$(kc_query get clients -r "$KC_REALM" -q "clientId=$CLIENT_ID" --fields id 2>/dev/null || true)
  if echo "$existing" | grep -q '"id"'; then
    client_exists=true
  fi
fi

if [[ "$client_exists" == "true" ]]; then
  log "Client '$CLIENT_ID' already exists — skipping"
else
  log "Creating OIDC client: $CLIENT_ID"
  # Redirect URIs must include ziti://callback for iOS ZDE and
  # openziti://auth/callback for desktop ZDE.
  kc_exec create clients -r "$KC_REALM" -s "clientId=$CLIENT_ID" \
    -s 'publicClient=true' \
    -s 'standardFlowEnabled=true' \
    -s 'directAccessGrantsEnabled=false' \
    -s 'redirectUris=["ziti://callback","openziti://auth/callback","https://127.0.0.1:*/auth/callback","http://127.0.0.1:*/auth/callback","https://localhost:*/auth/callback","http://localhost:*/auth/callback"]' \
    -s 'attributes={"pkce.code.challenge.method":"S256","access.token.lifespan":"300","client.offline.session.idle.timeout":"28800"}'
fi

# Retrieve the internal client UUID for mapper creation.
CLIENT_UUID=""
if [[ -z "$DRY_RUN" ]]; then
  CLIENT_UUID=$(kc_query get clients -r "$KC_REALM" -q "clientId=$CLIENT_ID" --fields id \
    | grep '"id"' | head -1 | sed 's/.*: *"//;s/".*//')
  if [[ -z "$CLIENT_UUID" ]]; then
    warn "Could not retrieve UUID for client '$CLIENT_ID'"
    exit 1
  fi
  log "Client UUID: $CLIENT_UUID"
fi

# ============================================================================
# Phase 2: Audience Mapper
# ============================================================================

log "--- Phase 2: Audience Mapper ---"

AUDIENCE_MAPPER_NAME="openziti-audience"

mapper_exists=false
if [[ -z "$DRY_RUN" && -n "$CLIENT_UUID" ]]; then
  existing=$(kc_query get "clients/$CLIENT_UUID/protocol-mappers/models" -r "$KC_REALM" \
    --fields name 2>/dev/null || true)
  if echo "$existing" | grep -q "\"$AUDIENCE_MAPPER_NAME\""; then
    mapper_exists=true
  fi
fi

if [[ "$mapper_exists" == "true" ]]; then
  log "Audience mapper '$AUDIENCE_MAPPER_NAME' already exists — skipping"
else
  log "Creating audience mapper: $AUDIENCE_MAPPER_NAME"
  kc_exec create "clients/$CLIENT_UUID/protocol-mappers/models" -r "$KC_REALM" \
    -s "name=$AUDIENCE_MAPPER_NAME" \
    -s 'protocol=openid-connect' \
    -s 'protocolMapper=oidc-audience-mapper' \
    -s 'config={"included.custom.audience":"openziti","id.token.claim":"false","access.token.claim":"true"}'
fi

# ============================================================================
# Phase 3: Realm Role Mapper
# ============================================================================

log "--- Phase 3: Realm Role Mapper ---"

ROLE_MAPPER_NAME="ziti-realm-roles"

role_mapper_exists=false
if [[ -z "$DRY_RUN" && -n "$CLIENT_UUID" ]]; then
  existing=$(kc_query get "clients/$CLIENT_UUID/protocol-mappers/models" -r "$KC_REALM" \
    --fields name 2>/dev/null || true)
  if echo "$existing" | grep -q "\"$ROLE_MAPPER_NAME\""; then
    role_mapper_exists=true
  fi
fi

if [[ "$role_mapper_exists" == "true" ]]; then
  log "Role mapper '$ROLE_MAPPER_NAME' already exists — skipping"
else
  log "Creating realm role mapper: $ROLE_MAPPER_NAME"
  kc_exec create "clients/$CLIENT_UUID/protocol-mappers/models" -r "$KC_REALM" \
    -s "name=$ROLE_MAPPER_NAME" \
    -s 'protocol=openid-connect' \
    -s 'protocolMapper=oidc-usermodel-realm-role-mapper' \
    -s 'config={"multivalued":"true","claim.name":"realm_roles","jsonType.label":"String","id.token.claim":"false","access.token.claim":"true","userinfo.token.claim":"false"}'
fi

# ============================================================================
# Phase 4: Realm Roles
# ============================================================================

log "--- Phase 4: Realm Roles ---"

ROLES=(
  member
  engineering
  infra-admin
  openclaw-admin
  devops-watcher
)

for role in "${ROLES[@]}"; do
  role_exists=false
  if [[ -z "$DRY_RUN" ]]; then
    existing=$(kc_query get roles -r "$KC_REALM" --fields name 2>/dev/null || true)
    if echo "$existing" | grep -q "\"$role\""; then
      role_exists=true
    fi
  fi

  if [[ "$role_exists" == "true" ]]; then
    log "Realm role '$role' already exists — skipping"
  else
    log "Creating realm role: $role"
    kc_exec create roles -r "$KC_REALM" -s "name=$role"
  fi
done

# ============================================================================
# Phase 5: User Role Assignments
# ============================================================================

log "--- Phase 5: User Role Assignments ---"

# Format: "email|role1 role2 role3 ..."
USER_ROLES=(
  "seanh@focuspass.com|member engineering infra-admin openclaw-admin"
  "sconejos@focuspass.com|member engineering"
  "mrh@focuspass.com|member engineering infra-admin"
  "abdulrehman@focuspass.com|member engineering"
  "azlankhan@focuspass.com|member engineering"
  "mahakhan@focuspass.com|member"
  "zaryabayub@focuspass.com|member engineering devops-watcher"
)

for entry in "${USER_ROLES[@]}"; do
  IFS='|' read -r email roles <<< "$entry"

  for role in $roles; do
    log "Assigning role '$role' to user '$email'"
    # add-roles is idempotent — no-op if already assigned
    kc_exec add-roles -r "$KC_REALM" --uusername "$email" --rolename "$role"
  done
done

# ============================================================================
# Phase 6: Verification
# ============================================================================

log "--- Phase 6: Verification ---"

if [[ -z "$DRY_RUN" ]]; then
  echo ""
  echo "Client:"
  kc_query get clients -r "$KC_REALM" -q "clientId=$CLIENT_ID" \
    --fields clientId,publicClient,standardFlowEnabled,redirectUris || true
  echo ""
  echo "Protocol Mappers:"
  kc_query get "clients/$CLIENT_UUID/protocol-mappers/models" -r "$KC_REALM" \
    --fields name,protocolMapper || true
  echo ""
  echo "Realm Roles:"
  kc_query get roles -r "$KC_REALM" --fields name || true
else
  log "(verification skipped in dry-run mode)"
fi

echo ""
log "Done — expected: 1 client, 2 protocol mappers, ${#ROLES[@]} realm roles, ${#USER_ROLES[@]} users configured"
