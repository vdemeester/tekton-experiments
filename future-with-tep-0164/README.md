# Future with TEP-0164: Before and After

This directory contains **non-functional** YAML showing what the three
experiments would look like if [TEP-0164](https://github.com/tektoncd/community/pull/1248)
was implemented. These files can't be applied — they use proposed API
fields that don't exist yet. They serve as the "north star" for the TEP.

## What TEP-0164 eliminates

Every friction point discovered in the PoC experiments disappears:

| Today (PoC) | With TEP-0164 | Lines saved |
|---|---|---|
| `create-oci-artifact` StepAction (oras push) | Entrypoint uploads automatically | ~40 lines/task |
| `use-oci-artifact` StepAction (oras pull) | Init container downloads + verifies | ~30 lines/task |
| Export step (StepAction result → Task result) | Controller promotes artifact results | ~8 lines/task |
| `attach-artifacts` / `bundle-artifacts` Task | Controller handles grouping + referrers | Entire task gone |
| Chains `IMAGE_URL`/`IMAGE_DIGEST` type hinting | Controller provides artifact metadata to Chains | ~4 lines/task |
| Artifact URI plumbing (params/results chain) | `from: tasks.X.outputs.Y` binding | ~10 lines/pipeline |
| `insecure` param threading through all layers | `config-artifact-storage` ConfigMap | Per-cluster, once |
| `hack/setup.sh` registry setup | Operator configures storage backend | Per-cluster, once |

**Total: ~60% fewer lines of YAML for the same pipeline.**

## The three experiments, reimagined

### 1. Container image build → [01-image-build.yaml](01-image-build.yaml)

The `build-artifact-referrers` experiment rewritten.
- Tasks declare `spec.artifacts.inputs/outputs`
- Steps just write files to `$(outputs.name.path)` — Tekton handles the rest
- Pipeline binds artifacts with `from: tasks.X.outputs.Y`
- No StepActions, no oras, no export steps, no attach task
- Chains integration is automatic (no `IMAGE_URL`/`IMAGE_DIGEST` type hinting)

### 2. Binary tarball build → [02-binary-build.yaml](02-binary-build.yaml)

The `build-artifact-referrers-noimage` experiment rewritten.
- Same declarative API works for non-container artifacts
- `mediaType` hint tells Tekton how to store the artifact
- `buildOutput: true` marks the tarball as the referrer subject

### 3. Config and PipelineRun → [03-config-and-run.yaml](03-config-and-run.yaml)

The cluster-level configuration and PipelineRun that ties it together.
- `config-artifact-storage` ConfigMap configures OCI backend once
- PipelineRun has zero artifact boilerplate — just params

### Artifact storage vs referrer attachment

These are two **distinct** concerns that TEP-0164 must handle separately:

#### 1. Artifact storage (passing data between tasks)

When a task produces an output artifact (source code, test results, coverage),
the controller uploads it to a **staging repository** configured in
`config-artifact-storage`. This is an OCI repository used purely for
intermediate data transfer — the equivalent of today's `oras push` to
`artifact-store`.

Example: `ghcr.io/org/project/artifacts:ns-pipelinerun-junit`

#### 2. Referrer attachment (supply chain graph on the build output)

When `oci.attachReferrers: "true"` is set and a pipeline has a
`buildOutput: true` artifact, the controller must **re-push** (or
cross-mount) those artifacts into the **subject's repository** with a
`subject` descriptor pointing to the build output's digest.

This is required by the [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers):

> Each descriptor is of an image manifest or index **in the same `<name>`
> namespace** with a `subject` field that specifies the value of `<digest>`.

Referrers **cannot** cross repository boundaries. A manifest in
`ghcr.io/org/project/artifacts` cannot be a referrer to an image in
`ghcr.io/org/project`. The referrer manifest must live in the same
repository as its subject.

#### What the controller must do

For a pipeline with `buildOutput: true`:

1. **During the run**: store intermediate artifacts in `oci.repository`
   (the staging repo) for task-to-task passing.
2. **After the run**: for each output artifact, push a manifest into
   the **build output's repository** with `subject` set to the build
   output's digest. This is the equivalent of `oras attach`.

For a pipeline **without** `buildOutput` (e.g. binary tarball builds
where the artifact store *is* the final location), referrers are
attached within the artifact store repo itself.

```
# Image build: two repos involved
ghcr.io/org/project/artifacts   ← staging (task-to-task passing)
ghcr.io/org/project             ← referrers live here (same repo as image)

# Binary build: one repo
ghcr.io/org/project/artifacts   ← both staging AND referrer subject
```

#### Cross-registry implications

If the build output lives in a different registry than the artifact
storage (e.g. image pushed to `quay.io/org/project` but artifacts
stored in `ghcr.io/org/project/artifacts`), the controller must:
- Have push credentials for the build output's registry
- Cross-mount or re-upload artifact blobs into that registry
- Push referrer manifests there

This should be clearly documented and the controller should fail
gracefully (with a warning, not a pipeline failure) if it cannot
attach referrers due to missing credentials or registry limitations.

### Chains integration

With TEP-0164, Chains integration becomes seamless:
- Artifacts with `buildOutput: true` are automatically recognized by Chains as SLSA subjects
- No `IMAGE_URL`/`IMAGE_DIGEST` type hinting needed — the controller provides artifact metadata
- Chains attestations, cosign signatures, and build artifacts all appear as OCI referrers
- The full supply chain graph is visible via `cosign tree` or `oras discover`

Chains attestations follow the same OCI referrer constraint — they
must be pushed to the **subject's repository**. Today this works
because Chains knows the image ref directly. With TEP-0164, the
controller provides this metadata to Chains via TaskRun/PipelineRun
status, so Chains doesn't need type-hinted result names.

Today's PoC already demonstrates this on ghcr.io (see `build-artifact-referrers/`),
but TEP-0164 eliminates the manual plumbing required to make it work.

## Side-by-side: today vs TEP-0164

### Task definition

**Today (91 lines):**
```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: run-tests
spec:
  params:
    - name: source-artifact          # manual URI passing
    - name: artifact-store           # manual registry config
    - name: insecure                 # manual registry mode
    - name: packages
    - name: go-version
  results:
    - name: tests-passed
    - name: coverage-pct
    - name: junit-artifact           # manual result for artifact URI
    - name: coverage-artifact        # manual result for artifact URI
  volumes:
    - name: workdir
      emptyDir: {}                   # manual volume for data
  stepTemplate:
    volumeMounts:
      - name: workdir
        mountPath: /var/workdir      # manual mount
  steps:
    - name: use-source               # manual fetch step
      ref:
        name: use-oci-artifact
      params:
        - name: uri
          value: $(params.source-artifact)
        - name: path
          value: /var/workdir/source
    - name: test
      image: docker.io/library/golang:$(params.go-version)
      script: |
        # ... test logic ...
    - name: create-junit-artifact    # manual push step
      ref:
        name: create-oci-artifact
      params:
        - name: store
          value: $(params.artifact-store)
        - name: name
          value: junit-results.xml
        - name: path
          value: /var/workdir/junit-results.xml
    - name: create-coverage-artifact # manual push step
      ref:
        name: create-oci-artifact
      params:
        - name: store
          value: $(params.artifact-store)
        - name: name
          value: coverage.out
        - name: path
          value: /var/workdir/coverage.out
    - name: export-results           # manual export step
      image: alpine:3.20
      env:
        - name: JUNIT_URI
          value: $(steps.create-junit-artifact.results.uri)
        - name: COVERAGE_URI
          value: $(steps.create-coverage-artifact.results.uri)
      script: |
        echo -n "${JUNIT_URI}" > $(results.junit-artifact.path)
        echo -n "${COVERAGE_URI}" > $(results.coverage-artifact.path)
```

**TEP-0164 (31 lines):**
```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: run-tests
spec:
  params:
    - name: packages
    - name: go-version
  results:
    - name: tests-passed
    - name: coverage-pct
  artifacts:
    inputs:
      - name: source
    outputs:
      - name: test-results
        mediaType: application/vnd.tekton.artifact.junit.v1+xml
      - name: coverage
        mediaType: application/vnd.tekton.artifact.coverage.v1
  steps:
    - name: test
      image: docker.io/library/golang:$(params.go-version)
      script: |
        cd $(inputs.source.path)
        gotestsum --junitfile $(outputs.test-results.path)/junit.xml ...
        go test -coverprofile=$(outputs.coverage.path)/coverage.out ...
```

**That's it.** No StepActions, no volumes, no export steps.
The controller handles download, upload, digest verification, and
result propagation.

### Pipeline definition

**Today (50+ lines):**
```yaml
tasks:
  - name: run-tests
    taskRef:
      name: run-tests
    params:
      - name: source-artifact
        value: $(tasks.git-clone.results.source-artifact)  # manual plumbing
      - name: artifact-store
        value: $(params.artifact-store)                    # manual config passing
      - name: packages
        value: "./..."
  - name: attach                                           # entire extra task!
    taskRef:
      name: attach-artifacts
    params:
      - name: image-ref
        value: $(tasks.build-image.results.image-ref)
      - name: junit-artifact
        value: $(tasks.run-tests.results.junit-artifact)   # manual plumbing
      - name: coverage-artifact
        value: $(tasks.run-tests.results.coverage-artifact) # manual plumbing
```

**TEP-0164 (12 lines):**
```yaml
tasks:
  - name: run-tests
    taskRef:
      name: run-tests
    artifacts:
      inputs:
        - name: source
          from: tasks.git-clone.outputs.source  # declarative binding
    params:
      - name: packages
        value: "./..."
  # No attach task — controller handles referrer attachment automatically
```
