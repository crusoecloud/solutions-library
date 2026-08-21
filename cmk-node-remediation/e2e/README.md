# E2E Tests

End-to-end tests for crusoe-node-remediation.

## Quick Start

```bash
# 1. Copy values template and fill in your cluster details
cp e2e/example-values.yaml e2e/values.yaml
# Edit e2e/values.yaml: set image.repository

# 2. Run all phases (build + deploy + verify)
bash e2e/run-e2e.sh all --values e2e/values.yaml

# 3. Or run individual phases
bash e2e/run-e2e.sh build
bash e2e/run-e2e.sh deploy --values e2e/values.yaml
bash e2e/run-e2e.sh deploy-workloads
bash e2e/run-e2e.sh verify
bash e2e/run-e2e.sh verify-pdb
bash e2e/run-e2e.sh dry-run-off
bash e2e/run-e2e.sh vm-reset
bash e2e/run-e2e.sh cleanup
```

## How It Works

The E2E test uses the **same Helm chart** as production — just with a
different `values.yaml`. The workflow is identical:

```bash
# E2E (test cluster, fast thresholds, noop action)
helm install crusoe-node-remediation ./helm/crusoe-node-remediation \
  --namespace crusoe-node-remediation \
  -f e2e/example-values.yaml

# Production (real cluster, 55d/55d thresholds, vm-reset)
helm install crusoe-node-remediation ./helm/crusoe-node-remediation \
  --namespace crusoe-node-remediation \
  -f my-production-values.yaml
```

## Files

| File | Committed? | Purpose |
|------|-----------|---------|
| `e2e/example-values.yaml` | ✅ Yes | Template with test defaults (noop, 30m/1h, dry-run) |
| `e2e/values.yaml` | ❌ No (gitignored) | Your cluster details — copy from template |
| `e2e/run-e2e.sh` | ✅ Yes | Test script — 10 phases, all idempotent |

## Setup

Copy the values template and fill in your cluster details:

```bash
cp e2e/example-values.yaml e2e/values.yaml
```

Edit `e2e/values.yaml`:

```yaml
image:
  repository: registry.your-location.ccr.crusoecloudcompute.com/crusoe-node-remediation.your-project-id
  tag: v0.0.23

nodeSelector:
  matchLabels:
    crusoe.ai/project.id: "your-project-id"

crusoeProjectId: "your-project-id"
```

## Phases

| Phase | Command | What it does | Idempotent? |
|-------|---------|-------------|-------------|
| build | `bash e2e/run-e2e.sh build` | Build + push container image | ✅ |
| deploy | `bash e2e/run-e2e.sh deploy` | Create secret + install Helm (dry-run) | ✅ |
| deploy-workloads | `bash e2e/run-e2e.sh deploy-workloads` | Create test workloads with PDBs | ✅ |
| verify | `bash e2e/run-e2e.sh verify` | Check logs, events, labels | ✅ (read-only) |
| verify-pdb | `bash e2e/run-e2e.sh verify-pdb` | Verify drain respects PDBs | ✅ (read-only) |
| dry-run-off | `bash e2e/run-e2e.sh dry-run-off` | Upgrade to dryRun=false (noop) | ✅ |
| vm-reset | `bash e2e/run-e2e.sh vm-reset` | Real VM reset (interactive confirm) | ✅ |
| empirical | `bash e2e/run-e2e.sh empirical [N]` | Run N passes of vm-reset with timing data (default 5) | ✅ |
| cleanup | `bash e2e/run-e2e.sh cleanup` | Uninstall + uncordon + remove test workloads | ✅ |
| all | `bash e2e/run-e2e.sh all` | build + deploy + verify | ✅ |

## PDB Drain Verification

The `deploy-workloads` phase creates three test workloads in `crusoe-e2e-test` namespace:

| Workload | PDB? | Replicas | What it tests |
|----------|------|----------|---------------|
| `pdb-test` | ✅ `minAvailable: 2` | 3 | Drain should block (only 1 evictable) |
| `no-pdb-test` | ❌ | 2 | Drain should evict cleanly |
| `emptydir-test` | ❌ | 2 | Force drain should delete emptyDir data |

### Test flow

```bash
# 1. Deploy workloads with PDBs
bash e2e/run-e2e.sh deploy-workloads

# 2. Run remediation with forceAfterEvictionFailure=false
#    → drain should block on PDB-protected pods, node left cordoned
bash e2e/run-e2e.sh dry-run-off  # noop action, tests cordon/drain/uncordon
bash e2e/run-e2e.sh verify-pdb

# 3. Switch to forceAfterEvictionFailure=true and re-run
#    → force drain bypasses PDB, pods evicted
helm upgrade crusoe-node-remediation ./helm/crusoe-node-remediation \
  --namespace crusoe-node-remediation \
  -f e2e/values.yaml \
  --set forceAfterEvictionFailure=true
bash e2e/run-e2e.sh verify-pdb

# 4. Clean up
bash e2e/run-e2e.sh cleanup
```

### What to look for

With `forceAfterEvictionFailure: false`:
- Logs show `drain blocked for node X` and `DrainBlocked` event
- PDB-protected pods remain on the node
- Node left cordoned (not remediated)

With `forceAfterEvictionFailure: true`:
- Logs show `force draining node X`
- All pods evicted (including PDB-protected)
- Node remediated and uncordoned

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--values FILE` | Path to values file | `e2e/values.yaml` |
| `--namespace NS` | Kubernetes namespace | `crusoe-node-remediation` |
| `--use-builtin-secret` | Use `crusoe-secrets` from `crusoe-system` (CMK) | auto-detect from values |
| `--no-builtin-secret` | Use custom secret (requires `CRUSOE_ACCESS_KEY`/`CRUSOE_SECRET_KEY`) | auto-detect from values |
