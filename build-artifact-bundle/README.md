# Build Artifact Bundle — PoC

## What this proves

A single OCI artifact per PipelineRun that bundles **all build outputs**
into one addressable, inspectable, distributable object — using only
existing Tekton primitives (no code changes to Tekton Pipelines).

**No PVCs.** Data flows entirely through OCI artifacts between tasks.

## Architecture

```
                        PipelineRun
                            │
                            ▼
                    ┌───────────────┐
                    │  git-clone-oci│
                    │               │
                    │  clone repo   │
                    │  oras push ───┼──▶ oci:registry/artifacts@sha256:...
                    └───────┬───────┘               (source tarball)
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐
    │   build-image    │        │    run-tests      │
    │                  │        │                   │
    │  oras pull src   │        │  oras pull src    │
    │  ko build        │        │  gotestsum        │
    │  oras push ──────┼──┐     │  oras push ───────┼──┐
    └──────────────────┘  │     └───────────────────┘  │
                          │                            │
              images-manifest.json          junit-results.xml
                          │                 coverage.out
                          │                            │
                          ▼                            ▼
                    ┌─────────────────────────────────────┐
                    │         bundle-artifacts             │
                    │                                      │
                    │  oras pull (each artifact by digest) │
                    │  oras push (single multi-layer OCI)  │
                    │                                      │
                    │  ──▶ registry/bundle:latest          │
                    └─────────────────────────────────────┘
```

## OCI Manifest (real output)

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.tekton.build-artifact.v1+json",
    "digest": "sha256:b662336929e0...",
    "size": 209
  },
  "layers": [
    {
      "mediaType": "application/vnd.tekton.artifact.images.v1+json",
      "digest": "sha256:64ef25b36445...",
      "size": 348,
      "annotations": {
        "org.opencontainers.image.title": "images-manifest.json"
      }
    },
    {
      "mediaType": "application/vnd.tekton.artifact.junit.v1+xml",
      "digest": "sha256:71b49b8e27aa...",
      "size": 1266,
      "annotations": {
        "org.opencontainers.image.title": "junit-results.xml"
      }
    },
    {
      "mediaType": "application/vnd.tekton.artifact.coverage.v1",
      "digest": "sha256:3e9b9ad48d57...",
      "size": 366,
      "annotations": {
        "org.opencontainers.image.title": "coverage.out"
      }
    }
  ],
  "annotations": {
    "dev.tekton.artifact/created": "2026-03-30T14:43:53Z",
    "dev.tekton.artifact/git-sha": "667a418878369...",
    "dev.tekton.artifact/git-url": "https://github.com/vdemeester/tekton-experiments",
    "dev.tekton.artifact/pipelinerun": "build-artifact-bundle-64npn"
  }
}
```

## Task results (real output)

```
git-clone:
  commit:          667a4188783691e05d603667b140b9ae20b51195
  source-artifact: oci:registry/artifacts@sha256:17d53ac8...

build-image:
  image-ref:       registry/tekton-experiments@sha256:85857e29...
  images-artifact: oci:registry/artifacts@sha256:5aed7351...

run-tests:
  tests-passed:     true
  coverage-pct:     33.3%
  junit-artifact:   oci:registry/artifacts@sha256:8e31bde3...
  coverage-artifact: oci:registry/artifacts@sha256:b1d886e8...

bundle:
  bundle-ref:    registry/bundle:latest
  bundle-digest: sha256:e04b84d61c4a...
```

## Consumer experience

```bash
# Pull everything
oras pull registry/bundle:latest

# Just test results
oras pull registry/bundle:latest --include "junit-results.xml"

# Inspect manifest (see all layers + annotations)
oras manifest fetch registry/bundle:latest | jq

# List layers with digests
oras manifest fetch registry/bundle:latest | \
  jq '.layers[] | {file: .annotations["org.opencontainers.image.title"], digest, mediaType}'
```

## What this shows for TEP-0164

| Today (this PoC)                                   | With TEP-0164                                |
|----------------------------------------------------|----------------------------------------------|
| Manual `oras push/pull` in StepActions              | Entrypoint/init container handles it         |
| Export step to copy StepAction result → Task result | Controller promotes artifact results         |
| Bundle task must know every file name               | Controller collects all declared outputs     |
| Artifact URI plumbing through params/results        | `$(tasks.build.outputs.images)` auto-resolves|
| No digest verification between tasks                | Init container verifies on download          |

## Files

- `01-tasks.yaml` — StepActions (create/use OCI artifact) + Tasks (clone, build, test, bundle)
- `02-pipeline.yaml` — Pipeline wiring
- `run.yaml` — Example PipelineRun (local registry, no auth)
