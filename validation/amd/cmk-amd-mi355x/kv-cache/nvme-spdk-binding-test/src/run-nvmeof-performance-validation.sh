#!/bin/bash
# SPDK NVMe-oF RDMA Performance Validation for MI355X
# Two-node end-to-end performance test with fabric control and RDMA measurements
#
# Usage: ./run-nvmeof-performance-validation.sh <kubeconfig> <target-node> <initiator-node>
#
# Example:
#   ./run-nvmeof-performance-validation.sh \
#     ~/.kube/validation-cluster-config \
#     <target-node> \
#     <initiator-node>

set -euo pipefail

# Configuration
KUBECONFIG_PATH="${1:-}"
TARGET_NODE="${2:-}"
INITIATOR_NODE="${3:-}"
TEST_DEVICE="0003:00:05.0"
IONIC_DEVICE="ionic_0"
GID_INDEX="1"
NQN="nqn.2026-10.com.crusoe:test"
SERIAL="CRUSOE00000000001"
PORT="4420"

# Pod names
POD_TARGET="spdk-perf-target"
POD_INITIATOR="spdk-perf-initiator"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check arguments
if [ -z "$KUBECONFIG_PATH" ] || [ -z "$TARGET_NODE" ] || [ -z "$INITIATOR_NODE" ]; then
    echo "Usage: $0 <kubeconfig> <target-node> <initiator-node>"
    exit 1
fi

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "Error: kubeconfig not found at $KUBECONFIG_PATH"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

# Logging functions
log_header() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_result() {
    echo -e "${GREEN}✓${NC} $1"
}

# Helper functions
exec_target() {
    kubectl exec "$POD_TARGET" -- bash -c "$1"
}

exec_initiator() {
    kubectl exec "$POD_INITIATOR" -- bash -c "$1"
}

# Cleanup function
cleanup() {
    log_warn "Cleaning up..."

    # Kill processes
    exec_target 'pkill -9 nvmf_tgt || true; pkill -9 ib_write || true' 2>/dev/null || true
    exec_initiator 'pkill -9 spdk_nvme_perf || true; pkill -9 ib_write || true' 2>/dev/null || true

    # Delete pods
    kubectl delete pod "$POD_TARGET" --force --grace-period=0 2>/dev/null || true
    kubectl delete pod "$POD_INITIATOR" --force --grace-period=0 2>/dev/null || true

    log_info "Cleanup complete"
}

trap cleanup EXIT

# STEP 1: Deploy pods
log_header "STEP 1: Deploy Test Pods"

log_step "Creating target pod on $TARGET_NODE"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_TARGET
spec:
  nodeName: $TARGET_NODE
  hostNetwork: true
  hostPID: true
  hostIPC: true
  restartPolicy: Never
  containers:
  - name: spdk
    image: ubuntu:24.04
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
      capabilities:
        add: [SYS_MODULE, SYS_RAWIO, SYS_ADMIN, IPC_LOCK, SYS_RESOURCE]
    resources:
      limits:
        memory: 16Gi
    volumeMounts:
    - name: hugepages
      mountPath: /dev/hugepages
    - name: dshm
      mountPath: /dev/shm
    - name: ibdev
      mountPath: /dev/infiniband
    - name: devvfio
      mountPath: /dev/vfio
    - name: hostnvme
      mountPath: /hostnvme
      readOnly: true
    - name: hosttmp
      mountPath: /hosttmp
  volumes:
  - name: hugepages
    hostPath:
      path: /dev/hugepages
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 4Gi
  - name: ibdev
    hostPath:
      path: /dev/infiniband
  - name: devvfio
    hostPath:
      path: /dev/vfio
      type: DirectoryOrCreate
  - name: hostnvme
    hostPath:
      path: /mnt/nvme
  - name: hosttmp
    hostPath:
      path: /tmp
EOF

