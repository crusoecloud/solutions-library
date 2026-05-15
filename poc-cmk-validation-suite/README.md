# Crusoe Managed Kubernetes — POC Validation Suite

A guided, two-step validation suite for any new Crusoe Managed Kubernetes (CMK) GPU cluster.
The intent is for a Solutions Engineer to clone this repo at the start of a customer POC,
walk the numbered subdirectories in order, and finish with a documented "this cluster is
ready for production training" result.

The same workflow applies to H100, H200, B200, and B300 SKUs — each has a per-SKU manifest
file inside the subdirectories.

---

## When to use this suite

- **Customer onboarding** — proves the cluster meets H200/H100/B200/B300 baseline expectations
- **Cluster commissioning** — quick health check after node-pool changes or driver updates
- **Slow-training triage** — isolates whether the IB fabric or the application stack is at fault

If the customer only wants one test, run **01-nccl-test** alone — it covers ~80% of cluster
issues in ~5 minutes of wall time. **02-torchtitan-llama3-8b** is the end-to-end follow-up
that exercises FSDP, NCCL, dataloader, optimizer, and checkpointing at once.

---

## Prerequisites

The cluster must have:

- **CMK cluster** in any supported region with at least one GPU node pool joined and `Ready`
- **NVIDIA GPU Operator + Network Operator** (the standard CMK add-ons `nvidia_gpu_operator`,
  `nvidia_network_operator`, `crusoe_csi`) — these come from the cluster's `--add-ons` list
  at create time
- **Kubeflow MPI Operator v0.6.0** — installed by `00-prerequisites/install-mpi-operator.sh`
- **Kubeflow Training Operator v1.8.1** (for PyTorchJob) — installed once via:
  ```bash
  kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.8.1"
  kubectl -n kubeflow wait --for=condition=Available deploy/training-operator --timeout=120s
  ```

Per-SKU configuration (NCCL_IB_HCA, NCCL_TOPO_FILE) is already encoded in each manifest — no
edits required for the supported SKUs.

---

## Run order

| Step | Directory | Wall time | What it proves |
|---|---|---|---|
| 0 | `00-prerequisites/` | 1 min | Operators installed |
| 1 | `01-nccl-test/` | ~5–10 min | Inter-node IB fabric + NCCL stack healthy |
| 2 | `02-torchtitan-llama3-8b/` | ~30 min | Full FSDP training stack matches H200 baseline |

Each subdirectory has its own `README.md` with concrete `kubectl` invocations and expected
output. Do them in order — if step 1 fails, step 2 will too (training builds on top of NCCL).

---

## Expected results (16-GPU H200 reference, validated 2026-05-14 on `eu-iceland1-a`)

### Step 1 — NCCL all_reduce_perf

| Metric | Healthy value | Failure threshold |
|---|---|---|
| busbw at 16 GiB | **~480–490 GB/s** | < 200 GB/s suggests fabric or NCCL config issue |
| Validation errors | 0 | any non-zero = bad |
| Avg bus bandwidth | ~138 GB/s | < 50 GB/s = bad |

### Step 2 — TorchTitan 1000-step run

| Metric | Healthy value | Failure threshold |
|---|---|---|
| MFU | **~51–53%** | < 30% indicates a problem |
| tps/GPU | ~8,800 | dramatically below = problem |
| Final loss (1000 steps, batch=2, seq=8192) | ~4.0 | NaN/spiking = bad |
| Memory util | ~62% (batch=2) or ~90% (batch=4 with AC) | OOM = need to reduce batch |

---

## Common gotchas

### NCCL_IB_GID_INDEX=3
Some templates (notably older `crusoecloud/solutions-library` PyTorchJob examples) set
`NCCL_IB_GID_INDEX=3` for Blackwell/RoCE-style fabrics. **This is wrong for H100/H200 native
InfiniBand and causes a ~10× MFU degradation** (NCCL falls back to a slower codepath).

The manifests in this suite **omit** `NCCL_IB_GID_INDEX` for H100/H200 and include it only
in Blackwell variants. Do not re-add it on Hopper SKUs.

### Wrong K8s API version for MPIJob
Two different operators handle `mpijobs.kubeflow.org`:
- `kubeflow.org/v1` — Kubeflow `training-operator`
- `kubeflow.org/v2beta1` — Kubeflow `mpi-operator` (what this suite uses)

If you install the training-operator first, then install mpi-operator on top, you'll need to
**delete the existing `mpijobs.kubeflow.org` CRD** (only safe if no MPIJob objects exist)
before applying the v2beta1 version. `install-mpi-operator.sh` handles this automatically.

### Iceland image-pull latency
ECR/GHCR images can take 5–10 min to first-pull in the iceland (icat-m) region (see
internal incidents `inc466` and similar). Allow extra time for the first run; subsequent
runs benefit from the node-local image cache.

### batch=4 OOMs on small (≤16 GPU) clusters
The torchtitan upstream README's "16-node, 128-GPU H200, batch=4 → 52.96% MFU" baseline does
**not** linearly scale down. At 16 GPUs you need `batch=2` (without AC) or `batch=4` with
selective activation checkpointing. See `02-torchtitan-llama3-8b/README.md`.

---

## Per-SKU NCCL configuration reference

| SKU | NCCL_IB_HCA | NCCL_TOPO_FILE | Notes |
|---|---|---|---|
| H100 80GB SXM | `^mlx5_0:1` | `h100-80gb-sxm-ib-cloud-hypervisor.xml` | native IB; no GID override |
| H200 141GB SXM | `^mlx5_0:1` | `h200-141gb-sxm-ib-cloud-hypervisor.xml` | native IB; no GID override |
| B200 192GB SXM | `mlx5_5,mlx5_6,…,mlx5_12` | `b200-180gb-sxm-ib-cloud-hypervisor.xml` | Blackwell HCA layout; consider `NCCL_IB_GID_INDEX=3` |
| B300 288GB SXM | `mlx5_5,mlx5_6,…,mlx5_12` | `b300-288gb-sxm-ib-cloud-hypervisor.xml` | same as B200; see `b300-nccltest-cmk-mpijob/` reference |

All topology XMLs ship on Crusoe GPU nodes at `/etc/crusoe/nccl_topo/` and are mounted into
pods via `hostPath` — no need to bake them into images.

---

## Related references in this repo

- [`torchtitan-llama3_1_8B-kubernetes-pytorchjob/`](../torchtitan-llama3_1_8B-kubernetes-pytorchjob/)
  — standalone torchtitan example, fuller documentation, multi-variant manifests
- [`b300-nccltest-cmk-mpijob/`](../b300-nccltest-cmk-mpijob/) — original B300-only NCCL test
  example; the H100/H200 variants in this suite use the same MPIJob pattern but a
  prebuilt multi-arch image
