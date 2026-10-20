# Mooncake NVMe-oF KV cache tier on AMD MI355X

Build and validate a **cross-node NVMe storage tier for Mooncake Store** on AMD
Instinct MI355X nodes, using SPDK NVMe-over-Fabrics across an RoCEv2 fabric.

This lets inference nodes pool their local NVMe drives into one logical KV cache
tier, so a prefill computed on one node can be reused by any other node instead
of being recomputed.

**Validated end to end:** build on ROCm, register drives with the Mooncake
master, move data cross-node at 42 GB/s, and prove a put on one node reads back
byte-identical on another.

---

## Results

| | Measured | |
|---|---|---|
| Cross-node bandwidth | **42.36 GB/s** | 128KB blocks, QD=64, 7 drives |
| Cross-node, 1MB blocks | 38.90 GB/s | QD=128 |
| Loopback, same node | 36.32 GB/s | 128KB, QD=32 |
| Fabric ceiling | 47.6 GB/s | `ib_write_bw`, 8 QPs, 10.34 µs |
| Pool registered | 24.45 TB | 7 x 3.49 TiB |
| Cross-node put/get | byte-identical | 10 MB blob, SHA256 verified |

Cross-node beating loopback is expected: loopback drives both directions through
one NIC and contends for cores on a single host.

---

## Hardware and software validated

```
GPU          8x AMD Instinct MI355X (gfx950)
NIC          8x AMD Pensando Pollara 400, RoCEv2, rail-isolated
NVMe         8 local drives, 7 usable (one holds containerd)
Kernel       6.8.12-322.crusoe.amd64
Platform     Crusoe Managed Kubernetes (CMK)

ROCm         7.14.1
Mooncake     v0.3.12.post1, built with USE_NOF=ON USE_HIP=ON
SPDK         pinned by the Mooncake submodule
```

---

## How the tier works

```
GPU VRAM
   │  hipMemcpy device-to-host  ("D2H staging")
   ▼
host DRAM (hugepages)
   │  SPDK, userspace poll-mode
   ▼
RoCEv2 NIC ──── NVMe-oF ────▶  remote node's NVMe
```

Data stages through host memory before SPDK writes it out. Nothing goes
storage-direct-to-VRAM, so **no GPUDirect Storage equivalent is required** and
the path works on ROCm unmodified. Both `USE_CUDA` and `USE_HIP` log the same
`enabling D2H staging`.

### Two flags, one of which is the wrong one

Mooncake has two unrelated NVMe-over-fabrics code paths. Use `USE_NOF`.

| | `USE_NVMEOF` | `USE_NOF` |
|---|---|---|
| Subsystem | `mooncake-transfer-engine` | `mooncake-store` |
| Depends on | NVIDIA cuFile | **SPDK + DPDK** |
| Builds on ROCm | no | **yes** |

`USE_NVMEOF` pulls in `cufile.h` and is CUDA-only. If you find yourself reading
`cufile_context.cpp`, you are in the wrong subsystem.

---

## Prerequisites

- A CMK cluster with an MI355X nodepool, at least 2 `Ready` nodes
- `kubectl`, and a registry you can push to plus a matching `dockerconfigjson`
  pull secret
- The **ionic userspace RDMA provider**. Stock images cannot see the Pollara
  NICs without it. Copy these three files off any running MI355X node:

  ```
  /usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so
  /usr/lib/x86_64-linux-gnu/libionic.so.1
  /etc/libibverbs.d/ionic.driver
  ```

  Place them flat next to the Dockerfile before building. The provider ABI is
  rdma-core **v34**; bundle a compatible rdma-core in your image.

### Pod requirements

The target pod needs `hostNetwork: true`, `hostPID: true`, `privileged: true`,
and hostPath mounts for `/dev/vfio`, `/dev/infiniband`, `/lib/modules` and
hugepages. `rdma_bind_addr()` binds a **local** address, so without
`hostNetwork` the RDMA interface does not exist in the pod's namespace and the
listener cannot come up.

This is a significant isolation reduction. Review it before running on anything
shared.

---

## Build

Full detail in [BUILD.md](./BUILD.md). In short:

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

The Dockerfile builds Mooncake with:

```
-DUSE_NOF=ON -DUSE_HIP=ON -DUSE_HIP_DMABUF=ON -DUSE_CUDA=OFF
```

and asserts at build time that `libamdhip64` is linked and `libcudart` is not.

Two things the build handles that are easy to miss: it stubs `amdgpu-arch` so
the image can build on a GPU-less kaniko node, and it wraps `rpc.py` to run
under Python 3.12, since older SPDK uses `action='store_true'` on a positional
argument which Python 3.14 rejects.

---

## Run

### 1. Deploy

```bash
sed -e "s#__IMAGE__#<registry>/mooncake-nof-mi355x:v1#g" \
    -e "s#__PULL_SECRET__#<pull-secret>#g" \
    -e "s#<target-node>#$TARGET#g" \
    mooncake-nvmeof-target-pod.yaml | kubectl apply -f -
```

Confirm the provider took: `ibv_devinfo` should list `ionic_0` through
`ionic_7`.

