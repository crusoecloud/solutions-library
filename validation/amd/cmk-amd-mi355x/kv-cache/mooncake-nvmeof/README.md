# Mooncake NVMe-oF KV cache tier on AMD MI355X

Pool the local NVMe drives across your GPU nodes into one shared KV cache tier,
so a prefill computed on one node can be reused by every other node instead of
recomputed.

Validated end to end on MI355X: **42.36 GB/s cross-node**, 24.45 TB pooled,
and a 10 MB blob written on one node reads back byte-identical on another.

---

## The problem this solves

When an LLM serves a request it first runs **prefill**: it reads the whole
prompt and builds a KV cache. Only then does it start producing tokens. Prefill
is expensive and it scales with context length, so for long prompts it can be
seconds of GPU time before the first token appears.

If two requests share a prefix, a long system prompt, a document, a
conversation history, the second one can reuse the first one's KV cache and skip
that work entirely. That is the whole game.

The catch is where you keep the cache. GPU memory is small, so entries get
evicted quickly. When an entry is gone you pay for prefill again:

```
GPU VRAM        sub-microsecond    hot, current requests
host DRAM       microseconds       warm
local NVMe      ~100 µs            cold, this node only
pooled NVMe     ~110 µs            cold, SHARED across nodes    ← this guide
─────────────────────────────────────────────────────────────
recompute       100 ms to seconds  1000x worse
```

Every tier above the line is an I/O cost. The line below is a compute cost, and
it is three to four orders of magnitude more expensive.

A bigger local disk gets you a deeper cache on one node. **Pooling gets you
something different:** a prefill computed on node 5 is reusable by node 20.
Without it, a 60-node cluster recomputes the same popular prefixes 60 times.

This guide builds that pooled tier.

---

## Results

Measured on a 2-node MI355X cluster, 7 drives per node.

| | |
|---|---|
| **Cross-node bandwidth** | **42.36 GB/s** (128KB blocks, QD=64) |
| Cross-node, 1MB blocks | 38.90 GB/s (QD=128) |
| Loopback, same node | 36.32 GB/s (128KB, QD=32) |
| Fabric ceiling | 47.6 GB/s (`ib_write_bw`, 8 QPs, 10.34 µs) |
| Pool registered | 24.45 TB across 7 namespaces |
| Cross-node put/get | byte-identical, SHA256 verified |

Roughly 90% of both the drive and fabric ceilings.

Cross-node beating loopback is expected, not a mistake: loopback drives both
directions through one NIC and contends for cores on a single host, so it is the
harder case.

<details>
<summary>Full queue-depth sweep</summary>

128 KB blocks, 30-second runs, target on cores 0-3, initiator on cores 4-7:

| Queue depth | IOPS | Throughput | Avg latency |
|---|---|---|---|
| 32 | 336,724 | 42.09 GB/s | 665 µs |
| **64** | 338,880 | **42.36 GB/s** | 1,321 µs |
| 128 | 338,012 | 42.25 GB/s | 2,650 µs |

QD=32 is the sweet spot if latency matters: 665 µs while still delivering
42 GB/s.

</details>

---

## How it works

```
GPU VRAM
   │  hipMemcpy device-to-host   ("D2H staging")
   ▼
host DRAM (hugepages)
   │  SPDK, userspace poll-mode driver
   ▼
RoCEv2 NIC ──── NVMe-oF ────▶  remote node's NVMe
```

Data stages through host memory before SPDK writes it out. Nothing goes
storage-direct-to-VRAM, so **no GPUDirect Storage equivalent is needed** and
this works on ROCm unmodified. Both `USE_CUDA` and `USE_HIP` log the same
`enabling D2H staging`.

### One thing to get right before you start

Mooncake has **two unrelated NVMe-over-fabrics code paths**. You want `USE_NOF`.

| | `USE_NVMEOF` | `USE_NOF` |
|---|---|---|
| Subsystem | `mooncake-transfer-engine` | `mooncake-store` |
| Depends on | NVIDIA cuFile | **SPDK + DPDK** |
| Builds on ROCm | no | **yes** |

