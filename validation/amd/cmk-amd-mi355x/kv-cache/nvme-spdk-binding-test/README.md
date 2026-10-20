# SPDK Validation Suite for CMK AMD MI355X

Comprehensive validation of SPDK (Storage Performance Development Kit) on AMD MI355X instances in Crusoe Managed Kubernetes (CMK) clusters.

## Test Suite Overview

This suite includes three progressive tests:

### Test 1: Basic SPDK Device Binding
Validates fundamental SPDK capabilities:
- Bind NVMe devices to `vfio-pci` driver
- Mount detection protects system drives
- PCI allowlist filtering
- Device reset to kernel `nvme` driver
- Multi-device binding and unbinding

**Duration:** ~2 minutes
**See:** Quick Start section below

### Test 2: NVMe-oF RDMA with Real Devices
Validates end-to-end SPDK NVMe-oF over RDMA fabric:
- Hugepage allocation with cgroup v2
- SPDK build with RDMA support
- AMD Pensando ionic RDMA NICs (8 devices)
- Real NVMe device attachment via vfio-pci
- DPDK initialization in IOVA=PA mode
- NVMe-oF subsystem serving real device over RDMA

**Duration:** ~10-12 minutes (includes SPDK build)
**See:** [NVMEOF-RDMA.md](NVMEOF-RDMA.md)

### Test 3: Two-Node RDMA Performance Validation
Comprehensive performance test measuring RDMA vs PCIe performance:
- Two-node automated test (target + initiator)
- Fabric control tests (ib_write_bw, ib_write_lat)
- PCIe baseline measurements (4 tests)
- RDMA performance measurements (4 tests)
- Automated report generation with efficiency analysis
- Validates line-rate performance over RDMA fabric

**Duration:** ~25-30 minutes (includes SPDK builds on both nodes)
**See:** [PERFORMANCE-TEST.md](PERFORMANCE-TEST.md)
**Script:** `./run-nvmeof-performance-validation.sh <kubeconfig> <target-node> <initiator-node>`

## Why This Matters

MI355X instances include 8× local NVMe devices (Micron 7500 PRO, 3.5TB each). SPDK is a storage acceleration framework used by high-performance applications (e.g., Ceph, MinIO, distributed databases). This test validates that SPDK can take control of NVMe devices for userspace I/O, bypassing the kernel block layer.

## Test 1: Basic Device Binding Summary

The basic binding test:
1. Identifies all NVMe devices and their PCI addresses
2. Detects which device hosts the containerd filesystem (must never be bound)
3. Loads the `vfio-pci` kernel module in no-IOMMU mode
4. Uses SPDK's `setup.sh` to bind test devices from `nvme` → `vfio-pci`
5. Verifies devices disappear from `/sys/block/` (now in userspace control)
6. Resets devices back to kernel driver: `vfio-pci` → `nvme`
7. Confirms block devices reappear and node returns to original state

**Result:** ✓ SPDK can bind local NVMe devices on MI355X VMs

## Prerequisites

- CMK cluster with MI355X nodepool (bundle 2.2+ recommended)
- `kubectl` access with cluster-admin permissions
- At least one MI355X node in `Ready` state

**Software bundle tested:**
- Kernel: `6.8.12-322.crusoe.amd64-g275dd86317a7` (bundle 2.2)
- vfio-pci module available in kernel
- No hugepages pre-allocated required (test skips hugepage allocation)

## Hardware Configuration

MI355X instances include:
- **8× NVMe devices** (Micron 7500 PRO, 3.5TB each)
- PCI layout across two root complexes:
  - `pci0002:00`: 4 devices (05.0, 06.0, 07.0, 08.0)
  - `pci0003:00`: 4 devices (05.0, 06.0, 07.0, 08.0)
- **One device is mounted** at `/mnt/nvme` for containerd storage
- **Boot disk** is separate virtio device (`vda`)

## IOMMU Status

- Kernel boot parameter: `iommu=pt` (passthrough enabled)
- **IOMMU groups: 0** (no visible IOMMU groups)
- **Implication:** SPDK requires `enable_unsafe_noiommu_mode=1` to use vfio-pci

This is expected in virtualized environments. The "unsafe" flag means reduced isolation between devices, but is standard for SPDK in VMs.

## Safety Mechanisms

**Built-in protections:**
1. **Mount detection:** SPDK automatically skips devices with active mounts
2. **PCI allowlist:** Only devices in `PCI_ALLOWED` are touched
3. **Boot disk protection:** Virtio boot disk automatically skipped
4. **Explicit exclusion:** Containerd drive never appears in allowlist