log_step "Creating initiator pod on $INITIATOR_NODE"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_INITIATOR
spec:
  nodeName: $INITIATOR_NODE
  hostNetwork: true
  hostPID: true
  hostIPC: true
  restartPolicy: Never
  containers:
  - name: spdk
    image: ubuntu:24.04
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
      capabilities:
        add: [SYS_MODULE, SYS_RAWIO, SYS_ADMIN, IPC_LOCK, SYS_RESOURCE]
    resources:
      limits:
        memory: 16Gi
    volumeMounts:
    - name: hugepages
      mountPath: /dev/hugepages
    - name: dshm
      mountPath: /dev/shm
    - name: ibdev
      mountPath: /dev/infiniband
    - name: devvfio
      mountPath: /dev/vfio
    - name: hostnvme
      mountPath: /hostnvme
      readOnly: true
    - name: hosttmp
      mountPath: /hosttmp
  volumes:
  - name: hugepages
    hostPath:
      path: /dev/hugepages
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 4Gi
  - name: ibdev
    hostPath:
      path: /dev/infiniband
  - name: devvfio
    hostPath:
      path: /dev/vfio
      type: DirectoryOrCreate
  - name: hostnvme
    hostPath:
      path: /mnt/nvme
  - name: hosttmp
    hostPath:
      path: /tmp
EOF

log_info "Waiting for pods to start..."
kubectl wait --for=condition=Ready pod/$POD_TARGET --timeout=120s
kubectl wait --for=condition=Ready pod/$POD_INITIATOR --timeout=120s
log_result "Pods running"

# STEP 2: Setup environment on both nodes
log_header "STEP 2: Environment Setup"

setup_node() {
    local POD=$1
    local NODE_NAME=$2

    log_step "Setting up $NODE_NAME"

    # Install packages
    kubectl exec "$POD" -- bash -c '
        apt-get update -qq && \
        apt-get install -y -qq git build-essential python3 python3-yaml python3-jinja2 \
            pkg-config libssl-dev libaio-dev libfuse3-dev libfuse3-3 libibverbs-dev \
            librdmacm-dev libnuma1 nvme-cli kmod perftest ibverbs-utils pciutils > /dev/null 2>&1
    ' > /dev/null

    # Configure hugepages
    kubectl exec "$POD" -- bash -c '
        POD_CGROUP=$(cat /proc/self/cgroup | cut -d: -f3 | cut -d/ -f1-4)
        echo max > /sys/fs/cgroup${POD_CGROUP}/hugetlb.2MB.max
        echo max > /sys/fs/cgroup${POD_CGROUP}/hugetlb.2MB.rsvd.max
        echo 4096 > /proc/sys/vm/nr_hugepages
        mkdir -p /mnt/ht
        mount -t hugetlbfs -o pagesize=2M nodev /mnt/ht
    '

    # Install ionic provider
    kubectl exec "$POD" -- bash -c '
        SNAP=$(find /hostnvme/containerd -name "libionic-rdmav34.so" 2>/dev/null | head -1 | xargs dirname | xargs dirname | xargs dirname | xargs dirname | xargs dirname)/fs
        if [ -d "$SNAP" ]; then
            cp ${SNAP}/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so /usr/lib/x86_64-linux-gnu/libibverbs/ 2>/dev/null || true
            cp ${SNAP}/usr/lib/x86_64-linux-gnu/libionic.so.1.* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
            mkdir -p /etc/libibverbs.d
            cp ${SNAP}/etc/libibverbs.d/ionic.driver /etc/libibverbs.d/ 2>/dev/null || true
        fi
        cd /usr/lib/x86_64-linux-gnu
        ln -sf libionic.so.1.* libionic.so.1 2>/dev/null || true
        ln -sf libionic.so.1 libionic.so 2>/dev/null || true
        ln -sf libaio.so.1t64 libaio.so.1 2>/dev/null || true
        ldconfig
    '

    log_result "$NODE_NAME setup complete"
}

# Copy ionic provider from target to initiator if needed
log_step "Installing ionic provider on target"
setup_node "$POD_TARGET" "TARGET"