`USE_NVMEOF` pulls in `cufile.h` and is CUDA-only. If you find yourself reading
`cufile_context.cpp`, you are in the wrong subsystem.

---

## Prerequisites

```
GPU        8x AMD Instinct MI355X (gfx950)
NIC        8x AMD Pensando Pollara 400, RoCEv2, rail-isolated
NVMe       8 local drives, 7 usable (one holds containerd)
Kernel     6.8.12-322.crusoe.amd64
Platform   Crusoe Managed Kubernetes, 2+ Ready nodes
```

Plus `kubectl` and a container registry.

### Registry access

You need one `docker-registry` Secret, used twice: the build pod pushes the
image with it, and both validation pods pull the image with it. The manifests
substitute the same `__PULL_SECRET__` name into all three.

```bash
kubectl -n <namespace> create secret docker-registry <secret-name> \
  --docker-server=<registry-host> \
  --docker-username=<username> \
  --docker-password=<token>
```

On Crusoe's CCR the username is your **account email address**, not the user
UUID, and the password is a token from `crusoe registry tokens create`. Worked
example and the full image-path format in
[BUILD.md](./BUILD.md#1-registry-credentials).

Any OCI registry works. Nothing here is tied to one provider.

### The ionic RDMA provider

Stock images **cannot see the Pollara NICs**. `ibv_devinfo` lists nothing and
every listener fails. You need three files, copied off any running MI355X node:

```
/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so
/usr/lib/x86_64-linux-gnu/libionic.so.1
/etc/libibverbs.d/ionic.driver
```

Place them flat next to the Dockerfile before building. The provider ABI is
rdma-core **v34**, so bundle a compatible rdma-core in your image.

### Pod requirements

The pods need `hostNetwork: true`, `hostPID: true`, `privileged: true`, and
hostPath mounts for `/dev/vfio`, `/dev/infiniband`, `/lib/modules` and
hugepages.

`hostNetwork` is not optional. `rdma_bind_addr()` binds a **local** address, so
without it the RDMA interface does not exist in the pod's namespace and no
listener can come up.

> This is a significant reduction in container isolation. Review it before
> running on anything shared.

---

## Build

Detail in [BUILD.md](./BUILD.md). In short:

```bash
# context must be flat: Dockerfile + the three ionic files
kubectl create configmap build-context \
  --from-file=Dockerfile=Dockerfile.mooncake-nof-mi355x \
  --from-file=libionic-rdmav34.so --from-file=libionic.so.1 \
  --from-file=ionic.driver

sed -e "s#__IMAGE__#<registry>/mooncake-nof-mi355x:v1#g" \
    -e "s#__PULL_SECRET__#<pull-secret>#g" \
    kaniko-build-mooncake-nof.yaml | kubectl apply -f -
```

Build flags:

```
-DUSE_NOF=ON -DUSE_HIP=ON -DUSE_HIP_DMABUF=ON -DUSE_CUDA=OFF
```

The build asserts `libamdhip64` is linked and `libcudart` is not. Two things it
handles that are easy to miss: it stubs `amdgpu-arch` so the image can build on
a GPU-less kaniko node, and it wraps `rpc.py` to run under Python 3.12, since
older SPDK uses `action='store_true'` on a positional argument which Python 3.14
rejects.

---

## Run

### 1. Deploy and confirm the provider

```bash
sed -e "s#__IMAGE__#<registry>/mooncake-nof-mi355x:v1#g" \
    -e "s#__PULL_SECRET__#<pull-secret>#g" \
    -e "s#<target-node>#$TARGET#g" \
    mooncake-nvmeof-target-pod.yaml | kubectl apply -f -

kubectl exec <pod> -- ibv_devinfo | grep ionic    # expect ionic_0..ionic_7
```

### 2. Hugepages

Set the limit at **every level** of the cgroup tree, not just the leaf. If you
skip the walk you get `ENOMEM` from `mmap` with no other diagnostic. See
[hugepage allocation fails](#dpdk-cannot-allocate-hugepages).

```bash
echo 8192 > /proc/sys/vm/nr_hugepages
CG=$(awk -F: '{print $3}' /proc/self/cgroup | head -1)
P="/sys/fs/cgroup${CG}"
while [ "$P" != "/sys/fs/cgroup" ]; do
  [ -f "$P/hugetlb.2MB.max" ] && { echo max > "$P/hugetlb.2MB.max"; \
                                   echo max > "$P/hugetlb.2MB.rsvd.max"; }
  P=$(dirname "$P")
done
mkdir -p /mnt/ht && mount -t hugetlbfs -o pagesize=2M nodev /mnt/ht
```

### 3. Bind the drives

```bash
modprobe vfio-pci
echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
mkdir -p /dev/vfio && mknod /dev/vfio/0 c 234 0; chmod 666 /dev/vfio/0

# per drive:
echo "${VENDOR#0x} ${DEVICE#0x}" > /sys/bus/pci/drivers/vfio-pci/new_id
echo <BDF> > /sys/bus/pci/drivers/vfio-pci/bind
```

`/dev/vfio/<group>` is **not** auto-created in no-IOMMU mode. Skip the `mknod`
and DPDK reports `Cannot find device` for a drive that is correctly bound.

Leave the containerd drive alone: `findmnt -no SOURCE /var/lib/containerd`.

### 4. Target, transport, namespaces

Order matters. The transport must exist before any listener.

```bash
nvmf_tgt -m 0xF -s 1024 --env-context="--huge-dir=/mnt/ht" &
spdk-rpc nvmf_create_transport -t RDMA

for i in $(seq 0 6); do
  spdk-rpc bdev_nvme_attach_controller -b nvme$i -t pcie -a <BDF_$i>
  spdk-rpc nvmf_create_subsystem nqn.2016-06.io.spdk:cnode$i -a -s SPDK$i
  spdk-rpc nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode$i nvme${i}n1
  spdk-rpc nvmf_subsystem_add_listener nqn.2016-06.io.spdk:cnode$i \
      -t rdma -f ipv6 -a <target-ionic-ipv6> -s 4420
done
```

**On an IPv6 fabric `-f ipv6` is required and the address must be in compressed
form.** SPDK compares listener addresses as literal strings; a zero-padded
address silently never matches. See
[connections rejected](#all-connections-rejected).

> **`-a` means allow any host.** These subsystems have no host authentication,
> so anything reaching the listener can read and write those drives. Fine for a
> closed validation run, wrong for a shared fabric. For anything beyond a test,
> drop `-a` and allow specific host NQNs with `nvmf_subsystem_add_host`, or put
> storage traffic on its own isolated traffic class.

### 5. Register with Mooncake

```bash
mooncake_master --enable_http_metadata_server=true --http_metadata_server_port=8080
```

```python
from mooncake.store import MooncakeDistributedNoFRegister

register = MooncakeDistributedNoFRegister()
for i in range(7):
    register.real_register(f'nqn.2016-06.io.spdk:cnode{i}', 1,
                           '<target-ionic-ipv6>', 4420, 0,
                           namespace_size_bytes, '127.0.0.1:50051')
```

Confirm in the master log that segment descriptors read `adrfam:IPv6`, and that
the counter reaches your pool size. On IPv6 fabrics this needs
[`mooncake-ipv6-adrfam.patch`](./mooncake-ipv6-adrfam.patch), since upstream
hardcodes `adrfam:IPv4`.

### 6. Measure

```bash
spdk_nvme_perf \
  -r "trtype:RDMA adrfam:IPv6 traddr:<target-ionic-ipv6> trsvcid:4420 subnqn:nqn.2016-06.io.spdk:cnode0" \
  ... (one -r per namespace) \
  -c 0xF0 -q 64 -o 131072 -w read -t 30
```

Three things that will give you a wrong number:

- **fio does not drive the SPDK path.** Queue depth will not scale: an early fio
  run gave 87,752 IOPS at QD=1 against 89,973 at QD=32. Use `spdk_nvme_perf`.
- **Small blocks measure IOPS, not bandwidth.** A 4 KB run produced 12.1 GB/s at
  3.1M IOPS. Use 128 KB or larger.
- **Target and initiator need disjoint core masks.** Both on `0x3` produced 9 ms
  latency from scheduler thrashing, which reads as a fabric problem and is not.

### 7. Prove the Mooncake path

`spdk_nvme_perf` bypasses Mooncake entirely, so it proves the plumbing and
nothing more. To exercise the tier itself:

```python
from mooncake.store import MooncakeDistributedStore, ReplicateConfig

cfg = ReplicateConfig()
cfg.nof_replica_num = 1     # default is 0 — without this it never reaches NVMe
store.put(key, data, cfg)
```

Then `get(key)` from a second node pointed at the first node's metadata server
and master, and compare checksums.

### 8. Clean up

Unbind the drives, set `enable_unsafe_noiommu_mode` back to `0`, remove
`/dev/vfio/0`. See `../nvme-spdk-binding-test/cleanup-spdk-nvmeof.sh`.

---

## When things break

Four failures that each cost days here. All have misleading symptoms.

### DPDK cannot allocate hugepages

```
alloc_seg(): mmap() failed: Cannot allocate memory
EAL: FATAL: Cannot init memory
```

or, earlier in EAL init, `couldn't find suitable memseg_list` or
`rte_service_init() failed`. All three are the same problem at different stages.

**Why it is confusing:** everything looks right. 8192 free hugepages,
hugetlbfs mounted, and the container's own cgroup limits set to `max`.

**Cause:** in cgroup v2 the effective hugetlb limit is the **minimum along the
entire path from root to leaf**. Kubernetes sets the pod-level limit from the
pod's `hugepages-2Mi` request. When kubelet reports `hugepages-2Mi: 0` capacity
you cannot request any, so the pod cgroup gets:

```
/sys/fs/cgroup/kubepods/burstable/pod<UUID>/hugetlb.2MB.max      = 0
/sys/fs/cgroup/kubepods/burstable/pod<UUID>/hugetlb.2MB.rsvd.max = 0
```

Setting the leaf to `max` changes nothing while an ancestor holds `0`.

**Diagnose** by walking the tree:

```bash
CG=$(awk -F: '{print $3}' /proc/self/cgroup | head -1)
P="/sys/fs/cgroup${CG}"
while [ "$P" != "/sys/fs/cgroup" ] && [ "$P" != "/" ]; do
  echo "$P max=$(cat $P/hugetlb.2MB.max 2>/dev/null)" \
       "rsvd=$(cat $P/hugetlb.2MB.rsvd.max 2>/dev/null)"
  P=$(dirname "$P")
done
```

**Fix** is the loop in [step 2](#2-hugepages). Note `rsvd.max` is a *separate*
limit and it is the one that bites: it gates `mmap(MAP_POPULATE)`, which is what
DPDK uses.

**Test with mmap, not `dd`:**

```bash
python3 -c "
import mmap
MAP_HUGETLB = 0x40000
m = mmap.mmap(-1, 2*1024*1024,
              flags=mmap.MAP_PRIVATE|mmap.MAP_ANONYMOUS|MAP_HUGETLB,
              prot=mmap.PROT_READ|mmap.PROT_WRITE)
m.write(b'x'*4096); print('HUGEPAGE MMAP OK')"
```

`dd` to a hugetlbfs file always fails with `EINVAL`, because hugetlbfs supports
`mmap()` and not `write()`. That is correct behaviour on a healthy mount and
tells you nothing.

**Do not reach for `--no-huge`.** It looks like the obvious escape and cannot
work:

```
no IOMMU  →  IOVA=PA required  →  hugepages mandatory
--no-huge →  forces IOVA=VA
            "Expecting 'PA' IOVA mode but current mode is 'VA'"
```

`nvmf_tgt` starts, then real PCIe devices refuse to attach. That looks like
progress and is not.

### All connections rejected

```
ctrlr.c:739:nvmf_qpair_access_allowed: *ERROR*: Subsystem '...' does not allow
host 'nqn.2014-08.org.nvmexpress:uuid:...' to connect at this address.
```

Connections reach the target and are logged. `allow_any_host` is true. Loopback
fails identically to cross-node.

**Why it is confusing:** the message names the host NQN, so it reads as host
access control. It is not. There are two checks with different messages:

```c
spdk_nvmf_subsystem_host_allowed()      -> "does not allow host '%s'"
spdk_nvmf_subsystem_listener_allowed()  -> "... to connect AT THIS ADDRESS."
```

The trailing **"at this address"** is the *listener* check. The host check
already passed.

**Cause:** `spdk_nvme_transport_id_compare()` compares `traddr` with
`strcasecmp()` and does not normalise IPv6. Incoming connections carry whatever
`inet_ntop()` produced, which is compressed per RFC 5952:

```
registered    fd00:0801:0002:0003:0690:81ff:fe40:0001    zero-padded
incoming      fd00:801:2:3:690:81ff:fe40:1               compressed
                   ^^^^ ^^^^ ^^^^ ^^^^
```

Never matches. Every connection rejected.

**Fix** — re-register with the exact string the system reports:

```bash
spdk-rpc nvmf_subsystem_get_listeners nqn.2016-06.io.spdk:cnode0  # what SPDK holds
ip -6 addr show <rdma-netdev> | grep inet6                        # what it should be

spdk-rpc nvmf_subsystem_remove_listener <nqn> -t rdma -f ipv6 -a <padded> -s 4420
spdk-rpc nvmf_subsystem_add_listener    <nqn> -t rdma -f ipv6 -a <compressed> -s 4420
```

**Related:** `getaddrinfo failed ... (-9)` earlier in the process is
`EAI_ADDRFAMILY`, meaning the address does not match the family in the hints.
You passed an IPv6 address without `-f ipv6`. Varying the address will not help;
the family is the wrong parameter.

### put() succeeds but nothing reaches NVMe

`store.put()` returns `0`. No errors. The master's `NVMe-oF SSD: 0 B / <size>`
counter never moves.

**Cause:** `ReplicateConfig.nof_replica_num` defaults to **0**, meaning
memory-only. A put without it goes to DRAM and never touches the NVMe tier.

```python
cfg = ReplicateConfig()
cfg.nof_replica_num = 1       # REQUIRED
store.put(key, data, cfg)
```

**Verify by watching the used counter**, not the return code:

```
NVMe-oF SSD: 10.00 MB / 24.45 TB     # used side moved -> data is on NVMe
```

This is the quietest failure of the four. Everything reports success and the
tier you built is simply unused.

### ibv_devinfo shows no ionic devices

`ibv_devinfo` lists `mlx5_0` but no `ionic_*`. Or `rdma_bind_addr()` fails on an
address that `ip -6 addr` clearly shows on the interface.

**Cause:** the missing ionic provider. See
[prerequisites](#the-ionic-rdma-provider). Bake the three files into the image
rather than copying into running pods, or you will redo it after every restart.

If the provider is present and bind still fails, check `hostNetwork`.
`rdma_bind_addr()` binds a local address; without `hostNetwork: true` the pod
has its own network namespace where the RDMA interface does not exist. That is
an existence error, not a permissions error.

### Quick reference

| Symptom | Cause |
|---|---|
| `mmap() failed: Cannot allocate memory` | cgroup ancestor holds `hugetlb.2MB.max=0` |
| `couldn't find suitable memseg_list` | same |
| `rte_service_init() failed` | same |
| `Expecting 'PA' IOVA mode` | `--no-huge` under no-IOMMU |
| `does not allow host ... at this address` | listener `traddr` string mismatch |
| `getaddrinfo failed ... (-9)` | missing `-f ipv6` |
| `put()` returns 0, counter stays at 0 B | `nof_replica_num` defaults to 0 |
| No `ionic_*` in `ibv_devinfo` | missing ionic provider |
| `rdma_bind_addr() failed` | missing provider, or no `hostNetwork` |
| `Cannot find device <BDF>` | `/dev/vfio/<group>` not created in no-IOMMU mode |

---

## Upstream bugs found

Both reproducible, both affecting any IPv6 RoCE fabric.

### Mooncake hardcodes `adrfam:IPv4`

In `mooncake-store/src/ssd_register_client.cpp`, in **both** `set_register()`
and `set_unregister_by_endpoint()`:

```cpp
std::string te_endpoint = "traddr:" + traddr +
                          " trsvcid:" + std::to_string(trsvcid) +
                          " subnqn:" + nqn + " trtype:" + trtype +
                          " adrfam:IPv4 ns:" + std::to_string(nsid);
```

Present in `v0.3.12.post1` and `main`. The adjacent `trtype` *is* configurable
through `NoFRegisterConfig`, which suggests the address family was an oversight
rather than a decision.

The string feeds `spdk_nvme_transport_id_parse()` and then `spdk_nvme_probe()`,
so it is functional, not cosmetic.

Patch both functions together. `set_unregister_by_endpoint()` rebuilds the
identical string and matches on it exactly, so patching only the register side
leaves segments unremovable. Fix:
[`mooncake-ipv6-adrfam.patch`](./mooncake-ipv6-adrfam.patch).

### SPDK does not normalise IPv6 in listener matching

Covered in [all connections rejected](#all-connections-rejected) above.
`spdk_nvme_transport_id_compare()` uses `strcasecmp()` on `traddr`, so a
listener registered in zero-padded form is unreachable, and the error points at
host access control rather than address formatting.

---

## Pollara VF capabilities

From `ibv_devinfo -v -d ionic_0`, full output in
[`ibv-devinfo-ionic0.txt`](./ibv-devinfo-ionic0.txt).

| | |
|---|---|
| `max_qp` | 4096 |
| `max_qp_wr` | 65535 |
| `max_srq` | 256 |
| `max_mr` | 16383 |
| `max_cqe` | 65435 |
| `max_sge` | 8 |

**Size `max_qp` against your topology before committing to all-to-all.** If each
peer opens *n* queue pairs, a pool of *N* nodes needs roughly `(N-1) x n`
inbound QPs per VF, plus whatever the initiator side consumes on the same
device.

Address families on this fabric:

```
GID 0        link-local IPv6, RoCE v2
GID 1        global IPv6, RoCE v2
GID 2-255    all zeros
```

No IPv4 GID at any index, which is what makes both upstream bugs matter here.

---

## Files

| | |
|---|---|
| `Dockerfile.mooncake-nof-mi355x` | ROCm 7.14 + SPDK + Mooncake `USE_NOF` |
| `BUILD.md` | build and registry push |
| `kaniko-build-mooncake-nof.yaml` | in-cluster build |
| `mooncake-nvmeof-{target,initiator}-pod.yaml` | validation pods |
| `mooncake-ipv6-adrfam.patch` | IPv6 address-family fix |
| `ibv-devinfo-ionic0.txt` | Pollara VF capabilities |
| `ionic-provider/` | `ionic.driver` stub. The two `.so` files are **not** in this repo — copy them off a running node, see [prerequisites](#the-ionic-rdma-provider) |

## Related

- [`../nvme-spdk-binding-test/`](../nvme-spdk-binding-test/) — SPDK NVMe-oF over
  RoCE without Mooncake. Useful on its own, and the right place to start when
  something here fails: if the SPDK layer works standalone, the problem is above
  it. The cleanup script lives there too.
- [Mooncake](https://github.com/kvcache-ai/Mooncake) · [SPDK](https://spdk.io)
