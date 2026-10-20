# SPDK NVMe-oF RDMA Validation for MI355X

End-to-end validation that SPDK can serve a real NVMe device over RDMA fabric using AMD Pensando ionic NICs on MI355X instances.

## What This Tests

1. **Hugepage allocation** with cgroup v2 controls
2. **SPDK build** with RDMA support
3. **Ionic RDMA provider** installation and device discovery
4. **Real NVMe device** attachment (3.8TB Micron) via vfio-pci
5. **DPDK initialization** in IOVA=PA mode with hugepages
6. **NVMe-oF subsystem** creation with real device namespace
7. **RDMA listener** on ionic network interface

## Prerequisites

- CMK cluster with MI355X nodepool (bundle 2.2+)
- `kubectl` access with cluster-admin permissions
- At least one MI355X node in `Ready` state
- 16GB memory available for test pod
- Internet access for downloading SPDK source

**Tested Configuration:**
- Bundle: 2.2
- Kernel: 6.8.12-322.crusoe.amd64-g275dd86317a7
- SPDK: v27.01-pre (latest from GitHub)
- RDMA NICs: 8× AMD Pensando ionic (firmware 1.117.5-a-196)

## Quick Start

### 1. Select a node

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x
```

### 2. Deploy the test pod

Edit `spdk-nvmeof-pod.yaml` and set `nodeName:` to your chosen node:

```bash
kubectl apply -f spdk-nvmeof-pod.yaml
kubectl wait --for=condition=Ready pod/spdk-nvmeof-test --timeout=120s
```

### 3. Run the test

```bash
chmod +x run-spdk-nvmeof-rdma-test.sh
./run-spdk-nvmeof-rdma-test.sh
```

The test takes approximately 10-12 minutes (most time spent building SPDK).

### 4. Cleanup

**IMPORTANT:** Always run cleanup before deleting the pod:

```bash
chmod +x cleanup-spdk-nvmeof.sh
./cleanup-spdk-nvmeof.sh
kubectl delete -f spdk-nvmeof-pod.yaml
```

## Expected Output

### Step 1: Environment Setup
```
[INFO] Packages installed ✓
[INFO] Configuring hugepage cgroup limits...
max
[INFO] Creating hugepage mount at /mnt/ht...
nodev on /mnt/ht type hugetlbfs (rw,relatime,pagesize=2M)
```

### Step 2: Hugepage Validation
```
[INFO] Testing anonymous hugepage mmap...
✓ Anonymous hugepage mmap OK
[INFO] Testing file-backed hugepage mmap...
✓ File-backed hugepage mmap OK
```

### Step 3: SPDK Build
```
[INFO] SPDK cloned ✓
[INFO] Dependencies installed ✓
[INFO] Configuration complete ✓
[INFO] Build complete ✓
[INFO] Verifying build artifacts...
/tmp/spdk/build/bin/nvmf_tgt 14M
/tmp/spdk/build/examples/bdevperf 14M
```

### Step 4: Ionic RDMA Provider
```
[INFO] Installing ionic provider libraries...
[INFO] Discovered 8 ionic RDMA devices ✓
```

### Step 5: NVMe Device Preparation
```
[INFO] Binding device to vfio-pci...
../../../bus/pci/drivers/vfio-pci
[INFO] Creating VFIO group device file...
crw-rw-rw- 1 root root 234, 0 ... /dev/vfio/0
```

### Step 6: SPDK Startup
```
[INFO] nvmf_tgt running ✓
app.c: 993:spdk_app_start: *NOTICE*: Total cores available: 2
reactor.c: 996:reactor_run: *NOTICE*: Reactor started on core 0
reactor.c: 996:reactor_run: *NOTICE*: Reactor started on core 1
```

### Step 7: RDMA Transport
```
rdma.c:2438:create_ib_device: *NOTICE*: Create IB device mlx5_0(...) succeed.
rdma.c:2438:create_ib_device: *NOTICE*: Create IB device ionic_0(...) succeed.
rdma.c:2438:create_ib_device: *NOTICE*: Create IB device ionic_1(...) succeed.
[... 6 more ionic devices ...]
```

### Step 8: NVMe Device Attachment
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
  Listener: RDMA at 172.27.x.x:4420
```

### Step 10: Summary
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
  ✓ RDMA listener: 172.27.x.x:4420