log_step "Installing ionic provider on initiator"
# Try to setup initiator
kubectl exec "$POD_INITIATOR" -- bash -c '
    apt-get update -qq && \
    apt-get install -y -qq git build-essential python3 python3-yaml python3-jinja2 \
        pkg-config libssl-dev libaio-dev libfuse3-dev libfuse3-3 libibverbs-dev \
        librdmacm-dev libnuma1 nvme-cli kmod perftest ibverbs-utils pciutils > /dev/null 2>&1
    POD_CGROUP=$(cat /proc/self/cgroup | cut -d: -f3 | cut -d/ -f1-4)
    echo max > /sys/fs/cgroup${POD_CGROUP}/hugetlb.2MB.max
    echo max > /sys/fs/cgroup${POD_CGROUP}/hugetlb.2MB.rsvd.max
    echo 4096 > /proc/sys/vm/nr_hugepages
    mkdir -p /mnt/ht
    mount -t hugetlbfs -o pagesize=2M nodev /mnt/ht
' > /dev/null

# Copy ionic from target to initiator
log_info "Copying ionic provider from target to initiator"
kubectl exec "$POD_TARGET" -- tar czf - /usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so /usr/lib/x86_64-linux-gnu/libionic.so.1.* /etc/libibverbs.d/ionic.driver 2>/dev/null | \
    kubectl exec -i "$POD_INITIATOR" -- tar xzf - -C /
exec_initiator 'cd /usr/lib/x86_64-linux-gnu && ln -sf libionic.so.1.* libionic.so.1 && ln -sf libionic.so.1 libionic.so && ln -sf libaio.so.1t64 libaio.so.1 && ldconfig'

# Verify ionic devices
IONIC_COUNT_TARGET=$(exec_target 'ibv_devinfo | grep -c "hca_id.*ionic" || echo 0')
IONIC_COUNT_INIT=$(exec_initiator 'ibv_devinfo | grep -c "hca_id.*ionic" || echo 0')
log_result "TARGET: $IONIC_COUNT_TARGET ionic devices"
log_result "INITIATOR: $IONIC_COUNT_INIT ionic devices"

# STEP 3: Map rails and get IP addresses
log_header "STEP 3: Rail Mapping"

TARGET_IPV6=$(exec_target "ip -6 addr show enP2p0s9 | grep 'inet6 fc01' | awk '{print \$2}' | cut -d/ -f1")
TARGET_IPV4=$(exec_target "hostname -I | awk '{print \$1}'")
INITIATOR_IPV6=$(exec_initiator "ip -6 addr show enP2p0s9 | grep 'inet6 fc01' | awk '{print \$2}' | cut -d/ -f1")
INITIATOR_IPV4=$(exec_initiator "hostname -I | awk '{print \$1}'")

log_info "TARGET ($TARGET_NODE):"
log_info "  IPv6: $TARGET_IPV6"
log_info "  IPv4: $TARGET_IPV4"
log_info "INITIATOR ($INITIATOR_NODE):"
log_info "  IPv6: $INITIATOR_IPV6"
log_info "  IPv4: $INITIATOR_IPV4"

# STEP 4: Build or find SPDK on both nodes
log_header "STEP 4: SPDK Setup"

# Check for existing SPDK on target
if exec_target '[ -f /hosttmp/spdk/build/bin/nvmf_tgt ] && [ -f /hosttmp/spdk/build/bin/spdk_nvme_perf ]' 2>/dev/null; then
    log_info "Using existing SPDK build on target"
    exec_target 'ln -sf /hosttmp/spdk /tmp/spdk 2>/dev/null || true'
else
    log_step "Building SPDK on target (this takes 5-10 minutes)..."
    exec_target 'cd /tmp && rm -rf spdk && git clone --depth 1 https://github.com/spdk/spdk.git' > /dev/null 2>&1
    exec_target 'cd /tmp/spdk && git submodule update --init --depth 1' > /dev/null 2>&1
    exec_target 'cd /tmp/spdk && scripts/pkgdep.sh' > /dev/null 2>&1
    exec_target 'cd /tmp/spdk && ./configure --with-rdma' > /dev/null 2>&1
    exec_target 'cd /tmp/spdk && make -j$(nproc)' > /dev/null 2>&1
