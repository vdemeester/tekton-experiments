# Results + Artifact Archival

This experiment demonstrates how **Tekton Results** captures and indexes OCI artifact
metadata from PipelineRuns, bridging artifact creation (OCI referrers) with long-term
archival and queryability.

## Architecture

```
PipelineRun completes
    │
    ├── Chains → signs + attests (cosign, SLSA provenance)
    │
    └── Results Watcher → captures PipelineRun + TaskRun records
         │
         ├── Records: status, results (IMAGE_URL, IMAGE_DIGEST, artifact URIs)
         ├── Queryable via REST API with CEL filters
         └── Source of truth after CRD garbage collection
```

**Key insight:** Results stores metadata (small, queryable in postgres), OCI registry
stores blobs (large, tierable). Together they form a complete, searchable supply chain
inventory.

## Prerequisites

Run `./hack/setup.sh` — it installs Pipelines, Chains, **and** Results.

## Scripts

### `01-query-artifacts.sh`

Queries the Results API after a pipeline run to show:
- All Results/Records in the default namespace
- Filtering by annotation (git-sha, pipeline name)
- Extracting artifact URIs from TaskRun results

### `02-artifact-index.sh`

Builds a JSON artifact index by:
1. Querying Results API for completed PipelineRuns
2. Extracting artifact URIs from TaskRun results
3. Running `oras discover` on each to get the referrer tree
4. Producing a complete supply chain inventory

### `03-survive-deletion-demo.sh`

Demonstrates the core archival value proposition:
1. Shows current PipelineRuns/TaskRuns in the cluster
2. Verifies Results API has captured them
3. **Deletes ALL PipelineRuns and TaskRuns**
4. Queries Results API again — all data is still there

This proves that Results (postgres) is the durable source of truth after
CRD garbage collection. Artifact blobs remain in the OCI registry;
Results provides the queryable index.

## How It Relates to SRVKP-10766

| Requirement | How This Addresses It |
|---|---|
| Automatic archival of supply artifacts | Results auto-captures all run metadata |
| Metadata enrichment | Annotations flow through to Results records |
| Long-term retention | Results persists in postgres after CRD GC |
| Searchability | CEL filters on Results API |
| Storage optimization | Results=index (small), OCI=blobs (tiered) |
| Auditability | Results record → OCI image → referrer tree |
