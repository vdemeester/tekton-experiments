# Build Artifact Referrers (non-container) — PoC

## What this proves

OCI referrers work for **any build output** — not just container images.
A Go binary tarball pushed as an OCI artifact becomes the subject,
with test results and coverage attached as referrers.

This applies to RPMs, JARs, Helm charts, WASM modules, ML models —
anything you can push to an OCI registry.

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
    │  build-binary    │        │  run-tests-local  │
    │                  │        │                   │
    │  go build (4 OS) │        │  gotestsum        │
    │  tar -czf        │        │  junit + coverage │
    │  oras push ──────┼──┐     └────────┬──────────┘
    └──────────────────┘  │              │
                          │              │
          binary tarball  │              │
          (the subject)   │              │
                          ▼              ▼
                    ┌─────────────────────────┐
                    │ attach-artifacts-to-binary│
                    │                          │
                    │ oras attach              │
                    │ junit → binary           │
                    │ coverage → binary        │
                    └──────────────────────────┘
```

## Binary artifact manifest (real output)

The subject is a **tarball**, not a container image:

```json
{
  "config": {
    "mediaType": "application/vnd.tekton.build-info.v1+json"
  },
  "layers": [
    {
      "mediaType": "application/gzip",
      "size": 5739182,
      "annotations": {
        "org.opencontainers.image.title": "tekton-experiments-latest.tar.gz"
      }
    }
  ]
}
```

## Referrer tree (real output)

```
$ oras discover localhost:5555/tekton-experiments/bin:latest

localhost:5555/tekton-experiments/bin@sha256:25a17b58...
├── application/vnd.tekton.artifact.junit.v1+xml
│   └── sha256:8e1a0cd729b5...
│       └── [annotations]
│           ├── dev.tekton.artifact/pipelinerun: build-artifact-noimage-9gxsn
│           └── dev.tekton.artifact/task: run-tests
└── application/vnd.tekton.artifact.coverage.v1
    └── sha256:97eb0701b053...
        └── [annotations]
            ├── dev.tekton.artifact/pipelinerun: build-artifact-noimage-9gxsn
            └── dev.tekton.artifact/task: run-tests
```

## Pull the binary

```bash
# Pull the tarball
oras pull registry/bin:latest
tar -tzf tekton-experiments-latest.tar.gz
# tekton-experiments-darwin-amd64
# tekton-experiments-darwin-arm64
# tekton-experiments-linux-amd64
# tekton-experiments-linux-arm64

# Pull just the test results
DIGEST=$(oras discover --format json registry/bin:latest | \
  jq -r '.referrers[] | select(.artifactType | contains("junit")) | .digest')
oras pull "registry/bin@${DIGEST}"
```

## Implications for TEP-0164

The `subject` for referrers doesn't have to be a container image.
TEP-0164's artifact API should support declaring any build output as
the subject:

```yaml
# Future TEP-0164 API
spec:
  artifacts:
    outputs:
      - name: binary
        type: file                    # not a container image
        mediaType: application/gzip
        buildOutput: true             # this becomes the subject
      - name: test-results
        type: file
        mediaType: application/xml
        attachTo: binary              # referrer to the binary
```
