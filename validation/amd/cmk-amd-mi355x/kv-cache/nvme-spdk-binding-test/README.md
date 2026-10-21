# SPDK NVMe-oF over RoCE on AMD MI355X

Take control of a node's local NVMe drives from userspace with SPDK, and serve
them to other nodes over the Pollara RDMA fabric as NVMe-over-Fabrics targets.

Three progressive tests, each useful on its own:

| | What it proves | Time |
|---|---|---|
| **1. Device binding** | SPDK can claim NVMe drives via `vfio-pci` and hand them back | ~2 min |
| **2. NVMe-oF over RDMA** | A real drive served over the ionic fabric, single node | ~12 min |
| **3. Two-node performance** | RDMA throughput against a local PCIe baseline | ~30 min |

This is the layer underneath
[`../mooncake-nvmeof/`](../mooncake-nvmeof/). If something there misbehaves,
start here: if SPDK works standalone, the problem is above it.

---

## Why bother

MI355X nodes ship with 8 local NVMe drives (Micron 7500 PRO, 3.5 TB each,
PCIe Gen4, 28 TB raw). SPDK drives them from userspace with a poll-mode
driver, bypassing the kernel block layer entirely — no syscalls, no
interrupts. That is what storage-heavy systems like Ceph, MinIO and
distributed databases use to reach line rate.

These tests establish that the pattern works on this hardware, which is the
prerequisite for anything built on it.

---

## Results

Measured on a 2-node MI355X cluster, Bundle 2.2, kernel
`6.8.12-322.crusoe.amd64`.

### Binding (test 1)

```
single device     nvme -> vfio-pci -> nvme        clean round trip
three devices     bound and reset together        clean
mounted drives    skipped automatically           see Safety below
node state        fully restored after reset
```

### Two-node performance (test 3)

One drive served over RDMA, compared against the same drive locally:

| Transport | Block | QD | IOPS | MiB/s | Avg latency |
|---|---|---|---|---|---|
| PCIe | 4K | 1 | 293,530 | 1,146 | 6.80 µs |
| PCIe | 4K | 32 | 1,281,797 | 5,007 | 49.92 µs |
| PCIe | 128K | 32 | 53,383 | 6,672 | 1,198 µs |
| RDMA | 4K | 1 | 60,215 | 235 | 33.21 µs |
| RDMA | 4K | 32 | 1,296,974 | 5,066 | 49.34 µs |
| RDMA | 128K | 32 | 53,346 | 6,668 | 1,199 µs |

**At queue depth, RDMA matches local PCIe.** 128K QD32 lands within 0.1% of
the local baseline, and 4K QD32 is marginally ahead. The fabric is not the
constraint; the drive is.

The cost shows up at QD1, where RDMA adds **26 µs** over local access. That is
the round trip, and it is the number to care about for latency-sensitive
single-threaded work.

> **A correction worth knowing.** Earlier runs of this suite reported a fabric
> ceiling of 136 Gb/s and concluded RDMA was using 39% of it. That 136 Gb/s
> was a **single-queue-pair** measurement. With 8 QPs the same fabric delivers
> **380.72 Gb/s (47.6 GB/s)** at 10.34 µs. Any single-QP fabric number on this
> hardware understates it by roughly 2.8x.
>
> The conclusion above is unaffected — a single drive tops out near 53 Gb/s
> either way, so the drive is the limit — but utilisation percentages computed
> against 136 Gb/s are wrong.

---

## Prerequisites

