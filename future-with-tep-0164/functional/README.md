# Functional TEP-0164 Pipeline

**These YAMLs actually work** against the `tep-0164-artifact-transport` branch
of tektoncd/pipeline. Compare with the parent directory's aspirational YAMLs.

## Setup

```bash
# 1. Deploy a kind cluster with the TEP-0164 branch
#    (See hack/ or use the setup from tekton-experiments)

export KUBECONFIG=/tmp/tekton-tep0164.kubeconfig

# 2. Ensure feature flags and artifact storage are configured
kubectl patch configmap feature-flags -n tekton-pipelines \
    --type merge -p '{"data":{"enable-artifacts":"true"}}'
kubectl patch configmap config-artifact-storage -n tekton-pipelines \
    --type merge -p '{"data":{"oci-repository":"tekton-registry:5000/tekton-artifacts","insecure":"true"}}'

# 3. Apply tasks and pipeline
kubectl apply -f 01-tasks.yaml
kubectl apply -f 02-pipeline.yaml

# 4. Run
kubectl create -f 03-run.yaml
```

## What's demonstrated

| Task | Artifact Inputs | Artifact Outputs | Status |
|------|----------------|-----------------|--------|
| `git-clone` | — | `source` (cloned repo) | ✅ |
| `build-image` | `source` ← git-clone | `images` (buildOutput) | ✅ |
| `run-tests` | `source` ← git-clone | `test-results`, `coverage` | ✅ |

### Pipeline flow

```
git-clone ──→ build-image    (source artifact passed via OCI)
          └─→ run-tests      (same source artifact, parallel)
```

### Key TEP-0164 features exercised

- **`spec.artifacts.inputs/outputs`** — declarative artifact declarations on Tasks
- **`$(inputs.X.path)` / `$(outputs.X.path)`** — path substitution
- **`from: tasks.X.outputs.Y`** — pipeline artifact bindings
- **`buildOutput: true`** — marks primary build output for Chains/referrers
- **`config-artifact-storage`** — cluster-level OCI backend configuration
- **Automatic upload/download** — entrypoint handles OCI transport transparently

### Lines of YAML comparison

| | PoC (build-artifact-referrers) | TEP-0164 (this) |
|---|---|---|
| Tasks | ~200 lines (+ StepActions) | ~100 lines |
| Pipeline | ~80 lines | ~40 lines |
| StepActions | 2 required | 0 |
| Attach task | 1 required | 0 |
| Artifact params | 3-4 per task | 0 |

## Results integration

With Tekton Results deployed, artifact metadata is automatically captured
and queryable — no extra configuration needed. TEP-0164 populates
`status.artifacts.outputs` on TaskRuns, which Results watcher stores in
postgres.

```bash
# Query artifact inventory from Results API
./04-query-results.sh

# Query a specific PipelineRun
./04-query-results.sh build-and-test-xxxxx

# Demonstrate artifact metadata survives CRD deletion
./05-survive-deletion.sh
```

### Architecture

```
PipelineRun completes
    │
    ├── Pipeline controller → uploads artifacts to OCI registry
    │   └── status.artifacts.outputs = [{name, uri, digest}]
    │
    └── Results watcher → captures TaskRun/PipelineRun records
        └── postgres: artifact URIs + digests + results (queryable)

After CRD garbage collection:
    OCI registry  → artifact blobs (durable)
    Results API   → artifact metadata (durable, queryable)
    Cluster       → nothing (CRDs deleted) ← this is fine
```
