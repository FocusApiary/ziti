#!/usr/bin/env bash
set -euo pipefail

# Create Ziti ext-jwt-signer, auth-policy, per-user OIDC identities, and
# kiosk device identities for Keycloak SSO integration.
#
# Idempotent: existing resources are skipped or updated in-place.
#
# Usage:
#   scripts/configure_oidc.sh                        # full setup
#   DRY_RUN=1 scripts/configure_oidc.sh              # print commands only
#   VERBOSE=1 scripts/configure_oidc.sh              # show ziti CLI output

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
VERBOSE="${VERBOSE:-}"
CTRL_MGMT_PORT="${CTRL_MGMT_PORT:-1280}"
AKV_NAME="${AKV_NAME:-omlab-secrets}"
OUT_DIR="$ROOT_DIR/out/identities"
VM_NAMESPACE="igpu-vms"

# ---------- OIDC user definitions ----------------------------------------------
# Format: "email|identity_name|role_attributes"
OIDC_USERS=(
  "seanh@focuspass.com|seanh-oidc|member,engineering,infra-admin,openclaw-admin"
  "sconejos@focuspass.com|sconejos-oidc|member,engineering"
  "mrh@focuspass.com|mrh-oidc|member,engineering"
  "abdulrehman@focuspass.com|abdulrehman-oidc|member,engineering"
  "azlankhan@focuspass.com|azlankhan-oidc|member,engineering"
  "mahakhan@focuspass.com|mahakhan-oidc|member"
  "zaryabayub@focuspass.com|zaryabayub-oidc|member,engineering,devops-watcher"
)

# ---------- kiosk device definitions ------------------------------------------
# Format: "identity_name|akv_secret_name|node_desc"
KIOSKS=(
  "cc5-kiosk|ziti-kiosk-cc5|Curiosity Cottage 1 (node-5, 192.168.1.159)"
  "cc6-kiosk|ziti-kiosk-cc6|Curiosity Cottage 3 (node-6, 192.168.1.169)"
)

# ---------- old identities to clean up ----------------------------------------
OLD_VM_IDENTITIES=(
  "sconejos-workstation|ziti-identity-sconejos"
  "mrh-workstation|ziti-identity-mrh"
)

# ---------- helpers ------------------------------------------------------------

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
      log "  (already exists -- skipping)"
      return 0
    fi
    warn "ziti edge $* failed (rc=$rc): $err"
    return "$rc"
  fi

  rm -f "$stderr_file"
  return 0
}

# Call the Ziti management REST API.
# Usage: curl_mgmt <METHOD> <PATH> <BODY> <TOKEN>
curl_mgmt() {
  local method="$1" path="$2" body="$3" token="$4"
  local url="https://localhost:${CTRL_MGMT_PORT}/edge/management/v1${path}"
  local args=(-sk -X "$method" "$url" -H "zt-session: ${token}" -H "Content-Type: application/json")
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  kubectl -n ziti exec "$CTRL_POD" -c ziti-controller -- curl "${args[@]}" 2>/dev/null
}

# Run a ziti edge command and capture stdout (for JSON parsing).
ziti_exec_capture() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "  [dry-run] ziti edge $*" >&2
    echo ""
    return 0
  fi

  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge $*" 2>/dev/null
}

# ---------- prerequisites ------------------------------------------------------

