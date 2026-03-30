# tekton-experiments

Tekton experiments and proof-of-concepts.

## Experiments

### `build-artifact-bundle` — OCI Build Artifact Bundle

**Goal:** Produce a single OCI artifact per PipelineRun that bundles
everything: built images, test results, coverage — addressable
by one registry reference, inspectable per-layer.

**No PVCs needed.** Data flows entirely through OCI artifacts between
tasks (inspired by [Konflux CI trusted artifacts](https://github.com/konflux-ci/build-trusted-artifacts)).

This validates the design direction for [TEP-0164: Tekton Artifacts
Phase 2](https://github.com/tektoncd/community/pull/1248).

### Quick start

```bash
# Setup kind cluster with local registry + Tekton
./hack/setup.sh
export KUBECONFIG=/tmp/tekton-experiments.kubeconfig

# Apply tasks, pipeline, and run
kubectl apply -f build-artifact-bundle/01-tasks.yaml
kubectl apply -f build-artifact-bundle/02-pipeline.yaml
kubectl create -f build-artifact-bundle/run.yaml

# Watch progress
kubectl get pipelinerun -w
```

### Inspect the bundle

```bash
# View the OCI manifest — shows all layers with media types
$ oras manifest fetch --plain-http localhost:5555/tekton-experiments/bundle:latest | jq .
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

# Pull everything
$ oras pull --plain-http localhost:5555/tekton-experiments/bundle:latest
Downloading images-manifest.json
Downloading junit-results.xml
Downloading coverage.out

# Pull just the test results
$ oras pull --plain-http localhost:5555/tekton-experiments/bundle:latest \
    --include "junit-results.xml"

# Verify layer digests
$ oras manifest fetch --plain-http localhost:5555/tekton-experiments/bundle:latest | \
    jq '.layers[] | {file: .annotations["org.opencontainers.image.title"], digest: .digest, mediaType}'
```

### Teardown

```bash
./hack/setup.sh teardown
```

## About

This repo also serves as the build subject — the Go binary, tests,
and coverage produced here are the artifacts that get bundled.
