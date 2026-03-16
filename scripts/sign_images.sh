#!/usr/bin/env bash
set -euo pipefail

# Sign patched Ziti container images in Harbor using Notation + Azure KV.
#
# Dispatches a Kubernetes Job in the ci namespace that resolves the image
# digest, then signs it with Notation using the Azure Key Vault plugin.
#
# Prerequisites:
#   - kubectl access to the cluster
#   - Secrets/ConfigMaps in ci namespace:
#       notation-signing   (key-id, client-id, client-secret, tenant-id)
#       harbor-infra-push  (config.json with Harbor creds)
#       harbor-ca          (ConfigMap with harbor-ca.crt)
#   - ServiceAccount: builder (in ci namespace)
#
# Usage:
#   scripts/sign_images.sh                             # sign both controller + router
#   IMAGE_TAG=2.0.0-pre2-patched scripts/sign_images.sh  # explicit tag

HARBOR_PROJECT="${HARBOR_PROJECT:-infra}"
IMAGE_TAG="${IMAGE_TAG:-2.0.0-pre2-patched}"
SIGN_NAMESPACE="${SIGN_NAMESPACE:-ci}"
SIGN_TIMEOUT="${SIGN_TIMEOUT:-600}"
SIGN_IMAGE="${SIGN_IMAGE:-harbor.focuscell.org/dockerhub-proxy/debian:bookworm-slim}"
HARBOR_PUSH_SECRET="${HARBOR_PUSH_SECRET:-harbor-infra-push}"
REGISTRY="harbor.harbor.svc.cluster.local"

IMAGES=(
  "ziti-controller"
  "ziti-router"
)

log() { echo "==> $*"; }

