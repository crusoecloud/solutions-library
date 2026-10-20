# SPDK NVMe-oF RDMA Performance Validation

Comprehensive two-node end-to-end performance test for SPDK NVMe-oF over RDMA fabric on AMD MI355X nodes.

## Overview

This test validates that SPDK NVMe-oF can deliver line-rate performance over AMD Pensando ionic RDMA NICs, matching or exceeding local PCIe performance when serving NVMe devices to remote clients.

**What it measures:**
- Fabric control plane (ib_write_bw, ib_write_lat) - establishes performance ceiling
- PCIe baseline (local device performance without networking)
- RDMA performance (NVMe-oF serving the same device over fabric)
- QD scaling, latency overhead, fabric utilization

**Test duration:** ~25-30 minutes (includes SPDK builds on both nodes)

## Test Architecture

```
TARGET NODE (<target-node>)              INITIATOR NODE (<initiator-node>)
┌────────────────────────────────┐        ┌────────────────────────────────┐
│                                │        │                                │
│  nvmf_tgt (SPDK target)        │        │  spdk_nvme_perf (client)       │
│  └─ NVMe 0003:00:05.0          │        │  └─ connects to target         │
│     (bound to vfio-pci)        │        │                                │
│                                │        │                                │
│  Listener:                     │        │  Initiator:                    │
│  fc01:800:800b:9571:...:9cb1   │◄──────►│  fc01:800:200b:9566:...:3011   │
│  Port 4420                     │  RDMA  │  GID index 1                   │
│  GID index 1                   │  ionic │                                │
│                                │   _0   │                                │
└────────────────────────────────┘        └────────────────────────────────┘
```

## Prerequisites

- CMK cluster with 2+ MI355X nodes (bundle 2.2+)
- kubeconfig with cluster-admin permissions
- Both nodes in `Ready` state, no customer workloads
- Nodes must have:
  - Kernel 6.8.12-322.crusoe or later
  - 8× ionic RDMA NICs
  - 8× NVMe devices (Micron 7500 PRO)

## Usage

```bash
./run-nvmeof-performance-validation.sh <kubeconfig> <target-node> <initiator-node>
```

**Example:**
```bash
./run-nvmeof-performance-validation.sh \
  ~/.kube/validation-cluster-config \
  <target-node> \
  <initiator-node>
```

## What the Script Does

### STEP 1: Deploy Test Pods (30s)
- Creates privileged pods on both nodes with:
  - `hostNetwork: true` (access to host network interfaces)
  - Hugepage mounts (`/dev/hugepages`)
  - Infiniband devices (`/dev/infiniband`)
  - VFIO access (`/dev/vfio`)
  - Access to containerd storage (`/hostnvme`)

### STEP 2: Environment Setup (2-3 min)
- Installs packages: `build-essential`, `libibverbs-dev`, `libfuse3-dev`, `perftest`, etc.
- Configures hugepages:
  - Sets `hugetlb.2MB.max` and `hugetlb.2MB.rsvd.max` to `max`
  - Allocates 4096×2MB hugepages
  - Mounts hugetlbfs at `/mnt/ht`
- Installs AMD Pensando ionic RDMA provider:
  - Copies libraries from containerd snapshots
  - Creates symlinks and runs `ldconfig`
  - Verifies 8 ionic devices detected

### STEP 3: Rail Mapping (5s)
- Discovers IPv6 addresses on `ionic_0` (enP2p0s9)
- Records GID indices for RDMA connections
- Validates same rail index on both nodes (rail-optimized fabric)

### STEP 4: SPDK Setup (10-15 min for builds)
- Checks for existing SPDK builds
- Clones SPDK from GitHub if needed
- Runs `scripts/pkgdep.sh` to install dependencies
- Configures with `./configure --with-rdma`
- Builds with `make -j$(nproc)`
- Verifies binaries: `nvmf_tgt`, `spdk_nvme_perf`

