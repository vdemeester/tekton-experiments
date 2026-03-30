# Build Artifact Bundle — PoC

## What this proves

A single OCI artifact per PipelineRun that bundles **all build outputs**
into one addressable, inspectable, distributable object — using only
existing Tekton primitives (no code changes).

## Architecture

```
                        PipelineRun
                            │
         ┌──────────────────┼──────────────────┐
         ▼                  ▼                  ▼
   ┌───────────┐    ┌──────────────┐    ┌────────────┐
   │ git-clone │    │              │    │            │
   │           │───▶│ build-image  │    │ run-tests  │
   │ (catalog) │    │              │    │            │
   └───────────┘    └──────┬───────┘    └─────┬──────┘
         │                 │                  │
         │          images-manifest.json      │
         │                 │           junit-results.xml
         │                 │           coverage.out
         │                 ▼                  ▼
         │          ┌─────────────────────────────────┐
         │          │      bundle-artifacts            │
         │          │                                  │
         │          │  Collects all outputs + pushes   │
         │          │  as single OCI artifact via oras │
         │          │                                  │
         │          │  → registry/artifacts:tag        │
         │          └─────────────────────────────────┘
         │
         ▼
  ┌─────────────────────────────────────────────────────┐
  │  OCI Artifact Bundle                                │
  │  ghcr.io/vdemeester/tekton-experiments/artifacts:v1 │
  │                                                     │
  │  Config: {pipelinerun, git-sha, timestamp}          │
  │  Layer 0: images-manifest.json                      │
  │  Layer 1: junit-results.xml                         │
  │  Layer 2: coverage.out                              │
  └─────────────────────────────────────────────────────┘
```

## Consumer experience

```bash
# Pull everything
oras pull ghcr.io/vdemeester/tekton-experiments/artifacts:v1

# Just test results
oras pull ghcr.io/vdemeester/tekton-experiments/artifacts:v1 \
  --include "junit-results.xml"

# Inspect manifest (see all layers + annotations)
oras manifest fetch ghcr.io/vdemeester/tekton-experiments/artifacts:v1 | jq

# Verify layer digests
oras manifest fetch ghcr.io/vdemeester/tekton-experiments/artifacts:v1 | \
  jq '.layers[] | {title: .annotations["org.opencontainers.image.title"], digest}'
```

## What this shows for TEP-0164

| Today (this PoC)                          | With TEP-0164                               |
|-------------------------------------------|----------------------------------------------|
| Manual `oras push` step                   | Entrypoint handles upload automatically      |
| Workspace plumbing between tasks          | Declarative `spec.artifacts` + auto-wiring   |
| Bundle task knows all file names           | Controller collects declared outputs         |
| No digest verification between tasks      | Init container verifies on download          |
| Auth handled manually in step             | SA credentials propagated automatically      |
| No Chains integration for bundle          | Chains reads StorageRef from status          |

## Files

- `01-tasks.yaml` — Task definitions (build, test, bundle)
- `02-pipeline.yaml` — Pipeline wiring the tasks together
- `run.yaml` — Example PipelineRun
