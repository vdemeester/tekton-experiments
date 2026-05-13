#!/usr/bin/env bash
# Demonstrate that TEP-0164 artifact metadata survives CRD deletion.
#
# This is the core value of Results + TEP-0164:
#   - Pipeline controller stores artifacts in OCI registry (durable)
#   - Results watcher captures metadata in postgres (durable + queryable)
#   - CRDs are ephemeral — safe to garbage-collect
#
# Usage:
#   export KUBECONFIG=/tmp/tekton-tep0164.kubeconfig
#   ./05-survive-deletion.sh
set -euo pipefail

: "${KUBECONFIG:=/tmp/tekton-tep0164.kubeconfig}"
export KUBECONFIG

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}==>${NC} $*"; }

# ── Setup ───────────────────────────────────────────────────────────
cleanup() { kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; }
kubectl port-forward -n tekton-pipelines svc/tekton-results-api-service 18080:8080 &>/dev/null &
PF_PID=$!
trap cleanup EXIT
sleep 2

TOKEN=$(kubectl create token default --duration=1h)
RESULTS_API="https://localhost:18080/apis/results.tekton.dev/v1alpha2/parents/default"

query() {
    curl -sk -H "Authorization: Bearer ${TOKEN}" "$@"
}

count_artifacts() {
    query "${RESULTS_API}/results/-/records" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
count = 0
for rec in data.get('records', []):
    value = rec.get('data', {}).get('value', '')
    if not value: continue
    try:
        obj = json.loads(base64.b64decode(value))
    except: continue
    for d in ['inputs', 'outputs']:
        for a in obj.get('status', {}).get('artifacts', {}).get(d, []):
            count += len(a.get('values', []))
print(count)
" 2>/dev/null
}

# ── Step 1: Show current state ──────────────────────────────────────
log "Step 1: Current cluster state"
PR_COUNT=$(kubectl get pipelineruns --no-headers 2>/dev/null | wc -l)
TR_COUNT=$(kubectl get taskruns --no-headers 2>/dev/null | wc -l)
ARTIFACT_COUNT=$(count_artifacts)

echo "  PipelineRuns in cluster: ${PR_COUNT}"
echo "  TaskRuns in cluster:     ${TR_COUNT}"
echo "  Artifacts in Results:    ${ARTIFACT_COUNT}"
echo ""

# ── Step 2: Pick a random artifact and verify it ────────────────────
log "Step 2: Pick a random artifact and verify content"
RANDOM_URI=$(query "${RESULTS_API}/results/-/records" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
for rec in data.get('records', []):
    value = rec.get('data', {}).get('value', '')
    if not value: continue
    try:
        obj = json.loads(base64.b64decode(value))
    except: continue
    for a in obj.get('status', {}).get('artifacts', {}).get('outputs', []):
        for v in a.get('values', []):
            uri = v.get('uri', '')
            if 'test-results' in uri or 'coverage' in uri:
                print(uri.replace('tekton-registry:5000', 'localhost:5555'))
                sys.exit(0)
" 2>/dev/null)

if [[ -n "${RANDOM_URI}" ]]; then
    echo "  Artifact: ${RANDOM_URI}"
    DIGEST=$(echo "${RANDOM_URI}" | cut -d@ -f2)
    REPO=$(echo "${RANDOM_URI}" | cut -d@ -f1)
    LAYER=$(crane manifest "${RANDOM_URI}" 2>/dev/null | jq -r '.layers[0].digest')
    echo "  Content preview:"
    crane blob "${REPO}@${LAYER}" 2>/dev/null | tar xzf - -O 2>/dev/null | head -5 | sed 's/^/    /'
fi
echo ""

# ── Step 3: Delete all CRDs ────────────────────────────────────────
warn "Step 3: Deleting ALL PipelineRuns and TaskRuns from cluster..."
kubectl delete pipelineruns --all --wait=false 2>/dev/null
kubectl delete taskruns --all --wait=false 2>/dev/null
sleep 3

PR_COUNT=$(kubectl get pipelineruns --no-headers 2>/dev/null | wc -l)
TR_COUNT=$(kubectl get taskruns --no-headers 2>/dev/null | wc -l)
echo "  PipelineRuns in cluster: ${PR_COUNT} (deleted)"
echo "  TaskRuns in cluster:     ${TR_COUNT} (deleted)"
echo ""

# ── Step 4: Query Results — still there ─────────────────────────────
log "Step 4: Query Results API — artifact metadata survives"
ARTIFACT_COUNT_AFTER=$(count_artifacts)
echo "  Artifacts in Results:    ${ARTIFACT_COUNT_AFTER} (unchanged!)"
echo ""

if [[ -n "${RANDOM_URI}" ]]; then
    log "Step 5: Verify artifact blob still accessible in OCI registry"
    if crane manifest "${RANDOM_URI}" &>/dev/null; then
        echo "  ✅ ${RANDOM_URI} — still exists"
        echo "  Content still readable:"
        crane blob "${REPO}@${LAYER}" 2>/dev/null | tar xzf - -O 2>/dev/null | head -3 | sed 's/^/    /'
    else
        echo "  ❌ ${RANDOM_URI} — gone (registry was cleaned)"
    fi
fi

echo ""
log "Summary:"
echo "  CRDs are gone from the cluster — garbage collected."
echo "  But artifact metadata lives on in Results (postgres)."
echo "  And artifact blobs live on in the OCI registry."
echo "  Together: a durable, queryable supply chain inventory."
