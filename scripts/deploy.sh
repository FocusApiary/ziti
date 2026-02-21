#!/usr/bin/env bash
set -euo pipefail

# Idempotent deployment of OpenZiti controller + router on buck-lab k8s.
#
# Usage:
#   scripts/deploy.sh                          # full deploy
#   SKIP_ROUTER=1 scripts/deploy.sh            # controller only
#   ZITI_OVERLAY=buck-lab scripts/deploy.sh     # explicit overlay

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OVERLAY="${ZITI_OVERLAY:-buck-lab}"
CTRL_CHART_VERSION="${ZITI_CTRL_CHART_VERSION:-3.0.0}"
ROUTER_CHART_VERSION="${ZITI_ROUTER_CHART_VERSION:-2.0.0}"
SKIP_ROUTER="${SKIP_ROUTER:-}"
HARBOR_HOST="${HARBOR_HOST:-harbor.focuscell.org}"
AKV_NAME="${AKV_NAME:-omlab-secrets}"

# ---------- helpers ----------------------------------------------------------

log() { echo "==> $*"; }

wait_for_rollout() {
  local ns="$1" resource="$2" timeout="${3:-300}"
  kubectl -n "$ns" rollout status "$resource" --timeout="${timeout}s" || true
}

# ---------- 1. namespace + service account -----------------------------------

log "Applying namespace"
kubectl apply -f k8s/manifests/namespace.yaml

log "Applying service account"
kubectl apply -f k8s/manifests/serviceaccount.yaml

# ---------- 2. Envoy Gateway (TLS passthrough is native — no patching needed) -

log "Envoy Gateway handles TLS passthrough natively via TLSRoute — skipping"

# ---------- 3. helm repo ----------------------------------------------------

log "Adding openziti Helm repo"
helm repo add openziti https://docs.openziti.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null

# ---------- 4. deploy controller --------------------------------------------

log "Installing/upgrading ziti-controller (chart $CTRL_CHART_VERSION)"

ctrl_extra=()
if [[ -f "k8s/controller/overlays/${OVERLAY}/values.yaml" ]]; then
  ctrl_extra+=( -f "k8s/controller/overlays/${OVERLAY}/values.yaml" )
fi

helm upgrade --install ziti-controller openziti/ziti-controller \
  --namespace ziti \
  --version "$CTRL_CHART_VERSION" \
  -f k8s/controller/values.yaml \
  "${ctrl_extra[@]}"

log "Waiting for controller"
wait_for_rollout ziti deploy/ziti-controller 300

kubectl -n ziti get pods -o wide
kubectl -n ziti get svc

# ---------- 5. store secrets in AKV ------------------------------------------

log "Storing secrets in AKV ($AKV_NAME)"
"$ROOT_DIR/scripts/store_secrets.sh"

# ---------- 6. deploy router ------------------------------------------------

if [[ -n "$SKIP_ROUTER" ]]; then
  log "SKIP_ROUTER set — skipping router deployment"
  exit 0
fi

# Ensure router enrollment JWT exists as a k8s secret.
ROUTER_NAME="${ZITI_ROUTER_NAME:-buck-lab-router-01}"
JWT_SECRET="ziti-router-${ROUTER_NAME}-jwt"

if kubectl -n ziti get secret "$JWT_SECRET" >/dev/null 2>&1; then
  log "Router enrollment JWT secret ($JWT_SECRET) already exists"
else
  log "Creating edge-router '$ROUTER_NAME' and storing enrollment JWT"

  # Exec into the controller pod to create the router.
  CTRL_POD=$(kubectl -n ziti get pod -l app.kubernetes.io/name=ziti-controller \
    -o jsonpath='{.items[0].metadata.name}')

  # Login as admin.
  ADMIN_PW=$(kubectl -n ziti get secret ziti-controller-admin-secret \
    -o jsonpath='{.data.admin-password}' | base64 -d)

  kubectl -n ziti exec "$CTRL_POD" -- sh -c "
    ziti edge login localhost:${CTRL_MGMT_PORT:-1280} -u admin -p '$ADMIN_PW' --yes &&
    ziti edge create edge-router '$ROUTER_NAME' \
      -o /tmp/router.jwt \
      --jwt-output-file /tmp/router.jwt \
      --tunneler-enabled 2>/dev/null || true
  "

  # Extract JWT from the pod.
  ROUTER_JWT=$(kubectl -n ziti exec "$CTRL_POD" -- cat /tmp/router.jwt)

  # Create k8s secret with the JWT (key must be "enrollmentJwt" for the chart).
  kubectl -n ziti create secret generic "$JWT_SECRET" \
    --from-literal=enrollmentJwt="$ROUTER_JWT" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

log "Installing/upgrading ziti-router (chart $ROUTER_CHART_VERSION)"

router_extra=()
if [[ -f "k8s/router/overlays/${OVERLAY}/values.yaml" ]]; then
  router_extra+=( -f "k8s/router/overlays/${OVERLAY}/values.yaml" )
fi

helm upgrade --install ziti-router openziti/ziti-router \
  --namespace ziti \
  --version "$ROUTER_CHART_VERSION" \
  -f k8s/router/values.yaml \
  "${router_extra[@]}" \
  --set "enrollmentJwtFromSecret=true" \
  --set "enrollmentJwtSecretName=$JWT_SECRET"

log "Waiting for router"
wait_for_rollout ziti deploy/ziti-router 300

kubectl -n ziti get pods -o wide
kubectl -n ziti get svc

# ---------- 7. verify -------------------------------------------------------

log "Verifying deployment"

CTRL_POD=$(kubectl -n ziti get pod -l app.kubernetes.io/name=ziti-controller \
  -o jsonpath='{.items[0].metadata.name}')

ADMIN_PW=$(kubectl -n ziti get secret ziti-controller-admin-secret \
  -o jsonpath='{.data.admin-password}' | base64 -d)

kubectl -n ziti exec "$CTRL_POD" -- sh -c "
  ziti edge login localhost:${CTRL_MGMT_PORT:-1280} -u admin -p '$ADMIN_PW' --yes &&
  echo '--- Edge Routers ---' &&
  ziti edge list edge-routers
" || log "WARNING: verification failed (controller may still be initializing)"

log "Done"