**What gets protected:**
```
nvme7 (0002:00:08.0) → mounted at /mnt/nvme → AUTOMATIC SKIP
vda (virtio boot disk) → contains root filesystem → AUTOMATIC SKIP
```

**Expected output when running SPDK setup (both tests):**
```
0002:00:08.0 (1344 51b7): Active devices: mount@nvme7n1:nvme7n1, so not binding PCI dev
0000:00:01.0 (1af4 1042): Active devices: mount@vda:vda1,mount@vda:vda15,mount@vda:vda16, so not binding PCI dev
```

This confirms SPDK's mount detection is protecting system drives.

## Quick Start

**TL;DR:** See [QUICKSTART.md](QUICKSTART.md) for copy-paste commands.

### Test 1: Basic Device Binding (~2 minutes)

Validates fundamental SPDK device binding capabilities.

```bash
# 1. Get a node
kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x

# 2. Edit spdk-test-pod.yaml with your node name, then:
kubectl apply -f spdk-test-pod.yaml
kubectl wait --for=condition=Ready pod/spdk-test-privileged --timeout=60s

# 3. Run test
chmod +x run-spdk-binding-test.sh
./run-spdk-binding-test.sh

# 4. Cleanup
kubectl delete pod spdk-test-privileged
```

**What it tests:**
- ✓ vfio-pci driver binding
- ✓ Mount detection (protects containerd drive)
- ✓ Multi-device binding
- ✓ Device reset to nvme driver

### Test 2: NVMe-oF RDMA (~10-12 minutes)

Validates complete SPDK NVMe-oF stack with real NVMe device over RDMA fabric.

```bash
# 1. Get a node
kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x

# 2. Edit spdk-nvmeof-pod.yaml with your node name, then:
kubectl apply -f spdk-nvmeof-pod.yaml
kubectl wait --for=condition=Ready pod/spdk-nvmeof-test --timeout=120s

# 3. Run test (builds SPDK)
chmod +x run-spdk-nvmeof-rdma-test.sh cleanup-spdk-nvmeof.sh
./run-spdk-nvmeof-rdma-test.sh

# 4. Cleanup (REQUIRED!)
./cleanup-spdk-nvmeof.sh
kubectl delete pod spdk-nvmeof-test
```

**What it tests:**
- ✓ All of Test 1, plus:
- ✓ Hugepage allocation with cgroup v2
- ✓ SPDK build with RDMA support
- ✓ AMD Pensando ionic RDMA provider (8 NICs)
- ✓ DPDK initialization (IOVA=PA mode)
- ✓ Real NVMe device (3.8TB Micron) attachment
- ✓ NVMe-oF subsystem creation
- ✓ RDMA listener on ionic network

**Deep dive:** See [NVMEOF-RDMA.md](NVMEOF-RDMA.md) for technical details.

---

## Expected Output - Test 1

Look for these key indicators of success:

**Device binding:**
```
0002:00:05.0 (1344 51b7): nvme -> vfio-pci
```

**Mount protection working:**
```
0002:00:08.0 (1344 51b7): Active devices: mount@nvme7n1:nvme7n1, so not binding PCI dev
```

**Reset successful:**
```
0002:00:05.0 (1344 51b7): vfio-pci -> nvme
```

**Final verification:**
```
All 8 NVMe devices visible in block layer ✓
nvme7n1 still mounted at /mnt/nvme ✓
No vfio modules loaded ✓
```

### 5. Cleanup

```bash
kubectl delete -f spdk-test-pod.yaml
```

## Expected Output - Test 2

### Step 2: Hugepage Validation
```
✓ Anonymous hugepage mmap OK
✓ File-backed hugepage mmap OK
```

### Step 7: RDMA Transport
```
rdma.c:2438:create_ib_device: *NOTICE*: Create IB device mlx5_0(...) succeed.
rdma.c:2438:create_ib_device: *NOTICE*: Create IB device ionic_0(...) succeed.
[... 7 more ionic devices ...]
```

### Step 8: Real NVMe Device Attachment
```
✓ Device: nvme0n1
  Model: MTFDKCC3T8TGP-1BK1DABYY
  Capacity: 3.84 TB
  PCI: 0003:00:05.0
```

