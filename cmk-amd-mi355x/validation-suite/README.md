# CMK AMD MI355X — Validation Suite

Reproducible validation bundle for AMD Instinct **MI355X** GPUs with the
**AMD Pensando Pollara 400** AI NIC on **Crusoe Managed Kubernetes (CMK)**.
Each check is packaged as a self-contained folder with the script or
manifest needed to run it against a live 2-node cluster.

The bundle covers cluster provisioning, kernel/driver/firmware verification,
per-rail RDMA bandwidth (host-memory and GPU-direct dma-buf), 2-node RCCL
all-reduce, and per-GPU compute + straggler + XGMI + ECC health.

---

## Platform

| Component | Version |
|---|---|
| Bundle | B.MI355.2.1 |
| Linux kernel | `6.8.0-124-generic` |
| ROCm | `7.2.0` |
| RCCL | `2.27.7` |
| `amdgpu` module | `6.16.13` |
| AINIC firmware | `1.117.5-a-77` |
| Mellanox CX-7 firmware | `28.43.3608` |
| GPU | MI355X (`0x75a3`, gfx950, 256 CUs, 288 GB HBM3E) — 8 per node |
| NIC | AMD Pensando Pollara 400 — 8 × 400 Gbps VFs per node (`ionic_0…ionic_7`) |
| GPU-Direct path | dma-buf (`NCCL_DMABUF_ENABLE=1`) |

---

## What this suite contains

Each folder ships a `src/` directory with the runnable artifact.
`logs/` and `results/` are created when the check runs.

| Folder | Purpose |
|---|---|
| [env-verify/](env-verify/) | Per-node kernel / driver / GPU / NIC / dmesg dump against Bundle 2.1 spec |
| [rccl-allreduce/](rccl-allreduce/) | 2-node RCCL `all_reduce_perf` with the Crusoe + mlcommons-tuned NCCL envelope |
| [gpu-straggler-scan/](gpu-straggler-scan/) | Per-GPU compute burst + sustained GEMM + XGMI mesh + ECC + bad-pages scan |
| [gpu-to-nic-bw-hostmem/](gpu-to-nic-bw-hostmem/) | Per-rail bidirectional `ib_write_bw` from host memory (baseline; no GPU-direct) |
| [gpu-to-nic-bw-gpu-direct/](gpu-to-nic-bw-gpu-direct/) | Per-rail bidirectional `ib_write_bw` with GPU-direct dma-buf (`--use_rocm --use_rocm_dmabuf`) |
| [build-image/](build-image/) | In-cluster Kaniko build of an AMD-patched `perftest` image (needed only for the GPU-direct bandwidth check) |
| [mirror-image/](mirror-image/) | One-time skopeo-based mirror of the Bundle 2.1 base image between registries |

---

## Observed results (Crusoe internal dry-run, 2 × MI355X-288GB-ROCE.8x)

Numbers below were observed on a 2-node CMK cluster during Crusoe's
internal validation run. They set the reference bar for a subsequent
customer POC on the same platform.

| Check | Result | Interpretation |
|---|---|---|
| Environment (Bundle 2.1) | ✅ PASS both nodes | All versions match the Bundle 2.1 spec exactly. Zero ECC errors, zero bad pages, all 8 Pollara VFs `PORT_ACTIVE` at MTU 4096 (RoCEv2). |
| 2-node RCCL all-reduce | ✅ **381.88 GB/s** Avg bus bandwidth | 95.5 % of the 400 GB/s theoretical peak (2 nodes × 8 rails × 400 Gbps). Every rail carrying GPU-direct dma-buf traffic; parity check clean across all cycles. |
| GPU compute + straggler + XGMI | ✅ 16/16 GPUs healthy | Sustained bf16 GEMM 1331-1399 TFLOPS (means: 1389.8 / 1372.8 TF), 92-97 % of MI355X vendor spec. Full XGMI mesh up. Zero stragglers. |
| Per-rail bandwidth — host memory | ✅ **~778 Gb/s** per rail, 0.2 % spread | Confirms each of the 16 rails saturates the NIC at bidirectional line rate with buffers in host memory. |
| Per-rail bandwidth — GPU-direct dma-buf | ✅ **~778 Gb/s** per rail (peak 779.28), 0.2 % rail-to-rail spread | 97 % of the 800 Gb/s theoretical bidirectional line rate. Confirms `--use_rocm --use_rocm_dmabuf` is landing in HBM with correct GPU-NIC affinity. NIC-limited, so throughput matches the host-memory baseline; the value here is proving the dma-buf code path is live end-to-end (RDMA into HBM). |