if [[ -z "$DRY_RUN" ]]; then
  log "Checking prerequisites"

  if ! kubectl -n ziti get pods >/dev/null 2>&1; then
    warn "Cannot reach ziti namespace -- is kubectl configured?"
    exit 1
  fi

  CTRL_POD=$(kubectl -n ziti get pod -l app.kubernetes.io/name=ziti-controller \
    -o jsonpath='{.items[0].metadata.name}')

  if [[ -z "$CTRL_POD" ]]; then
    warn "Controller pod not found"
    exit 1
  fi

  ADMIN_PW="$(get_admin_password)"

  # v2.0.0 CLI uses OIDC for login; use REST API for password auth, then
  # pass the token to the CLI for subsequent commands.
  log "Authenticating to controller via REST API ($CTRL_POD)"
  ADMIN_TOKEN=$(kubectl -n ziti exec "$CTRL_POD" -c ziti-controller -- \
    curl -sk -X POST "https://localhost:${CTRL_MGMT_PORT}/edge/management/v1/authenticate?method=password" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")

  if [[ -z "$ADMIN_TOKEN" ]]; then
    warn "REST API authentication failed"
    exit 1
  fi

  # Set CLI session token so ziti_exec commands work without OIDC login.
  if ! kubectl -n ziti exec "$CTRL_POD" -c ziti-controller -- sh -c \
    "ziti edge login localhost:${CTRL_MGMT_PORT} --token '${ADMIN_TOKEN}' --yes" \
    >/dev/null 2>&1; then
    warn "CLI token login failed; continuing with REST API only"
  fi
else
  CTRL_POD="(dry-run)"
  log "DRY_RUN mode -- printing commands only"
fi

mkdir -p "$OUT_DIR"

# ============================================================================
# Phase 1: ext-jwt-signer
# ============================================================================

log "--- Phase 1: ext-jwt-signer ---"

SIGNER_NAME="keycloak-omlabs"
AUTH_POLICY_NAME="oidc-keycloak"

KC_ISSUER="https://auth.focuspass.com/realms/omlabs"
KC_JWKS_URL="https://auth.focuspass.com/realms/omlabs/protocol/openid-connect/certs"
KC_EXTERNAL_AUTH_URL="$KC_ISSUER"

# Resolve an existing auth-policy ID up front so the signer can point at the
# correct enrollment policy during updates. If the policy does not exist yet we
# create it in Phase 2 and update the signer again afterwards.
EXISTING_AUTH_POLICY_ID=""
if [[ -z "$DRY_RUN" ]]; then
  existing_policy_json="$(curl_mgmt "GET" "/auth-policies?filter=name%3D%22${AUTH_POLICY_NAME}%22" "" "$ADMIN_TOKEN")"
  EXISTING_AUTH_POLICY_ID="$(python3 -c "
import json, sys
try:
    items = json.loads(sys.stdin.read()).get('data', [])
    if items:
        print(items[0]['id'])
except Exception:
    pass
" <<< "$existing_policy_json" 2>/dev/null || true)"
fi

# Create or update the ext-jwt-signer via REST API using OIDC discovery via
# jwksEndpoint and issuer URLs. This keeps the signer aligned with the Desktop
# Edge browser flow and avoids stale pinned cert data.
log "Creating/updating ext-jwt-signer: $SIGNER_NAME"
if [[ -n "$DRY_RUN" ]]; then
  echo "  [dry-run] POST/PUT /edge/management/v1/external-jwt-signers (issuer/jwksEndpoint OIDC config)"
else
  # Check if signer already exists.
  EXISTING_SIGNER=$(curl_mgmt "GET" "/external-jwt-signers?filter=name%3D%22${SIGNER_NAME}%22" "" "$ADMIN_TOKEN")
  EXISTING_ID=$(echo "$EXISTING_SIGNER" | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin).get('data', [])
    if items: print(items[0]['id'])
except: pass
" 2>/dev/null || true)

  SIGNER_BODY="$(EXISTING_AUTH_POLICY_ID="$EXISTING_AUTH_POLICY_ID" python3 - <<'PY'
import json
import os

body = {
    "name": "keycloak-omlabs",
    "issuer": "https://auth.focuspass.com/realms/omlabs",
    "jwksEndpoint": "https://auth.focuspass.com/realms/omlabs/protocol/openid-connect/certs",
    "audience": "openziti",
    "clientId": "openziti-tunneler",
    "claimsProperty": "email",
    "useExternalId": True,
    "enabled": True,
    "externalAuthUrl": "https://auth.focuspass.com/realms/omlabs",
    "scopes": ["openid", "profile", "email", "offline_access"],
    "targetToken": "ACCESS",
    "enrollToCertEnabled": True,
    "enrollToTokenEnabled": True,
    "enrollNameClaimsSelector": "/email",
    "enrollAttributeClaimsSelector": "/realm_roles",
}

if os.environ.get("EXISTING_AUTH_POLICY_ID"):
    body["enrollAuthPolicyId"] = os.environ["EXISTING_AUTH_POLICY_ID"]

print(json.dumps(body))
PY
)"

  if [[ -n "$EXISTING_ID" ]]; then
    log "Signer '$SIGNER_NAME' exists (id=$EXISTING_ID) -- updating via PUT"
    curl_mgmt "PUT" "/external-jwt-signers/${EXISTING_ID}" "$SIGNER_BODY" "$ADMIN_TOKEN" >/dev/null
  else
    log "Creating signer '$SIGNER_NAME' via POST"
    curl_mgmt "POST" "/external-jwt-signers" "$SIGNER_BODY" "$ADMIN_TOKEN" >/dev/null
  fi
