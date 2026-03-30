# tekton-experiments

Tekton experiments and proof-of-concepts.

## Experiments

### `build-artifact-bundle` — OCI Build Artifact Bundle

**Goal:** Produce a single OCI artifact per PipelineRun that bundles
everything: built images, test results, coverage, SBOM — addressable
by one registry reference.

```
ghcr.io/vdemeester/tekton-experiments/artifacts:latest
├── Layer: images-manifest.json   (built image refs + digests)
├── Layer: junit-results.xml      (test results)
├── Layer: coverage.out           (test coverage)
└── Config: {pipelinerun, git-sha, timestamp}
```

This PoC uses **only existing Tekton primitives** (Steps, Workspaces,
Results) plus `oras` to push OCI artifacts — no code changes to
Tekton Pipelines needed.

It validates the design direction for [TEP-0164: Tekton Artifacts
Phase 2](https://github.com/tektoncd/community/pull/1248).

### Quick start

```bash
# Apply the pipeline (requires a Tekton-enabled cluster)
kubectl apply -f build-artifact-bundle/

# Run it
kubectl create -f build-artifact-bundle/run.yaml

# Inspect the bundle
oras manifest fetch ghcr.io/vdemeester/tekton-experiments/artifacts:latest | jq
oras pull ghcr.io/vdemeester/tekton-experiments/artifacts:latest --include "junit-results.xml"
```

## About

This repo also serves as the build subject — the Go binary, tests,
and coverage produced here are the artifacts that get bundled.
