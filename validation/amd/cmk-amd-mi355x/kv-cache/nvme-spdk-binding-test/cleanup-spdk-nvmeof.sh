#!/bin/bash
# Cleanup script for SPDK NVMe-oF RDMA Test
# Restores node to original state

set -euo pipefail

POD_NAME="spdk-nvmeof-test"
NAMESPACE="default"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

exec_pod() {
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "$1" 2>/dev/null || true
}

log_info "Starting cleanup..."
echo ""

log_info "Stopping SPDK processes..."
exec_pod 'pkill -9 nvmf_tgt'
sleep 2

log_info "Resetting device bindings..."
exec_pod 'cd /tmp/spdk && scripts/setup.sh reset 2>&1 | grep -E "vfio-pci -> nvme|Already using"'

log_info "Disabling vfio noiommu mode..."
exec_pod 'echo 0 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode'

log_info "Removing VFIO group device file..."
exec_pod 'rm -f /dev/vfio/0'

log_info "Cleaning hugepage files..."
exec_pod 'rm -f /mnt/ht/*'

log_info "Verifying device restoration..."
DRIVER=$(exec_pod 'readlink /sys/bus/pci/devices/0003:00:05.0/driver' | grep -o 'nvme' || echo "unknown")
if [ "$DRIVER" == "nvme" ]; then
    log_info "✓ Device 0003:00:05.0 restored to nvme driver"
else
    log_warn "Device driver: $DRIVER (expected: nvme)"
fi

log_info "Verifying node health..."
kubectl get node $(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.spec.nodeName}') -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True" && log_info "✓ Node is Ready"

echo ""
log_info "Cleanup complete. Safe to delete pod:"
echo "  kubectl delete pod $POD_NAME -n $NAMESPACE"
echo ""
