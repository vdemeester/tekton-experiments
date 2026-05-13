#!/usr/bin/env bash
# Query Tekton Results API for PipelineRun artifact metadata.
#
# Usage:
#   ./results-artifact-archival/01-query-artifacts.sh
#   ./results-artifact-archival/01-query-artifacts.sh <pipelinerun-name>
#
# Requires: setup.sh has been run (Results API available)
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-tekton-experiments}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${CLUSTER_NAME}.kubeconfig}"
export KUBECONFIG="${KUBECONFIG_PATH}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==>${NC} $*"; }

PIPELINERUN_NAME="${1:-}"

# ── Get token for Results API ───────────────────────────────────────
log "Getting auth token..."
TOKEN=$(kubectl create token default -n default 2>/dev/null || echo "")

# ── Port-forward Results API ────────────────────────────────────────
pkill -f "port-forward.*tekton-results-api" 2>/dev/null || true
sleep 1

log "Port-forwarding Results API..."
kubectl port-forward -n tekton-pipelines svc/tekton-results-api-service 8080:8080 &>/dev/null &
PF_PID=$!
sleep 3

cleanup() { kill ${PF_PID} 2>/dev/null || true; }
trap cleanup EXIT

RESULTS_API="https://localhost:8080/apis/results.tekton.dev/v1alpha2"
CURL_OPTS=(-sk)
[[ -n "${TOKEN}" ]] && CURL_OPTS+=(-H "Authorization: Bearer ${TOKEN}")

# ── List all Results ────────────────────────────────────────────────
log "Listing all Results in default namespace..."
RESULTS=$(curl "${CURL_OPTS[@]}" "${RESULTS_API}/parents/default/results")

RESULT_COUNT=$(echo "${RESULTS}" | jq -r '.results | length // 0')
log "Found ${RESULT_COUNT} result(s)"

if [[ "${RESULT_COUNT}" == "0" ]]; then
    warn "No results found. Run a pipeline first: ./hack/run.sh --full"
    exit 0
fi

echo "${RESULTS}" | jq -r '.results[] | "\(.uid)  \(.name)"'
echo ""

# ── Select which result to inspect ──────────────────────────────────
if [[ -n "${PIPELINERUN_NAME}" ]]; then
    RESULT_NAME=$(echo "${RESULTS}" | jq -r --arg pr "${PIPELINERUN_NAME}" \
        '.results[] | select(.name | contains($pr)) | .name' | head -1)
    if [[ -z "${RESULT_NAME}" ]]; then
        warn "No result found matching '${PIPELINERUN_NAME}'"
        exit 1
    fi
else
    RESULT_NAME=$(echo "${RESULTS}" | jq -r '.results | sort_by(.createTime) | last | .name')
fi

log "Inspecting result: ${RESULT_NAME}"

# ── Fetch records ───────────────────────────────────────────────────
RECORDS=$(curl "${CURL_OPTS[@]}" "${RESULTS_API}/parents/default/results/${RESULT_NAME##*/}/records")
RECORD_COUNT=$(echo "${RECORDS}" | jq -r '.records | length // 0')
log "Found ${RECORD_COUNT} record(s)"

echo ""
log "Records:"
echo "${RECORDS}" | jq -r '.records[] | "  \(.name | split("/") | last)  \(.data.type // "unknown")"'

# ── Decode and show TaskRun results ─────────────────────────────────
# Results API stores data as base64-encoded JSON in .data.value
echo ""
log "TaskRun results (artifact references):"

echo "${RECORDS}" | jq -r '
    .records[]
    | select(.data.type == "tekton.dev/v1.TaskRun")
    | .data.value' | while IFS= read -r b64; do
    [[ -z "${b64}" ]] && continue
    DECODED=$(echo "${b64}" | base64 -d 2>/dev/null) || continue
    TASK=$(echo "${DECODED}" | jq -r '.metadata.labels["tekton.dev/pipelineTask"] // .metadata.name')
    RESULTS_LIST=$(echo "${DECODED}" | jq -r '.status.results[]? | "    \(.name) = \(.value)"' 2>/dev/null)
    if [[ -n "${RESULTS_LIST}" ]]; then
        echo "  Task: ${TASK}"
        echo "${RESULTS_LIST}"
    fi
done

echo ""
log "Done. Use 02-artifact-index.sh to build a full supply chain index."
