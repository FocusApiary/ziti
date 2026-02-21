# OpenZiti ZTNA — om-labs/ziti

## What This Repo Is

GitOps repo for OpenZiti ZTNA on buck-lab k8s. Controller + router deployed via Helm, images mirrored through Harbor, secrets in AKV `omlab-secrets`.

## Deployment Strategy

GitHub (source of truth) -> CI (lint + image sync to Harbor) -> ArgoCD or deploy script -> k8s.

## Key Patterns

- Helm values: base in `k8s/<component>/values.yaml`, overrides in `overlays/<cluster>/values.yaml`
- All scripts idempotent (`set -euo pipefail`, `helm upgrade --install`, `kubectl apply`)
- SOPS+age for any encrypted secrets in-repo
- Pod security: baseline enforce, restricted audit/warn
- Container hardening: runAsUser 2171 (ziggy), drop ALL caps, seccomp RuntimeDefault
- Storage: longhorn-r2 for persistent volumes
- Node placement: `om-labs.io/storage-node: "true"`
- Images: mirrored to Harbor (`harbor.focuscell.org/openziti/`), never pulled from Docker Hub at runtime

## Hostnames (3-level for Cloudflare compat)

- Controller: `ziti-ctrl-buck.omlabs.org`
- Router: `ziti-router-buck.omlabs.org`

## Service Routing (ZTNA)

All internal services are routed through the Ziti overlay via nginx ingress:

```
Client → Ziti Desktop Edge → Ziti overlay → Router (host mode)
  → ingress-nginx-controller.ingress-nginx.svc:443 → backend
```

### Internal Services (12, attribute: #internal-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| harbor | harbor.focuscell.org | 443 | |
| keycloak | auth-buck.omlabs.org | 443 | OIDC provider |
| longhorn | longhorn.buck-lab-k8s.omlabs.org | 443 | |
| mattermost | chat.focusjam.com | 443 | |
| minio-api | minio.buck-lab-k8s.omlabs.org | 443 | |
| minio-console | minio-console.buck-lab-k8s.omlabs.org | 443 | |
| slidee | dev.slidee.net | 443 | |
| vaultwarden | vault.omlabs.org | 443 | |
| coder | developerdojo.org | 443 | Main Coder UI |
| coder-wildcard | *.developerdojo.org | 443 | KasmVNC/filebrowser subdomains |
| argocd | argocd-buck.omlabs.org | 443 | ssl-passthrough (gRPC) |
| gitlab | gitlab-buck.omlabs.org | 443 | GitLab EE (HTTPS only, no SSH) |

### OpenClaw Services (5, attribute: #openclaw-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| openclaw-dashboard | agents-buck.omlabs.org | 443 | Dashboard UI |
| openclaw-admin | admin.focuschef.com | 443 | Admin panel |
| openclaw-hira | hira-buck.omlabs.org | 443 | HR agent |
| openclaw-lisa | lisa-buck.omlabs.org | 443 | Recruitment agent |
| openclaw-cody | cody-buck.omlabs.org | 443 | Engineering agent |

### Ziti Configs (18)

- 1 shared `host.v1` (nginx-ingress-host) — routes to nginx ingress ClusterIP:443
- 17 `intercept.v1` configs — one per service hostname

### Ziti Policies (7)

- **bind-all-services** (Bind) — `#routers` → `#internal-services`
- **bind-openclaw** (Bind) — `#routers` → `#openclaw-services`
- **dial-all-services** (Dial) — `#employees` → `#internal-services`
- **dial-openclaw** (Dial) — `#openclaw-admin` → `#openclaw-services`
- **all-employees-all-routers** (edge-router-policy) — `#employees` → `#all` routers
- **all-services-all-routers** (service-edge-router-policy) — `#internal-services` → `#all` routers
- **openclaw-all-routers** (service-edge-router-policy) — `#openclaw-services` → `#all` routers

### CoreDNS Entries (in-cluster resolution)

Required for services that do OIDC validation or cross-service calls:
- `auth-buck.omlabs.org` → nginx ingress ClusterIP
- `argocd-buck.omlabs.org` → nginx ingress ClusterIP
- `gitlab-buck.omlabs.org` → nginx ingress ClusterIP

### Execution Order

1. Deploy MetalLB: `make deploy-metallb`
2. Patch CoreDNS: `scripts/patch_coredns.sh`
3. Configure services: `scripts/configure_services.sh`
4. Create DNS CNAMEs: `ziti-ctrl-buck` + `ziti-router-buck` → DC DDNS hostname (CF grey cloud)
5. Configure router port forward: WAN 443 → MetalLB IP:443
6. Create test identities: `scripts/create_identities.sh <name>`
7. Verify from enrolled laptop + mobile, then create remaining identities
8. Remove Cloudflare tunnel
9. (Later) Switch cert-manager to DNS-01

## Load Balancer (MetalLB)

MetalLB L2 mode provides LoadBalancer IPs for bare-metal clusters. Deployed via `make deploy-metallb`.

- IP pool: `192.168.1.200-192.168.1.210` (edit `k8s/metallb/ip-pool.yaml` per DC)
- Ingress gets `192.168.1.200` as its external IP
- Chart: metallb v0.15.3

## DNS (External Access)

Controller + router must be publicly reachable for client enrollment and data plane:

```
ziti-ctrl-buck.omlabs.org   → CNAME → <dc-ddns-hostname>
ziti-router-buck.omlabs.org → CNAME → <dc-ddns-hostname>
```

- CNAME targets the DC's DDNS hostname (e.g., `2405-45th.ddns.net` for buck-lab)
- CF proxy must be OFF (grey cloud) — Ziti does its own mTLS
- Router port forward: WAN 443 → MetalLB IP:443

## Important

- ssl-passthrough on ingress-nginx is REQUIRED — OpenZiti does its own mTLS
- trust-manager must be configured with `app.trust.namespace=ziti` (not default cert-manager)
- CoreDNS hosts entry maps `ziti-ctrl-buck.omlabs.org` to controller ClusterIP for in-cluster enrollment
- Controller must be fully up before router enrollment
- Router enrollment JWT is one-time; the k8s secret preserves it for re-deploys
- Chart versions: ziti-controller 3.0.0 (app 1.7.2), ziti-router 2.0.0 (app 1.7.2)
- ArgoCD ingress requires `ssl-passthrough: "true"` (gRPC + HTTPS on same port)
- Coder wildcard (`*.developerdojo.org`) enables subdomain-based workspace apps (KasmVNC, filebrowser)

## Bugs Encountered During Initial Deploy

- `runAsNonRoot` fails with non-numeric user `ziggy` — must set `runAsUser: 2171` explicitly
- trust-manager default trust namespace is cert-manager, not the release namespace — requires `app.trust.namespace=ziti`
- Controller ClusterIP changes on reinstall — CoreDNS hosts entry must be updated
- CF API token in AKV (`cloudflare-api-token`) lacks DNS record permissions for omlabs.org zone