### STEP 5: PCIe Baseline (40s)
- Loads `vfio-pci` module, enables noiommu mode
- Unbinds `0003:00:05.0` from kernel `nvme` driver
- Binds to `vfio-pci` for userspace access
- Runs 4 performance tests:
  1. **4K QD1** (latency floor) - measures minimum achievable latency
  2. **4K QD32** (small-block IOPS) - measures random read throughput
  3. **128K QD32** (bandwidth) - measures sequential read bandwidth
  4. **128K QD128** (saturation) - validates no additional scaling

### STEP 6: Start NVMe-oF Target (10s)
- Starts `nvmf_tgt` with DPDK hugepage support
- Creates RDMA transport (discovers all 8 ionic devices)
- Attaches NVMe device via PCIe
- Creates NVMe-oF subsystem `nqn.2026-10.com.crusoe:test`
- Adds namespace `nvme0n1`
- Adds listener on target IPv6 address, port 4420

### STEP 7: Fabric Control (20s)
- Runs `ib_write_bw` to measure fabric bandwidth ceiling
  - Expected: 100-150 Gb/sec
- Runs `ib_write_lat` to measure fabric latency floor
  - Expected: <15 µs
- **If results are poor, test stops** (no point measuring NVMe-oF on broken fabric)

### STEP 8: RDMA Performance Tests (40s)
- Connects from initiator to target via IPv6 RDMA
- Runs same 4 tests as PCIe baseline:
  1. **4K QD1** - should be ~5x higher latency than PCIe (fabric floor)
  2. **4K QD32** - should match or exceed PCIe IOPS
  3. **128K QD32** - should match PCIe bandwidth (line-rate)
  4. **128K QD128** - should match PCIe bandwidth (saturation)

### STEP 9: Generate Report
- Parses all test results
- Calculates:
  - QD scaling ratios (sanity checks)
  - RDMA vs PCIe efficiency
  - Fabric utilization percentage
  - Added latency (RDMA - PCIe)
- Displays comprehensive performance table

## Expected Results

### Successful Test Output

```
================================================================================
SPDK NVMe-oF RDMA Performance Validation Report
================================================================================

Fabric Control (Ceiling):
  Bandwidth:  136.09 Gb/sec
  Latency:    10.39us average

Performance Results:
================================================================================
Transport  Block   QD    IOPS        MiB/s    Avg Lat(us)  Max Lat(us)
--------------------------------------------------------------------------------
PCIe       4K      1     293530      1146.60  6.80         24.26
PCIe       4K      32    1281797     5007.02  49.92        259.34
PCIe       128K    32    53383       6672.90  1198.87      3020.59
PCIe       128K    128   53295       6661.88  4797.77      9803.24
RDMA       4K      1     60215       235.21   33.21        212.54
RDMA       4K      32    1296974     5066.31  49.34        302.27
RDMA       128K    32    53346       6668.29  1199.32      8761.81
RDMA       128K    128   53239       6654.86  4824.20      74791.48
================================================================================

Analysis:

QD Scaling (Sanity Checks):
  PCIe 4K:  QD32/QD1 = 4.4x  ✓
  RDMA 4K:  QD32/QD1 = 21.5x ✓

RDMA Efficiency:
  RDMA 128K QD32: 6668.29 MiB/s = 53.3 Gb/sec
  Fabric ceiling: 136.09 Gb/sec
  Utilization:    39.2%

Latency Comparison (4K QD1):
  PCIe: 6.80us
  RDMA: 33.21us
  Added latency: 26.41us

RDMA vs PCIe Performance:
  4K QD32:    101.2% of PCIe IOPS     ✓ (matches local!)
  128K QD32:  99.9% of PCIe bandwidth ✓ (line-rate parity)
  128K QD128: 99.9% of PCIe bandwidth ✓ (line-rate parity)

================================================================================
✓ VALIDATION PASSED
================================================================================
```

### Pass Criteria

