#!/usr/bin/env bash
# Query Tekton Results API for TEP-0164 artifact metadata.
#
# Prerequisites:
#   export KUBECONFIG=/tmp/tekton-tep0164.kubeconfig
#   Tekton Results deployed + pipeline has run
#
# Usage:
#   ./04-query-results.sh                    # Show all artifacts
#   ./04-query-results.sh build-and-test-X   # Show specific PipelineRun
set -euo pipefail

: "${KUBECONFIG:=/tmp/tekton-tep0164.kubeconfig}"
export KUBECONFIG

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
info() { echo -e "${CYAN}   ${NC} $*"; }

# ── Setup port-forward ──────────────────────────────────────────────
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

# ── 1. List all Results ─────────────────────────────────────────────
log "Results in namespace 'default'"
query "${RESULTS_API}/results" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
print(f'  Total: {len(results)} results')
for r in results:
    uid = r['uid']
    ts = r.get('createdTime', '')[:19]
    # Count records
    print(f'  {uid}  ({ts})')
"
echo ""

# ── 2. Artifact inventory ──────────────────────────────────────────
log "TEP-0164 artifact inventory (from TaskRun status.artifacts)"
FILTER=""
if [[ "${1:-}" != "" ]]; then
    FILTER="?filter=data.metadata.name%3D%3D'${1}'+||+data.metadata.labels.'tekton.dev/pipelineRun'%3D%3D'${1}'"
fi

query "${RESULTS_API}/results/-/records${FILTER}" | python3 -c "
import sys, json, base64

data = json.load(sys.stdin)
pipelineruns = {}
taskruns = {}

for rec in data.get('records', []):
    d = rec.get('data', {})
    value = d.get('value', '')
    if not value:
        continue
    try:
        obj = json.loads(base64.b64decode(value))
    except:
        continue

    kind = obj.get('kind', '')
    name = obj.get('metadata', {}).get('name', '')
    status = obj.get('status', {})
    artifacts = status.get('artifacts', {})
    results = status.get('results', [])
    pipeline_task = obj.get('metadata', {}).get('labels', {}).get('tekton.dev/pipelineTask', '')
    pipeline_run = obj.get('metadata', {}).get('labels', {}).get('tekton.dev/pipelineRun', '')

    if kind == 'PipelineRun':
        pipelineruns[name] = {
            'results': {r['name']: r['value'] for r in results},
        }
    elif kind == 'TaskRun' and artifacts:
        taskruns[name] = {
            'pipelineRun': pipeline_run,
            'pipelineTask': pipeline_task,
            'artifacts': artifacts,
            'results': {r['name']: r['value'] for r in results},
        }

# Group by PipelineRun
by_pr = {}
standalone = []
for tr_name, tr in taskruns.items():
    pr = tr['pipelineRun']
    if pr:
        by_pr.setdefault(pr, []).append((tr_name, tr))
    else:
        standalone.append((tr_name, tr))

for pr_name in sorted(by_pr.keys()):
    pr_data = pipelineruns.get(pr_name, {})
    pr_results = pr_data.get('results', {})
    print(f'\\n📋 PipelineRun: {pr_name}')
    if pr_results:
        for k, v in pr_results.items():
            print(f'   Result: {k} = {v[:80]}')
    for tr_name, tr in sorted(by_pr[pr_name], key=lambda x: x[1]['pipelineTask']):
        print(f'\\n   🔧 {tr[\"pipelineTask\"]} ({tr_name})')
        for direction in ['inputs', 'outputs']:
            for a in tr['artifacts'].get(direction, []):
                for v in a.get('values', []):
                    uri = v.get('uri', '')
                    emoji = '📥' if direction == 'inputs' else '📦'
                    print(f'      {emoji} {direction}/{a[\"name\"]}: {uri}')
        for k, v in tr['results'].items():
            print(f'      📊 {k}: {v[:60]}')

if standalone:
    print(f'\\n📋 Standalone TaskRuns')
    for tr_name, tr in standalone:
        print(f'   🔧 {tr_name}')
        for direction in ['inputs', 'outputs']:
            for a in tr['artifacts'].get(direction, []):
                for v in a.get('values', []):
                    print(f'      📦 {direction}/{a[\"name\"]}: {v.get(\"uri\", \"\")}')
"
echo ""

# ── 3. Verify artifact blobs exist ─────────────────────────────────
log "Verifying artifact blobs in OCI registry"
query "${RESULTS_API}/results/-/records${FILTER}" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
uris = []
for rec in data.get('records', []):
    d = rec.get('data', {})
    value = d.get('value', '')
    if not value: continue
    try:
        obj = json.loads(base64.b64decode(value))
    except: continue
    for direction in ['inputs', 'outputs']:
        for a in obj.get('status', {}).get('artifacts', {}).get(direction, []):
            for v in a.get('values', []):
                uri = v.get('uri', '')
                if uri:
                    # Convert in-cluster to localhost
                    local = uri.replace('tekton-registry:5000', 'localhost:5555')
                    print(local)
" 2>/dev/null | sort -u | while read -r uri; do
    if crane manifest "${uri}" &>/dev/null; then
        info "✅ ${uri}"
    else
        info "❌ ${uri} (NOT FOUND)"
    fi
done

echo ""
log "Done. Artifacts are stored in OCI registry, metadata in Results."
log "Even after PipelineRun/TaskRun CRDs are garbage-collected,"
log "Results retains the full artifact inventory."
