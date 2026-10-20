# Validation results

Measurements from a two-node MI355X validation cluster. Build and runbook are in
[README.md](./README.md); the failures encountered along the way are in
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md).

```
Platform     Crusoe Managed Kubernetes, MI355X nodepool, 2 nodes
Kernel       6.8.12-322.crusoe.amd64
GPU          8x AMD Instinct MI355X (gfx950)
NIC          8x AMD Pensando Pollara 400, RoCEv2, rail-isolated
NVMe         8 local drives per node, 7 usable (one holds containerd)
ROCm         7.14.1
Mooncake     v0.3.12.post1, USE_NOF=ON USE_HIP=ON USE_HIP_DMABUF=ON USE_CUDA=OFF
SPDK         version pinned by the Mooncake submodule
```

---

## 1. Fabric baseline

`ib_write_bw` between `ionic_0` on each node, GID index 1, 1 MB messages.

| Queue pairs | Bandwidth | |
|---|---|---|
| 1 | 136 Gb/s | measurement artifact, not a fabric limit |
| **8** | **380.72 Gb/s (47.6 GB/s)** | |

Latency: **10.34 µs** average, 9.93 min, 13.31 max.

Single-QP measurements understate this fabric by about 2.8x. Use at least 8.

---

## 2. Build

Mooncake v0.3.12.post1 builds on ROCm with `-DUSE_NOF=ON -DUSE_HIP=ON`, no
source changes beyond the IPv6 address-family patch below.

Confirmed in the CMake output:

```
HIP support is enabled
mooncake_store: HIP detected, enabling D2H staging
HIP dmabuf MR registration enabled
```

Link check on `mooncake_client`: `libamdhip64` present, `libcudart` absent.

`mooncake_master` legitimately links neither — it is the control plane and does
no GPU work. Checking the master rather than the client produces a false
negative.

---

## 3. Registration

7 NVMe-oF namespaces registered with `mooncake_master`.

```
NVMe-oF SSD: 0 B / 24.45 TB (0.0%)
```

Segment descriptors in the master log, all seven:

```
NoF segment mount: segment_name=traddr:<addr> trsvcid:4420
  subnqn:nqn.2016-06.io.spdk:cnode0 trtype:RDMA adrfam:IPv6 ns:1
```

`adrfam:IPv6` confirms the patch is active. Upstream writes `IPv4` here
unconditionally.

---

## 4. SPDK data plane, cross-node

Target `-m 0xF` (cores 0-3), initiator `-c 0xF0` (cores 4-7), 7 namespaces,
30-second runs.

### 128 KB blocks

| Queue depth | IOPS | Throughput | Avg latency |
|---|---|---|---|
| 32 | 336,724 | 42.09 GB/s | 665 µs |
| **64** | 338,880 | **42.36 GB/s** | 1,321 µs |
| 128 | 338,012 | 42.25 GB/s | 2,650 µs |

### 1 MB blocks

| Queue depth | IOPS | Throughput | Avg latency |
|---|---|---|---|
| 128 | 38,898 | 38.90 GB/s | 23,043 µs |

### Cross-node vs loopback, 128 KB, QD=32

| | Throughput | Latency |
|---|---|---|
| Cross-node | **42.09 GB/s** | 665 µs |
| Loopback | 36.32 GB/s | 771 µs |

Cross-node is 16% faster. Loopback drives both directions through one NIC and
contends for cores on a single host, so it is the harder case rather than the
easier one.

### Headroom

```
7 drives, theoretical    ~47 GB/s   (6.7 GB/s each)
fabric, 8 QP              47.6 GB/s
measured                  42.36 GB/s   ~90% of both
```

### Block size matters more than anything else

An early run at 4 KB produced 12.1 GB/s at 3.1M IOPS and 292 µs latency. That
is IOPS-bound, not bandwidth-bound, and it is a measurement of the test
configuration rather than the hardware. Use 128 KB or larger for throughput
figures.

Two other configuration traps, both of which produce misleading numbers:

- **fio does not drive the SPDK path.** Queue depth will not scale: an early fio
  run gave 87,752 IOPS at QD=1 against 89,973 at QD=32. Use `spdk_nvme_perf`.
- **Target and initiator must use disjoint core masks.** Both on `0x3` produced
  9 ms latency from scheduler thrashing, which reads as a fabric problem and is
  not one.

---

## 5. Mooncake data plane, cross-node

A 10 MB random blob written on one node and read on the other.