fi

# ============================================================================
# Phase 2: auth-policy
# ============================================================================

log "--- Phase 2: auth-policy ---"

# Resolve signer ID via REST API.
log "Resolving ext-jwt-signer ID for $SIGNER_NAME"
SIGNER_ID=""
if [[ -z "$DRY_RUN" ]]; then
  signer_json="$(curl_mgmt "GET" "/external-jwt-signers?filter=name%3D%22${SIGNER_NAME}%22" "" "$ADMIN_TOKEN")"

  SIGNER_ID="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data.get('data', [])
    if items:
        print(items[0]['id'])
except Exception:
    pass
" <<< "$signer_json" 2>/dev/null || true)"

  if [[ -z "$SIGNER_ID" ]]; then
    warn "Could not resolve ext-jwt-signer ID for '$SIGNER_NAME' -- cannot continue"
    exit 1
  else
    log "Resolved signer ID: $SIGNER_ID"
  fi
fi

log "Creating auth-policy: $AUTH_POLICY_NAME"
if [[ -n "$DRY_RUN" ]]; then
  echo "  [dry-run] POST/PUT /edge/management/v1/auth-policies (primary ext-jwt allowed via <SIGNER_ID>)"
else
  EXISTING_POLICY_JSON="$(curl_mgmt "GET" "/auth-policies?filter=name%3D%22${AUTH_POLICY_NAME}%22" "" "$ADMIN_TOKEN")"
  EXISTING_POLICY_ID="$(python3 -c "
import json, sys
try:
    items = json.loads(sys.stdin.read()).get('data', [])
    if items:
        print(items[0]['id'])
except Exception:
    pass
" <<< "$EXISTING_POLICY_JSON" 2>/dev/null || true)"

  AUTH_POLICY_BODY="$(SIGNER_ID="$SIGNER_ID" python3 - <<'PY'
import json
import os

print(json.dumps({
    "name": "oidc-keycloak",
    "primary": {
        "cert": {
            "allowed": True,
            "allowExpiredCerts": False,
        },
        "extJwt": {
            "allowed": True,
            "allowedSigners": [os.environ["SIGNER_ID"]],
        },
        "updb": {
            "allowed": False,
            "lockoutDurationMinutes": 0,
            "maxAttempts": 0,
            "minPasswordLength": 5,
            "requireMixedCase": False,
            "requireNumberChar": False,
            "requireSpecialChar": False,
        },
    },
    "secondary": {
        "requireTotp": False,
    },
    "tags": {},
}))
PY
)"

  if [[ -n "$EXISTING_POLICY_ID" ]]; then
    log "Auth-policy '$AUTH_POLICY_NAME' exists (id=$EXISTING_POLICY_ID) -- updating via PUT"
    curl_mgmt "PUT" "/auth-policies/${EXISTING_POLICY_ID}" "$AUTH_POLICY_BODY" "$ADMIN_TOKEN" >/dev/null
  else
    log "Creating auth-policy '$AUTH_POLICY_NAME' via POST"
    curl_mgmt "POST" "/auth-policies" "$AUTH_POLICY_BODY" "$ADMIN_TOKEN" >/dev/null
  fi