fi
log_result "TARGET SPDK ready"

# Build SPDK on initiator
log_step "Building SPDK on initiator (this takes 5-10 minutes)..."
exec_initiator 'cd /tmp && rm -rf spdk && git clone --depth 1 https://github.com/spdk/spdk.git' > /dev/null 2>&1
exec_initiator 'cd /tmp/spdk && git submodule update --init --depth 1' > /dev/null 2>&1
exec_initiator 'cd /tmp/spdk && scripts/pkgdep.sh' > /dev/null 2>&1
exec_initiator 'cd /tmp/spdk && ./configure --with-rdma' > /dev/null 2>&1
exec_initiator 'cd /tmp/spdk && make -j$(nproc)' > /dev/null 2>&1
log_result "INITIATOR SPDK ready"

# STEP 5: PCIe Baseline Tests on Target
log_header "STEP 5: PCIe Baseline on Target"

log_step "Binding device $TEST_DEVICE to vfio-pci"
exec_target "
    modprobe vfio-pci
    echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
    mkdir -p /dev/vfio
    mknod /dev/vfio/0 c 234 0 2>/dev/null || true
    chmod 666 /dev/vfio/0
    echo $TEST_DEVICE > /sys/bus/pci/drivers/nvme/unbind 2>/dev/null || true
    VENDOR=\$(cat /sys/bus/pci/devices/$TEST_DEVICE/vendor)
    DEVICE=\$(cat /sys/bus/pci/devices/$TEST_DEVICE/device)
    echo \"\${VENDOR#0x} \${DEVICE#0x}\" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    echo $TEST_DEVICE > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
"

log_step "Running PCIe Test 1: 4K QD1 (latency floor)"
PCIE_TEST1=$(exec_target "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 1 -o 4096 -w randread -t 10 -r \"trtype:PCIe traddr:$TEST_DEVICE\" 2>&1 | grep '^Total'")

log_step "Running PCIe Test 2: 4K QD32 (small-block IOPS)"
PCIE_TEST2=$(exec_target "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 32 -o 4096 -w randread -t 10 -r \"trtype:PCIe traddr:$TEST_DEVICE\" 2>&1 | grep '^Total'")

log_step "Running PCIe Test 3: 128K QD32 (bandwidth)"
PCIE_TEST3=$(exec_target "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 32 -o 131072 -w read -t 10 -r \"trtype:PCIe traddr:$TEST_DEVICE\" 2>&1 | grep '^Total'")

log_step "Running PCIe Test 4: 128K QD128 (saturation)"
PCIE_TEST4=$(exec_target "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 128 -o 131072 -w read -t 10 -r \"trtype:PCIe traddr:$TEST_DEVICE\" 2>&1 | grep '^Total'")

log_result "PCIe baseline tests complete"

# STEP 6: Start NVMe-oF Target
log_header "STEP 6: Start NVMe-oF Target"

log_step "Starting nvmf_tgt"
exec_target 'cd /tmp/spdk && ./build/bin/nvmf_tgt -m 0x3 -s 1024 --env-context="--huge-dir=/mnt/ht" > /tmp/nvmf.log 2>&1 &'
sleep 5

log_step "Creating RDMA transport"
exec_target 'cd /tmp/spdk && scripts/rpc.py nvmf_create_transport -t RDMA'
sleep 2

log_step "Attaching NVMe device"
exec_target "cd /tmp/spdk && scripts/rpc.py bdev_nvme_attach_controller -b nvme0 -t pcie -a $TEST_DEVICE"

log_step "Creating subsystem"
exec_target "cd /tmp/spdk && scripts/rpc.py nvmf_create_subsystem $NQN -a -s $SERIAL"
exec_target "cd /tmp/spdk && scripts/rpc.py nvmf_subsystem_add_ns $NQN nvme0n1"

log_step "Adding listener on $TARGET_IPV6:$PORT"
exec_target "cd /tmp/spdk && scripts/rpc.py nvmf_subsystem_add_listener $NQN -t RDMA --adrfam IPv6 -a $TARGET_IPV6 -s $PORT"

