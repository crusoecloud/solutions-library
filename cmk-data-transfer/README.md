# CMK Cross Region Object Storage Data Transfer

Parallel-pull a dataset from **any S3-compatible object store** to a
**VAST-backed PB Scale shared disk** on **Crusoe Managed Kubernetes (CMK)**, engineered to
saturate worker hosts across a high-latency path. **OCI Object Storage is the
worked example throughout** but the source
backend is rclone's generic `provider = Other`, so AWS S3, MinIO/Ceph, GCS (S3
interop), Cloudflare R2, Backblaze B2, etc. work too — point `OCI_ENDPOINT` at
the store (see [Other S3-compatible sources](#other-s3-compatible-sources)).

The shape follows Crusoe's AWS-S3 ["rclone parallel streams"](https://support.crusoecloud.com/hc/en-us/articles/37041258573723-How-To-Download-Data-From-AWS-S3-Using-Rclone-Parallel-Streams) reference: a master
pod lists the source and writes balanced shard manifests to a shared disk; N
worker pods each take one shard and `rclone copy` it in parallel — tuned for a
**high-RTT path** where throughput comes from **massive concurrency**, not from
large files.

---

## Quick Start 

```bash
cp .env.example .env          # fill in OCI / other object storage creds, namespace, region, bucket
make sizing                   # (OPTIONAL) show the BDP/target concurrency plan (no cluster)
make dry-run                  # render manifests + preflight checks (launches nothing)
make preflight                # (OPTIONAL) measure the shared-disk write ceiling with fio (safe, no third party egress)
make run                      # full pipeline; PROMPTS before the large transfer
```

---

## Architecture

```
        operator workstation (this repo, python3 + kubectl)
        │  build rclone.conf → K8s Secret 
        │  list (via master) → bin-pack shards locally → push to shared disk
        ▼
┌──────────────────────────── Crusoe Managed Kubernetes ───────────────────────┐
│                                                                               │
│   Secret(rclone.conf, RO)        PVC: crusoe-csi-driver-fs-sc (VAST, RWX)     │
│        │  mounted RO into all pods         │  mounted into all pods           │
│        ▼                                   ▼                                  │
│   ┌─────────────┐   rclone lsf      ┌─────────────────────────────────────┐  │
│   │ master pod  │ ───────────────►  │  shared disk  /data                 │  │
│   │ (rclone img)│   shards pushed   │   /shards/shard-0..N-1.txt          │  │
│   └─────────────┘ ◄───────────────  │   /logs/worker-*.log                │  │
│                                     │   /dataset/...  (downloaded objects)│  │
│                                     └─────────────────────────────────────┘  │
│                                                  ▲  ▲  ▲  ▲                    │
│   K workers PER s2a node (topology-spread even, hostNetwork, unique rc port):  │
│   ┌───────── node 1 ─────────┐        ┌───────── node N ─────────┐            │
│   │ w0  w1  w2  w3 (shards)  │  ...   │ wK ... w(K+3)            │             │
│   │ share the 200 Gbps NIC   │        │ share the 200 Gbps NIC   │            │
│   └─────┬──────────────┬─────┘        └─────┬──────────────┬─────┘            │
└─────────┼──────────────┼────────────────────┼──────────────┼──────────────────┘
          │              │                    │              │  hundreds of parallel
          ▼              ▼                    ▼              ▼  ranged-GET streams
        ┌──────────────────────────────────────────────────┐
        │   OCI Object Storage  (S3-compatible endpoint)     │   > e.g. 150 ms RTT
        │   https://<ns>.compat.objectstorage.<region>....   │   (intercontinental)
        └──────────────────────────────────────────────────┘
```

The fleet runs **`PODS_PER_NODE` independent rclone processes on each node** —
multiple processes saturate the shared 200 Gbps NIC better than one big rclone
(a single process can hit internal ceilings: one `http.Transport`, GC, lock
contention). Each worker pod:

- **`hostNetwork: true`** — bypasses the CNI datapath and uses the node's NIC
  directly. Because hostNetwork pods share the node's network namespace, each
  worker binds a **unique rclone rc port** (`5572 + index`) so co-located
  workers don't collide.
- **`topologySpreadConstraints` (maxSkew=1 on `kubernetes.io/hostname`)** —
  spreads workers *evenly* so each node gets `PODS_PER_NODE`, not a pile-up on
  one node. CPU/memory requests are auto-sized so exactly that many pack per
  node (with system headroom).
- **`nodeSelector: crusoe.ai/instance.class: s2a`** — pins to the storage SKU.
- mounts the **RWX VAST PVC** read-write and the **rclone Secret** read-only,
  takes one shard, writes into the shared `/data/dataset`.

---




## Why concurrency, not file size: the 150 ms BDP

Over a >150 ms intercontinental path a single TCP stream is **window-limited**:

```
per_stream_throughput  ≈  tcp_window / RTT
```

With a typical autotuned window of ~16 MB:

```
16 MB × 8 bits / 0.150 s  ≈  853 Mbps  per stream
```

At high latencies, that's the ceiling **regardless of how large the file is**. A 100 GB file
pulled on one stream still moves at ~0.85 Gbps. So aggregate throughput has to
come from running **many streams in parallel** to fill the bandwidth-delay
product (BDP) of each node's NIC.

**BDP of one `s2a` node's 200 Gbps NIC at 150 ms:**

```
200e9 bits/s × 0.150 s  =  30e9 bits  =  3.75 GB  must be "in flight" to fill the pipe
```

**Streams needed to fill it** (using a deliberately conservative ~250 Mbps per
untuned stream, with a 1.5× safety factor):

```
200 Gbps ÷ 0.25 Gbps/stream  ≈  800 streams to fill the NIC
60  Gbps ÷ 0.25 Gbps/stream × 1.5  ≈  360 streams for a 60 Gbps/node target
```

rclone exposes two multiplicative concurrency levers:

- **`--transfers`** — number of files copied in parallel (also the *only*
  parallelism for files **below** `--multi-thread-cutoff`, since each gets one
  stream).
- **`--multi-thread-streams`** — ranged-GET streams per *single* file, for files
  **above** the cutoff (default 256 MiB). This is what fills the per-large-file
  BDP. (Multi-thread **downloads** are supported since rclone v1.63.)

So **in-flight streams per pod ≈ `transfers × multi-thread-streams`** for large
files. The orchestrator derives both from `TARGET_GBPS`; see `make sizing`.

---

## Throughput target math

`TARGET_GBPS` is the single sizing knob (default 30). To convert a daily volume
into a rate:

| GB/s | PB/day | per-node (4 nodes) | % of 200 Gbps NIC |
|---|---|---|---|
| 11.6 | 1.0 | 2.9 GB/s = 23 Gbps | 12% |
| 30   | 2.6 | 7.5 GB/s = 60 Gbps | 30% |

Four `s2a` nodes provide `4 × 200 Gbps ≈ 100 GB/s` of NIC line rate, so a
30 GB/s target is ~30% of the ceiling — feasible **on the network**. The real
binding constraint is usually **object-store egress throttling / request-rate
limits** or the **VAST write ceiling** ([Caveats](#operational-caveats)) — which
is why this repo ships a fio write-ceiling preflight and a throughput sweep.

### Fleet sizing is a function of `TARGET_GBPS`, `NUM_NODES`, and `PODS_PER_NODE`

The per-node stream budget is the same (BDP-driven); it's then **divided across
`PODS_PER_NODE` independent rclone processes**, and CPU/mem requests are sized so
exactly that many pack per node:

```
per_node_gbps      = TARGET_GBPS / NUM_NODES            (capped at 90% of NIC)
streams_per_node   = ceil(per_node_gbps × 1000 / PER_STREAM_MBPS × STREAM_SAFETY)
streams_per_pod    = ceil(streams_per_node / PODS_PER_NODE)
multi_thread_streams = clamp(streams_per_pod, 4..8)              # per pod
transfers          = ceil(streams_per_pod / multi_thread_streams)  # per pod, ≤ 2×(vCPU/pods)
checkers           = min(2 × transfers, 256)                    # per pod
cpu_request/pod    = (vCPU − headroom) / PODS_PER_NODE
```

Defaults for **30 GB/s across 4 nodes at 8 pods/node** (`make sizing`):

```
nodes x pods/node          4 x 8 = 32 worker pods
streams needed / node      360   ->  45 / pod
=> PER POD: --transfers 6  --multi-thread-streams 8  (--checkers omitted)
   in-flight streams/pod 48 ; per-node 384 ; fleet 1536
   pod requests cpu=9 mem=8Gi  (8 × 9 = 72 vCPU, fits 80 with headroom)
```

Override any derived value with env vars or flags (e.g.
`make run TARGET_GBPS=11.6 PODS_PER_NODE=16`, or `--pods-per-node 6 --transfers 40`).
`PODS_PER_NODE` is itself a throughput lever — sweep it (below) to find where
more processes stop helping. To pin per-pod concurrency to the AWS-S3 reference,
set `RCLONE_TRANSFERS=40 RCLONE_MULTI_THREAD_STREAMS=40`.

> `PER_STREAM_MBPS` (default 250) is intentionally pessimistic. If you tune host
> TCP buffers or OCI gives you more per-connection throughput, fewer streams are
> needed; the sweep harness finds the real knee empirically.

---

## Discovered `s2a` hardware

The sizing model is grounded in the `s2a.80x` SKU shape (product facts, observed
via a diagnostic pod):

| Resource | Per node |
|---|---|
| vCPU | 80 (AMD, AVX-512) |
| RAM | ~676 GiB |
| NIC | single 200 Gbps (Mellanox `mlx5`) |
| 4-node fleet line rate | 800 Gbps ≈ 100 GB/s |

---

## Configuration

All inputs come from `.env` (copied from `.env.example`), process env, or CLI
flags — **never hardcoded**. CLI flags > process env > `.env`.

| Variable | Meaning |
|---|---|
| `OCI_ACCESS_KEY_ID` / `OCI_SECRET_ACCESS_KEY` | OCI Customer Secret Key (S3-compat pair) |
| `OCI_NAMESPACE` | Object Storage namespace (builds the endpoint) |
| `OCI_REGION` | OCI region slug, e.g. `us-phoenix-1` / `us-ashburn-1` |
| `OCI_BUCKET` / `OCI_PREFIX` | source bucket and optional prefix |
| `TARGET_GBPS` | **the single sizing knob** (default 30) |
| `NUM_NODES` / `PODS_PER_NODE` | fleet size; total pods = nodes × pods/node (`NUM_PODS` forces an absolute total) |
| `RTT_MS` / `PER_STREAM_MBPS` / `STREAM_SAFETY` | BDP model inputs |
| `STORAGE_CLASS` / `PVC_NAME` / `PVC_SIZE` | VAST destination disk |
| `DEST_MODE` | `dynamic` / `import` / `nfs` destination (see below) |
| `EXISTING_DISK_ID` / `_NAME` / `_SERIAL` / `NFS_SERVER` | bind an existing disk (import/nfs modes) |
| `RCLONE_*` | per-flag overrides (blank = auto-derive) |

> **Region note:** use the **OCI** region slug where the *bucket* lives (not your
> destination/cloud region). Preflight warns if the slug doesn't look like OCI.

### Other S3-compatible sources

The source backend is rclone `provider = Other`, so any S3-compatible store
works. The `OCI_*` env names are just labels — for a non-OCI store, set
`OCI_ENDPOINT` to its S3 endpoint and use its access/secret key + bucket. OCI is
the only one that auto-builds the endpoint from `OCI_NAMESPACE` + `OCI_REGION`;
everything else just needs `OCI_ENDPOINT`:

| Source | `OCI_ENDPOINT` | Notes |
|---|---|---|
| OCI Object Storage | *(auto from namespace+region)* | the worked example |
| AWS S3 | `https://s3.<region>.amazonaws.com` | or leave blank with a real AWS key |
| MinIO / Ceph RGW | `https://<host>:<port>` | self-hosted |
| Google Cloud Storage | `https://storage.googleapis.com` | S3 interop + HMAC key |
| Cloudflare R2 | `https://<account>.r2.cloudflarestorage.com` | |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | |

`force_path_style` and `no_check_bucket` are set for broad compatibility. Egress
pricing and request-rate limits vary by provider — see [Caveats](#operational-caveats).

### Secrets handling

The credential is assembled into a complete `rclone.conf` and placed **only** in
a Kubernetes Secret, mounted **read-only** (`0400`) at `/config/rclone.conf`. It
never lands in the repo, in pod args, or in shell history. `.gitignore` blocks
`.env`, `rclone.conf`, and `*-secret.yaml`.

---

## What `make run` does

1. **Plan + sizing** — prints the BDP-derived concurrency.
2. **Preflight** — verifies `kubectl` reachability, that enough schedulable
   `s2a` nodes exist, and that the `crusoe-csi-driver-fs-sc` StorageClass
   exists (creates it if absent — this cluster ships the fs CSI driver but not
   always the StorageClass object).
3. **Secret** — builds `rclone.conf`, applies it in-cluster.
4. **PVC + master pod** — applies the RWX VAST claim and the master pod.
5. **List** — `rclone lsf --recursive --files-only --format sp` in the master
   pod → `/data/listing.tsv`.
6. **Shard** — pulls the listing, bin-packs (LPT) into N balanced shard files
   locally, pushes them to `/data/shards/`.
7. **Confirm** — *prompts before launching the large transfer* (skip with
   `--yes`).
8. **Launch** — one worker pod per node, each `rclone copy --files-from
   shard-i.txt --no-traverse …`.
9. **Monitor** — polls pod phases to completion.
10. **Teardown** — deletes worker + master pods (keeps PVC, Secret, data) unless
    `--keep`.

Idempotent: `rclone copy` skips objects already present (size/checksum), so a
re-run only fetches what's missing.

---

## Destination modes (`DEST_MODE`)

The tool can target the VAST shared disk three ways:

| `DEST_MODE` | What it does | Needs | When |
|---|---|---|---|
| `dynamic` (default) | provisions a new disk via the fs CSI driver | — | greenfield |
| `import` | binds an **existing** disk via a CSI **static PV** | disk `id` + `name` + `serial` | migrate into an existing disk, CSI healthy |
| `nfs` | binds an **existing** disk via an **in-tree NFS PV** straight to the VAST DNS endpoint (bypasses CSI) | disk `id` (+ `NFS_SERVER`) | when the CSI mount times out on an unroutable fallback IP |

Find the disk's identity with `crusoe storage disks list -f json` (pick the
`shared-volume` in your region): `.id`, `.name`, `.serial_number`. All modes use
`reclaimPolicy: Retain`, so deleting the PVC/PV never deletes the disk or data.

### `nfs` mode — when the CSI mount times out

If the fs CSI driver can't get a disk's "data path connectivity fields" it falls
back to a fixed IP that may be **unroutable from your nodepool**, so `dynamic`
and `import` mounts hang and time out. The **VAST DNS endpoint mounts cleanly**,
though — `nfs.crusoecloudcompute.com` resolves to the in-VPC VAST data IPs. `nfs`
mode creates an in-tree NFS PV that mounts it directly with `remoteports=dns`:

```bash
DEST_MODE=nfs  EXISTING_DISK_ID=<disk-id>   # NFS_SERVER defaults to nfs.crusoecloudcompute.com
make run                                     # (or --dest-mode nfs --import-disk-id <id>)
```

The orchestrator generates the PV/PVC (see `k8s/nfs-pv.yaml` for the manual /
`envsubst` equivalent), skips the StorageClass, and the workers write into the
existing disk. `PVC_SIZE` is the PV capacity; the NFS path is
`/volumes/<EXISTING_DISK_ID>` (override with `NFS_EXPORT_PATH`).

> The CSI `import` PV mirrors what the provisioner emits, so it mounts
> identically to a `dynamic` claim — and hits the same CSI fallback if that's
> the problem. If a CSI mount hangs, prefer `nfs`.

## Benchmarking & finding the binding constraint

**VAST write ceiling (run first, no egress):**

```bash
make preflight                       # one fio pod per node → aggregate write GB/s
# or: python3 preflight/run_fio.py --nodes 4 --size 20G --jobs 8 --bs 4M
```

If the download later plateaus near the fio number, the **write path** is the
limit — not OCI or the NIC.

**Disk read+write benchmark (fio on every node):** one fio pod per node, four
stonewalled profiles (seq/rand read+write, `direct=1`). Results saved to
git-ignored `bench/results/fio-<ts>/` (per-node JSON + `summary.csv`):

```bash
make fio-bench                       # → per-node + aggregate GB/s and IOPS
# default 16 jobs x iodepth 32/node; push harder with FIO_JOBS=32 FIO_IODEPTH=64
# standalone: python3 bench/fio/run_fio_bench.py --jobs 16 --iodepth 32 --runtime 30
```

Throughput scales with `FIO_JOBS × FIO_IODEPTH` (in-region disk — concurrency,
not window, is the lever). The runner skips unschedulable nodes and lists any it
missed. Sequential-read numbers can be inflated by server-side caching; treat
read as an upper bound unless the working set exceeds the cache.

**Throughput collector** (attach to a running fleet; polls each worker's rclone
remote-control `core/stats`):

```bash
make collect                         # → bench/results/throughput.csv + peak/median
```

**Parameter sweep** over `(transfers, multi-thread-streams, pods-per-node)` on a
*bounded sample* to find the saturation knee — including where adding more pods
per node stops helping:

```bash
make sweep SAMPLE_PREFIX=smoke-set/ TRANSFERS_GRID=16,32,48 MTS_GRID=4,8 \
           PODS_PER_NODE_GRID=2,4,8 MAX_SECONDS=120
# → bench/results/sweep.csv, ranked by peak aggregate GB/s
```

> **Each sweep point re-downloads the sample → OCI egress is billed.** Keep the
> sample small and the duration short. The sweep refuses to run without `--yes`.

Reading the results: throughput that rises with streams then **flattens** marks
the knee. If it flattens *below* the NIC and *at* the fio ceiling → VAST-bound.
If OCI starts returning `503 SlowDown` / `429` in the worker logs → request-rate
throttled (back off `transfers`/`checkers`, see below).

### OCI transfer experiments + total transfer time

`bench/oci_experiment.py` runs one transfer at a chosen node/pod concurrency,
pins exactly `pods/node` workers to each of N nodes, and reports the **total
transfer time** and average rate. Run to completion (full bucket) or time-box it:

```bash
# full bucket, 1 node, 24 pods/node (saturate the node), to completion:
python3 bench/oci_experiment.py --nodes 1 --pods-per-node 24 --label full-1node
# time-boxed steady-state probe (bounds egress):
python3 bench/oci_experiment.py --nodes 4 --pods-per-node 16 --label probe --max-seconds 120
```

Each run writes `bench/results/oci-exp-<label>/`:
- `summary.json` — `total_transfer_time_s`, `avg_GBps` (= bytes ÷ time, the
  headline), `avg_GBps_per_node`, `steady_GBps`, `peak_GBps`, `completed`,
  `failed_pods`, `throttle_signals`.
- `timeseries.csv` — aggregate-bytes / rate over time.

A run to completion is bounded by `--safety-seconds` (default 7200) so it can't
hang on a straggler. `--stats-sample` caps how many pods are polled per tick so
overhead stays small even with a 96-pod fleet.

### Tracking a run in progress

```bash
kubectl get pods -l app=cmk-data-transfer-worker -o wide        # phases + nodes
kubectl logs -f cmk-data-transfer-worker-0                      # live rclone progress (one shard)
kubectl exec cmk-data-transfer-worker-0 -- \
  rclone rc core/stats --rc-addr localhost:5572                 # live bytes/speed for that pod
kubectl top nodes ; kubectl top pods -l app=cmk-data-transfer-worker   # CPU/mem
```
The runner also prints a per-tick line (`elapsed`, est TB, ~rate, active/failed
pods). **Note:** rclone's own `MiB/s` in the logs is a *cumulative average* — on
a high-RTT path it decays during the straggler tail and understates steady rate;
trust `summary.json` / `timeseries.csv` for the real numbers.

---

## Tuning guide

| Symptom | Likely cause | Lever |
|---|---|---|
| Throughput flat, NIC < 30% | not enough streams to fill BDP | ↑ `PODS_PER_NODE`, ↑ `--multi-thread-streams`, ↑ `--transfers`, ↓ `PER_STREAM_MBPS` |
| One rclone process pegged / stalls below NIC | single-process ceiling | ↑ `PODS_PER_NODE` (more independent processes share the NIC) |
| Throughput flat near fio number | VAST write ceiling | more nodes; larger `--buffer-size`; accept the ceiling |
| `503 SlowDown` / `429` in logs | OCI request-rate throttling | ↓ `--checkers` and `--transfers`; spread the prefix |
| High CPU, low throughput | checksum/verify overhead | add `--s3-disable-checksum` via `RCLONE_EXTRA_FLAGS` |
| Many tiny files, slow | per-file overhead dominates | ↑ `--transfers` (streams don't help sub-cutoff files) |
| One worker lags | shard imbalance / a slow node | check `/data/logs/worker-*.log`; re-shard |
| Memory pressure | too many large in-flight chunks | ↓ `--multi-thread-streams` or `--multi-thread-chunk-size` |

`--transfers` scales **small-file** parallelism; `--multi-thread-streams` scales
**large-file** (BDP-fill) parallelism. Tune them independently to your dataset's
file-size distribution.

---

## Operational caveats

- **OCI egress is billed.** Every byte pulled — and every byte re-pulled during
  a sweep — incurs OCI Object Storage egress cost. Budget for the full dataset
  size plus sweep samples.
- **OCI request-rate throttling.** OCI Object Storage rate-limits requests per
  bucket/prefix; very high `--checkers`/`--transfers` can trigger `429`/`503
  SlowDown`. rclone retries with backoff, but sustained throttling caps
  throughput. If you control the source layout, spreading objects across more
  prefixes helps.
- **VAST write ceiling** may be the real limit well before the NIC line rate —
  always run the fio preflight so a plateau is attributed correctly.
- **`hostNetwork: true`** means workers share the node's network namespace and
  bind host ports — each worker's rclone rc listens on `localhost:5572+index`,
  so the ports are unique per pod even when several run on one node. Don't
  co-schedule other workloads that grab those ports; raise `PODS_PER_NODE`
  thoughtfully (each pod = one more rc port + CPU/mem slice).


---

## Alternative: native OCI backend

Instead of the S3-compat path you can use rclone's native `oracleobjectstorage`
backend, which authenticates via OCI IAM (no access/secret key):

```ini
[oci-native]
type = oracleobjectstorage
namespace = <namespace>
region = <region>
provider = user_principal_auth      # or instance_principal_auth / resource_principal_auth
config_file = /root/.oci/config
config_profile = DEFAULT
# compartment = ocid1.compartment.oc1..<...>   # for bucket listing
```

Mount your `~/.oci` config + key into the pods and point the remote at
`oci-native:`. The S3-compat path remains the default because it matches the
credential the customer already holds.

---

## Repo layout

```
.env.example            all inputs (copy to .env)
Makefile                preflight / run / sweep / collect / clean
orchestrator/           config, BDP sizing, rclone.conf builder, kubectl, manifests, run
shard/shard_manifest.py deterministic size-balanced LPT bin-packer (standalone + importable)
k8s/                    reference YAML: storageclass, pvc, import-pv, nfs-pv, master/worker pods, secret example
bench/                  collect.py (throughput → CSV), sweep.py (parameter sweep)
preflight/              fio VAST write-ceiling test (yaml + run_fio.py)
```

## Requirements

- `python3 >= 3.9` and `kubectl` on the operator workstation (stdlib only — no
  pip install required; the orchestrator shells out to `kubectl`).
- A `KUBECONFIG` with access to the CMK cluster and schedulable `s2a` nodes.
- OCI Customer Secret Key with read access to the source bucket.
