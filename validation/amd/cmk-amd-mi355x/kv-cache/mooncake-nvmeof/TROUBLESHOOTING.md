# Troubleshooting

Four failures encountered building this. Each took a day or more to find, each
has a misleading symptom, and none of them is documented anywhere else we could
find.

---

## 1. DPDK cannot allocate hugepages

**Symptom**

```
alloc_seg(): mmap() failed: Cannot allocate memory
EAL: attempted to allocate 1024 segments, but only 0 were allocated
EAL: FATAL: Cannot init memory
```

or, earlier in EAL init:

```
eal_memalloc_alloc_seg_bulk(): couldn't find suitable memseg_list
EAL: error allocating rte services array
EAL: FATAL: rte_service_init() failed
```

All three are the same underlying problem at different stages.

**What makes it confusing**

Everything looks correct:

```
HugePages_Total:  8192
HugePages_Free:   8192
hugetlb.2MB.max:       max      ← on the container's own cgroup
hugetlb.2MB.rsvd.max:  max
hugetlbfs mounted at /mnt/ht
```

**Cause**

In cgroup v2 the effective hugetlb limit is the **minimum along the entire path
from root to leaf**. Kubernetes sets the pod-level cgroup limit from the pod's
`hugepages-2Mi` resource request. When kubelet reports `hugepages-2Mi: 0`
capacity, you cannot request any, so the pod cgroup gets:

```
/sys/fs/cgroup/kubepods/burstable/pod<UUID>/hugetlb.2MB.max      = 0
/sys/fs/cgroup/kubepods/burstable/pod<UUID>/hugetlb.2MB.rsvd.max = 0
```

Setting the leaf to `max` changes nothing while an ancestor holds `0`.

**Diagnosis** — walk the tree and print every level:

```bash
CG=$(awk -F: '{print $3}' /proc/self/cgroup | head -1)
P="/sys/fs/cgroup${CG}"
while [ "$P" != "/sys/fs/cgroup" ] && [ "$P" != "/" ]; do
  echo "$P  max=$(cat $P/hugetlb.2MB.max 2>/dev/null)" \
       " rsvd=$(cat $P/hugetlb.2MB.rsvd.max 2>/dev/null)"
  P=$(dirname "$P")
done
```

**Fix** — set both limits at every level:

```bash
echo 8192 > /proc/sys/vm/nr_hugepages
CG=$(awk -F: '{print $3}' /proc/self/cgroup | head -1)
P="/sys/fs/cgroup${CG}"
while [ "$P" != "/sys/fs/cgroup" ]; do
  if [ -f "$P/hugetlb.2MB.max" ]; then
    echo max > "$P/hugetlb.2MB.max"
    echo max > "$P/hugetlb.2MB.rsvd.max"
  fi
  P=$(dirname "$P")
done
mkdir -p /mnt/ht && mount -t hugetlbfs -o pagesize=2M nodev /mnt/ht
```

**`rsvd.max` is a separate limit and it is the one that bites.** It gates
`mmap(MAP_POPULATE)`, which is what DPDK uses. Missing it gives `ENOMEM` from
`mmap()` with no other diagnostic.

**Verify with mmap, not `dd`:**

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
says nothing about your problem.

### Do not reach for `--no-huge`

It looks like the obvious escape and it cannot work here:

```
no IOMMU  →  IOVA=PA required  →  hugepages mandatory
--no-huge →  forces IOVA=VA
            "Expecting 'PA' IOVA mode but current mode is 'VA'"
```

`nvmf_tgt` starts, then real PCIe devices refuse to attach. That looks like
progress and is not.

---

## 2. All connections rejected with "does not allow host ... at this address"

**Symptom**

```
ctrlr.c:739:nvmf_qpair_access_allowed: *ERROR*: Subsystem
'nqn.2016-06.io.spdk:cnode0' does not allow host
'nqn.2014-08.org.nvmexpress:uuid:...' to connect at this address.
```

Connections reach the target and are logged. `allow_any_host` is `true`. The
host list is empty. Loopback fails identically to cross-node.

**What makes it confusing**

The message names the host NQN, so it reads as host access control. It is not.
`nvmf_qpair_access_allowed()` has two checks with different messages:

```c
spdk_nvmf_subsystem_host_allowed()      -> "does not allow host '%s'"
spdk_nvmf_subsystem_listener_allowed()  -> "... to connect AT THIS ADDRESS."
```

The trailing **"at this address"** is the *listener* check. The host check
already passed. What failed is matching the connection's transport ID against
the subsystem's registered listeners.

**Cause**

`spdk_nvme_transport_id_compare()` compares `traddr` with `strcasecmp()`. It
does **not** normalise IPv6. Incoming connections carry whatever `inet_ntop()`
produced, which is compressed form per RFC 5952:

```
registered    fd00:0801:0002:0003:0690:81ff:fe40:0001    zero-padded
incoming      fd00:801:2:3:690:81ff:fe40:1               compressed
                   ^^^^ ^^^^ ^^^^ ^^^^
```