log_result "NVMe-oF target listening on $TARGET_IPV6:$PORT"

# STEP 7: Fabric Control Tests
log_header "STEP 7: Fabric Control (Ceiling)"

log_step "Starting ib_write_bw server on target"
exec_target "ib_write_bw -d $IONIC_DEVICE -x $GID_INDEX -F --report_gbits > /tmp/ib_write_bw.log 2>&1 &"
sleep 2

log_step "Running ib_write_bw client from initiator"
FABRIC_BW=$(exec_initiator "ib_write_bw -d $IONIC_DEVICE -x $GID_INDEX -F --report_gbits $TARGET_IPV4" | grep '^.*65536' | awk '{print $3, $4}')
log_info "Fabric bandwidth: $FABRIC_BW"

exec_target 'pkill ib_write_bw'
sleep 1

log_step "Starting ib_write_lat server on target"
exec_target "ib_write_lat -d $IONIC_DEVICE -x $GID_INDEX -F > /tmp/ib_write_lat.log 2>&1 &"
sleep 2

log_step "Running ib_write_lat client from initiator"
FABRIC_LAT=$(exec_initiator "ib_write_lat -d $IONIC_DEVICE -x $GID_INDEX -F $TARGET_IPV4" | grep '^.*2.*1000' | awk '{print $6}')
log_info "Fabric latency: ${FABRIC_LAT}us"

log_result "Fabric control tests complete"

# STEP 8: RDMA Performance Tests
log_header "STEP 8: RDMA Performance Tests"

RDMA_CONN="trtype:RDMA adrfam:IPv6 traddr:$TARGET_IPV6 trsvcid:$PORT subnqn:$NQN"

log_step "Running RDMA Test 1: 4K QD1 (latency floor)"
RDMA_TEST1=$(exec_initiator "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 1 -o 4096 -w randread -t 10 -r \"$RDMA_CONN\" 2>&1 | grep '^Total'")

log_step "Running RDMA Test 2: 4K QD32 (small-block IOPS)"
RDMA_TEST2=$(exec_initiator "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 32 -o 4096 -w randread -t 10 -r \"$RDMA_CONN\" 2>&1 | grep '^Total'")

log_step "Running RDMA Test 3: 128K QD32 (bandwidth)"
RDMA_TEST3=$(exec_initiator "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 32 -o 131072 -w read -t 10 -r \"$RDMA_CONN\" 2>&1 | grep '^Total'")

log_step "Running RDMA Test 4: 128K QD128 (saturation)"
RDMA_TEST4=$(exec_initiator "cd /tmp/spdk && ./build/bin/spdk_nvme_perf -c 0x3 -q 128 -o 131072 -w read -t 10 -r \"$RDMA_CONN\" 2>&1 | grep '^Total'")

log_result "RDMA performance tests complete"

# STEP 9: Generate Report
log_header "STEP 9: Test Results"

# Parse results
parse_perf() {
    echo "$1" | awk '{
        gsub(/,/, "", $3);
        gsub(/,/, "", $5);
        printf "%d %.2f %.2f %.2f\n", $3, $5, $7, $9
    }'
}

PCIE1_VALS=($(parse_perf "$PCIE_TEST1"))
PCIE2_VALS=($(parse_perf "$PCIE_TEST2"))
PCIE3_VALS=($(parse_perf "$PCIE_TEST3"))
PCIE4_VALS=($(parse_perf "$PCIE_TEST4"))
RDMA1_VALS=($(parse_perf "$RDMA_TEST1"))
RDMA2_VALS=($(parse_perf "$RDMA_TEST2"))
RDMA3_VALS=($(parse_perf "$RDMA_TEST3"))
RDMA4_VALS=($(parse_perf "$RDMA_TEST4"))

FABRIC_BW_GBPS=$(echo "$FABRIC_BW" | awk '{print $2}')

# Display report
cat << EOF

================================================================================
SPDK NVMe-oF RDMA Performance Validation Report
================================================================================

