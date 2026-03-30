# Build Artifact Referrers — PoC

## What this proves

Build artifacts (test results, coverage, image manifests) attached as
**OCI referrers** to the built container image — using the OCI 1.1
`subject` field and the referrers API.

This is the same mechanism used by **cosign signatures**, **SBOMs**,
and **SLSA attestations**. Build artifacts become first-class citizens
in the OCI supply chain graph.

**No PVCs.** No separate bundle. Artifacts live alongside the image.

## Architecture

```
                        PipelineRun
                            │
                            ▼
                    ┌───────────────┐
                    │  git-clone-oci│
                    └───────┬───────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐
    │   build-image    │        │    run-tests      │
    │  → image@sha256  │        │  → junit, coverage│
    └────────┬─────────┘        └────────┬──────────┘
             │                           │
             └─────────┬─────────────────┘
                       ▼
              ┌────────────────┐
              │ attach-artifacts│
              │                │
              │ oras attach    │
              │ each artifact  │
              │ as referrer to │
              │ the built image│
              └────────────────┘
                       │
                       ▼
         image@sha256:8585...  (the subject)
         ├── referrer: images-manifest.json
         ├── referrer: junit-results.xml
         └── referrer: coverage.out
```

## Referrer tree (real output)

```
$ oras discover localhost:5555/tekton-experiments:latest

localhost:5555/tekton-experiments@sha256:85857e29...
├── application/vnd.tekton.artifact.images.v1+json
│   └── sha256:f4b9bba12916...
│       └── [annotations]
│           ├── dev.tekton.artifact/build-output: "true"
│           ├── dev.tekton.artifact/pipelinerun: build-artifact-referrers-65qfq
│           └── dev.tekton.artifact/task: build-image
├── application/vnd.tekton.artifact.junit.v1+xml
│   └── sha256:5e9b94f905af...
│       └── [annotations]
│           ├── dev.tekton.artifact/pipelinerun: build-artifact-referrers-65qfq
│           └── dev.tekton.artifact/task: run-tests
└── application/vnd.tekton.artifact.coverage.v1
    └── sha256:2d0eddcd8cab...
        └── [annotations]
            ├── dev.tekton.artifact/pipelinerun: build-artifact-referrers-65qfq
            └── dev.tekton.artifact/task: run-tests
```

## Referrer manifest (shows `subject` field)

```json
{
  "artifactType": "application/vnd.tekton.artifact.junit.v1+xml",
  "subject": {
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "digest": "sha256:85857e2956f0ad24167db262180e4ecda6dd3a1965946d1c80c5a6784d5418aa",
    "size": 1416
  },
  "annotations": {
    "dev.tekton.artifact/git-sha": "b3ee0c87db49...",
    "dev.tekton.artifact/pipelinerun": "build-artifact-referrers-65qfq",
    "dev.tekton.artifact/task": "run-tests"
  }
}
```

## Consumer experience

```bash
# Discover all artifacts attached to an image
oras discover registry/image:tag

# Pull a specific artifact type
DIGEST=$(oras discover --format json registry/image:tag | \
  jq -r '.referrers[] | select(.artifactType=="application/vnd.tekton.artifact.junit.v1+xml") | .digest')
oras pull "registry/image@${DIGEST}"

# Filter by pipelinerun (when multiple runs attach to same image)
oras discover --format json registry/image:tag | \
  jq '.referrers[] | select(.annotations["dev.tekton.artifact/pipelinerun"]=="my-run")'
```

## Full pipeline (`--full`)

The full pipeline adds SBOM generation (syft) and documentation:

```bash
./hack/run.sh --full
```

```
git-clone → build-image ─┬─→ generate-sbom ──┐
           run-tests ────┤                    ├→ attach-all-artifacts
           generate-docs ┘                    │
```

## Key advantage: ecosystem native

Referrers accumulate on the image — cosign signatures, SBOMs, SLSA
attestations, and now build artifacts all live in the same graph.

Real output from ghcr.io (`cosign tree`):

```
ghcr.io/vdemeester/tekton-experiments:latest
├── 🔐 Attestations (Tekton Chains SLSA provenance)
│   ├── sha256:cf27bc70...
│   └── sha256:73007a58...
├── 🔐 Signatures (Tekton Chains cosign)
│   └── sha256:833c9320...
├── 🔐 SBOMs (ko-generated SPDX)
│   └── sha256:8136b512...
├── 📦 coverage.out (OCI referrer)
├── 📦 images-manifest.json (OCI referrer)
└── 📦 junit-results.xml (OCI referrer)
```

## Files

- `01-tasks.yaml` — StepActions + Tasks (clone, build, test, attach)
- `01-extras.yaml` — Extra tasks for full pipeline (SBOM, docs, attach-all)
- `02-pipeline.yaml` — Basic pipeline (build + test + attach)
- `02-pipeline-full.yaml` — Full pipeline (+ SBOM, docs)
- `run.yaml` — Example PipelineRun (local registry)
- `run-full.yaml` — Example PipelineRun for full pipeline
