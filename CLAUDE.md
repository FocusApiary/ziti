# OpenZiti ZTNA — FocusApiary/ziti

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
- Node placement: `focusapiary.com/storage-node: "true"`
- Images: mirrored to Harbor (`harbor.focuscell.org/openziti/`), never pulled from Docker Hub at runtime

## Hostnames (3-level for Cloudflare compat)

- Controller: `ziti.focuspass.com`
- Router: `ziti-router.focuspass.com`

## Service Routing (ZTNA)

All internal services are routed through the Ziti overlay via Envoy Gateway:

```
Client -> Ziti Desktop Edge -> Ziti overlay -> Router (host mode)
  -> envoy-main-lan-vip.envoy-gateway-system.svc:443 -> backend
```

### Core Services (attribute: #core-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| keycloak | auth.focuspass.com | 443 | OIDC provider |
| mattermost | chat.focusbuzz.org | 443 | |
| slidee | dev.slidee.net | 443 | |
| vaultwarden | vault.focuspass.com | 443 | |
| coder | developerdojo.org | 443 | Main Coder UI |
| coder-wildcard | *.developerdojo.org | 443 | KasmVNC/filebrowser subdomains |
| fleet | fleet.focuspass.com | 443 | |
| draw-hardmagic | draw.hardmagic.com | 443 | Excalidraw whiteboard |
| excalidraw-collab | collab.hardmagic.com | 443 | Excalidraw real-time collab |
| studio-hardmagic | studio.hardmagic.com | 443 | |
| api-studio-hardmagic | api.studio.hardmagic.com | 443 | |
| studio-hypersight | studio.hypersight.net | 443 | |

### Dev Services (attribute: #dev-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| harbor | harbor.focuscell.org | 443 | |
| argocd | argocd.focuscell.org | 443 | ssl-passthrough (gRPC) |
| gitlab | git.developerdojo.org | 443 | GitLab EE (HTTPS only, no SSH) |

### Cluster Services (attribute: #cluster-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| longhorn | longhorn.focuscell.org | 443 | |
| seaweedfs-api | s3.focuscell.org | 443 | |
| seaweedfs-console | files.focuscell.org | 443 | |
| k8s-api | api.buck-lab.focuscell.org | 6443 | TLS passthrough to K8s API server |

### VoIP Services (attribute: #voip-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| pbx-admin | admin.focuscell.org | 443 | |
| pbx-webrtc | pbx.focuscell.org | 443 | |
| pbx-api | api.focuscell.org | 443 | |

### OpenClaw Services (5, attribute: #openclaw-services)

| Service | Hostname | Port | Notes |
|---------|----------|------|-------|
| openclaw-dashboard | agents.focuschef.com | 443 | Dashboard UI |
| openclaw-admin | admin.focuschef.com | 443 | Admin panel |
| openclaw-hira | hira.focuschef.com | 443 | HR agent |
| openclaw-lisa | lisa.focuschef.com | 443 | Recruitment agent |
| openclaw-cody | cody.focuschef.com | 443 | Engineering agent |

### Ziti Configs (27)

- 1 shared `host.v1` (ingress-host) — routes to Envoy Gateway ClusterIP:443
- 1 `host.v1` (k8s-api-host) — routes to Envoy Gateway ClusterIP:6443
- 25 `intercept.v1` configs — one per service hostname

### Ziti Policies (10 service-policies, 1 edge-router-policy, 5 service-edge-router-policies)

- **bind-core-services** (Bind) — `#routers` -> `#core-services`
- **bind-dev-services** (Bind) — `#routers` -> `#dev-services`
- **bind-cluster-services** (Bind) — `#routers` -> `#cluster-services`
- **bind-openclaw** (Bind) — `#routers` -> `#openclaw-services`
- **bind-voip-services** (Bind) — `#routers` -> `#voip-services`
- **dial-core-services** (Dial) — `#member` -> `#core-services`
- **dial-dev-services** (Dial) — `#engineering` -> `#dev-services`
- **dial-cluster-services** (Dial) — `#infra-admin` -> `#cluster-services`
- **dial-openclaw** (Dial) — `#openclaw-admin` -> `#openclaw-services`
- **dial-voip-services** (Dial) — `#member` -> `#voip-services`
- **all-members-all-routers** (edge-router-policy) — `#member` -> `#all` routers
- **core-all-routers** (service-edge-router-policy) — `#core-services` -> `#all` routers
- **dev-all-routers** (service-edge-router-policy) — `#dev-services` -> `#all` routers
- **cluster-all-routers** (service-edge-router-policy) — `#cluster-services` -> `#all` routers
- **openclaw-all-routers** (service-edge-router-policy) — `#openclaw-services` -> `#all` routers
- **voip-all-routers** (service-edge-router-policy) — `#voip-services` -> `#all` routers

### CoreDNS Entries (in-cluster resolution)

Required for services that do OIDC validation or cross-service calls:
- `auth.focuspass.com` -> Envoy Gateway ClusterIP
- `argocd.focuscell.org` -> Envoy Gateway ClusterIP
- `git.developerdojo.org` -> Envoy Gateway ClusterIP

### Execution Order

1. Deploy MetalLB: `make deploy-metallb`
2. Patch CoreDNS: `scripts/patch_coredns.sh`
3. Configure services: `scripts/configure_services.sh`
4. Create DNS CNAMEs: `ziti.focuspass.com` + `ziti-router.focuspass.com` -> DC DDNS hostname (CF grey cloud)
5. Configure router port forward: WAN 443 -> MetalLB IP:443
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
ziti.focuspass.com         -> CNAME -> <dc-ddns-hostname>
ziti-router.focuspass.com  -> CNAME -> <dc-ddns-hostname>
```

- CNAME targets the DC's DDNS hostname (e.g., `2405-45th.ddns.net` for buck-lab)
- CF proxy must be OFF (grey cloud) — Ziti does its own mTLS
- Router port forward: WAN 443 -> MetalLB IP:443

## Important

- ssl-passthrough on ingress is REQUIRED — OpenZiti does its own mTLS
- trust-manager must be configured with `app.trust.namespace=ziti` (not default cert-manager)
- CoreDNS hosts entry maps `ziti.focuspass.com` to controller ClusterIP for in-cluster enrollment
- Controller must be fully up before router enrollment
- Router enrollment JWT is one-time; the k8s secret preserves it for re-deploys
- Chart versions: ziti-controller 3.0.0 (app 1.7.2), ziti-router 2.0.0 (app 1.7.2)
- ArgoCD ingress requires `ssl-passthrough: "true"` (gRPC + HTTPS on same port)
- Coder wildcard (`*.developerdojo.org`) enables subdomain-based workspace apps (KasmVNC, filebrowser)

## Bugs Encountered During Initial Deploy

- `runAsNonRoot` fails with non-numeric user `ziggy` — must set `runAsUser: 2171` explicitly
- trust-manager default trust namespace is cert-manager, not the release namespace — requires `app.trust.namespace=ziti`
- Controller ClusterIP changes on reinstall — CoreDNS hosts entry must be updated
- CF API token in AKV (`cloudflare-api-token`) lacks DNS record permissions for focuspass.com zone
