#!/usr/bin/env bash
# Setup a kind cluster with a local registry, Tekton Pipelines, Tekton Chains, and Tekton Results.
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
export KUBECONFIG="${KUBECONFIG_PATH}"
REGISTRY_NAME="${REGISTRY_NAME:-tekton-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5555}"
REGISTRY_HOST="localhost"

TEKTON_PIPELINE_VERSION="${TEKTON_PIPELINE_VERSION:-v1.11.0}"
TEKTON_CHAINS_VERSION="${TEKTON_CHAINS_VERSION:-v0.26.2}"
TEKTON_RESULTS_VERSION="${TEKTON_RESULTS_VERSION:-v0.18.0}"

# External registry (optional)
EXTERNAL_REGISTRY=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==> WARN:${NC} $*"; }
err()  { echo -e "${RED}==> ERROR:${NC} $*" >&2; }

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        teardown)
            # Handle below
            TEARDOWN=true
            shift
            ;;
        --registry)
            EXTERNAL_REGISTRY="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ── Teardown ────────────────────────────────────────────────────────
teardown() {
    log "Tearing down..."
    helm uninstall vector -n vector --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
    kind delete cluster --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
    docker rm -f "${REGISTRY_NAME}" 2>/dev/null || true
    rm -f "${KUBECONFIG_PATH}"
    log "Done."
}

if [[ "${TEARDOWN:-}" == "true" ]]; then
    teardown
    exit 0
fi

# ── Prerequisites ───────────────────────────────────────────────────
for cmd in kind kubectl docker helm; do
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

log "Chains configured (OCI storage, cosign keys generated)"

# ── Install Tekton Results ──────────────────────────────────────────
log "Installing Tekton Results ${TEKTON_RESULTS_VERSION}..."

# Create postgres secret (Results bundles a postgres deployment)
RESULTS_DB_PASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | head -c 24)
kubectl create secret generic tekton-results-postgres \
    -n tekton-pipelines \
    --from-literal=POSTGRES_USER=result \
    --from-literal=POSTGRES_PASSWORD="${RESULTS_DB_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -

# Generate self-signed TLS cert for Results API
RESULTS_TLS_DIR=$(mktemp -d)
openssl req -x509 -newkey rsa:4096 -keyout "${RESULTS_TLS_DIR}/tls.key" \
    -out "${RESULTS_TLS_DIR}/tls.crt" -days 365 -nodes \
    -subj "/CN=tekton-results-api-service.tekton-pipelines.svc.cluster.local" \
    -addext "subjectAltName=DNS:tekton-results-api-service.tekton-pipelines.svc.cluster.local,DNS:localhost" \
    2>/dev/null

kubectl create secret tls tekton-results-tls \
    -n tekton-pipelines \
    --cert="${RESULTS_TLS_DIR}/tls.crt" \
    --key="${RESULTS_TLS_DIR}/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -
rm -rf "${RESULTS_TLS_DIR}"

# Apply Results release
kubectl apply -f "https://infra.tekton.dev/tekton-releases/results/previous/${TEKTON_RESULTS_VERSION}/release.yaml"

log "Waiting for Tekton Results..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/tekton-results-api -n tekton-pipelines
kubectl wait --for=condition=available --timeout=120s \
    deployment/tekton-results-watcher -n tekton-pipelines

# Configure Results: enable log storage
kubectl patch configmap tekton-results-api-config -n tekton-pipelines \
    --type merge -p '{"data":{"LOGS_API":"true","LOG_LEVEL":"info"}}' 2>/dev/null || true

# RBAC: allow default SA to query Results API
kubectl create clusterrolebinding tekton-results-readonly-binding \
    --clusterrole=tekton-results-readonly \
    --serviceaccount=default:default \
    --dry-run=client -o yaml | kubectl apply -f -

log "Tekton Results ${TEKTON_RESULTS_VERSION} ready"

# ── Install MinIO (S3-compatible object storage) ────────────────────
log "Installing MinIO..."

MINIO_ACCESS_KEY="minioadmin"
MINIO_SECRET_KEY="minioadmin"

kubectl create namespace minio 2>/dev/null || true

kubectl create secret generic minio-credentials \
    -n minio \
    --from-literal=access-key="${MINIO_ACCESS_KEY}" \
    --from-literal=secret-key="${MINIO_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

cat <<'MINIO_EOF' | kubectl apply -n minio -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: quay.io/minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: access-key
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: secret-key
          ports:
            - containerPort: 9000
            - containerPort: 9001
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
    - name: console
      port: 9001
MINIO_EOF

log "Waiting for MinIO..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/minio -n minio

# Create buckets
log "Creating MinIO buckets..."
kubectl run minio-setup --rm -i --restart=Never \
    -n minio \
    --image=quay.io/minio/mc:latest \
    --command -- sh -c '
    mc alias set local http://minio:9000 minioadmin minioadmin &&
    mc mb --ignore-existing local/tekton-logs &&
    mc mb --ignore-existing local/tekton-archive &&
    echo "Buckets created:"
    mc ls local/
