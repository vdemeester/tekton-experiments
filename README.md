# tekton-experiments

Tekton experiments and proof-of-concepts.

All experiments use **OCI artifacts for data transport between tasks**
(no PVCs) — inspired by [Konflux CI trusted artifacts](https://github.com/konflux-ci/build-trusted-artifacts).
They validate the design direction for [TEP-0164: Tekton Artifacts
Phase 2](https://github.com/tektoncd/community/pull/1248).

## Setup

```bash
# Local registry (default — no auth needed, fully offline)
./hack/setup.sh
export KUBECONFIG=/tmp/tekton-experiments.kubeconfig

# Or with an external registry (ghcr.io, quay.io, etc.)
./hack/setup.sh --registry ghcr.io/vdemeester
export KUBECONFIG=/tmp/tekton-experiments.kubeconfig

# Teardown
./hack/setup.sh teardown
```

## Run

```bash
# Basic referrers pipeline (build + test → attach to image)
./hack/run.sh

# Full pipeline (+ SBOM via syft, docs, Chains attestation)
./hack/run.sh --full

# Non-container artifact (binary tarball as subject)
./hack/run.sh --noimage

# Override registry at run time
./hack/run.sh --full --registry ghcr.io/vdemeester
```

## Experiments

### [`build-artifact-referrers`](build-artifact-referrers/) — Referrers approach ⭐

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
./hack/run.sh
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
./hack/run.sh --noimage
oras discover --plain-http localhost:5555/tekton-experiments/bin:latest
```

### ~~[`build-artifact-bundle`](build-artifact-bundle/) — Layers approach~~ (superseded)

> **Superseded by the referrers approach.** Kept for reference only.
>
> Bundles all outputs as layers in a single OCI manifest. While simpler
> conceptually, it creates a parallel artifact outside the OCI supply
> chain graph. The referrers approach is superior because it uses the
> same mechanism as cosign signatures, SBOMs, and SLSA attestations —
> no separate convention needed.

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

All PoC experiments use the same **shared primitives**:
- `create-oci-artifact` / `use-oci-artifact` StepActions for OCI transport
- `emptyDir` volumes (no PVCs)
- `oras` for OCI artifact operations

With TEP-0164, **none of these are needed** — the controller and
entrypoint handle OCI transport transparently.

## About

This repo also serves as the build subject — the Go binary, tests,
and coverage produced here are the artifacts that get bundled/attached.
