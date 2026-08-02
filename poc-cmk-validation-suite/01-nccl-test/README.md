# 01 — NCCL all_reduce_perf bandwidth test

A 5-minute multi-node NCCL test that proves the InfiniBand fabric and NCCL stack are healthy
before you commit to a longer training-style benchmark.

Built on the official Crusoe-recommended pattern documented at
<https://support.crusoecloud.com/hc/en-us/articles/36499606523291>, adapted for multi-SKU
use with prebuilt `public.ecr.aws/hpc-cloud/nccl-tests:latest` (no image build required).

## When to run

- **First** thing on a freshly provisioned CMK GPU cluster
- **Before** running [`../02-torchtitan-llama3-8b/`](../02-torchtitan-llama3-8b/) — fabric
  bugs (e.g. bad `NCCL_IB_GID_INDEX`, misconfigured HCAs) surface here much faster
- **When triaging** a customer report of slow training — isolates network from app stack

## Prerequisites

- Kubeflow MPI Operator v0.6.0 — install with `../00-prerequisites/install-mpi-operator.sh`
- ≥2 GPU worker nodes of the same SKU (the manifests are configured for `Worker.replicas: 2`)
- Standard CMK add-ons present: `nvidia_gpu_operator`, `nvidia_network_operator`, `crusoe_csi`

## Pick your SKU and apply

| Cluster SKU | Manifest |
|---|---|
| H100 80GB SXM IB | `nccl-test-h100.yaml` |
| H200 141GB SXM IB | `nccl-test-h200.yaml` |
| B300 288GB SXM IB | `nccl-test-b300.yaml` |

The B300 variant uses a different container image
(`ghcr.io/datadoc24/b300-nccl-tests:cuda-13.2` — CUDA 13.x, `sm_100`-compiled
`nccl-tests`, topology XML baked in). It also uses a different `NCCL_IB_HCA` list
and enables `NCCL_NVLS_ENABLE=1` for Blackwell in-network SHARP reduction. The
DNS-wait initContainer pattern is shared with H100/H200.

For B200 today, use the sibling [`b300-nccltest-cmk-mpijob/`](../../b300-nccltest-cmk-mpijob/)
as a starting point — it works for both Blackwell SKUs; swap the topology XML.

```bash
# 1. Create a dedicated namespace
kubectl create namespace nccl-test

# 2. Apply the manifest for your SKU
kubectl -n nccl-test create -f nccl-test-h200.yaml

# 3. Watch pods come up (image pull can take 5–10 min in some regions; first time only)
kubectl -n nccl-test get pods -w

# 4. Tail the launcher logs (bandwidth output appears here)
kubectl -n nccl-test logs -f -l training.kubeflow.org/job-role=launcher
```

## Reading the output

`all_reduce_perf` produces a table across a range of message sizes. The `busbw` column on
the right side of each row is what to read — the bus bandwidth that NCCL achieved across
the ring of GPUs.

The H100/H200 manifests sweep 8 B → 16 GiB (32 rows) to cover both the latency- and
bandwidth-dominated regimes. The B300 manifest sweeps only 2 GiB → 32 GiB (5 rows) — the
small-size latency numbers aren't useful diagnostic signal for Blackwell, and the large-size
rows are where SHARP wins become visible.

**Look for:**

- **`busbw at the largest size`** — this is the asymptotic, bandwidth-dominated number.
  Expected per SKU (16-GPU / 2-node, SHARP-enabled):

  | SKU | Expected large-size busbw |
  |---|---|
  | H100 80GB SXM IB | ~370–390 GB/s |
  | H200 141GB SXM IB | ~480–490 GB/s |
  | B300 288GB SXM IB | **~1 TB/s+** (NVLS/SHARP kicks in for `size ≥ 2 GiB`) |

  Significantly below the expected number means the IB fabric or NCCL config is unhealthy.
- `# Out of bounds values : 0 OK` — must be `0`. Any nonzero is a correctness failure.
- Latency at 8 B (H100/H200 only): should be ~25–30 µs for 16-rank all-reduce. Anomalous
  (>100 µs) suggests IB issues.

Reference run on 2× h200-141gb-sxm-ib.8x in `eu-iceland1-a` (2026-05-14):

```
   size           count   type   redop    out-of-place              in-place
                                          time(us) algbw busbw     time(us) algbw busbw
  17179869184   4294967296 float   sum   66197      259.5  486.6     66257     259.3  486.2
# Out of bounds values : 0 OK
# Avg bus bandwidth    : 137.625
```

(`Avg bus bandwidth` is averaged across the full size range and is pulled down by the
latency-dominated small sizes — focus on the large-size busbw row.)

## Scaling to more nodes

The committed manifests are configured for **2 worker nodes (16 GPUs)** to match the
suite's H200 baseline. To run at larger scale (4, 8, etc. nodes), you must update
**three values together** — they must be kept in sync:

| Value | Where | Default | Example for 8 nodes |
|---|---|---|---|
| Worker replicas | `Worker.replicas:` | `2` | `8` |
| mpirun `-np` (total processes) | mpirun args list | `"16"` (2 × 8 GPU) | `"64"` (8 × 8 GPU) |
| Init-container DNS wait count | `N=` in initContainer command | `2` | `8` |

If you forget the third one, the launcher's initContainer will exit early after
only waiting for the first N=2 workers, and mpirun will fail when it tries to
ssh to the unwaited workers.

### One-liner to apply at scale

```bash
# Replace 8 with your desired worker count, and swap the manifest filename
# for your SKU (nccl-test-h100.yaml / nccl-test-h200.yaml / nccl-test-b300.yaml).
N=8
sed -e "s|      replicas: 2$|      replicas: ${N}|" \
    -e "s|            - \"16\"|            - \"$((N*8))\"|" \
    -e "s|              N=2|              N=${N}|" \
  nccl-test-h200.yaml \
| kubectl -n nccl-test create -f -
```

### Why the DNS-wait initContainer matters at scale

The launcher container is created at roughly the same time as the worker pods.
At small scale (2 workers) all pods become Ready within seconds. At larger scale
(8+ workers) — especially when **cluster-autoscaler** needs to provision new
nodes — workers may take 5–15 minutes to all reach Ready.

Without the initContainer, the launcher's mpirun starts immediately, tries to
ssh to workers whose DNS records don't exist yet, fails fast, the Job retries,
hits BackoffLimit before workers come online, and the whole job is marked Failed.

The initContainer in these manifests blocks until all N workers are
DNS-resolvable and stable for 10s. It costs ~5 seconds at 2-node scale
(trivial) and unblocks 8+ node scale (essential).

## Cleanup

```bash
kubectl -n nccl-test delete mpijob nccl-tests-gdr-16-h200    # (or -h100 / -b300)
# Optionally tear the namespace
kubectl delete namespace nccl-test
```

The mpi-operator install persists across runs — leave it in place for next time.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| busbw plateaus at < 50 GB/s | Wrong NCCL_IB_HCA, or `NCCL_IB_GID_INDEX=3` set on Hopper | Verify env block matches the per-SKU manifest in this directory |
| MPIJob stuck pending | mpi-operator not running | `kubectl -n mpi-operator get pods`; re-run `00-prerequisites/install-mpi-operator.sh` |
| Image pull > 10 min | Iceland egress slowness (known) | Wait it out; the image caches on node after first pull |
| `Out of bounds values : N` (nonzero) | Bad GPU or memory corruption | Check `kubectl -n nccl-test logs <worker> -c nccl-worker` for hardware-level errors |