'

log "MinIO ready (buckets: tekton-logs, tekton-archive)"

# ── Install Vector (log forwarder) ──────────────────────────────────
log "Installing Vector via Helm..."

helm repo add vector https://helm.vector.dev 2>/dev/null || true
helm repo update vector 2>/dev/null || true

kubectl create namespace vector 2>/dev/null || true

# Create Vector config as a ConfigMap (avoids Helm Go template conflicts
# with Vector's {{ }} template syntax in key_prefix)
cat <<'VECTOR_CM_EOF' | kubectl apply -n vector -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-config
data:
  agent.yaml: |
    data_dir: /vector-data-dir
    api:
      enabled: false
    sources:
      kubernetes_logs:
        type: kubernetes_logs
        extra_label_selector: "app.kubernetes.io/managed-by=tekton-pipelines"
        fingerprint_lines: 1
    transforms:
      remap_logs:
        type: remap
        inputs: [kubernetes_logs]
        source: |-
          .log_type = "application"
          .kubernetes_namespace_name = .kubernetes.pod_namespace
          if exists(.kubernetes.pod_labels."tekton.dev/taskRunUID") {
            .taskRunUID = del(.kubernetes.pod_labels."tekton.dev/taskRunUID")
          } else {
            .taskRunUID = "none"
          }
          if exists(.kubernetes.pod_labels."tekton.dev/pipelineRunUID") {
            .pipelineRunUID = del(.kubernetes.pod_labels."tekton.dev/pipelineRunUID")
            .result = .pipelineRunUID
          } else {
            .result = .taskRunUID
          }
          if exists(.kubernetes.pod_labels."tekton.dev/task") {
            .task = del(.kubernetes.pod_labels."tekton.dev/task")
          } else {
            .task = "none"
          }
          if exists(.kubernetes.pod_namespace) {
            .namespace = del(.kubernetes.pod_namespace)
          } else {
            .namespace = "unlabeled"
          }
          .pod = .kubernetes.pod_name
          .container = .kubernetes.container_name
    sinks:
      minio_s3:
        type: aws_s3
        inputs: [remap_logs]
        bucket: tekton-logs
        region: us-east-1
        endpoint: http://minio.minio.svc.cluster.local:9000
        auth:
          access_key_id: minioadmin
          secret_access_key: minioadmin
        compression: none
        encoding:
          codec: text
        key_prefix: "/logs/{{ namespace }}/{{ result }}/{{ taskRunUID }}/{{ container }}"
        filename_time_format: ""
        filename_append_uuid: false
        batch:
          timeout_secs: 30
VECTOR_CM_EOF

helm upgrade --install vector vector/vector \
    -n vector \
    --set role=Agent \
    --set existingConfigMaps[0]=vector-config \
    --set dataDir=/vector-data-dir \
    --set service.enabled=false \
    --wait --timeout 120s

log "Vector ready (forwarding Tekton logs to MinIO)"

# ── Configure Results for logs + retention ──────────────────────────
log "Configuring Results for S3 log storage + archival retention..."

# Patch the config key inside the configmap (not top-level)
# We need to replace LOGS_API=false with true and set blob config
CURRENT_CONFIG=$(kubectl get configmap tekton-results-api-config \
    -n tekton-pipelines -o jsonpath='{.data.config}')

NEW_CONFIG=$(echo "${CURRENT_CONFIG}" | sed \
    -e 's|LOGS_API=false|LOGS_API=true|' \
    -e 's|LOGS_TYPE=File|LOGS_TYPE=Blob|' \
    -e 's|LOGGING_PLUGIN_API_URL=|LOGGING_PLUGIN_API_URL=s3://tekton-logs|' \
    -e "s|LOGGING_PLUGIN_QUERY_PARAMS='direction=forward'|LOGGING_PLUGIN_QUERY_PARAMS='v1alpha2LogType=true\&use_path_style=true'|" \
    -e 's|S3_ENDPOINT=|S3_ENDPOINT=http://minio.minio.svc.cluster.local:9000|' \
    -e "s|S3_ACCESS_KEY_ID=|S3_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}|" \
    -e "s|S3_SECRET_ACCESS_KEY=|S3_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}|" \
    -e 's|S3_REGION=|S3_REGION=us-east-1|' \
    -e 's|S3_HOSTNAME_IMMUTABLE=false|S3_HOSTNAME_IMMUTABLE=true|' \
)

kubectl create configmap tekton-results-api-config \
    -n tekton-pipelines \
    --from-literal=config="${NEW_CONFIG}" \
    --dry-run=client -o yaml | kubectl apply -f -

# Set retention to 7 years (2555 days)
kubectl patch configmap tekton-results-config-results-retention-policy \
    -n tekton-pipelines \
    --type merge -p '{"data":{"defaultRetention":"2555"}}'

