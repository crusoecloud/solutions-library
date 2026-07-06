# CMK Cross-Region Object Storage Data Transfer

Parallel-pull a dataset from **any S3-compatible object store** to a **VAST-backed
RWX shared disk** on **Crusoe Managed Kubernetes (CMK)**, tuned to saturate worker
hosts across a high-latency path. **OCI Object Storage is the worked example**, but
the source backend is rclone's generic `provider = Other`, so AWS S3, MinIO/Ceph,
GCS (S3 interop), Cloudflare R2, Backblaze B2, etc. work too — see
[Other S3-compatible sources](#other-s3-compatible-sources).

A **master pod** lists the source and writes balanced shard manifests to the shared
disk; **N worker pods** each `rclone copy` one shard in parallel. It follows Crusoe's
AWS-S3 ["rclone parallel streams"](https://support.crusoecloud.com/hc/en-us/articles/37041258573723-How-To-Download-Data-From-AWS-S3-Using-Rclone-Parallel-Streams)
reference, tuned for a **high-RTT path** where throughput comes from **massive
concurrency**.

---

## Quick Start

```bash
cp .env.example .env    # fill in creds, namespace, region, bucket, destination disk
make sizing             # (optional) print the concurrency plan — no cluster access
make dry-run            # render manifests + preflight checks (launches nothing)
make preflight          # (optional) fio write-ceiling test (safe, no egress)
make run                # full pipeline; PROMPTS before the large transfer
```

> **Where does the data land?** The shared disk mounts at **`/data`** in every pod,
> and objects copy to **`DEST_PATH`** (default `/data/dataset`) — set it in `.env`.
> **Using an existing disk?** Set `DEST_MODE=import` (or `nfs`) + the disk id, then
> point `DEST_PATH` at where on that disk you want the files. See
> [Destination modes](#destination-modes-dest_mode).

---

## Architecture

```
        operator workstation (this repo, python3 + kubectl)
        │  build rclone.conf → K8s Secret
        │  list (via master) → bin-pack shards locally → push to shared disk
        ▼
┌──────────────────────────── Crusoe Managed Kubernetes ───────────────────────┐
│   Secret(rclone.conf, RO)        PVC: shared disk (VAST, RWX)                 │
│        ▼                                   ▼                                  │
│   ┌─────────────┐   rclone lsf      ┌─────────────────────────────────────┐  │
│   │ master pod  │ ───────────────►  │  shared disk  /data                 │  │
│   │ (rclone img)│   shards pushed   │   /shards/shard-0..N-1.txt          │  │
│   └─────────────┘ ◄───────────────  │   /logs/worker-*.log                │  │
│                                     │   /dataset/...  (downloaded objects)│  │
│                                     └─────────────────────────────────────┘  │
│   K workers per node (topology-spread, hostNetwork, unique rc port):          │
│   ┌───────── node 1 ─────────┐        ┌───────── node N ─────────┐            │
│   │ w0  w1  w2  w3 (shards)  │  ...   │ wK ...                   │            │
│   └─────┬──────────────┬─────┘        └─────┬──────────────┬─────┘            │
└─────────┼──────────────┼────────────────────┼──────────────┼──────────────────┘
          ▼              ▼                    ▼              ▼  hundreds of parallel
        ┌──────────────────────────────────────────────────┐   ranged-GET streams
        │   S3-compatible object store (e.g. OCI)            │   high RTT (intercontinental)
        └──────────────────────────────────────────────────┘
```

The fleet runs **`PODS_PER_NODE` independent rclone processes per node** — multiple
processes saturate the node NIC better than one big rclone (a single process hits
internal ceilings: one `http.Transport`, GC, lock contention). Each worker pod:

- **`hostNetwork: true`** — uses the node's NIC directly; each worker binds a unique
  rclone rc port (`5572 + index`) so co-located workers don't collide.
- **`topologySpreadConstraints`** — spreads workers evenly (`PODS_PER_NODE` per node),
  with CPU/mem requests auto-sized so exactly that many pack per node.
- **`nodeSelector: crusoe.ai/instance.class`** (`INSTANCE_CLASS`, default `s2a`) —
  pins to the target node class.
- mounts the RWX shared-disk PVC (read-write) and the rclone Secret (read-only),
  takes one shard, writes into `DEST_PATH`.

---

## Why concurrency (bandwidth-delay product)

Over a high-RTT path a single TCP stream is **window-limited**: `throughput ≈
tcp_window / RTT`. A ~16 MB autotuned window at 150 ms ≈ **0.85 Gbps per stream —
regardless of file size**. Aggregate throughput therefore comes from running **many
streams in parallel** to fill each node's bandwidth-delay product (BDP). Two
multiplicative rclone levers:

- **`--transfers`** — files copied in parallel (also the *only* parallelism for files
  **below** `--multi-thread-cutoff`).
- **`--multi-thread-streams`** — ranged-GET streams per *single* file **above** the
  cutoff (rclone v1.63+ for downloads).

In-flight streams per pod ≈ `transfers × multi-thread-streams`. The orchestrator
derives both from `TARGET_GBPS`.

---

## Sizing

**`TARGET_GBPS` is the single knob** (default 30). The orchestrator splits it across
`NUM_NODES` × `PODS_PER_NODE`, derives the rclone flags from the BDP model, and
auto-sizes pod CPU/mem so the pods pack. Run `make sizing` to see the plan; override
anything via env/flags, e.g.:

```bash
make run TARGET_GBPS=11.6 PODS_PER_NODE=16
make run --transfers 40 --multi-thread-streams 40   # pin the AWS-S3 reference config
```

Rough conversions: **1 PB/day ≈ 11.6 GB/s**, **30 GB/s ≈ 2.6 PB/day**. The binding
constraint is usually the **network path / object-store egress limits**, not the
cluster (see [Caveats](#operational-caveats)) — which is why this repo ships an fio
preflight and a throughput sweep. Non-`s2a` SKU? Set `NODE_VCPU` / `NODE_RAM_GIB` /
`NODE_NIC_GBPS` so the sizing model matches your node.

> **Node count & `PODS_PER_NODE`.** On 1–2 nodes you're usually **path-capped** —
> more pods won't raise *steady* throughput, but more pods = smaller shards = a
> **shorter straggler tail**, which dominates total transfer time. Start around
> **16–24 pods/node**; raise it if a run shows a long tail, back off if CPU saturates
> before the path does. Lower `WORKER_MEM_REQUEST` (~`2Gi`; actual use is small) so
> CPU — not an inflated memory request — is the packing limit. Find the knee with
> `bench/oci_experiment.py` ([below](#benchmarking)).

---

## Configuration

All inputs come from `.env` (copied from `.env.example`), process env, or CLI flags —
**never hardcoded**. Precedence: CLI flags > process env > `.env`.

| Variable | Meaning |
|---|---|
| `OCI_ACCESS_KEY_ID` / `OCI_SECRET_ACCESS_KEY` | S3-compat access/secret key pair (OCI: "Customer Secret Key") |
| `OCI_NAMESPACE` / `OCI_REGION` | OCI Object Storage namespace + region (auto-build the endpoint) |
| `OCI_BUCKET` / `OCI_PREFIX` | source bucket and optional prefix |
| `OCI_ENDPOINT` | explicit S3 endpoint (for non-OCI stores; blank = auto from namespace+region) |
| `TARGET_GBPS` | **the single sizing knob** (default 30) |
| `NUM_NODES` / `PODS_PER_NODE` | fleet size; total = nodes × pods/node (`NUM_PODS` forces an absolute total) |
| `INSTANCE_CLASS` | node class for the nodeSelector (default `s2a`) |
| `NODE_VCPU` / `NODE_RAM_GIB` / `NODE_NIC_GBPS` | per-node hardware for the sizing model (defaults = s2a.80x) |
| `RTT_MS` / `PER_STREAM_MBPS` / `STREAM_SAFETY` | BDP model inputs |
| `DEST_PATH` | **where objects are saved** — folder under the `/data` mount (default `/data/dataset`) |
| `DEST_MODE` | `dynamic` / `import` / `nfs` destination (see below) |
| `STORAGE_CLASS` / `PVC_NAME` / `PVC_SIZE` | destination shared disk |
| `EXISTING_DISK_ID` / `_NAME` / `_SERIAL` / `NFS_SERVER` | bind an existing disk (import/nfs modes) |
| `RCLONE_*` / `WORKER_MEM_REQUEST` | per-flag / resource overrides (blank = auto-derive) |

> **Region note:** use the **OCI** region slug where the *bucket* lives (not your
> destination region). Preflight warns if it doesn't look like an OCI slug.

### Other S3-compatible sources

The source backend is rclone `provider = Other`, so any S3-compatible store works.
The `OCI_*` names are just labels — for a non-OCI store, set `OCI_ENDPOINT` to its S3
endpoint and use its access/secret key + bucket:

| Source | `OCI_ENDPOINT` |
|---|---|
| OCI Object Storage | *(auto from namespace + region)* |
| AWS S3 | `https://s3.<region>.amazonaws.com` (or blank with a real AWS key) |
| MinIO / Ceph RGW | `https://<host>:<port>` |
| Google Cloud Storage | `https://storage.googleapis.com` (S3 interop + HMAC key) |
| Cloudflare R2 | `https://<account>.r2.cloudflarestorage.com` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` |

`force_path_style` and `no_check_bucket` are set for broad compatibility.

### Secrets handling

The credential is assembled into a complete `rclone.conf` and placed **only** in a
Kubernetes Secret, mounted **read-only** (`0400`) at `/config/rclone.conf`. It never
lands in the repo, in pod args, or in shell history. `.gitignore` blocks `.env`,
`rclone.conf`, and `*-secret.yaml`.

---

## What `make run` does

1. **Sizing + preflight** — prints the concurrency plan; verifies `kubectl`,
   enough schedulable nodes (`INSTANCE_CLASS`), and the StorageClass (creates it if
   absent).
2. **Secret** — builds `rclone.conf`, applies it in-cluster.
3. **PVC + master pod** — applies the RWX claim and the master.
4. **List + shard** — `rclone lsf` in the master → pull the listing → bin-pack (LPT)
   into N balanced shard files → push to `/data/shards/`.
5. **Confirm** — prompts before the large transfer (skip with `--yes`).
6. **Launch** — `PODS_PER_NODE` workers per node (pinned), each `rclone copy
   --files-from shard-i.txt --no-traverse …`.
7. **Monitor → teardown** — polls to completion, then deletes worker + master pods
   (keeps PVC, Secret, data) unless `--keep`.

Idempotent: `rclone copy` skips objects already present (size/checksum), so a re-run
only fetches what's missing.

---

## Destination modes (`DEST_MODE`)

| `DEST_MODE` | What it does | Needs | When |
|---|---|---|---|
| `dynamic` (default) | provisions a new disk via the fs CSI driver | — | greenfield |
| `import` | binds an **existing** disk via a CSI **static PV** | disk `id` + `name` + `serial` | migrate into an existing disk, CSI healthy |
| `nfs` | binds an **existing** disk via an **in-tree NFS PV** to the VAST DNS endpoint (bypasses CSI) | disk `id` (+ `NFS_SERVER`) | when a CSI mount times out on an unroutable fallback IP |

Find the disk with `crusoe storage disks list -f json` (pick the `shared-volume` in
your region): `.id`, `.name`, `.serial_number`. All modes use `reclaimPolicy: Retain`,
so deleting the PVC/PV never deletes the disk or data.

**Where files go (all modes):** the bound disk mounts at `/data`; objects are written
to `DEST_PATH`. Point it wherever you want them — e.g. into a folder on an existing
disk:

```bash
DEST_MODE=import EXISTING_DISK_ID=<id> EXISTING_DISK_NAME=<name> EXISTING_DISK_SERIAL=<serial> \
  DEST_PATH=/data/datasets/fineweb-edu  make run
```

Because `rclone copy` is idempotent, `DEST_PATH` can point at a folder already holding
part of the dataset — only missing/changed objects are pulled.

> **`nfs` mode** exists because the fs CSI driver can fall back to a fixed IP that may
> be unroutable from your nodepool (mounts hang). The VAST DNS endpoint
> (`nfs.crusoecloudcompute.com`, `remoteports=dns`) mounts cleanly; `nfs` mode creates
> an in-tree NFS PV straight to it (see `k8s/nfs-pv.yaml`). If a CSI mount hangs,
> prefer `nfs`. Export path defaults to `/volumes/<EXISTING_DISK_ID>`.

---

## Benchmarking

- **`make preflight`** — fio write-ceiling, one pod per node, no egress. If the
  download later plateaus near this number, the write path is the limit.
- **`make fio-bench`** — full fio matrix (seq/rand read+write, `direct=1`) per node →
  git-ignored `bench/results/fio-<ts>/`. Tune `FIO_JOBS`/`FIO_IODEPTH`.
- **`make collect`** — attach to a running fleet; log throughput → CSV.
- **`make sweep …`** — sweep `(transfers, multi-thread-streams, pods-per-node)` on a
  *bounded sample* to find the knee. **Bills egress**; requires `--yes`.
- **`python3 bench/oci_experiment.py --nodes N --pods-per-node K [--max-seconds S]
  --label NAME`** — one transfer at a chosen concurrency (pins exactly K/node);
  reports total transfer time, avg/steady GB/s (from rclone stats **and** the node
  NIC counters as ground truth), and throttle signals → `bench/results/oci-exp-<NAME>/`.

### Tracking a run in progress

```bash
kubectl get pods -l app=cmk-data-transfer-worker -o wide        # phases + nodes
kubectl logs -f cmk-data-transfer-worker-0                      # live rclone progress (one shard)
kubectl top nodes ; kubectl top pods -l app=cmk-data-transfer-worker   # CPU/mem

# fleet-wide bytes transferred so far (RC_PORT = 5572 + index; skips not-ready pods):
kubectl get po -l app=cmk-data-transfer-worker --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name} {range .spec.containers[0].env[?(@.name=="RC_PORT")]}{.value}{end}{"\n"}{end}' \
  | xargs -P16 -n2 sh -c 'kubectl exec "$0" -- rclone rc core/stats --rc-addr localhost:"$1" 2>/dev/null | python3 -c "import json,sys;s=sys.stdin.read().strip();print(json.loads(s).get(\"bytes\",0) if s.startswith(\"{\") else 0)"' \
  | awk '{s+=$1; n++} END{printf "fleet: %.2f TB across %d pods\n", s/1e12, n}'
```

> rclone's own `MiB/s` in the logs is a *cumulative average* — on a high-RTT path it
> decays during the straggler tail and understates steady rate. Trust the byte-delta /
> NIC numbers from `oci_experiment.py` (`summary.json` / `timeseries.csv`).

---

## Tuning guide

| Symptom | Likely cause | Lever |
|---|---|---|
| Throughput flat, NIC underutilized | not enough streams to fill BDP | ↑ `PODS_PER_NODE`, ↑ `--multi-thread-streams`/`--transfers`, ↓ `PER_STREAM_MBPS` |
| One rclone pegged / stalls below NIC | single-process ceiling | ↑ `PODS_PER_NODE` (more independent processes) |
| Throughput flat near the fio number | disk write ceiling | more nodes; larger `--buffer-size`; accept the ceiling |
| `503 SlowDown` / `429` in logs | object-store request-rate throttling | ↓ `--checkers`/`--transfers`; spread the prefix |
| A few pods stall, throughput collapses | slow-connection lottery starves few slots | keep `--transfers` **high** (≈40); more pods/nodes for the tail |
| Long finishing tail | last-chunk stragglers | more pods/nodes (smaller shards); smaller `--multi-thread-chunk-size` |
| Memory pressure | too many large in-flight chunks | ↓ `--multi-thread-streams` / `--multi-thread-chunk-size` |

`--transfers` scales small/medium-file and connection-churn parallelism;
`--multi-thread-streams` scales large-file (BDP-fill) parallelism.

---

## Operational caveats

- **Egress is billed per byte** — every pull, and every re-pull during a sweep,
  incurs object-store egress. Budget for the dataset size plus sweep samples.
- **Request-rate throttling** — very high `--checkers`/`--transfers` can trigger
  `429`/`503`; rclone backs off, but sustained throttling caps throughput. Spreading
  objects across more prefixes helps.
- **Disk write/read ceiling** may bind before the NIC — run the fio preflight and
  cross-check throughput against the node NIC counters.
- **`hostNetwork: true`** — workers share the node's network namespace and bind host
  ports (`localhost:5572+index`). Don't co-schedule workloads that grab those ports.

---

## Alternative: native OCI backend

Instead of the S3-compat path you can use rclone's native `oracleobjectstorage`
backend (OCI IAM auth, no access/secret key):

```ini
[oci-native]
type = oracleobjectstorage
namespace = <namespace>
region = <region>
provider = user_principal_auth      # or instance_principal_auth / resource_principal_auth
config_file = /root/.oci/config
config_profile = DEFAULT
```

Mount your `~/.oci` config + key into the pods and point the remote at `oci-native:`.
The S3-compat path is the default because it matches the credential most users hold.

---

## Repo layout

```
.env.example            all inputs (copy to .env)
Makefile                sizing / dry-run / preflight / run / fio-bench / sweep / collect / clean
orchestrator/           config, BDP sizing, rclone.conf builder, kubectl, manifests, run
shard/shard_manifest.py deterministic size-balanced LPT bin-packer (standalone + importable)
k8s/                    reference YAML: storageclass, pvc, import-pv, nfs-pv, master/worker pods, secret example
bench/                  oci_experiment.py, collect.py, sweep.py, fio/
preflight/              fio write-ceiling test (yaml + run_fio.py)
```

## Requirements

- `python3 >= 3.9` and `kubectl` on the operator workstation (stdlib only — the
  orchestrator shells out to `kubectl`).
- A `KUBECONFIG` with access to the CMK cluster and schedulable worker nodes
  (`INSTANCE_CLASS`, default `s2a`).
- An S3-compatible access/secret key with read access to the source bucket.

---

## Disclaimer

This solution is provided **AS IS, WITHOUT WARRANTY OF ANY KIND**, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. The orchestrator, manifests, scripts, and documentation in this directory are reference implementations intended to help you get started — they are not a supported Crusoe product and may not be appropriate for every deployment without customization. Running transfers incurs object-store egress and compute cost, and throughput depends on factors outside this tooling (source-provider limits, network path, and storage backend). Use at your own risk; review the manifests and cost/egress implications against your security and operational requirements before applying them to production clusters.
