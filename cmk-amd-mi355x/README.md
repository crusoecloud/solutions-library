# CMK AMD MI355X

Solutions for validating AMD Instinct **MI355X** GPU nodepools — 8× MI355X
(gfx950, 288 GB HBM3E) plus 8× AMD Pensando Pollara 400 AI NICs per node — on
**Crusoe Managed Kubernetes (CMK)**. Use this when accepting a new MI355X
nodepool or investigating a suspected fabric/GPU problem on one.

## Contents

| Directory | Purpose |
|---|---|
| [validation-suite/](./validation-suite/) | Reproducible acceptance bundle pinned to Bundle **B.MI355.2.1**: per-node kernel/driver/firmware verification, per-rail RDMA bandwidth (host-memory and GPU-direct dma-buf), 2-node RCCL all-reduce with the Crusoe + mlcommons tuning envelope, and per-GPU compute / straggler / XGMI / ECC health. |

## Prerequisites

- A provisioned CMK cluster with an MI355X nodepool (2 × `Ready` nodes, each
  advertising `amd.com/gpu: 8` and `amd.com/vnic: 8`)
- `kubectl`, the Kubeflow MPI Operator, and a CCR `docker-registry` pull
  secret — exact commands in the
  [validation-suite README](./validation-suite/README.md#prerequisites)

## Quick start

Follow the [ordered workflow](./validation-suite/README.md#ordered-workflow):
environment verification → RCCL all-reduce → GPU straggler scan → per-rail
bandwidth (host-memory, then GPU-direct). Reference pass bars, observed on
Crusoe's internal dry-run: **≥ 300 GB/s** RCCL busbw (observed 381.88),
**≥ 500 Gb/s** per rail from host memory, **≥ 700 Gb/s** per rail with
GPU-direct dma-buf (observed ~778).

## Gotchas

- The GPU-direct bandwidth check needs an AMD-patched `perftest` image —
  build it in-cluster first via `validation-suite/build-image/`.
- RCCL on this platform requires the MI355X topology XML and
  `NCCL_DMABUF_ENABLE=1` (kernel 6.8 dropped `ib_peer_mem`; presence in
  `lsmod` is not activation) — the shipped manifest sets the full envelope
  and the [validation-suite README](./validation-suite/README.md#rccl--nccl-environment)
  documents why each setting exists.
