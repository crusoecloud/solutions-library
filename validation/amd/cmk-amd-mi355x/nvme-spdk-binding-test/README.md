# NVMe SPDK Binding Test for CMK AMD MI355X

Validates that SPDK can successfully bind local NVMe devices on AMD MI355X instances in Crusoe Managed Kubernetes (CMK) clusters. This test confirms:

- SPDK can bind NVMe devices to `vfio-pci` driver
- Built-in mount detection protects system drives
- PCI allowlist filtering works correctly
- Device reset restores original kernel `nvme` driver
- Multiple devices can be bound and unbound safely

## Why This Matters

MI355X instances include 8× local NVMe devices (Micron 7500 PRO, 3.5TB each). SPDK is a storage acceleration framework used by high-performance applications (e.g., Ceph, MinIO, distributed databases). This test validates that SPDK can take control of NVMe devices for userspace I/O, bypassing the kernel block layer.

## Test Summary

The experiment:
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

**Expected output when running SPDK setup:**
```
0002:00:08.0 (1344 51b7): Active devices: mount@nvme7n1:nvme7n1, so not binding PCI dev
0000:00:01.0 (1af4 1042): Active devices: mount@vda:vda1,mount@vda:vda15,mount@vda:vda16, so not binding PCI dev
```

## Quick Start

### 1. Select a node

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x
```

Pick any `Ready` node without active customer workloads.

### 2. Deploy the test pod

Edit `spdk-test-pod.yaml` to set `nodeName:` to your chosen node, then:

```bash
kubectl apply -f spdk-test-pod.yaml
kubectl wait --for=condition=Ready pod/spdk-test-privileged --timeout=60s
```

### 3. Run the test script

```bash
./run-spdk-binding-test.sh
```

This script will:
- Map NVMe devices to PCI addresses
- Identify the containerd drive
- Load vfio-pci module
- Test single-device binding
- Test multi-device binding
- Reset all devices
- Clean up and verify node state

### 4. Check the output

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

## Manual Test Procedure

If you prefer to run commands manually:

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

| Date | Bundle | Kernel | Result | Notes |
|------|--------|--------|--------|-------|
| 2024-10-15 | 2.2 | 6.8.12-322.crusoe | ✓ Pass | Single and multi-device binding successful |

## License

This test suite is provided as-is for validation purposes. SPDK is BSD-3-Clause licensed.
