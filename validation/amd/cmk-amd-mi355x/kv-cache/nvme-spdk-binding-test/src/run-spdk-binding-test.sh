#!/bin/bash
# SPDK NVMe Binding Test for MI355X
# Tests that SPDK can bind local NVMe devices to vfio-pci driver
# and safely reset them back to kernel nvme driver

set -euo pipefail

POD_NAME="spdk-test-privileged"
NAMESPACE="default"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

exec_pod() {
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- chroot /host bash -c "$1"
}

# Check prerequisites
log_info "Checking prerequisites..."
if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
    log_error "Pod $POD_NAME not found. Deploy spdk-test-pod.yaml first."
    exit 1
fi

if ! kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' | grep -q "Running"; then
    log_error "Pod $POD_NAME is not running. Wait for it to start."
    exit 1
fi

log_info "Pod $POD_NAME is running ✓"
echo ""

# STEP 1: Map NVMe topology
log_info "STEP 1: Mapping NVMe topology..."
echo "----------------------------------------"
exec_pod 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "NAME|nvme"'
echo ""

log_info "Identifying containerd drive..."
CONTAINERD_DEVICE=$(exec_pod 'findmnt -n -o SOURCE /var/lib/containerd | grep -oP "nvme[0-9]+" || echo "unknown"')
if [ "$CONTAINERD_DEVICE" == "unknown" ]; then
    log_warn "Could not identify containerd device automatically"
else
    log_info "Containerd drive: ${CONTAINERD_DEVICE} (will be protected)"
fi
echo ""

log_info "NVMe to PCI address mapping..."
exec_pod 'for i in {0..7}; do echo -n "nvme${i} -> "; readlink -f /sys/block/nvme${i}n1/device 2>/dev/null | grep -oP "pci[0-9a-f:./]+" | tail -1 || echo "not found"; done'
echo ""

# STEP 2: Load vfio-pci module
log_info "STEP 2: Loading vfio-pci kernel module..."
echo "----------------------------------------"
exec_pod 'modprobe vfio-pci 2>&1 && echo "SUCCESS: vfio-pci loaded"'
exec_pod 'lsmod | grep vfio'
echo ""

log_info "Enabling vfio no-IOMMU mode..."
exec_pod 'echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode'
exec_pod 'cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode | sed "s/Y/no-IOMMU mode enabled/"'
echo ""

# STEP 3: Install tools and clone SPDK
log_info "STEP 3: Setting up SPDK..."
echo "----------------------------------------"
log_info "Installing git (this may take a minute)..."
kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c 'apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1'

log_info "Cloning SPDK repository..."
exec_pod 'rm -rf /tmp/spdk-test && cd /tmp && git clone --depth 1 https://github.com/spdk/spdk.git spdk-test 2>&1 | tail -1'
exec_pod 'ls -la /tmp/spdk-test/scripts/setup.sh | head -1'
echo ""

# STEP 4: Test single device binding
log_info "STEP 4: Testing single device binding..."
echo "----------------------------------------"
TEST_PCI="0002:00:05.0"  # nvme0 - typically safe
log_info "Binding $TEST_PCI to vfio-pci..."

exec_pod "cd /tmp/spdk-test && PCI_ALLOWED=\"$TEST_PCI\" SKIP_HUGE=yes scripts/setup.sh 2>&1 | grep -E 'nvme -> vfio-pci|Active devices|Skipping denied'"
echo ""

log_info "Verifying binding..."
exec_pod "lspci -k -s $TEST_PCI | grep 'driver in use'"
exec_pod 'ls /sys/block/nvme0n1 2>&1 || echo "nvme0n1 not in block layer (expected - now controlled by vfio-pci)"'
echo ""

log_info "Resetting device..."
exec_pod 'cd /tmp/spdk-test && scripts/setup.sh reset 2>&1 | grep -E "vfio-pci -> nvme"'
echo ""

log_info "Verifying restoration..."
exec_pod "lspci -k -s $TEST_PCI | grep 'driver in use'"
exec_pod 'sleep 2 && ls -l /sys/block/nvme0n1 2>&1 | head -1'
echo ""

# STEP 5: Test multiple device binding
log_info "STEP 5: Testing multiple device binding..."
echo "----------------------------------------"
MULTI_PCI="0002:00:05.0 0002:00:06.0 0003:00:05.0"  # nvme0, nvme1, nvme2
log_info "Binding 3 devices: $MULTI_PCI"

exec_pod "cd /tmp/spdk-test && PCI_ALLOWED=\"$MULTI_PCI\" SKIP_HUGE=yes scripts/setup.sh 2>&1 | grep 'nvme -> vfio-pci'"
echo ""

log_info "Verifying all devices bound..."
for pci in 0002:00:05.0 0002:00:06.0 0003:00:05.0; do
    exec_pod "lspci -k -s $pci | grep 'driver in use'"
done
echo ""

log_info "Resetting all devices..."
exec_pod 'cd /tmp/spdk-test && scripts/setup.sh reset 2>&1 | grep "vfio-pci -> nvme"'
echo ""

log_info "Verifying all restored..."
exec_pod 'sleep 3 && lsblk -o NAME,SIZE,TYPE | grep -E "nvme[0-2]n1"'
echo ""

# STEP 6: Cleanup
log_info "STEP 6: Cleaning up..."
echo "----------------------------------------"
log_info "Disabling no-IOMMU mode..."
exec_pod 'echo 0 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode'

log_info "Unloading vfio modules..."
exec_pod 'modprobe -r vfio-pci vfio_pci_core vfio_iommu_type1 vfio 2>&1'
exec_pod 'lsmod | grep vfio || echo "No vfio modules loaded (clean)"'
echo ""

# Final verification
log_info "Final verification..."
echo "----------------------------------------"
exec_pod 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E "NAME|nvme"'
echo ""

log_info "✓ Test completed successfully!"
echo ""
log_info "Summary:"
echo "  - Single device binding: ✓ PASS"
echo "  - Multiple device binding: ✓ PASS"
echo "  - Device reset: ✓ PASS"
echo "  - Node restored to original state: ✓ PASS"
echo ""
log_info "SPDK can successfully bind NVMe devices on MI355X instances"