fi

# Resolve auth-policy ID for identity creation.
AUTH_POLICY_ID=""
if [[ -z "$DRY_RUN" ]]; then
  policy_json="$(curl_mgmt "GET" "/auth-policies?filter=name%3D%22${AUTH_POLICY_NAME}%22" "" "$ADMIN_TOKEN")"

  AUTH_POLICY_ID="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    items = data.get('data', [])
    if items:
        print(items[0]['id'])
except Exception:
    pass
" <<< "$policy_json" 2>/dev/null || true)"

  if [[ -z "$AUTH_POLICY_ID" ]]; then
    AUTH_POLICY_ID="$(echo "$policy_json" | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1 || true)"
  fi

  if [[ -z "$AUTH_POLICY_ID" ]]; then
    warn "Could not resolve auth-policy ID for '$AUTH_POLICY_NAME' -- cannot continue"
    exit 1
  else
    log "Resolved auth-policy ID: $AUTH_POLICY_ID"
  fi

  log "Updating ext-jwt-signer enrollment auth-policy binding"
  SIGNER_BODY="$(AUTH_POLICY_ID="$AUTH_POLICY_ID" python3 - <<'PY'
import json
import os

print(json.dumps({
    "name": "keycloak-omlabs",
    "issuer": "https://auth.focuspass.com/realms/omlabs",
    "jwksEndpoint": "https://auth.focuspass.com/realms/omlabs/protocol/openid-connect/certs",
    "audience": "openziti",
    "clientId": "openziti-tunneler",
    "claimsProperty": "email",
    "useExternalId": True,
    "enabled": True,
    "externalAuthUrl": "https://auth.focuspass.com/realms/omlabs",
    "scopes": ["openid", "profile", "email", "offline_access"],
    "targetToken": "ACCESS",
    "enrollToCertEnabled": True,
    "enrollToTokenEnabled": True,
    "enrollNameClaimsSelector": "/email",
    "enrollAttributeClaimsSelector": "/realm_roles",
    "enrollAuthPolicyId": os.environ["AUTH_POLICY_ID"],
    "tags": {},
}))
PY
)"
  curl_mgmt "PUT" "/external-jwt-signers/${SIGNER_ID}" "$SIGNER_BODY" "$ADMIN_TOKEN" >/dev/null
fi

# ============================================================================
# Phase 3: Per-user OIDC identities
# ============================================================================

log "--- Phase 3: Per-user OIDC identities ---"

oidc_created=0
oidc_updated=0