### 2. Hugepages

Set the limit at **every level** of the cgroup tree, not just the leaf. See
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md#1-dpdk-cannot-allocate-hugepages).

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

### 3. Bind drives

```bash
modprobe vfio-pci
echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
mkdir -p /dev/vfio && mknod /dev/vfio/0 c 234 0; chmod 666 /dev/vfio/0
# then, per drive:
echo "${VENDOR#0x} ${DEVICE#0x}" > /sys/bus/pci/drivers/vfio-pci/new_id
echo <BDF> > /sys/bus/pci/drivers/vfio-pci/bind
```

`/dev/vfio/<group>` is not auto-created in no-IOMMU mode. Skip the `mknod` and
DPDK reports `Cannot find device` for a drive that is correctly bound.

Leave the containerd drive alone. Find it with
`findmnt -no SOURCE /var/lib/containerd`.

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

**On an IPv6 fabric, `-f ipv6` is required and the address must be in compressed
form.** SPDK compares listener addresses as literal strings. A zero-padded
address silently never matches and every connection is rejected. See
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md#2-all-connections-rejected-with-does-not-allow-host--at-this-address).

> **`-a` means allow any host.** Every subsystem above is created with no host
> authentication, so anything that can reach the listener can read and write
> those drives. That is fine for a closed validation run and wrong for a shared
> fabric. For anything beyond a test, drop `-a` and allow specific host NQNs
> with `nvmf_subsystem_add_host`, or put the storage traffic on its own
> isolated VLAN or traffic class.

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

Check the master log for `adrfam:IPv6` in the segment descriptors, and the
counter reaching your pool size.

On IPv6 fabrics this needs
[`mooncake-ipv6-adrfam.patch`](./mooncake-ipv6-adrfam.patch); upstream
hardcodes `adrfam:IPv4`.

### 6. Measure

```bash
spdk_nvme_perf \
  -r "trtype:RDMA adrfam:IPv6 traddr:<target-ionic-ipv6> trsvcid:4420 subnqn:nqn.2016-06.io.spdk:cnode0" \
  ... (one -r per namespace) \
  -c 0xF0 -q 64 -o 131072 -w read -t 30
```

Use `spdk_nvme_perf`, not fio — fio does not drive the SPDK path and queue
depth will not scale. Give the initiator a core mask **disjoint** from the
target's.

### 7. Prove the Mooncake path

`spdk_nvme_perf` bypasses Mooncake entirely, so it proves the plumbing and
nothing more. To exercise the tier itself:

```python
from mooncake.store import MooncakeDistributedStore, ReplicateConfig

cfg = ReplicateConfig()
cfg.nof_replica_num = 1     # default is 0 — without this it never reaches NVMe
store.put(key, data, cfg)
```

Then `get(key)` from a second node pointed at the first node's metadata and
master, and compare checksums.

### 8. Clean up

Unbind the drives, set `enable_unsafe_noiommu_mode` back to `0`, and remove
`/dev/vfio/0`. See `../nvme-spdk-binding-test/cleanup-spdk-nvmeof.sh`.

---

## Known issues found during this work

Both are upstream, both are reproducible, neither is documented elsewhere.

**Mooncake hardcodes `adrfam:IPv4`.** In `mooncake-store/src/ssd_register_client.cpp`,
both `set_register()` and `set_unregister_by_endpoint()` build the endpoint
string with a literal `adrfam:IPv4`, while the adjacent `trtype` is
configurable. Present in `v0.3.12.post1` and `main`. Breaks any IPv6 RoCE
fabric. Patch included.

**SPDK does not normalise IPv6 in listener matching.**
`spdk_nvme_transport_id_compare()` uses `strcasecmp()` on `traddr`, while
incoming connections carry whatever `inet_ntop()` produced (compressed, per RFC
5952). A listener registered zero-padded is unreachable, and the rejection
message points at host access control rather than address formatting.

---

## Files

| | |
|---|---|
| `Dockerfile.mooncake-nof-mi355x` | ROCm 7.14 + SPDK + Mooncake `USE_NOF` |
| `BUILD.md` | build and registry push |
| `ionic-provider/` | `ionic.driver` stub. The two `.so` files are **not** in this repo — copy them off a running MI355X node, see Prerequisites |
| `kaniko-build-mooncake-nof.yaml` | in-cluster build |
| `mooncake-nvmeof-{target,initiator}-pod.yaml` | validation pods |
| `mooncake-ipv6-adrfam.patch` | IPv6 address-family fix |
| `ibv-devinfo-ionic0.txt` | Pollara VF capabilities (QP/MR/CQ limits) |
| `TROUBLESHOOTING.md` | four failures that each cost days |
| `RESULTS.md` | measurements and conditions |

## Related

- [`../nvme-spdk-binding-test/`](../nvme-spdk-binding-test/) — SPDK NVMe-oF
  over RoCE without Mooncake. Useful on its own, and the right place to start
  when something here fails: if the SPDK layer works standalone, the problem
  is above it. The cleanup script lives there too.
- [Mooncake](https://github.com/kvcache-ai/Mooncake) · [SPDK](https://spdk.io)