sign_image() {
  local image_name="$1"
  local repository="${HARBOR_PROJECT}/${image_name}"
  local job_name="sign-${image_name}-$(date +%s)"

  log "Creating sign job for ${REGISTRY}/${repository}:${IMAGE_TAG}"

  cat > /tmp/sign-job-${image_name}.yaml <<EOJOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${SIGN_NAMESPACE}
  labels:
    app: ${image_name}-sign
    pipeline: notation
spec:
  ttlSecondsAfterFinished: 3600
  activeDeadlineSeconds: ${SIGN_TIMEOUT}
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: ${image_name}-sign
    spec:
      serviceAccountName: builder
      restartPolicy: Never
      initContainers:
        - name: prepare-certs
          image: ${SIGN_IMAGE}
          securityContext:
            allowPrivilegeEscalation: false
          command: ["bash", "-c"]
          args:
            - |
              set -euo pipefail
              apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null 2>&1
              cp /etc/ssl/certs/ca-certificates.crt /ssl/ca-certificates.crt
              cat /certs/harbor-ca.crt >> /ssl/ca-certificates.crt
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
          volumeMounts:
            - name: harbor-ca
              mountPath: /certs/harbor-ca.crt
              subPath: harbor-ca.crt
              readOnly: true
            - name: ssl-certs
              mountPath: /ssl
        - name: prepare-notation
          image: ${SIGN_IMAGE}
          securityContext:
            allowPrivilegeEscalation: false
          command: ["bash", "-c"]
          args:
            - |
              set -euo pipefail
              apt-get update -qq && apt-get install -y -qq wget >/dev/null 2>&1
              NOTATION_VERSION="1.3.0"
              PLUGIN_VERSION="1.2.1"
              mkdir -p /tools/plugins/azure-kv
              wget -q "https://github.com/notaryproject/notation/releases/download/v\${NOTATION_VERSION}/notation_\${NOTATION_VERSION}_linux_amd64.tar.gz" -O /tmp/n.tar.gz
              tar --no-same-owner -xzf /tmp/n.tar.gz -C /tools notation
              wget -q "https://github.com/Azure/notation-azure-kv/releases/download/v\${PLUGIN_VERSION}/notation-azure-kv_\${PLUGIN_VERSION}_linux_amd64.tar.gz" -O /tmp/p.tar.gz
              tar --no-same-owner -xzf /tmp/p.tar.gz -C /tools/plugins/azure-kv
              chmod +x /tools/notation /tools/plugins/azure-kv/notation-azure-kv
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: tools
              mountPath: /tools
      containers:
        - name: sign
          image: ${SIGN_IMAGE}
          securityContext:
            allowPrivilegeEscalation: false
          command: ["bash", "-c"]
          args:
            - |
              set -euo pipefail
              apt-get update -qq && apt-get install -y -qq curl jq >/dev/null 2>&1
              export SSL_CERT_FILE=/ssl/ca-certificates.crt
              export XDG_CONFIG_HOME=/tmp
              export DOCKER_CONFIG=/docker

              AUTH=\$(jq -r '.auths["harbor.harbor.svc.cluster.local"].auth // .auths["harbor.focuscell.org"].auth // empty' /docker/config.json)
              [ -n "\${AUTH}" ] || { echo "missing Harbor auth in /docker/config.json"; exit 1; }
              AUTH=\$(printf '%s' "\${AUTH}" | base64 -d)
              USER=\${AUTH%%:*}
              PASS=\${AUTH#*:}

              DIGEST=\$(curl -fsS --cacert /ssl/ca-certificates.crt -u "\${USER}:\${PASS}" \
                -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
                -I "https://${REGISTRY}/v2/${repository}/manifests/${IMAGE_TAG}" 2>/dev/null \
                | grep -i docker-content-digest | tr -d '\r' | awk '{print \$2}')
              [ -n "\${DIGEST}" ] && [ "\${DIGEST}" != "null" ] || {
                echo "failed to resolve digest for ${REGISTRY}/${repository}:${IMAGE_TAG}";
                exit 1;
              }
              echo "Resolved digest: \${DIGEST}"

              mkdir -p "\${XDG_CONFIG_HOME}/notation/plugins/azure-kv"
              cp /tools/plugins/azure-kv/notation-azure-kv "\${XDG_CONFIG_HOME}/notation/plugins/azure-kv/"

              /tools/notation sign \
                --signature-format cose \
                --id "\${NOTATION_KEY_ID}" \
                --plugin azure-kv \
                --plugin-config self_signed=true \
                --plugin-config credential_type=environment \
                "${REGISTRY}/${repository}@\${DIGEST}"
              echo "Signed ${REGISTRY}/${repository}@\${DIGEST}"
          env:
            - name: NOTATION_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: notation-signing
                  key: key-id
            - name: AZURE_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: notation-signing
                  key: client-id
            - name: AZURE_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: notation-signing
                  key: client-secret
            - name: AZURE_TENANT_ID
              valueFrom:
                secretKeyRef:
                  name: notation-signing
                  key: tenant-id
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: harbor-push-creds
              mountPath: /docker
              readOnly: true
            - name: ssl-certs
              mountPath: /ssl
              readOnly: true
            - name: tools
              mountPath: /tools
              readOnly: true
      volumes:
        - name: harbor-push-creds
          secret:
            secretName: ${HARBOR_PUSH_SECRET}
            items:
              - key: config.json
                path: config.json
        - name: harbor-ca
          configMap:
            name: harbor-ca
            items:
              - key: harbor-ca.crt
                path: harbor-ca.crt
        - name: ssl-certs
          emptyDir: {}
        - name: tools
          emptyDir: {}
EOJOB

  kubectl apply -f /tmp/sign-job-${image_name}.yaml

  log "Waiting for job ${job_name} to complete (timeout ${SIGN_TIMEOUT}s)..."
  local end=$((SECONDS + SIGN_TIMEOUT))
  local types=""
  while [ $SECONDS -lt $end ]; do
    types=$(kubectl get job -n "${SIGN_NAMESPACE}" "${job_name}" \
      -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true)
    case " $types " in
      *" Complete "*)
        log "Job ${job_name} completed successfully"
        kubectl logs -n "${SIGN_NAMESPACE}" "job/${job_name}" --all-containers --tail=100
        return 0
        ;;
      *" Failed "*)
        log "=== Sign job ${job_name} failed ==="
        kubectl logs -n "${SIGN_NAMESPACE}" "job/${job_name}" --all-containers --tail=100
        kubectl delete job -n "${SIGN_NAMESPACE}" "${job_name}" 2>/dev/null || true
        return 1
        ;;
    esac
    sleep 5
  done

  log "=== Sign job ${job_name} timed out ==="
  kubectl logs -n "${SIGN_NAMESPACE}" "job/${job_name}" --all-containers --tail=100
  kubectl delete job -n "${SIGN_NAMESPACE}" "${job_name}" 2>/dev/null || true
  return 1
}

for image in "${IMAGES[@]}"; do
  sign_image "$image"
done

log "All images signed"