---

## Prerequisites

- `kubectl` pointed at the target CMK cluster (`kubectl get nodes` returns 2 × `Ready`).
- Each node advertises `amd.com/gpu: 8` and `amd.com/vnic: 8`.
- Kubeflow MPI Operator installed in the `default` namespace:

  ```bash
  kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
  ```

- A Crusoe Container Registry (CCR) `docker-registry` secret in `default`,
  used by all pods that pull the AMD workload image:

  ```bash
  kubectl -n default create secret docker-registry ccr-cred \
    --docker-server=registry.<region>.ccr.crusoecloudcompute.com \
    --docker-username="<your-crusoe-email>" \
    --docker-password="<crusoe-registry-token>"
  ```

  **Note on CCR docker Basic auth:** the username is the Crusoe user's
  email address (not the user UUID or token ID). The password is a
  registry token issued by `crusoe registry tokens create`.

- Local tooling: `envsubst` (from `gettext`) for the RCCL manifest render step.

---

## Ordered workflow

> This suite assumes the CMK cluster and MI355X nodepool have **already been provisioned by Crusoe** — you receive a working kubeconfig, and the pre-flight in the Prerequisites section passes (2 × `Ready` nodes, each advertising `amd.com/gpu: 8` and `amd.com/vnic: 8`).

Each step writes its outputs into its own `<test>/logs/` (raw evidence) and
`<test>/results/` (parsed one-page summary), created on first run.

1. **Install the Kubeflow MPI Operator** — see Prerequisites (one-time setup, needed for the RCCL step).
2. **Create the CCR docker-registry secret** `ccr-cred` — see Prerequisites (one-time setup, needed for private images).
3. **(Optional) Mirror the Bundle 2.1 base image into your CCR** —
   `mirror-image/src/mirror-a77-to-ccr.yaml` (or ask your Crusoe SE contact
   to run `crusoe registry manifests copy` for you). Skip if you already
   have the AMD workload image in your CCR.
4. **(Optional) Build the AMD-patched perftest image** —
   `bash build-image/src/build-kaniko-amdperftest.sh`.
   Only needed if you plan to run the `gpu-to-nic-bw-gpu-direct` check
   with GPU-direct dma-buf. The other checks work against the upstream
   `mirror.gcr.io/rocm/roce-workload:…-a-56` image.
5. **Environment verification** —
   `bash env-verify/src/env-verify.sh`.
   Produces `env-verify/logs/env-report-<node>-<ts>.txt`. Confirm the
   observed versions match the Bundle 2.1 spec (see table above) and
   that `bad_pages`, ECC counters, and Pollara VF state are clean.
6. **2-node RCCL all-reduce** —

   ```bash
   IMAGE=<full CCR image ref> PULL_SECRET=ccr-cred N=2 \
     bash rccl-allreduce/src/deploy-rccl-allreduce.sh
   ```

   Reference bar: **≥ 300 GB/s** busbw (dry-run observed 381.88 GB/s).
7. **Per-GPU compute + straggler scan** —
   `kubectl apply -f gpu-straggler-scan/src/gpu-straggler-scan-mi355x.yaml`
   (edit the nodeSelector line if your nodepool label differs).