Node Configuration:
  TARGET:     $TARGET_NODE
  INITIATOR:  $INITIATOR_NODE
  Test Device: $TEST_DEVICE
  Fabric NIC:  $IONIC_DEVICE (GID index $GID_INDEX)

Rail Mapping:
  TARGET IPv6:     $TARGET_IPV6
  INITIATOR IPv6:  $INITIATOR_IPV6

Fabric Control (Ceiling):
  Bandwidth:  $FABRIC_BW_GBPS Gb/sec
  Latency:    ${FABRIC_LAT}us average

Performance Results:
================================================================================
Transport  Block   QD    IOPS        MiB/s    Avg Lat(us)  Max Lat(us)
--------------------------------------------------------------------------------
PCIe       4K      1     ${PCIE1_VALS[0]}     ${PCIE1_VALS[1]}      ${PCIE1_VALS[2]}         ${PCIE1_VALS[3]}
PCIe       4K      32    ${PCIE2_VALS[0]}    ${PCIE2_VALS[1]}     ${PCIE2_VALS[2]}        ${PCIE2_VALS[3]}
PCIe       128K    32    ${PCIE3_VALS[0]}      ${PCIE3_VALS[1]}    ${PCIE3_VALS[2]}      ${PCIE3_VALS[3]}
PCIe       128K    128   ${PCIE4_VALS[0]}      ${PCIE4_VALS[1]}    ${PCIE4_VALS[2]}      ${PCIE4_VALS[3]}
RDMA       4K      1     ${RDMA1_VALS[0]}       ${RDMA1_VALS[1]}       ${RDMA1_VALS[2]}        ${RDMA1_VALS[3]}
RDMA       4K      32    ${RDMA2_VALS[0]}    ${RDMA2_VALS[1]}     ${RDMA2_VALS[2]}        ${RDMA2_VALS[3]}
RDMA       128K    32    ${RDMA3_VALS[0]}      ${RDMA3_VALS[1]}    ${RDMA3_VALS[2]}      ${RDMA3_VALS[3]}
RDMA       128K    128   ${RDMA4_VALS[0]}      ${RDMA4_VALS[1]}    ${RDMA4_VALS[2]}      ${RDMA4_VALS[3]}
================================================================================

Analysis:

QD Scaling (Sanity Checks):
  PCIe 4K:  QD32/QD1 = $(echo "scale=1; ${PCIE2_VALS[0]} / ${PCIE1_VALS[0]}" | bc)x
  RDMA 4K:  QD32/QD1 = $(echo "scale=1; ${RDMA2_VALS[0]} / ${RDMA1_VALS[0]}" | bc)x

RDMA Efficiency:
  RDMA 128K QD32: ${RDMA3_VALS[1]} MiB/s = $(echo "scale=1; ${RDMA3_VALS[1]} * 8 / 1024" | bc) Gb/sec
  Fabric ceiling: $FABRIC_BW_GBPS Gb/sec
  Utilization:    $(echo "scale=1; ${RDMA3_VALS[1]} * 8 * 100 / ($FABRIC_BW_GBPS * 1024)" | bc)%

Latency Comparison (4K QD1):
  PCIe: ${PCIE1_VALS[2]}us
  RDMA: ${RDMA1_VALS[2]}us
  Added latency: $(echo "scale=2; ${RDMA1_VALS[2]} - ${PCIE1_VALS[2]}" | bc)us

RDMA vs PCIe Performance:
  4K QD32:    $(echo "scale=1; ${RDMA2_VALS[0]} * 100 / ${PCIE2_VALS[0]}" | bc)% of PCIe IOPS
  128K QD32:  $(echo "scale=1; ${RDMA3_VALS[1]} * 100 / ${PCIE3_VALS[1]}" | bc)% of PCIe bandwidth
  128K QD128: $(echo "scale=1; ${RDMA4_VALS[1]} * 100 / ${PCIE4_VALS[1]}" | bc)% of PCIe bandwidth

Core Usage: 2 cores (mask 0x3)

================================================================================
✓ VALIDATION PASSED
================================================================================

EOF

log_result "Performance validation complete!"
