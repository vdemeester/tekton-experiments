# tekton-experiments

Tekton experiments and proof-of-concepts.

All experiments use **OCI artifacts for data transport between tasks**
(no PVCs) — inspired by [Konflux CI trusted artifacts](https://github.com/konflux-ci/build-trusted-artifacts).
They validate the design direction for [TEP-0164: Tekton Artifacts
Phase 2](https://github.com/tektoncd/community/pull/1248).

## Setup

```bash
# Creates a kind cluster with local registry + Tekton Pipelines + Chains
./hack/setup.sh
export KUBECONFIG=/tmp/tekton-experiments.kubeconfig

# Teardown when done
./hack/setup.sh teardown
```

## Experiments

### [`build-artifact-bundle`](build-artifact-bundle/) — Layers approach

All build outputs bundled into a **single multi-layer OCI manifest**.
One address, one pull gets everything.

```
registry/bundle:latest
├── Layer: images-manifest.json
├── Layer: junit-results.xml
└── Layer: coverage.out
```

```bash
kubectl apply -f build-artifact-bundle/01-tasks.yaml
kubectl apply -f build-artifact-bundle/02-pipeline.yaml
kubectl create -f build-artifact-bundle/run.yaml

# Inspect
oras manifest fetch --plain-http localhost:5555/tekton-experiments/bundle:latest | jq
oras pull --plain-http localhost:5555/tekton-experiments/bundle:latest
```

### [`build-artifact-referrers`](build-artifact-referrers/) — Referrers approach

Each build artifact attached as an **OCI referrer** to the built
container image, using the OCI 1.1 `subject` field. Same mechanism
as cosign signatures, SBOMs, and SLSA attestations.

```
image@sha256:8585...           ← the built image
├── referrer: images-manifest.json    (artifact type)
├── referrer: junit-results.xml       (artifact type)
├── referrer: coverage.out            (artifact type)
├── cosign signature                  (already works)
└── SLSA attestation                  (Tekton Chains)
```

```bash
kubectl apply -f build-artifact-referrers/01-tasks.yaml
kubectl apply -f build-artifact-referrers/02-pipeline.yaml
kubectl create -f build-artifact-referrers/run.yaml

# Discover referrers
oras discover --plain-http localhost:5555/tekton-experiments:latest
```

### Comparison

| | **Layers** | **Referrers** |
|---|---|---|
| Model | One manifest, multiple layers | Multiple manifests linked via `subject` |
| Address | Separate tag (`bundle:latest`) | The built image itself |
| Discovery | `oras manifest fetch` → layers array | `oras discover` → referrer tree |
| Pull one artifact | `oras pull --include "file"` | `oras pull <referrer-digest>` |
| Ecosystem fit | Custom convention | Native (cosign, SBOM, Chains) |
| History | One snapshot per tag | Referrers accumulate per image digest |

Both approaches use the same **shared primitives**:
- `create-oci-artifact` / `use-oci-artifact` StepActions for OCI transport
- `emptyDir` volumes (no PVCs)
- `oras` for OCI artifact operations

## About

This repo also serves as the build subject — the Go binary, tests,
and coverage produced here are the artifacts that get bundled/attached.
