#!/usr/bin/env bash
# Build a JSON artifact index from Results API + OCI referrers.
#
# Combines Results (metadata/queryability) with OCI referrers (supply chain graph)
# to produce a complete supply chain inventory.
#
# Usage:
#   ./results-artifact-archival/02-artifact-index.sh
#   ./results-artifact-archival/02-artifact-index.sh --json    # JSON output only
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-tekton-experiments}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${CLUSTER_NAME}.kubeconfig}"
export KUBECONFIG="${KUBECONFIG_PATH}"
REGISTRY_CONFIG="${KUBECONFIG_PATH%.kubeconfig}.registry"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
JSON_ONLY=false
[[ "${1:-}" == "--json" ]] && JSON_ONLY=true

log()  { $JSON_ONLY && return; echo -e "${GREEN}==>${NC} $*"; }
warn() { $JSON_ONLY && return; echo -e "${YELLOW}==>${NC} $*"; }

# Detect registry
REG_TYPE="local"
[[ -f "${REGISTRY_CONFIG}" ]] && REG_TYPE=$(cat "${REGISTRY_CONFIG}")

ORAS_FLAGS=""
REGISTRY_HOST="localhost:5555"
if [[ "${REG_TYPE}" == "local" ]]; then
    ORAS_FLAGS="--plain-http"
fi

# ── Port-forward Results API ────────────────────────────────────────
TOKEN=$(kubectl create token default -n default 2>/dev/null || echo "")
pkill -f "port-forward.*tekton-results-api" 2>/dev/null || true
sleep 1
kubectl port-forward -n tekton-pipelines svc/tekton-results-api-service 8080:8080 &>/dev/null &
PF_PID=$!
sleep 3
trap "kill ${PF_PID} 2>/dev/null || true" EXIT

RESULTS_API="https://localhost:8080/apis/results.tekton.dev/v1alpha2"
CURL_OPTS=(-sk)
[[ -n "${TOKEN}" ]] && CURL_OPTS+=(-H "Authorization: Bearer ${TOKEN}")

# ── Fetch all Results ───────────────────────────────────────────────
log "Fetching Results..."
RESULTS=$(curl "${CURL_OPTS[@]}" "${RESULTS_API}/parents/default/results")
RESULT_COUNT=$(echo "${RESULTS}" | jq -r '.results | length // 0')
log "Found ${RESULT_COUNT} result(s)"

if [[ "${RESULT_COUNT}" == "0" ]]; then
    warn "No results found. Run a pipeline first."
    $JSON_ONLY && echo "[]"
    exit 0
fi

# ── Build artifact index ────────────────────────────────────────────
log "Building artifact index..."
INDEX="[]"

while IFS= read -r result_name; do
    [[ -z "${result_name}" ]] && continue
    log "Processing result: ${result_name}"

    RECORDS=$(curl "${CURL_OPTS[@]}" "${RESULTS_API}/parents/default/results/${result_name##*/}/records")

    # Decode PipelineRun record for metadata
    PR_B64=$(echo "${RECORDS}" | jq -r '.records[] | select(.data.type == "tekton.dev/v1.PipelineRun") | .data.value' | head -1)
    PR_NAME="unknown"
    PR_TIME="unknown"
    GIT_SHA="unknown"
    if [[ -n "${PR_B64}" ]]; then
        PR_DATA=$(echo "${PR_B64}" | base64 -d 2>/dev/null || echo "{}")
        PR_NAME=$(echo "${PR_DATA}" | jq -r '.metadata.name // "unknown"')
        PR_TIME=$(echo "${PR_DATA}" | jq -r '.metadata.creationTimestamp // "unknown"')
        GIT_SHA=$(echo "${PR_DATA}" | jq -r '.spec.params[]? | select(.name == "git-revision") | .value // "unknown"')
    fi

    # Collect artifact URIs from all TaskRun records
    ARTIFACTS="[]"
    echo "${RECORDS}" | jq -r '
        .records[]
        | select(.data.type == "tekton.dev/v1.TaskRun")
        | .data.value' | while IFS= read -r b64; do
        [[ -z "${b64}" ]] && continue
        DECODED=$(echo "${b64}" | base64 -d 2>/dev/null) || continue

        TASK=$(echo "${DECODED}" | jq -r '.metadata.labels["tekton.dev/pipelineTask"] // .metadata.name')

        # Extract all result values that look like OCI/image references
        echo "${DECODED}" | jq -r '.status.results[]? | select(.value | test("oci:|sha256:")) | "\(.name)|\(.value)"' 2>/dev/null | while IFS='|' read -r rname rvalue; do
            [[ -z "${rvalue}" ]] && continue

            # Translate in-cluster registry to host-accessible
            HOST_URI="${rvalue}"
            if [[ "${REG_TYPE}" == "local" ]]; then
                HOST_URI=$(echo "${rvalue}" | sed "s|tekton-registry:5000|${REGISTRY_HOST}|g")
                # Strip oci: prefix for oras
                HOST_URI="${HOST_URI#oci:}"
            fi

            log "  ${TASK}/${rname}: ${HOST_URI}"

            # Get OCI referrers (timeout to avoid hanging on artifacts without referrers)
            REFERRERS=$(timeout 5 oras discover ${ORAS_FLAGS} --format json "${HOST_URI}" 2>/dev/null || echo '{"referrers":[]}')
            REFERRER_LIST=$(echo "${REFERRERS}" | jq -c '[(.referrers // .manifests // [])[] | {type: .artifactType, digest: .digest}]' 2>/dev/null || echo "[]")

            echo "${rvalue}|${rname}|${TASK}|${REFERRER_LIST}"
        done
    done > /tmp/artifact-entries.txt 2>/dev/null || true

    # Build artifacts array from collected entries
    if [[ -s /tmp/artifact-entries.txt ]]; then
        while IFS='|' read -r uri rname task refs; do
            [[ -z "${uri}" ]] && continue
            ENTRY=$(jq -nc --arg uri "${uri}" --arg name "${rname}" --arg task "${task}" --argjson refs "${refs:-[]}" \
                '{uri: $uri, result_name: $name, task: $task, referrers: $refs}')
            ARTIFACTS=$(echo "${ARTIFACTS}" | jq --argjson e "${ENTRY}" '. + [$e]')
        done < /tmp/artifact-entries.txt
    fi

    RESULT_ENTRY=$(jq -nc \
        --arg pr "${PR_NAME}" \
        --arg time "${PR_TIME}" \
        --arg sha "${GIT_SHA}" \
        --argjson artifacts "${ARTIFACTS}" \
        '{pipelinerun: $pr, timestamp: $time, git_revision: $sha, artifacts: $artifacts}')

    INDEX=$(echo "${INDEX}" | jq --argjson e "${RESULT_ENTRY}" '. + [$e]')
done < <(echo "${RESULTS}" | jq -r '.results[].name')

rm -f /tmp/artifact-entries.txt

# ── Output ──────────────────────────────────────────────────────────
if $JSON_ONLY; then
    echo "${INDEX}" | jq .
else
    echo ""
    log "Supply Chain Artifact Index:"
    echo "${INDEX}" | jq .
    echo ""

    TOTAL_ARTIFACTS=$(echo "${INDEX}" | jq '[.[].artifacts | length] | add // 0')
    TOTAL_REFERRERS=$(echo "${INDEX}" | jq '[.[].artifacts[].referrers | length] | add // 0')
    log "Summary: ${RESULT_COUNT} pipeline run(s), ${TOTAL_ARTIFACTS} artifact(s), ${TOTAL_REFERRERS} referrer(s)"
fi