8. **Per-rail host-memory bandwidth baseline** —
   `bash gpu-to-nic-bw-hostmem/src/gpu-to-nic-bw-hostmem.sh`.
   Reference bar: **≥ 500 Gb/s** per rail.
9. **Per-rail GPU-direct dma-buf bandwidth** —
   `IMAGE=<CCR image with amd-patched perftest> \
      bash gpu-to-nic-bw-gpu-direct/src/gpu-to-nic-bw-gpu-direct.sh`.
   Reference bar: **≥ 700 Gb/s** per rail.

---

## RCCL / NCCL environment

The manifest at
[rccl-allreduce/src/rccl-allreduce-mpijob-generic.yaml](rccl-allreduce/src/rccl-allreduce-mpijob-generic.yaml)
combines the settings mandatory for MI355X + Pollara on CMK with the
mlcommons `AMDMi355xTrainingv6.1` bundle2 tuning envelope. The
load-bearing settings and their rationale:

| Variable | Value | Rationale |
|---|---|---|
| `NCCL_TOPO_FILE` | `/etc/crusoe/rccl_topo/mi355x-288gb-ib.xml` | Cloud Hypervisor flattens the PCIe view, so RCCL cannot infer GPU ↔ NIC affinity on its own. The MI355X XML has device id `0x75a3` (gfx950); the MI350X `0x75a0` would silently mis-match and drop bandwidth. |
| `NCCL_DMABUF_ENABLE` | `1` | Kernel 6.8+ dropped `ib_peer_mem`. The module appears in `lsmod` on this bundle but is **not** registered as a peer-memory client by `amdgpu` — presence is not activation. dma-buf is the real GPU-direct path. |
| `NCCL_SOCKET_FAMILY` | `AF_INET` | Prevents NCCL from picking an IPv6 link-local on the RDMA `eth` interface and hanging rendezvous. |
| `NCCL_IB_HCA` | `ionic_0,…,ionic_7` | Explicit Pollara VF list — the 8 rails. |
| `NCCL_IB_GID_INDEX` | `1` | RoCEv2 GID index on Pollara. |
| `NCCL_IB_QPS_PER_CONNECTION` | `4` | Rail-optimised bandwidth ramp. |
| `NCCL_IB_TC` | `96` | RoCE traffic class (DSCP 48). |
| `NCCL_IGNORE_CPU_AFFINITY` | `1` | Cloud-Hypervisor synthetic CPU affinity is not authoritative. |
| `NCCL_SHM_DISABLE` | `1` | Forces inter-node traffic through the NIC path instead of SHM. |
| `HSA_NO_SCRATCH_RECLAIM` | `1` | ROCm 7.2 gfx950 workaround for a scratch-spill path. |
| `RCCL_AINIC_ROCE`, `IONIC_LOCKFREE`, `NCCL_GDR_FLUSH_DISABLE`, … | (~20 more) | mlcommons bundle2 tuning envelope. Full list is in the manifest. |

---

## Adapting the suite for a different project

The scripts read all tenant-specific values from environment variables
and enforce them with `${VAR:?…}` guards. To retarget the suite:

| Variable | Where to find it | Used by |
|---|---|---|
| `PROJECT_ID` | `crusoe projects list` | mirror-image, build-image |
| `CCR_URL`, `CCR_REPO` (= `<registry>.<project-short>`) | `crusoe registry list` | build-image, mirror-image |
| `IMAGE` | Full CCR image ref of the AMD workload image | rccl-allreduce, gpu-to-nic-bw-gpu-direct |
| `PULL_SECRET` | Name of the `docker-registry` secret you created | rccl-allreduce, gpu-to-nic-bw-gpu-direct |

Everything else — Dockerfile, RCCL manifest, NCCL environment, target
thresholds, topology XML path — is invariant across tenants because it
is specific to the MI355X + Bundle 2.1 platform, not to any particular
project.