### Step 9: NVMe-oF Subsystem
```
✓ Subsystem: nqn.2026-10.com.crusoe:test
  Serial: CRUSOE00000000001
  Namespace: nvme0n1
  Listener: RDMA at <node-ip>:4420
```

### Final Summary
```
✓ NVMe-oF RDMA Test Completed Successfully!
Test Results:
  ✓ Hugepage mmap validation: PASS
  ✓ SPDK build with RDMA: PASS
  ✓ Ionic RDMA provider: 8 devices
  ✓ NVMe device binding (vfio-pci): PASS
  ✓ DPDK initialization (IOVA=PA): PASS
  ✓ Real NVMe device attachment: PASS
  ✓ NVMe-oF subsystem creation: PASS
  ✓ RDMA listener: <ip>:4420
```

---

## Manual Test Procedure - Test 1

If you prefer to run Test 1 commands manually:

### Step 1: Deploy privileged pod

```bash
kubectl apply -f spdk-test-pod.yaml
kubectl exec -it spdk-test-privileged -- bash
```

### Step 2: Map NVMe topology (inside pod)

```bash
chroot /host bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep nvme

# Identify containerd drive
df /var/lib/containerd

# Map devices to PCI addresses
for i in {0..7}; do
  echo -n "nvme${i} -> "
  readlink -f /sys/block/nvme${i}n1/device | grep -oP "pci[0-9a-f:./]+" | tail -1
done
```

### Step 3: Load vfio-pci and enable no-IOMMU mode

```bash
modprobe vfio-pci
echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
lsmod | grep vfio
```

### Step 4: Clone SPDK and test binding

```bash
cd /tmp
git clone --depth 1 https://github.com/spdk/spdk.git spdk-test
cd spdk-test

# Test single device (example: 0002:00:05.0)
# NEVER include the containerd drive (0002:00:08.0 in our test)
PCI_ALLOWED="0002:00:05.0" SKIP_HUGE=yes scripts/setup.sh

# Verify binding
lspci -k -s 0002:00:05.0 | grep "driver in use"
# Should show: Kernel driver in use: vfio-pci

ls /sys/block/nvme0n1
# Should show: No such file or directory (expected - device now in userspace)
```

### Step 5: Reset and verify

```bash
scripts/setup.sh reset

# Verify restoration
lspci -k -s 0002:00:05.0 | grep "driver in use"
# Should show: Kernel driver in use: nvme

ls /sys/block/nvme0n1
# Should exist again
```

### Step 6: Test multiple devices

```bash
# Example: bind 3 devices (excluding containerd drive)
PCI_ALLOWED="0002:00:05.0 0002:00:06.0 0003:00:05.0" SKIP_HUGE=yes scripts/setup.sh

# Verify all bound
for pci in 0002:00:05.0 0002:00:06.0 0003:00:05.0; do
  lspci -k -s $pci | grep "driver in use"
done

# Reset all
scripts/setup.sh reset
```

### Step 7: Cleanup

```bash
# Disable no-IOMMU mode
echo 0 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode

# Unload modules
modprobe -r vfio-pci vfio_pci_core vfio_iommu_type1 vfio

# Exit pod
exit
```

## Expected Results

### Successful Binding

```
0002:00:05.0 (1344 51b7): nvme -> vfio-pci
```

Verification:
- `lspci -k -s 0002:00:05.0` shows `Kernel driver in use: vfio-pci`
- `/sys/block/nvme0n1` does not exist
- Device is now accessible via VFIO API for userspace I/O

### Successful Reset

```
0002:00:05.0 (1344 51b7): vfio-pci -> nvme
```

Verification:
- `lspci -k -s 0002:00:05.0` shows `Kernel driver in use: nvme`
- `/sys/block/nvme0n1` exists again
- `lsblk` shows nvme0n1 as 3.5T disk

### Safety Mechanisms Working

```
0002:00:08.0 (1344 51b7): Active devices: mount@nvme7n1:nvme7n1, so not binding PCI dev
```

This confirms SPDK detected the mounted filesystem and refused to bind the device.

## Troubleshooting

### "Operation not permitted" when loading modules

**Problem:** Standard debug pods lack CAP_SYS_MODULE

**Solution:** Use the provided privileged pod manifest with `securityContext.privileged: true`

### "No IOMMU groups found"

**Problem:** Expected in virtualized environments

**Solution:** Enable no-IOMMU mode:
```bash
echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
```

### Device binding fails with "Active devices" message

**Symptom:** SPDK refuses to bind a device, shows mount or active usage

