# om-labs/ziti

OpenZiti ZTNA deployment for buck-lab k8s. Zero Trust Network Access for internal services without public exposure.

## Architecture

- **Controller**: manages identities, policies, PKI. Runs as a StatefulSet with BoltDB on longhorn-r2.
- **Router**: data-plane edge router. Enrolls against the controller, handles tunneled traffic.
- **Harbor**: upstream OpenZiti images mirrored to `harbor.focuscell.org/openziti/` for supply-chain control.
- **ArgoCD**: optional GitOps sync from this repo's Helm values.

## Deployment Pipeline

```
Gitea (source of truth) -> Gitea Actions CI -> Harbor (image mirror) -> k8s
                        -> GitHub (push mirror)
```

## Quick Start

```bash
# Full deploy (controller + router)
scripts/deploy.sh

# Controller only
SKIP_ROUTER=1 scripts/deploy.sh

# Mirror upstream images to Harbor
scripts/sync_images.sh

# Extract & store secrets in AKV
scripts/store_secrets.sh

# Rotate/reconcile router enrollment JWT (AKV + Kubernetes)
scripts/rotate_router_jwt.sh
```

## Repo Layout

```
k8s/
  manifests/          Namespace, ServiceAccount
  controller/         ziti-controller Helm values
  router/             ziti-router Helm values
  argocd/             ArgoCD Application manifests
scripts/
  deploy.sh           Idempotent full deploy
  sync_images.sh      Mirror upstream -> Harbor
  store_secrets.sh    Extract k8s secrets -> AKV
  rotate_router_jwt.sh Re-enroll router and upsert enrollment JWT
```

## Overlay Pattern

Base values in `k8s/<component>/values.yaml`, per-cluster overrides in `k8s/<component>/overlays/<cluster>/values.yaml`. Deploy script merges both.

## Secrets

All secrets stored in Azure Key Vault `omlab-secrets`:
- `ziti-admin-password` — controller admin credential
- `ziti-ctrl-root-ca` — controller root CA (needed by routers)
- `ziti-ctrl-signing-cert` — controller signing cert
- `ziti-router-buck-lab-router-01-jwt` — router enrollment token (for re-enrollment/recovery)

## Remotes

| Remote | URL | Role |
|--------|-----|------|
| gitea | `buck-git.omlabs.org/om-labs/ziti` | Source of truth |
| github | `github.com/Om-Labs/ziti` | Mirror |