```

## What Gets Validated

### 1. Hugepage Support
- **Anonymous hugepage mmap** with MAP_HUGETLB flag
- **File-backed hugepage mmap** on hugetlbfs mount
- **Cgroup v2 controls** for hugepage limits (both `.max` and `.rsvd.max`)

### 2. RDMA Infrastructure
- **8× ionic RDMA NICs** discovered via libibverbs
- **Ionic provider plugin** loaded from host containerd snapshot
- **RDMA CM (connection manager)** available

### 3. SPDK Components
- **DPDK EAL initialization** with hugepages in IOVA=PA mode
- **vfio-pci driver** binding in noiommu mode
- **Real NVMe controller** attachment (not malloc bdev)
- **NVMe-oF RDMA target** with ionic transport

### 4. Device Safety
- **Mount detection** protects containerd drive (0002:00:08.0)
- **Test device** uses 0003:00:05.0 (never mounted)
- **Automatic skip** of active filesystems

## Technical Details

### Hugepage Configuration

The test configures cgroup v2 hugepage limits:

```bash
echo "max" > hugetlb.2MB.max        # Allow unlimited hugepage usage
echo "max" > hugetlb.2MB.rsvd.max   # Allow unlimited reservations
```

**Why both limits?**
- `hugetlb.2MB.max` controls total usage
- `hugetlb.2MB.rsvd.max` controls reservations (required for mmap with MAP_POPULATE)
- Both must be set for DPDK memory initialization

### VFIO Noiommu Mode

MI355X instances run in virtualized environments without full IOMMU support:

```bash
echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
```

This allows vfio-pci to work without IOMMU groups. The "unsafe" designation means reduced device isolation, which is standard for SPDK in VMs.

### VFIO Group Device File

The kernel doesn't automatically create `/dev/vfio/<group>` in noiommu mode:

```bash
mknod /dev/vfio/0 c 234 0
```

This manual step enables DPDK to open the VFIO group.

### Ionic Provider Installation

The ionic RDMA provider is installed from the host's containerd storage:

```bash
/hostnvme/containerd/.../snapshots/*/fs/usr/lib/x86_64-linux-gnu/libibverbs/
```

This ensures compatibility with the kernel's ionic_rdma module.

### SPDK Build Configuration

```bash
./configure --with-rdma
```

Enables RDMA transport support in SPDK. Build produces:
- `nvmf_tgt` - NVMe-oF target application
- `bdevperf` - Block device performance tool
- RPC client scripts for configuration

### NVMe-oF Subsystem Structure

```
nqn.2026-10.com.crusoe:test
├── Namespace 1: nvme0n1 (Micron 3.8TB)
└── Listener: RDMA at <node-ip>:4420
```

Any NVMe-oF initiator can connect to this subsystem over RDMA and access the device.

## Troubleshooting

### Build fails with missing dependencies

**Solution:** The test script automatically installs all required packages. If build still fails:

```bash
kubectl exec spdk-nvmeof-test -- bash -c 'cd /tmp/spdk && scripts/pkgdep.sh'
```

### Hugepage mmap fails

**Check cgroup limits:**
```bash
kubectl exec spdk-nvmeof-test -- bash -c '
POD_CGROUP=$(cat /proc/self/cgroup | cut -d: -f3 | cut -d/ -f1-4)
cat /sys/fs/cgroup${POD_CGROUP}/hugetlb.2MB.max
cat /sys/fs/cgroup${POD_CGROUP}/hugetlb.2MB.rsvd.max
'
```

Both should show `max`. If not, rerun the environment setup step.

### Ionic devices not found

**Verify host kernel module:**
```bash
kubectl exec spdk-nvmeof-test -- bash -c 'ls /sys/module/ionic_rdma'
```

**Check containerd snapshot:**
```bash
kubectl exec spdk-nvmeof-test -- bash -c 'find /hostnvme -name "libionic-rdmav34.so" 2>/dev/null'
```

### DPDK fails to initialize

**Check logs:**
```bash
kubectl exec spdk-nvmeof-test -- cat /tmp/nvmf.log
```

Look for:
- `--iova-mode=pa` in EAL parameters (correct)
- `--iova-mode=va` means hugepage mount failed (wrong)
- VFIO errors indicate missing `/dev/vfio/0` device file

### Device attachment fails

**Verify device is bound to vfio-pci:**
```bash
kubectl exec spdk-nvmeof-test -- readlink /sys/bus/pci/devices/0003:00:05.0/driver
```

Should show `../../../bus/pci/drivers/vfio-pci`

**Check VFIO group:**
```bash
kubectl exec spdk-nvmeof-test -- ls -l /dev/vfio/0
```

Should exist with permissions `crw-rw-rw-`

## Performance Testing

The test validates that the infrastructure works, but doesn't run performance benchmarks. To test actual performance:

### From host (direct PCIe baseline):

```bash
kubectl exec spdk-nvmeof-test -- bash -c '
cd /tmp/spdk
./build/examples/bdevperf -q 128 -o 131072 -w randread -t 60 \
  -r "trtype:PCIe traddr:0003:00:05.0"
'
```

### From RDMA client (fabric performance):

Requires NVMe-oF initiator with nvme-rdma kernel module (not available in bundle 2.2).

Alternative: Use SPDK initiator in a second pod:

```bash
# In second pod with SPDK
./build/examples/bdevperf -q 128 -o 131072 -w randread -t 60 \
  -r "trtype:RDMA adrfam:IPv4 traddr:<target-ip> trsvcid:4420 \
      subnqn:nqn.2026-10.com.crusoe:test"
```

## Production Deployment

For production SPDK deployments on MI355X:

1. **Persistent hugepage allocation**
   - Configure hugepages at boot via kernel parameters
   - Pre-allocate before applications start

2. **Device binding on boot**
   - Use `pci-stub` or kernel boot parameters to reserve devices
   - Create systemd service to bind devices early in boot

3. **Monitoring**
   - Track hugepage usage with cgroup metrics
   - Monitor RDMA device statistics
   - Log SPDK subsystem connections

4. **High availability**
   - Deploy multiple NVMe-oF targets with different devices
   - Use multipath on initiators for redundancy
   - Implement health checks and automatic failover

5. **Security**
   - Restrict NVMe-oF subsystem to authorized hosts
   - Use TLS for RDMA connections (if supported)
   - Implement authentication with PSK or certificates

## References

- [SPDK NVMe-oF Target](https://spdk.io/doc/nvmf.html)
- [DPDK with Hugepages](https://doc.dpdk.org/guides/linux_gsg/sys_reqs.html#use-of-hugepages-in-the-linux-environment)
- [Linux VFIO Driver](https://www.kernel.org/doc/Documentation/vfio.txt)
- [NVMe-oF Specification](https://nvmexpress.org/specification/nvme-of-specification/)

## Test History

| Date | Bundle | SPDK | Result | Notes |
|------|--------|------|--------|-------|
| 2024-10-16 | 2.2 | v27.01-pre | ✓ PASS | All components validated successfully |