# Add AWS env vars for Go CDK S3 access to MinIO (used by the Blob log plugin)
kubectl patch deployment tekton-results-api -n tekton-pipelines --type json -p '[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "AWS_ACCESS_KEY_ID", "value": "'"${MINIO_ACCESS_KEY}"'"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "AWS_SECRET_ACCESS_KEY", "value": "'"${MINIO_SECRET_KEY}"'"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "AWS_REGION", "value": "us-east-1"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "AWS_ENDPOINT_URL_S3", "value": "http://minio.minio.svc.cluster.local:9000"}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "AWS_S3_USE_PATH_STYLE", "value": "true"}}
]'

# Restart to pick up all config changes
kubectl rollout restart deployment tekton-results-api -n tekton-pipelines
kubectl wait --for=condition=available --timeout=60s \
    deployment/tekton-results-api -n tekton-pipelines
kubectl wait --for=condition=available --timeout=60s \
    deployment/tekton-results-watcher -n tekton-pipelines

log "Results configured (S3 logs via MinIO, 7-year retention)"

# ── External registry setup ────────────────────────────────────────
if [[ -n "${EXTERNAL_REGISTRY}" ]]; then
    log "Configuring external registry: ${EXTERNAL_REGISTRY}"

    # Determine docker config location
    DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-${HOME}/.docker}"
    DOCKER_CONFIG_FILE="${DOCKER_CONFIG_DIR}/config.json"

    if [[ ! -f "${DOCKER_CONFIG_FILE}" ]]; then
        err "Docker config not found at ${DOCKER_CONFIG_FILE}"
        err "Please login first: docker login $(echo ${EXTERNAL_REGISTRY} | cut -d/ -f1)"
        exit 1
    fi

    # Extract the registry hostname
    REGISTRY_HOSTNAME=$(echo "${EXTERNAL_REGISTRY}" | cut -d/ -f1)

    # Verify credentials exist for this registry
    if ! grep -q "${REGISTRY_HOSTNAME}" "${DOCKER_CONFIG_FILE}" 2>/dev/null; then
        warn "No credentials found for ${REGISTRY_HOSTNAME} in ${DOCKER_CONFIG_FILE}"
        warn "You may need to: docker login ${REGISTRY_HOSTNAME}"
    fi

    # Create k8s secret with docker credentials
    kubectl delete secret registry-credentials --ignore-not-found 2>/dev/null
    kubectl create secret generic registry-credentials \
        --from-file=config.json="${DOCKER_CONFIG_FILE}" \
        --from-file=.dockerconfigjson="${DOCKER_CONFIG_FILE}" \
        --type=kubernetes.io/dockerconfigjson 2>/dev/null || \
    kubectl create secret docker-registry registry-credentials \
        --from-file=.dockerconfigjson="${DOCKER_CONFIG_FILE}" 2>/dev/null || \
    kubectl create secret generic registry-credentials \
        --from-file=config.json="${DOCKER_CONFIG_FILE}"

    # Patch default ServiceAccount to use the credentials for image pull/push
    kubectl patch serviceaccount default -p '{"secrets": [{"name": "registry-credentials"}], "imagePullSecrets": [{"name": "registry-credentials"}]}'

    # Update Chains config — no insecure flag needed, no separate storage repo
    kubectl patch configmap chains-config -n tekton-chains --type merge -p '{
      "data": {
        "storage.oci.repository.insecure": "false"
      }
    }'
    kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
    kubectl wait --for=condition=available --timeout=60s \
        deployment/tekton-chains-controller -n tekton-chains

    # Write registry config for run.sh
    echo "${EXTERNAL_REGISTRY}" > "${KUBECONFIG_PATH%.kubeconfig}.registry"

    log "External registry configured: ${EXTERNAL_REGISTRY}"
    log "Credentials from: ${DOCKER_CONFIG_FILE}"
else
    # Write local registry config for run.sh
    echo "local" > "${KUBECONFIG_PATH%.kubeconfig}.registry"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
log "Setup complete!"
echo ""
echo "  KUBECONFIG:     export KUBECONFIG=${KUBECONFIG_PATH}"
if [[ -n "${EXTERNAL_REGISTRY}" ]]; then
echo "  Registry:       ${EXTERNAL_REGISTRY} (external, HTTPS)"
echo ""
echo "  Run pipeline:   ./hack/run.sh"
echo "  Run full:       ./hack/run.sh --full"
else
echo "  Registry:       ${REGISTRY_HOST}:${REGISTRY_PORT} (host)"
echo "                  ${REGISTRY_NAME}:5000 (in-cluster)"
echo ""
echo "  Run pipeline:   ./hack/run.sh"
echo "  Run full:       ./hack/run.sh --full"
fi
echo ""
echo "  Results API:    kubectl port-forward -n tekton-pipelines svc/tekton-results-api-service 8080:8080"
echo "  MinIO console:  kubectl port-forward -n minio svc/minio 9001:9001  (minioadmin/minioadmin)"
echo ""
echo "  Teardown:       ./hack/setup.sh teardown"
