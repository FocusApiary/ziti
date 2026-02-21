#!/usr/bin/env bash
set -euo pipefail

# Mirror upstream OpenZiti container images to Harbor.
#
# Uses skopeo (daemonless image copy) — the right tool for mirroring.
# Kaniko is for builds; skopeo is for registry-to-registry copies.
#
# Prerequisites:
#   - skopeo installed
#   - docker/podman login to Harbor already done, OR
#     HARBOR_USER + HARBOR_PASS set
#
# Usage:
#   scripts/sync_images.sh                    # sync all images
#   ZITI_TAG=1.2.0 scripts/sync_images.sh     # pin a specific tag

HARBOR_HOST="${HARBOR_HOST:-harbor.focuscell.org}"
HARBOR_PROJECT="${HARBOR_PROJECT:-openziti}"
ZITI_TAG="${ZITI_TAG:-1.7.2}"
DEST_TLS_VERIFY="${DEST_TLS_VERIFY:-false}"

# Upstream images to mirror.
IMAGES=(
  "docker.io/openziti/ziti-controller"
  "docker.io/openziti/ziti-router"
  "docker.io/openziti/zac"
)

log() { echo "==> $*"; }

# Harbor auth (if not already logged in via docker/podman credential store).
if [[ -n "${HARBOR_USER:-}" ]] && [[ -n "${HARBOR_PASS:-}" ]]; then
  DEST_CREDS="--dest-creds ${HARBOR_USER}:${HARBOR_PASS}"
else
  DEST_CREDS=""
fi

for src in "${IMAGES[@]}"; do
  name="${src##*/}"
  dest="docker://${HARBOR_HOST}/${HARBOR_PROJECT}/${name}:${ZITI_TAG}"

  log "Syncing ${src}:${ZITI_TAG} -> ${dest}"
  # shellcheck disable=SC2086
  skopeo copy \
    "docker://${src}:${ZITI_TAG}" \
    "$dest" \
    $DEST_CREDS \
    --dest-tls-verify="$DEST_TLS_VERIFY" \
    --retry-times 3
done

log "All images synced to ${HARBOR_HOST}/${HARBOR_PROJECT}"
