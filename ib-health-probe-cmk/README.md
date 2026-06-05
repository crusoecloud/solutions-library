# IB Health Probe — CMK

A Kubernetes-native cluster health check for InfiniBand fabrics. Lands one pod per GPU worker node, runs `ib_write_bw` loopback through every HCA, then a single-node NCCL all_reduce, and surfaces any HCA running below line rate.

Use when you need to know "are all the IB links on this cluster actually pushing the bandwidth they advertise?" before kicking off a long training run, or after suspecting a straggler.

## What it does

Two manifests, used independently or together:

| Manifest | Type | Purpose |
|---|---|---|
| `ib-probe-job.yaml` | Indexed `batch/v1` Job | **Per-node unit test.** Per-HCA loopback bandwidth + single-node NCCL. Catches single-link degradation (link-up-but-slow), bad PCIe negotiation, NUMA misrouting. |
| `multi-node-nccl-job.yaml` | `kubeflow.org/v2beta1` MPIJob | **Cluster integration test.** Multi-node all_reduce_perf across all selected nodes. Catches fabric-level issues that only show under load (switch congestion, ECMP imbalance, tree-vs-ring topology problems). |

The unit probe is fully parallel and SKU-agnostic. It scales the same way at 4 nodes or 1000 — one pod per node, all running concurrently.

### Coexist mode (default)

The Job runs with `hostNetwork: true` + `privileged: true` + hostPath `/dev/infiniband` instead of requesting `nvidia.com/gpu` / `nvidia.com/hostdev` from the device plugin. This lets the probe co-schedule alongside Slurm worker pods (or any other workload) that's already holding the resource pool — which is the normal state on a CMK cluster.

Tradeoff: if a real workload is **actively pushing traffic** while you run the probe, the bandwidth numbers will be skewed by the contention. For clean baseline readings, drain or pause your workloads first (`squeue` should be empty for a slurm cluster; check active pods otherwise). The probe itself works either way — but a clean result requires a quiet fabric.

## Quick start (4-node H200 / poc-cluster)

```bash
export KUBECONFIG=/path/to/your/kubeconfig
cd ib-health-probe-cmk
./apply.sh
kubectl get pods -l app=ib-probe -w               # watch
kubectl logs -l app=ib-probe --tail=-1 | ./parse-results.sh
```

Expected on a healthy 4-node H200 cluster: 32 `IBHEALTH|...|OK` lines (8 HCAs × 4 nodes), 4 `NCCLHEALTH|...|OK` lines, exit code 0 from the Job.

## How HCAs are discovered

The probe script walks `/sys/class/infiniband/` at runtime and selects HCAs where:

- `link_layer == InfiniBand` (skips Ethernet adapters automatically)
- `state == 4` (ACTIVE)
- `rate` is readable

It groups them by `device/numa_node` and pairs **within** each NUMA group so each loopback test stays on its local PCIe root complex. The bandwidth target is `rate × 90%` — derived from `rate` in sysfs, not hardcoded — so NDR400 nodes look for ≥360 Gbps and HDR200 nodes look for ≥180 Gbps without any config change.

This is what makes the manifest SKU-portable. Switching from H200 to B200 changes the HCA names (`mlx5_1..8` → `mlx5_5..12`) but the script doesn't care — it discovers whatever is active.

## Running on other SKUs

```bash
# B200 (8x NDR400, different pool label)
./apply.sh "nodepool-name" b200-180gb-sxm-ib-cloud-hypervisor.xml

# Larger cluster, explicit parallelism
./apply.sh "nodepool-name" b200-180gb-sxm-ib-cloud-hypervisor.xml 128
```

The only SKU-specific inputs are:

1. **Pool label** — the value of the `crusoe.ai/nodepool.name` node label. Find it with `kubectl get nodes -L crusoe.ai/nodepool.name`.
2. **NCCL topology XML filename** — files live at `/etc/crusoe/nccl_topo/` on the host and are hostPath-mounted into the pod. Pick the one that matches the SKU.

Everything else (HCA names, line rate, NUMA layout, GPU count) is discovered at runtime.

## Multi-node NCCL (optional)

Apply the integration test once you've confirmed per-node health:

```bash
POOL_LABEL=slurm-h200-workers \
NCCL_TOPO_FILE=h200-141gb-sxm-ib-cloud-hypervisor.xml \
WORKER_REPLICAS=4 \
TOTAL_GPUS=32 \
PROBE_IMAGE=ghcr.io/crusoecloud/nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1 \
envsubst < multi-node-nccl-job.yaml | kubectl apply -f -

kubectl logs -f nccl-integration-launcher
```