for entry in "${OIDC_USERS[@]}"; do
  IFS='|' read -r email identity attrs <<< "$entry"
  jwt_file="/tmp/${identity}.jwt"

  log "--- ${identity} (${email}) ---"

  if [[ -n "$DRY_RUN" ]]; then
    log "Would create/update OIDC identity: $identity (externalId: $email, attrs: $attrs)"
    echo "  [dry-run] ziti edge create identity '${identity}' --auth-policy '<AUTH_POLICY_ID>' --external-id '${email}' -a '${attrs}' -o '${jwt_file}'"
    continue
  fi

  # Check if identity already exists.
  if kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${identity}\"' -j 2>/dev/null" 2>/dev/null \
    | grep -q "\"name\":\"${identity}\""; then
    log "Identity '$identity' already exists -- updating attributes + auth-policy"
    ziti_exec "update identity '${identity}' \
      --auth-policy '${AUTH_POLICY_ID}' \
      --external-id '${email}' \
      -a '${attrs}'"
    oidc_updated=$((oidc_updated + 1))
    continue
  fi

  log "Creating OIDC identity: $identity (externalId: $email)"
  if ! kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge create identity '${identity}' --auth-policy '${AUTH_POLICY_ID}' --external-id '${email}' -a '${attrs}' -o '${jwt_file}'" 2>&1; then
    warn "Failed to create identity '$identity'"
    continue
  fi

  # Extract JWT from the pod.
  jwt_content=$(kubectl -n ziti exec "$CTRL_POD" -- cat "$jwt_file" 2>/dev/null || true)

  if [[ -n "$jwt_content" ]]; then
    # Write locally.
    printf '%s' "$jwt_content" > "$OUT_DIR/${identity}.jwt"
    log "JWT written to out/identities/${identity}.jwt"

    # Store in AKV.
    if command -v az >/dev/null 2>&1; then
      if az keyvault secret set --vault-name "$AKV_NAME" \
        --name "ziti-oidc-${identity}" \
        --value "$jwt_content" >/dev/null 2>&1; then
        log "JWT stored in AKV as ziti-oidc-${identity}"
      else
        warn "Failed to store JWT in AKV (continuing)"
      fi
    else
      log "az CLI not found -- skipping AKV storage"
    fi
  else
    warn "Could not extract JWT from pod for '$identity'"
  fi

  oidc_created=$((oidc_created + 1))
done

if [[ -z "$DRY_RUN" ]]; then
  log "OIDC identities: created=$oidc_created, updated=$oidc_updated"
fi

# ============================================================================
# Phase 4: Kiosk device identities
# ============================================================================

log "--- Phase 4: Kiosk device identities ---"

kiosk_created=0
kiosk_skipped=0

for entry in "${KIOSKS[@]}"; do
  IFS='|' read -r identity secret_name node_desc <<< "$entry"
  jwt_file="/tmp/${identity}.jwt"

  log "--- ${identity} (${node_desc}) ---"

  if [[ -n "$DRY_RUN" ]]; then
    log "Would create kiosk identity: $identity (tag: #member)"
    echo "  [dry-run] ziti edge create identity device '$identity' -a member -o '$jwt_file'"
    echo "  [dry-run] kubectl -n $VM_NAMESPACE create secret generic '$secret_name' --from-literal=ziti-identity.jwt=<jwt>"
    continue
  fi

  # Check if identity already exists.
  if kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${identity}\"' -j 2>/dev/null" 2>/dev/null \
    | grep -q "\"name\":\"${identity}\""; then
    log "Identity '$identity' already exists (skipping creation)"
    kiosk_skipped=$((kiosk_skipped + 1))

    # Ensure k8s secret exists.
    if kubectl -n "$VM_NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
      log "K8s secret '$secret_name' already exists"
    else
      warn "Identity exists but k8s secret '$secret_name' is missing -- re-enroll manually or delete+recreate identity"
    fi
    continue
  fi

  log "Creating kiosk identity: $identity (tag: #member)"
  if ! kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge create identity device '${identity}' -a member -o '${jwt_file}'" 2>&1; then
    warn "Failed to create identity '$identity'"
    continue
  fi

  # Extract JWT from the pod.
  jwt_content=$(kubectl -n ziti exec "$CTRL_POD" -- cat "$jwt_file" 2>/dev/null || true)

  if [[ -z "$jwt_content" ]]; then
    warn "Could not extract JWT from pod for '$identity'"
    continue
  fi

  # Write locally.
  printf '%s' "$jwt_content" > "$OUT_DIR/${identity}.jwt"
  log "JWT written to out/identities/${identity}.jwt"

  # Store in AKV.
  if command -v az >/dev/null 2>&1; then
    if az keyvault secret set --vault-name "$AKV_NAME" \
      --name "$secret_name" \
      --value "$jwt_content" >/dev/null 2>&1; then
      log "JWT stored in AKV as $secret_name"
    else
      warn "Failed to store JWT in AKV (continuing)"
    fi
  else
    log "az CLI not found -- skipping AKV storage"
  fi

  # Create/update k8s secret in igpu-vms namespace.
  if kubectl -n "$VM_NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
    log "K8s secret '$secret_name' already exists (updating)"
    kubectl -n "$VM_NAMESPACE" delete secret "$secret_name" >/dev/null 2>&1
  fi

  kubectl -n "$VM_NAMESPACE" create secret generic "$secret_name" \
    --from-literal=ziti-identity.jwt="$jwt_content"
  kubectl -n "$VM_NAMESPACE" label secret "$secret_name" managed-by=gitops
  log "K8s secret '$secret_name' created in namespace $VM_NAMESPACE"

  kiosk_created=$((kiosk_created + 1))
