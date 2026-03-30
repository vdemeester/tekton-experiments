#!/usr/bin/env bash
# Setup a kind cluster with a local registry, Tekton Pipelines, and Tekton Chains.
#
# Usage:
#   ./hack/setup.sh          # Create cluster + install everything
#   ./hack/setup.sh teardown # Delete cluster + registry
#
# After setup:
#   export KUBECONFIG=/tmp/tekton-experiments.kubeconfig
#   kubectl get pods -n tekton-pipelines
#
# The local registry is available at:
#   localhost:5555        (from host)
#   registry.local:5555  (from inside the cluster)
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-tekton-experiments}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${CLUSTER_NAME}.kubeconfig}"
REGISTRY_NAME="${REGISTRY_NAME:-tekton-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5555}"
REGISTRY_HOST="localhost"

TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-v1.11.0}"
TEKTON_CHAINS_VERSION="${TEKTON_CHAINS_VERSION:-v0.26.2}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==> WARN:${NC} $*"; }
err()  { echo -e "${RED}==> ERROR:${NC} $*" >&2; }

# ── Teardown ────────────────────────────────────────────────────────
teardown() {
    log "Tearing down..."
    kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
    docker rm -f "${REGISTRY_NAME}" 2>/dev/null || true
    rm -f "${KUBECONFIG_PATH}"
    log "Done."
}

if [[ "${1:-}" == "teardown" ]]; then
    teardown
    exit 0
fi

# ── Prerequisites ───────────────────────────────────────────────────
for cmd in kind kubectl docker; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is required but not found"
        exit 1
    fi
done

# ── Local registry ──────────────────────────────────────────────────
if docker inspect "${REGISTRY_NAME}" &>/dev/null; then
    log "Registry ${REGISTRY_NAME} already running"
else
    log "Starting local registry on port ${REGISTRY_PORT}..."
    docker run -d --restart=always \
        -p "127.0.0.1:${REGISTRY_PORT}:5000" \
        --network bridge \
        --name "${REGISTRY_NAME}" \
        registry:2
fi

REGISTRY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${REGISTRY_NAME}")
log "Registry IP: ${REGISTRY_IP}"

# ── Kind cluster ────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log "Cluster ${CLUSTER_NAME} already exists"
else
    log "Creating kind cluster: ${CLUSTER_NAME}..."
    cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
EOF
fi

export KUBECONFIG="${KUBECONFIG_PATH}"

# ── Connect registry to kind network ───────────────────────────────
if ! docker network inspect kind | grep -q "${REGISTRY_NAME}"; then
    log "Connecting registry to kind network..."
    docker network connect kind "${REGISTRY_NAME}" 2>/dev/null || true
fi

# Configure containerd to use the local registry
REGISTRY_DIR="/etc/containerd/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    log "Configuring registry on node: ${node}"
    docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
    cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REGISTRY_NAME}:5000"]
EOF
done

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY_HOST}:${REGISTRY_PORT}"
    hostFromContainerRuntime: "${REGISTRY_NAME}:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# ── Install Tekton Pipelines ───────────────────────────────────────
log "Installing Tekton Pipelines ${TEKTON_PIPELINE_VERSION}..."
kubectl apply -f "https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml"

log "Waiting for Tekton Pipelines..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/tekton-pipelines-controller -n tekton-pipelines
kubectl wait --for=condition=available --timeout=120s \
    deployment/tekton-pipelines-webhook -n tekton-pipelines

# Enable alpha features (artifacts)
kubectl patch configmap feature-flags -n tekton-pipelines \
    --type merge -p '{"data":{"enable-artifacts":"true"}}'

log "Tekton Pipelines $(kubectl get deploy tekton-pipelines-controller -n tekton-pipelines \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}') ready"

# ── Install Tekton Chains ──────────────────────────────────────────
log "Installing Tekton Chains ${TEKTON_CHAINS_VERSION}..."
kubectl apply -f "https://infra.tekton.dev/tekton-releases/chains/previous/${TEKTON_CHAINS_VERSION}/release.yaml"

log "Waiting for Tekton Chains..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/tekton-chains-controller -n tekton-chains

log "Tekton Chains $(kubectl get deploy tekton-chains-controller -n tekton-chains \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}') ready"

# ── Configure Chains for OCI storage ───────────────────────────────
log "Configuring Chains for OCI storage with local registry..."

# Generate cosign key pair for signing
COSIGN_DIR=$(mktemp -d)
COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix="${COSIGN_DIR}/cosign" 2>/dev/null

# Replace the signing-secrets secret with our key pair
kubectl delete secret signing-secrets -n tekton-chains 2>/dev/null || true
kubectl create secret generic signing-secrets -n tekton-chains \
    --from-file=cosign.key="${COSIGN_DIR}/cosign.key" \
    --from-file=cosign.pub="${COSIGN_DIR}/cosign.pub" \
    --from-literal=cosign.password=""

# Copy public key for verification
cp "${COSIGN_DIR}/cosign.pub" "${KUBECONFIG_PATH%.kubeconfig}.cosign.pub"
rm -rf "${COSIGN_DIR}"

# Configure Chains:
# - OCI storage for TaskRun and PipelineRun attestations
# - Insecure registry (local HTTP registry)
# - SLSA v1 format
# - Deep inspection for PipelineRun (captures task-level results)
# - No storage.oci.repository → attestations stored alongside the image (as referrers)
kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
  "data": {
    "artifacts.taskrun.format": "slsa/v2alpha4",
    "artifacts.taskrun.storage": "oci",
    "artifacts.pipelinerun.format": "slsa/v2alpha4",
    "artifacts.pipelinerun.storage": "oci",
    "artifacts.pipelinerun.enable-deep-inspection": "true",
    "artifacts.oci.storage": "oci",
    "storage.oci.repository.insecure": "true"
  }
}'

# Restart Chains to pick up new config + keys
kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
kubectl wait --for=condition=available --timeout=60s \
    deployment/tekton-chains-controller -n tekton-chains

log "Chains configured (OCI storage, insecure registry, cosign keys generated)"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
log "Setup complete!"
echo ""
echo "  KUBECONFIG:     export KUBECONFIG=${KUBECONFIG_PATH}"
echo "  Registry:       ${REGISTRY_HOST}:${REGISTRY_PORT} (host)"
echo "                  ${REGISTRY_NAME}:5000 (in-cluster)"
echo ""
echo "  Push images:    docker tag myimage ${REGISTRY_HOST}:${REGISTRY_PORT}/myimage"
echo "                  docker push ${REGISTRY_HOST}:${REGISTRY_PORT}/myimage"
echo ""
echo "  In Tekton use:  ${REGISTRY_HOST}:${REGISTRY_PORT}/tekton-experiments"
echo ""
echo "  Teardown:       ./hack/setup.sh teardown"
