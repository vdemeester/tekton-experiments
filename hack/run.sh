#!/usr/bin/env bash
# Run the build-artifact-referrers pipeline.
#
# Usage:
#   ./hack/run.sh                              # basic referrers pipeline
#   ./hack/run.sh --full                       # full pipeline (+ SBOM, docs)
#   ./hack/run.sh --registry ghcr.io/user      # override registry
#   ./hack/run.sh --full --registry quay.io/u  # full + custom registry
#
# Registry is auto-detected from setup.sh config, or can be overridden.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

CLUSTER_NAME="${CLUSTER_NAME:-tekton-experiments}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${CLUSTER_NAME}.kubeconfig}"
REGISTRY_CONFIG="${KUBECONFIG_PATH%.kubeconfig}.registry"

# Defaults
PIPELINE="build-artifact-referrers"
PIPELINE_DIR="build-artifact-referrers"
REGISTRY=""
FULL=false

# Colors
GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}==>${NC} $*"; }

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            FULL=true
            shift
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --noimage)
            PIPELINE="build-artifact-referrers-noimage"
            PIPELINE_DIR="build-artifact-referrers-noimage"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ── Detect registry ────────────────────────────────────────────────
if [[ -z "${REGISTRY}" ]]; then
    if [[ -f "${REGISTRY_CONFIG}" ]]; then
        REGISTRY=$(cat "${REGISTRY_CONFIG}")
    else
        REGISTRY="local"
    fi
fi

export KUBECONFIG="${KUBECONFIG_PATH}"

# ── Apply resources ─────────────────────────────────────────────────
log "Applying tasks and pipeline..."
kubectl apply -f "${REPO_DIR}/${PIPELINE_DIR}/01-tasks.yaml" 2>&1 | grep -v unchanged || true

if [[ "${FULL}" == "true" ]]; then
    PIPELINE="build-artifact-referrers-full"
    kubectl apply -f "${REPO_DIR}/build-artifact-referrers/01-extras.yaml" 2>&1 | grep -v unchanged || true
    kubectl apply -f "${REPO_DIR}/build-artifact-referrers/02-pipeline-full.yaml" 2>&1 | grep -v unchanged || true
else
    kubectl apply -f "${REPO_DIR}/${PIPELINE_DIR}/02-pipeline.yaml" 2>&1 | grep -v unchanged || true
fi

# ── Build PipelineRun ───────────────────────────────────────────────
if [[ "${REGISTRY}" == "local" ]]; then
    IMAGE_REGISTRY="tekton-registry:5000/tekton-experiments"
    ARTIFACT_STORE="tekton-registry:5000/tekton-experiments/artifacts"
    log "Using local registry (tekton-registry:5000)"
else
    IMAGE_REGISTRY="${REGISTRY}/tekton-experiments"
    ARTIFACT_STORE="${REGISTRY}/tekton-experiments/artifacts"
    log "Using external registry: ${REGISTRY}"
fi

PIPELINERUN=$(cat <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: run-
spec:
  pipelineRef:
    name: ${PIPELINE}
  params:
    - name: git-url
      value: https://github.com/vdemeester/tekton-experiments
    - name: git-revision
      value: main
    - name: image-registry
      value: ${IMAGE_REGISTRY}
    - name: artifact-store
      value: ${ARTIFACT_STORE}
    - name: version-tag
      value: latest
EOF
)

# ── Create PipelineRun ──────────────────────────────────────────────
RUN_NAME=$(echo "${PIPELINERUN}" | kubectl create -f - -o jsonpath='{.metadata.name}')
log "Created PipelineRun: ${RUN_NAME}"

# ── Watch ───────────────────────────────────────────────────────────
log "Watching PipelineRun..."
kubectl get pipelinerun "${RUN_NAME}" -w --no-headers 2>&1 | while read line; do
    echo "  ${line}"
    # Exit when we see a final status
    if echo "${line}" | grep -qE "True|False"; then
        break
    fi
done || true

# Brief pause for final status
sleep 2

echo ""
log "Task results:"
for tr in $(kubectl get taskruns -l tekton.dev/pipelineRun="${RUN_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
    TASK=$(kubectl get taskrun "$tr" -o jsonpath='{.metadata.labels.tekton\.dev/pipelineTask}')
    STATUS=$(kubectl get taskrun "$tr" -o jsonpath='{.status.conditions[0].reason}')
    SIGNED=$(kubectl get taskrun "$tr" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}')
    printf "  %-20s %s" "${TASK}" "${STATUS}"
    [[ -n "${SIGNED}" ]] && printf "  (chains: %s)" "${SIGNED}"
    echo ""
done

echo ""
if [[ "${REGISTRY}" == "local" ]]; then
    log "Inspect referrers (from host):"
    echo "  oras discover --plain-http localhost:5555/tekton-experiments:latest"
    echo ""
    log "Pull artifact:"
    echo "  oras pull --plain-http localhost:5555/tekton-experiments:latest"
else
    log "Inspect referrers:"
    echo "  oras discover ${IMAGE_REGISTRY}:latest"
    echo ""
    log "Verify Chains attestation:"
    COSIGN_PUB="${KUBECONFIG_PATH%.kubeconfig}.cosign.pub"
    echo "  cosign verify-attestation --key ${COSIGN_PUB} --type slsaprovenance1 ${IMAGE_REGISTRY}:latest"
fi
