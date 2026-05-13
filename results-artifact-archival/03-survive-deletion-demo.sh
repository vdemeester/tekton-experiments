#!/usr/bin/env bash
# Demonstrate that Results API preserves pipeline data after CRD deletion.
#
# This is the core archival value proposition: Results persists in postgres
# even after PipelineRun/TaskRun CRDs are garbage collected.
#
# Usage:
#   ./results-artifact-archival/03-survive-deletion-demo.sh
#
# Requires: setup.sh + at least one pipeline run completed
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-tekton-experiments}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${CLUSTER_NAME}.kubeconfig}"
export KUBECONFIG="${KUBECONFIG_PATH}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==>${NC} $*"; }
bold() { echo -e "${BOLD}$*${NC}"; }

# ── Step 1: Show current cluster state ──────────────────────────────
bold "Step 1: Current cluster state"
PR_COUNT=$(kubectl get pipelineruns --no-headers 2>/dev/null | wc -l)
TR_COUNT=$(kubectl get taskruns --no-headers 2>/dev/null | wc -l)
log "PipelineRuns in cluster: ${PR_COUNT}"
log "TaskRuns in cluster: ${TR_COUNT}"
echo ""

if [[ "${PR_COUNT}" -eq 0 ]]; then
    warn "No PipelineRuns found. Run some first:"
    warn "  ./hack/run.sh --full"
    warn "  ./hack/run.sh --full"
    warn "Then re-run this script."
    exit 0
fi

# ── Step 2: Verify Results has captured them ────────────────────────
bold "Step 2: Verify Results API has captured the records"
kubectl port-forward -n tekton-pipelines svc/tekton-results-api-service 8080:8080 &>/dev/null &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null || true" EXIT

TOKEN=$(kubectl create token default -n default 2>/dev/null || echo "")
CURL_OPTS=(-sk)
[[ -n "${TOKEN}" ]] && CURL_OPTS+=(-H "Authorization: Bearer ${TOKEN}")
API="https://localhost:8080/apis/results.tekton.dev/v1alpha2"

RESULTS_BEFORE=$(curl "${CURL_OPTS[@]}" "${API}/parents/default/results")
RESULT_COUNT=$(echo "${RESULTS_BEFORE}" | jq '.results | length')
log "Results API has ${RESULT_COUNT} result(s)"
echo ""

# ── Step 3: Delete ALL PipelineRuns ─────────────────────────────────
bold "Step 3: Deleting ALL PipelineRuns and TaskRuns"
echo -e "${RED}==> kubectl delete pipelineruns --all${NC}"
kubectl delete pipelineruns --all --wait=false 2>/dev/null
echo -e "${RED}==> kubectl delete taskruns --all${NC}"
kubectl delete taskruns --all --wait=false 2>/dev/null
sleep 3

PR_AFTER=$(kubectl get pipelineruns --no-headers 2>/dev/null | wc -l)
TR_AFTER=$(kubectl get taskruns --no-headers 2>/dev/null | wc -l)
log "PipelineRuns remaining: ${PR_AFTER}"
log "TaskRuns remaining: ${TR_AFTER}"
echo ""

# ── Step 4: Query Results API — data is still there ─────────────────
bold "Step 4: Query Results API — data survives deletion"
echo ""

# Restart port-forward (may have died)
kill ${PF_PID} 2>/dev/null || true
sleep 1
kubectl port-forward -n tekton-pipelines svc/tekton-results-api-service 8080:8080 &>/dev/null &
PF_PID=$!
sleep 3

RESULTS_AFTER=$(curl "${CURL_OPTS[@]}" "${API}/parents/default/results")
RESULT_COUNT_AFTER=$(echo "${RESULTS_AFTER}" | jq '.results | length')
log "Results API still has ${RESULT_COUNT_AFTER} result(s)"
echo ""

echo "${RESULTS_AFTER}" | jq -r '.results[].name' | while IFS= read -r rname; do
    [[ -z "${rname}" ]] && continue
    RECORDS=$(curl "${CURL_OPTS[@]}" "${API}/parents/default/results/${rname##*/}/records")

    # Decode PipelineRun
    PR_B64=$(echo "${RECORDS}" | jq -r '.records[] | select(.data.type == "tekton.dev/v1.PipelineRun") | .data.value' | head -1)
    [[ -z "${PR_B64}" ]] && continue
    PR_DATA=$(echo "${PR_B64}" | base64 -d 2>/dev/null) || continue
    PR_NAME=$(echo "${PR_DATA}" | jq -r '.metadata.name')
    PR_TIME=$(echo "${PR_DATA}" | jq -r '.metadata.creationTimestamp')
    PR_STATUS=$(echo "${PR_DATA}" | jq -r '.status.conditions[0].reason')
    RECORD_COUNT=$(echo "${RECORDS}" | jq '.records | length')

    echo -e "  ${BOLD}📋 ${PR_NAME}${NC}  ${PR_TIME}  ${PR_STATUS}  [${RECORD_COUNT} records]"

    # Show artifact URIs
    echo "${RECORDS}" | jq -r '.records[] | select(.data.type == "tekton.dev/v1.TaskRun") | .data.value' | while IFS= read -r b64; do
        DECODED=$(echo "${b64}" | base64 -d 2>/dev/null) || continue
        TASK=$(echo "${DECODED}" | jq -r '.metadata.labels["tekton.dev/pipelineTask"]')
        echo "${DECODED}" | jq -r '.status.results[]? | select(.value | test("oci:|sha256:")) | .name' 2>/dev/null | while read aname; do
            echo "     ${TASK}/${aname}"
        done
    done
    echo ""
done

# ── Summary ─────────────────────────────────────────────────────────
echo ""
bold "Summary"
echo "  Cluster CRDs:  ${PR_COUNT} PipelineRuns → ${PR_AFTER} (deleted)"
echo "  Results API:   ${RESULT_COUNT} results → ${RESULT_COUNT_AFTER} (preserved)"
echo ""
log "Results API is the source of truth after CRD garbage collection."
log "Artifact blobs remain in the OCI registry; Results provides the index."