Never matches. Every connection rejected.

**Fix** — re-register using the exact string the system reports:

```bash
spdk-rpc nvmf_subsystem_get_listeners nqn.2016-06.io.spdk:cnode0   # what SPDK holds
ip -6 addr show <rdma-netdev> | grep inet6                          # what it should be

spdk-rpc nvmf_subsystem_remove_listener nqn.2016-06.io.spdk:cnode0 \
    -t rdma -f ipv6 -a <padded-form> -s 4420
spdk-rpc nvmf_subsystem_add_listener nqn.2016-06.io.spdk:cnode0 \
    -t rdma -f ipv6 -a <compressed-form> -s 4420
```

Compare the two strings character by character. The difference is easy to miss
by eye.

### Related: `getaddrinfo` fails before you get this far

```
getaddrinfo failed: Address family for hostname not supported (-9)
```

That is `EAI_ADDRFAMILY`: the address does not match the family in the hints.
You passed an IPv6 address without `-f ipv6`, so SPDK resolved it as IPv4.
Varying the *address* will not help; the *family* is the wrong parameter.

```bash
spdk-rpc nvmf_subsystem_add_listener <nqn> -t rdma -f ipv6 -a <addr> -s 4420
#                                                   ^^^^^^^^
```

---

## 3. Mooncake put() succeeds but nothing reaches NVMe

**Symptom**

`store.put()` returns `0`. No errors anywhere. The master's
`NVMe-oF SSD: 0 B / <pool size>` counter never moves.

**Cause**

`ReplicateConfig.nof_replica_num` defaults to **0**, meaning memory-only. A put
without it goes to DRAM and never touches the NVMe tier.

**Fix**

```python
from mooncake.store import ReplicateConfig

cfg = ReplicateConfig()
cfg.nof_replica_num = 1       # REQUIRED — default 0 means no NoF storage
store.put(key, data, cfg)
```

**Verify** by watching the used counter, not the return code:

```
NVMe-oF SSD: 10.00 MB / 24.45 TB     # used side moved -> data is on NVMe
```

And in the SPDK wrapper log:

```
spdk_wrapper.cpp:290] Attaching to <addr> nqn.2016-06.io.spdk:cnode1
```

This is the quietest failure of the four. Everything reports success and the
tier you built is simply unused.

---

## 4. `ibv_devinfo` shows no ionic devices

**Symptom**

`ibv_devinfo` lists `mlx5_0` but no `ionic_*`. Or `rdma_bind_addr()` fails on an
address that `ip -6 addr` clearly shows on the interface.

**Cause**

The Pollara NICs need a userspace RDMA provider that stock images do not carry.
Without it, libibverbs cannot enumerate them at all.

**Fix** — three files, copied from any running MI355X node:

```
/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so
/usr/lib/x86_64-linux-gnu/libionic.so.1
/etc/libibverbs.d/ionic.driver
```

Bake them into the image rather than copying into running pods, or you will do
it again after every restart. Provider ABI is rdma-core **v34**.

### Related: `rdma_bind_addr()` failed

If the provider is present and bind still fails, check `hostNetwork`.
`rdma_bind_addr()` binds a **local** address; without `hostNetwork: true` the
pod has its own network namespace where the RDMA interface does not exist. The
failure is an existence error, not a permissions error.

---

## Quick reference

| Symptom | Cause | Section |
|---|---|---|
| `mmap() failed: Cannot allocate memory` | cgroup ancestor holds `hugetlb.2MB.max=0` | [1](#1-dpdk-cannot-allocate-hugepages) |
| `couldn't find suitable memseg_list` | same | [1](#1-dpdk-cannot-allocate-hugepages) |
| `rte_service_init() failed` | same | [1](#1-dpdk-cannot-allocate-hugepages) |
| `Expecting 'PA' IOVA mode` | `--no-huge` under no-IOMMU | [1](#do-not-reach-for---no-huge) |
| `does not allow host ... at this address` | listener traddr string mismatch | [2](#2-all-connections-rejected-with-does-not-allow-host--at-this-address) |
| `getaddrinfo failed ... (-9)` | missing `-f ipv6` | [2](#related-getaddrinfo-fails-before-you-get-this-far) |
| `put()` returns 0, counter stays at 0 B | `nof_replica_num` defaults to 0 | [3](#3-mooncake-put-succeeds-but-nothing-reaches-nvme) |
| No `ionic_*` in `ibv_devinfo` | missing ionic provider | [4](#4-ibv_devinfo-shows-no-ionic-devices) |
| `rdma_bind_addr() failed` | missing provider, or no `hostNetwork` | [4](#related-rdma_bind_addr-failed) |
| `Cannot find device <BDF>` | `/dev/vfio/<group>` not created in no-IOMMU mode | [README](./README.md#3-bind-drives) |