- A CMK cluster with an MI355X nodepool, 2 `Ready` nodes for test 3
- `kubectl` and cluster-admin on it
- The **ionic userspace RDMA provider** for tests 2 and 3. Stock images cannot
  see the Pollara NICs without it. The scripts install it in-container; see
  [`../mooncake-nvmeof/README.md`](../mooncake-nvmeof/README.md#the-ionic-rdma-provider)
  for where the three files come from.

The pods run `privileged: true` with `hostNetwork`, `hostPID` and
`SYS_MODULE`/`SYS_RAWIO`/`SYS_ADMIN`/`IPC_LOCK`. That is what userspace NVMe
requires. Review it before running on anything shared.

---

## Safety

**SPDK protects mounted drives itself.** `setup.sh` detects active mounts and
refuses to bind those devices. You will see it skip them:

```
0002:00:08.0 (1344 51b7): Active devices: mount@nvme7n1:nvme7n1, so not binding PCI dev
0000:00:01.0 (1af4 1042): Active devices: mount@vda:vda1,..., so not binding PCI dev
```

That is correct behaviour, not an error. **Do not override it.** The first is
the node's OS/container drive, the second its boot disk.

Two further layers: `PCI_ALLOWED` restricts `setup.sh` to an explicit device
list, and the OS drive is never placed in that list.

> Which drive holds the OS **varies by node**. On the nodes used here it was
> `0002:00:08.0` mounted at `/mnt/nvme`, but neither the BDF nor the mount
> point is fixed. Never hardcode the list from another node's output — let
> `setup.sh` detect mounts, or enumerate first.

---

## Running the tests

All three scripts live in [`src/`](./src/).

### Test 1 — device binding

```bash
kubectl apply -f src/spdk-test-pod.yaml      # edit nodeName first
./src/run-spdk-binding-test.sh
```

Binds one device, verifies it leaves `/sys/block/`, resets it, confirms it
comes back. Then repeats with three devices at once.

### Test 2 — NVMe-oF over RDMA, single node

```bash
kubectl apply -f src/spdk-nvmeof-pod.yaml    # edit nodeName first
./src/run-spdk-nvmeof-rdma-test.sh
```

Builds SPDK, allocates hugepages, binds a drive, starts `nvmf_tgt`, creates an
RDMA transport and serves the drive as an NVMe-oF subsystem. Ten steps, each
reporting pass or fail.

### Test 3 — two-node performance

```bash
./src/run-nvmeof-performance-validation.sh <kubeconfig> <target-node> <initiator-node>
```

Deploys to both nodes, measures the fabric with `ib_write_bw` and
`ib_write_lat`, takes a local PCIe baseline, then the same workload over RDMA,
and writes a comparison report.

**Pass criteria:**

```
fabric bandwidth    >= 100 Gb/s          (use 8 QPs, see the correction above)
fabric latency      < 15 µs
QD scaling          QD32/QD1 >= 3x, both transports
RDMA 4K QD32        >= 90% of PCIe baseline
RDMA 128K           >= 95% of PCIe baseline
RDMA latency        < 50 µs at 4K QD1
```

### Cleanup

```bash
./src/cleanup-spdk-nvmeof.sh
```

**Not optional on a shared cluster.** It resets drives to the kernel driver,
disables no-IOMMU mode and removes the vfio device nodes.

If drives will not rebind to `nvme` afterwards, the device's `driver_override`
is still set to `vfio-pci`. Clear it and re-probe:

```bash
echo        > /sys/bus/pci/devices/$BDF/driver_override
echo "$BDF" > /sys/bus/pci/drivers_probe
```

---

## Why it works this way

Four decisions that look odd until you know the reason.

**Both hugepage cgroup limits, not one.** cgroup v2 needs
`hugetlb.2MB.max` *and* `hugetlb.2MB.rsvd.max`. The second gates
`mmap(MAP_POPULATE)`, which is what DPDK uses. Miss it and DPDK fails with
`ENOMEM` and no other diagnostic.

**vfio-pci in no-IOMMU mode.** These VMs run `iommu=pt` with no visible IOMMU
groups, which is normal for virtualised environments. SPDK needs `vfio-pci`
for userspace NVMe, so `enable_unsafe_noiommu_mode=1` is required. "Unsafe"
means reduced device isolation; it is standard practice for SPDK in VMs and it
taints the kernel while enabled.

**GID index 1.** The RDMA data plane uses index 1, the routable global IPv6
address, because it is the one present on every node:

```
index 0    fe80::...            link-local IPv6
index 1    fc01:800:...         global IPv6     <- used for RDMA
index 2    ::ffff:192.168...    IPv4-mapped, present on SOME nodes only
index 3+   all zeros
```

The IPv4-mapped address at index 2 is **not reliable**. A two-node capture
found it on one node and not the other. Do not build on it.

**Two different addresses for one test.** `ib_write_bw` negotiates parameters
over TCP before doing RDMA, so the control plane uses the node's regular IPv4
management interface while the data plane uses the ionic IPv6. They are not
the same address and that is expected.

**Rail isolation.** Each of the 8 ionic devices is a separate physical path.
`ionic_0` on node A reaches `ionic_0` on node B and nothing else. Use the same
index on both ends.

---

## Troubleshooting

**`Operation not permitted` loading modules.** The pod lacks `CAP_SYS_MODULE`.
Use the provided manifests, which set `privileged: true`.

**`No IOMMU groups found`.** Expected in a VM. Enable no-IOMMU mode as above.

**SPDK refuses to bind, reports `Active devices`.** Correct behaviour — the
drive is mounted. See [Safety](#safety). Do not override.

**Hugepage mmap fails.** Check *both* cgroup limits, at every level of the
hierarchy rather than just the container's own. The pod-level cgroup commonly
holds `0` when the pod requests no hugepage resources.

**No ionic devices in `ibv_devinfo`.** The userspace provider is missing. It
is not in stock images.

**DPDK will not initialise.** Usually hugepages. Note that `--no-huge` cannot
be used as a workaround: no-IOMMU forces IOVA=PA, which requires hugepages,
and real PCIe devices refuse to attach under IOVA=VA.

**`Failed to modify QP to RTR`.** Usually a GID index mismatch between the two
ends, or crossed rails. Confirm both sides use index 1 and the same `ionic_N`.

**Very low RDMA throughput, under ~10% of PCIe.** Check that the target and
the benchmark are not pinned to the same cores. Overlapping core masks produce
latency that looks like a fabric problem and is not.

**Node unreachable after a test.** The OS drive was bound. Recover by resetting
drives to the kernel driver from a host-namespace debug pod.

---

## Known limitations

**No IOMMU groups.** Must run `enable_unsafe_noiommu_mode=1`, which taints the
kernel. Low risk and standard for VMs, but worth stating explicitly for anyone
evaluating this for production. SPDK's userspace isolation still provides
process-level separation.

**Hugepages are not pre-allocated.** `HugePages_Total` is 0 by default, so
SPDK must allocate at runtime. For production, reserve them on the kernel
command line before kubelet starts, otherwise Kubernetes never sees them as
schedulable capacity.

**Privileged pods.** Root access to the host, in exchange for userspace NVMe.
Use only with appropriate RBAC.

---

## Files

```
README.md                              this guide
RESULTS.md                             detailed per-test evidence
src/
  run-spdk-binding-test.sh             test 1
  run-spdk-nvmeof-rdma-test.sh         test 2
  run-nvmeof-performance-validation.sh test 3
  cleanup-spdk-nvmeof.sh               reset the node
  spdk-test-pod.yaml                   pod for test 1
  spdk-nvmeof-pod.yaml                 pod for tests 2 and 3
```

## Related

- [`../mooncake-nvmeof/`](../mooncake-nvmeof/) — Mooncake KV cache tier built
  on this foundation, pooling drives across nodes
- [SPDK](https://spdk.io) · [NVMe-oF spec](https://nvmexpress.org/specifications/)