```
put node        node A
get node        node B
blob            10 MB
put SHA256      de7a723f...6b806a
get SHA256      de7a723f...6b806a      match
```

Master metrics after the put:

```
NVMe-oF SSD: 10.00 MB / 24.45 TB (0.0%)
Keys: 1 (soft-pinned: 0)
Requests: Get=0.10/0.10 (100% success)
```

The **used** side of the counter moving is what proves the data reached the NVMe
tier rather than staying in DRAM. SPDK confirms the attachment:

```
spdk_wrapper.cpp:290] Attaching to <addr> nqn.2016-06.io.spdk:cnode1
spdk_wrapper.cpp:297] Attached to <addr> nqn.2016-06.io.spdk:cnode1
```

This required `ReplicateConfig.nof_replica_num = 1`. The default of `0` is
memory-only and a put succeeds without ever touching NVMe. See
[TROUBLESHOOTING.md §3](./TROUBLESHOOTING.md#3-mooncake-put-succeeds-but-nothing-reaches-nvme).

**Scope:** this is a correctness test, not a performance one. 10 MB proves the
path works end to end. Throughput through the Mooncake path was not measured and
would be lower than the SPDK figure above, since it goes through D2H staging and
the transfer engine.

---

## 6. Pollara VF capabilities

From `ibv_devinfo -v -d ionic_0`, full output in
[`ibv-devinfo-ionic0.txt`](./ibv-devinfo-ionic0.txt).

| | |
|---|---|
| `max_qp` | 4096 |
| `max_qp_wr` | 65535 |
| `max_srq` | 256 |
| `max_mr` | 16383 |
| `max_mr_size` | 0xffffffffffffffff |
| `max_cqe` | 65435 |
| `max_sge` | 8 |

`max_qp` is worth sizing against before committing to an all-to-all topology. If
each peer opens *n* queue pairs, a pool of *N* nodes needs roughly `(N-1) x n`
inbound QPs per VF, plus whatever the initiator side consumes on the same
device.

### Address families

```
GID 0        link-local IPv6, RoCE v2
GID 1        global IPv6, RoCE v2
GID 2-255    all zeros
```

**No IPv4 GID at any index.** This fabric is IPv6-only, which is what makes both
upstream issues below matter here.

---

## 7. Upstream issues

Both reproducible, both affecting any IPv6 RoCE fabric.

### Mooncake hardcodes `adrfam:IPv4`

`mooncake-store/src/ssd_register_client.cpp`, in both `set_register()` and
`set_unregister_by_endpoint()`:

```cpp
std::string te_endpoint = "traddr:" + traddr +
                          " trsvcid:" + std::to_string(trsvcid) +
                          " subnqn:" + nqn + " trtype:" + trtype +
                          " adrfam:IPv4 ns:" + std::to_string(nsid);
```

Present in `v0.3.12.post1` and in `main`. The adjacent `trtype` is configurable
through `NoFRegisterConfig`, which suggests the address family was an oversight
rather than a decision.

The string feeds `spdk_nvme_transport_id_parse()` and then `spdk_nvme_probe()`,
so it is functional rather than cosmetic.

Both functions must be patched together: `set_unregister_by_endpoint()` rebuilds
the identical string and matches on it exactly, so patching only the register
side leaves segments unremovable.

Fix: [`mooncake-ipv6-adrfam.patch`](./mooncake-ipv6-adrfam.patch).

### SPDK does not normalise IPv6 in listener matching

`spdk_nvme_transport_id_compare()` compares `traddr` with `strcasecmp()`.
Incoming connections carry whatever `inet_ntop()` produced, which is compressed
form per RFC 5952. A listener registered in zero-padded form never matches:

```
registered    fc01:0800:800b:...:0690:...     zero-padded
incoming      fc01:800:800b:...:690:...       compressed
```

Every connection is rejected, and the error message points at host access
control rather than address formatting, which makes it hard to find. Detail in
[TROUBLESHOOTING.md §2](./TROUBLESHOOTING.md#2-all-connections-rejected-with-does-not-allow-host--at-this-address).

---

## Summary

| | Result |
|---|---|
| Mooncake builds with `USE_NOF` on ROCm | yes, no source changes beyond the IPv6 patch |
| Pool registers over IPv6 | yes, 24.45 TB across 7 namespaces |
| Cross-node SPDK throughput | 42.36 GB/s |
| Cross-node Mooncake put/get | byte-identical |
| Requires patched Mooncake on IPv6 fabrics | yes |
| Requires compressed IPv6 in SPDK listeners | yes |