done

if [[ -z "$DRY_RUN" ]]; then
  log "Kiosk identities: created=$kiosk_created, skipped=$kiosk_skipped"
fi

# ============================================================================
# Phase 5: Cleanup old identities
# ============================================================================

log "--- Phase 5: Cleanup old identities ---"

for entry in "${OLD_VM_IDENTITIES[@]}"; do
  IFS='|' read -r old_identity old_secret <<< "$entry"

  log "Cleaning up old identity: $old_identity"

  if [[ -n "$DRY_RUN" ]]; then
    echo "  [dry-run] ziti edge delete identity '${old_identity}'"
    echo "  [dry-run] kubectl -n $VM_NAMESPACE delete secret '$old_secret'"
    echo "  [dry-run] az keyvault secret delete --vault-name '$AKV_NAME' --name '$old_secret'"
    continue
  fi

  # Delete from Ziti controller.
  if kubectl -n ziti exec "$CTRL_POD" -- sh -c \
    "ziti edge list identities 'name=\"${old_identity}\"' -j 2>/dev/null" 2>/dev/null \
    | grep -q "\"name\":\"${old_identity}\""; then
    ziti_exec "delete identity '${old_identity}'"
    log "Deleted identity '$old_identity' from controller"
  else
    log "Identity '$old_identity' not found (already deleted)"
  fi

  # Delete k8s secret.
  if kubectl -n "$VM_NAMESPACE" get secret "$old_secret" >/dev/null 2>&1; then
    kubectl -n "$VM_NAMESPACE" delete secret "$old_secret" >/dev/null 2>&1
    log "Deleted k8s secret '$old_secret' from $VM_NAMESPACE"
  else
    log "K8s secret '$old_secret' not found (already deleted)"
  fi

  # Delete AKV secret.
  if command -v az >/dev/null 2>&1; then
    if az keyvault secret delete --vault-name "$AKV_NAME" \
      --name "$old_secret" >/dev/null 2>&1; then
      log "Deleted AKV secret '$old_secret'"
    else
      log "AKV secret '$old_secret' not found or already deleted"
    fi
  else
    log "az CLI not found -- skipping AKV cleanup"
  fi
done

# ============================================================================
# Phase 6: Verification
# ============================================================================

log "--- Phase 6: Verification ---"

if [[ -z "$DRY_RUN" ]]; then
  echo ""
  echo "ext-jwt-signers:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list ext-jwt-signers 'true'" 2>/dev/null || true
  echo ""
  echo "Auth Policies:"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list auth-policies 'true'" 2>/dev/null || true
  echo ""
  echo "Identities (with externalId):"
  kubectl -n ziti exec "$CTRL_POD" -- sh -c "ziti edge list identities 'true'" 2>/dev/null || true
else
  log "(verification skipped in dry-run mode)"
fi

echo ""
log "Done -- expected: 1 ext-jwt-signer, 1 auth-policy, ${#OIDC_USERS[@]} OIDC identities, ${#KIOSKS[@]} kiosk identities"
