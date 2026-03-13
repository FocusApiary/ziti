# om-labs/ziti

OpenZiti ZTNA deployment for buck-lab k8s. Zero Trust Network Access for internal services without public exposure.

## Architecture

- **Controller**: manages identities, policies, PKI. Runs as a StatefulSet with BoltDB on longhorn-r2.
- **Router**: data-plane edge router. Enrolls against the controller, handles tunneled traffic.
- **Harbor**: upstream OpenZiti images mirrored to `harbor.focuscell.org/openziti/` for supply-chain control.
- **Azure backup tunnel**: the `ziti-edge-tunnel` image is promoted from Harbor into ACR by an in-cluster CronJob so Azure ACI never has to pull directly from Harbor.
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

# Validate vLLM API access over Ziti edge identity
scripts/validate_vllm_edge_access.sh --identity /etc/ziti/identities/matthew-laptop.json

# Validate vLLM service visibility with Keycloak/OIDC JWT (no local identity file)
scripts/validate_vllm_edge_access.sh --ext-jwt /tmp/seanh-openziti.jwt
```

Validation exits:
- `0`: `api-vllm-hardmagic` visible and `/health` + `/v1/models` pass over Ziti.
- `2`: service not visible for identity (role/policy gap).
- `3`: service visible but endpoint checks fail through proxy.

Notes:
- The validator now paginates `/edge/client/v1/services` to avoid false negatives on large service sets.
- `--ext-jwt` runs visibility-only validation (proxy checks require `--identity`).

## Repo Layout

```
k8s/
  manifests/          Namespace, backup-proxy, backup image sync CronJob
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
| gitea | `git.developerdojo.org/focusapiary/ziti` | Source of truth |
| github | `github.com/FocusApiary/ziti` | Mirror |
