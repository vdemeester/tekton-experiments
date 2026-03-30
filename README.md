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

### [`build-artifact-referrers-noimage`](build-artifact-referrers-noimage/) — Referrers for non-container artifacts

Same referrers pattern, but the build output is a **Go binary tarball**
(not a container image). Proves OCI referrers work for RPMs, JARs,
Helm charts — anything pushable to an OCI registry.

```
binary-tarball@sha256:25a1...     ← a .tar.gz, not an image
├── referrer: junit-results.xml
└── referrer: coverage.out
```

```bash
kubectl apply -f build-artifact-referrers-noimage/01-tasks.yaml
kubectl apply -f build-artifact-referrers-noimage/02-pipeline.yaml
kubectl create -f build-artifact-referrers-noimage/run.yaml

# Discover referrers on a tarball
oras discover --plain-http localhost:5555/tekton-experiments/bin:latest
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

### [`future-with-tep-0164`](future-with-tep-0164/) — What it looks like with TEP-0164

**Non-functional YAML** showing the same experiments rewritten with the
proposed declarative artifact API. Side-by-side comparison of today vs
tomorrow — ~60% fewer lines, no StepActions, no attach task, no
artifact URI plumbing.

```yaml
# Today: 7 steps per task (fetch, build, push, export...)
# TEP-0164: 1 step per task (just build)
artifacts:
  inputs:
    - name: source
  outputs:
    - name: test-results
      mediaType: application/vnd.tekton.artifact.junit.v1+xml
steps:
  - name: test
    script: |
      cd $(inputs.source.path)                              # ← auto-fetched
      gotestsum --junitfile $(outputs.test-results.path)/... # ← auto-uploaded
```

---

All approaches use the same **shared primitives**:
- `create-oci-artifact` / `use-oci-artifact` StepActions for OCI transport
- `emptyDir` volumes (no PVCs)
- `oras` for OCI artifact operations

## About

This repo also serves as the build subject — the Go binary, tests,
and coverage produced here are the artifacts that get bundled/attached.