Healthy busbw target: H200 ≥350 GB/s, B200 ≥400 GB/s on 2 nodes; falls off slowly with scale.

## Tunable thresholds

Set these via the `env:` block in `ib-probe-job.yaml` or via the script env vars:

| Var | Default | What it does |
|---|---|---|
| `IB_THRESHOLD_PCT` | 90 | Bandwidth floor as % of detected line rate |
| `IB_DURATION` | 15 | Seconds per loopback direction |
| `IB_MSG_SIZE` | 8388608 | Message size for ib_write_bw |
| `NCCL_THRESHOLD` | 350 | Single-node NCCL busbw floor (GB/s) |
| `SKIP_NCCL` | 0 | Set to 1 to skip the NCCL step |
| `SKIP_APT` | 0 | Set to 1 if perftest+numactl are already in the image |

## Image notes

Defaults to `ghcr.io/crusoecloud/nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1`. This image **does not include perftest**, so the probe script `apt-get install`s `perftest` + `numactl` at pod startup (~30s one-time, idempotent). The MLNX OFED repo embedded in the image is unreachable but that's non-fatal — Ubuntu universe `perftest 24.01.0` installs cleanly alongside `libibverbs 2410mlnx54`.

### Ordering gotcha (important)

`probe.sh` runs **NCCL before** `apt-get install` deliberately. Installing perftest pulls in `librdmacm1t64` which **replaces** the MLNX-OFED `librdmacm1` and triggers `ldconfig` — that disturbs the container's CUDA runtime ↔ driver linkage and the next `cudaGetDevice` call returns `CUDA driver version is insufficient for CUDA runtime version` (error 35). Running NCCL first preserves the original library state. If you refactor probe.sh, **do not reorder these steps**.

### Air-gapped / zero-install path

For air-gapped clusters or customers wanting zero-install probes: build a pre-baked image and override with `PROBE_IMAGE=...`:

```dockerfile
FROM ghcr.io/crusoecloud/nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends perftest numactl && \
    rm -rf /var/lib/apt/lists/*
```

Then set `SKIP_APT=1` in the Job's env block. With perftest baked in, the ordering trap above doesn't apply — apt is never invoked at runtime, so NCCL and IB tests can run in any order.

## Output format

Pipe-delimited, one line per HCA test + one summary per host. Greppable from `kubectl logs`.

```
IBHEALTH|<host>|<client_hca>-><server_hca>|numa=<n>|<bw_gbps>|<line_rate_gbps>|<OK|FAIL: reason>
NCCLHEALTH|<host>|<gpus>|<busbw_gbps>|<OK|FAIL: reason>
SUMMARY|<host>|<HEALTHY|UNHEALTHY>|hcas=<n>|pairs=<n>
INFO|<host>|<message>
ERROR|<host>|<message>
```

Matches the convention used by the Solutions Engineering `/ib-health-check` skill (sysfs counter probe) so reports from both tools compose.

## Files

```
ib-health-probe-cmk/
├── README.md                  this file
├── probe.sh                   per-node script (source of truth)
├── ib-probe-job.yaml          Indexed Job manifest (envsubst template)
├── apply.sh                   wrapper: builds ConfigMap from probe.sh + applies Job
├── parse-results.sh           aggregates kubectl logs into a per-host table
└── multi-node-nccl-job.yaml   MPIJob for multi-node integration test
```

## What this does NOT cover (yet)

- **Multi-node binary-search isolation.** If the multi-node NCCL fails, you currently have to bisect manually. Planned for v2 as a driver that runs all-pairs `ib_write_bw` between nodes and binary-searches the failing partition.
- **Recurring/scheduled mode.** v1 is on-demand. Wrapping in a CronJob is straightforward if you want it.
- **Prometheus metrics emit.** Output is to pod logs. For continuous monitoring use the existing `grafana-cmk` solution which scrapes the same sysfs counters.
- **PHY-level diagnostics** (BER, FEC margin) — those need `mlxlink` and root access. Use the Ansible-based `/ib-health-check` skill on bare metal for that.

## Companion tools

- **`/ib-health-check`** (Solutions Engineering skill) — sysfs counter read + NVLink check. Read-only, no traffic. Complementary to this probe: the skill catches accumulating errors that have already occurred; this probe catches degradation that only shows under live load.
- **`../cmk-nccltests/nccl-b200.yaml`** — the multi-node MPIJob that `multi-node-nccl-job.yaml` is forked from.
- **`../grafana-cmk/`** — continuous monitoring stack if you want trend data.