✅ **Fabric bandwidth** ≥100 Gb/sec
✅ **Fabric latency** <15 µs
✅ **QD scaling** (QD32/QD1 ≥3x for both PCIe and RDMA)
✅ **RDMA 4K QD32 IOPS** ≥90% of PCIe baseline
✅ **RDMA 128K bandwidth** ≥95% of PCIe baseline
✅ **RDMA latency** <50 µs (4K QD1)

### Failure Indicators

❌ **Fabric bandwidth** <50 Gb/sec → ionic NIC or cable issue
❌ **Fabric latency** >100 µs → network congestion or misconfiguration
❌ **RDMA latency flat ~9ms** → kernel nvme-rdma used instead of SPDK (DOCA/OFED mismatch)
❌ **RDMA bandwidth** <10% of fabric ceiling → RDMA transport not working
❌ **No QD scaling** → test configuration error

## Cleanup

The script automatically cleans up on exit:
- Kills `nvmf_tgt` and `ib_write_*` processes
- Deletes both test pods (which triggers device unbinding)
- Node returns to original state

**Manual cleanup if needed:**
```bash
kubectl delete pod spdk-perf-target spdk-perf-initiator --force --grace-period=0
```

## Technical Details

### Why Two Hugepage Limits?

cgroup v2 requires both limits for MAP_POPULATE mmap:
- `hugetlb.2MB.max` - maximum hugepage consumption
- `hugetlb.2MB.rsvd.max` - maximum reservation quota

Without both set to `max`, DPDK initialization fails with ENOMEM.

### Why vfio-pci noiommu Mode?

MI355X VMs have `iommu=pt` but no visible IOMMU groups. This is normal for virtualized environments. SPDK requires vfio-pci for userspace NVMe access, so we enable `enable_unsafe_noiommu_mode=1`. The "unsafe" flag means reduced device isolation, but this is standard practice for SPDK in VMs.

### Why GID Index 1?

```
GID 0: fe80::... (link-local IPv6)
GID 1: fc01:800:... (global IPv6) ← used for RDMA data plane
GID 2: ::ffff:192.168.100.1 (IPv4-mapped, only on one node)
GID 3: :: (all zeros, invalid)
```

We use GID index 1 because it's the routable global IPv6 address present on both nodes.

### Why Two IP Addresses?

- **Control plane** (ib_write_bw parameter negotiation): Uses ens3 IPv4 over TCP
- **Data plane** (RDMA, NVMe-oF): Uses ionic_0 IPv6 over RDMA

This is because `ib_write_bw` uses TCP for parameter exchange, but only one node had IPv4 on the ionic interface.

### Rail-Optimized Fabric

Each of the 8 ionic devices is a separate physical path. `ionic_0` on node A can only reach `ionic_0` on node B, not other indices. The test uses `ionic_0` (enP2p0s9) consistently on both nodes.

## Troubleshooting

### "Pod not found" or "Pod not running"
Pods take 30-60s to start. Wait for `Running` status before proceeding.

### "Could not find ionic provider"
Containerd overlay snapshots are not accessible. The script will copy from target to initiator as fallback.

### "Failed to modify QP to RTR"
Wrong GID index. Check `cat /sys/class/infiniband/ionic_0/ports/1/gids/*` for valid GIDs.

### "Invalid parameters" when adding listener
Missing `--adrfam IPv6` flag for IPv6 addresses. Script includes this automatically.

### SPDK build fails
Check disk space (`df -h /tmp`). SPDK build requires ~2GB. Delete old builds with `rm -rf /tmp/spdk`.

### Very low RDMA performance (<10% of PCIe)
Likely using wrong transport. Verify `nvmf_tgt` logs show "Create IB device ionic_0".

## Related Documentation

- [NVMEOF-RDMA.md](NVMEOF-RDMA.md) - Detailed NVMe-oF setup guide
- [QUICKSTART.md](QUICKSTART.md) - Basic SPDK device binding test
- [README.md](README.md) - Test suite overview
- [RESULTS.md](RESULTS.md) - Reference test results

## Test Results Archive

Reference results from validation runs are stored in `RESULTS.md`.
