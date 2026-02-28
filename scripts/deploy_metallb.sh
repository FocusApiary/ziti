#!/usr/bin/env bash
set -euo pipefail

# Deploy MetalLB load balancer with L2 mode for bare-metal clusters.
#
# Installs MetalLB via Helm and applies the IPAddressPool + L2Advertisement
# CRDs. Idempotent: safe to re-run.
#
# Usage:
#   scripts/deploy_metallb.sh                # install/upgrade
#   DRY_RUN=1 scripts/deploy_metallb.sh      # helm template only
#
# Override IP pool by editing k8s/metallb/ip-pool.yaml before running.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${DRY_RUN:-}"
METALLB_VERSION="${METALLB_VERSION:-0.15.3}"
METALLB_NS="metallb-system"

# ---------- helpers ----------------------------------------------------------

log() { printf '[%s] ==> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# ---------- prerequisites ----------------------------------------------------

if ! command -v helm &>/dev/null; then
  warn "helm not found in PATH"
  exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
  warn "Cannot reach k8s cluster"
  exit 1
fi

# ---------- helm repo --------------------------------------------------------

log "Adding MetalLB Helm repo"
helm repo add metallb https://metallb.github.io/metallb --force-update
helm repo update metallb

# ---------- install / upgrade ------------------------------------------------

if [[ -n "$DRY_RUN" ]]; then
  log "DRY_RUN mode — rendering template only"
  helm template metallb metallb/metallb \
    --namespace "$METALLB_NS" \
    --version "$METALLB_VERSION"
  exit 0
fi

log "Installing/upgrading MetalLB v${METALLB_VERSION}"
helm upgrade --install metallb metallb/metallb \
  --namespace "$METALLB_NS" \
  --create-namespace \
  --version "$METALLB_VERSION" \
  --wait --timeout 120s

# ---------- wait for controller ----------------------------------------------

log "Waiting for MetalLB controller to be ready"
kubectl -n "$METALLB_NS" rollout status deploy/metallb-controller --timeout=90s

# ---------- apply IP pool + L2 advertisement ---------------------------------

log "Applying IPAddressPool + L2Advertisement"
kubectl apply -f "$ROOT_DIR/k8s/metallb/ip-pool.yaml"

# ---------- verify -----------------------------------------------------------

log "Verifying MetalLB resources"
kubectl -n "$METALLB_NS" get ipaddresspool,l2advertisement

LB_IP=$(kubectl -n envoy-gateway-system get svc \
  -l "gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -n "$LB_IP" ]]; then
  log "Envoy Gateway LoadBalancer IP: $LB_IP"
else
  warn "Envoy Gateway does not yet have a LoadBalancer IP — check the IPAddressPool range"
fi

log "Done"