**This is CORRECT behavior** - SPDK is protecting your data. Do NOT override this.

### Node becomes unreachable after test

**If you accidentally bound the containerd drive:**

This should be prevented by SPDK's mount detection, but if it happens:
1. Node will lose connectivity as containerd storage disappears
2. Kubernetes will mark the node NotReady
3. Drain the node and reboot via cloud admin tools
4. Review logs to identify which device was incorrectly bound

**Prevention:** Always verify PCI_ALLOWED excludes the mounted device

## Production Considerations

### When to use SPDK on MI355X

- High-performance distributed storage (Ceph, MinIO)
- Database storage engines requiring low-latency I/O
- ML training pipelines with local NVMe staging
- Applications requiring userspace NVMe control

### Deployment recommendations

1. **Reserve devices for SPDK at boot**
   - Use kernel boot parameters: `pci_stub` or `vfio-pci.ids`
   - Prevents kernel nvme driver from binding initially

2. **Pre-allocate hugepages**
   - SPDK requires hugepages for DMA buffers
   - Configure via kernel parameters or systemd scripts

3. **Use IOMMU groups if available**
   - Future bundle updates may expose IOMMU groups
   - Prefer IOMMU mode over no-IOMMU when available

4. **Persistent configuration**
   - Create systemd service to bind devices on boot
   - Store SPDK configuration in ConfigMaps
   - Use init containers to set up devices before application starts

### Performance tuning

- **CPU isolation:** Pin SPDK threads to specific cores
- **IRQ affinity:** Route NVMe IRQs to isolated cores
- **Memory locality:** Use NUMA-aware memory allocation
- **Polling vs interrupts:** SPDK defaults to polling for lowest latency

## Technical Details

### Kernel Modules Required

```
vfio                   # Core VFIO subsystem
vfio_iommu_type1      # IOMMU backend
vfio_pci_core         # PCI device support
vfio_pci              # Main vfio-pci driver
iommufd               # Modern IOMMU interface
```

### SPDK Setup Script Environment Variables

```bash
PCI_ALLOWED="0002:00:05.0 0002:00:06.0"  # Whitelist devices
PCI_BLOCKED="0002:00:08.0"                # Blacklist devices (optional)
SKIP_HUGE=yes                             # Skip hugepage allocation
NRHUGE=2048                               # Number of hugepages (if not skipped)
HUGEPGSZ=2048                             # Hugepage size in KB
DRIVER_OVERRIDE=vfio-pci                  # Force specific driver
```

### Device States

| State | Driver | /sys/block/ | Access Method |
|-------|--------|-------------|---------------|
| Normal | nvme | Present | Kernel block layer |
| SPDK Bound | vfio-pci | Absent | VFIO API (userspace) |
| Reset | nvme | Present | Kernel block layer |

### Security Model

**Privileged pod requirements:**
- `hostNetwork: true` - Access host network namespace
- `hostPID: true` - Access host process namespace
- `hostIPC: true` - Access host IPC namespace
- `privileged: true` - Full device access
- CAP_SYS_MODULE - Load kernel modules
- CAP_SYS_RAWIO - Raw device I/O
- CAP_SYS_ADMIN - Administrative operations

**Risks:**
- Pod has root access to host system
- Can load arbitrary kernel modules
- Can access all hardware devices
- Should only be used in controlled environments

**Mitigations:**
- Use PodSecurityPolicy or Pod Security Standards to restrict privileged pods
- Audit all privileged pod usage
- Limit to specific service accounts
- Run only during maintenance windows

## References

- [SPDK Documentation](https://spdk.io/doc/)
- [SPDK GitHub](https://github.com/spdk/spdk)
- [VFIO Documentation](https://www.kernel.org/doc/Documentation/vfio.txt)
- [Linux IOMMU Documentation](https://www.kernel.org/doc/Documentation/Intel-IOMMU.txt)

## Test History

| Date | Test | Bundle | Kernel | Result | Notes |
|------|------|--------|--------|--------|-------|
| 2024-10-16 | Test 2 (NVMe-oF RDMA) | 2.2 | 6.8.12-322.crusoe | ✓ Pass | Complete stack validated: hugepages, 8 ionic NICs, real 3.8TB NVMe over RDMA |
| 2024-10-15 | Test 1 (Basic Binding) | 2.2 | 6.8.12-322.crusoe | ✓ Pass | Single and multi-device binding successful |

## License

This test suite is provided as-is for validation purposes. SPDK is BSD-3-Clause licensed.
