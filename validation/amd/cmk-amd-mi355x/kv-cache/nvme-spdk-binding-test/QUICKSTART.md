# Quick Start - SPDK Validation

Run either test with copy-paste commands. Start with Test 1 (2 min) for basic validation, then Test 2 (10-12 min) for complete RDMA stack.

---

## Test 1: Basic Device Binding (2 minutes)

### Commands
```bash
# 1. Get node name
NODE=$(kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x -o name | head -1 | cut -d/ -f2)
echo "Using node: $NODE"

# 2. Edit pod YAML and deploy
sed "s/YOUR-MI355X-NODE-NAME-HERE/$NODE/" spdk-test-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/spdk-test-privileged --timeout=60s

# 3. Run test
chmod +x run-spdk-binding-test.sh
./run-spdk-binding-test.sh

# 4. Cleanup
kubectl delete pod spdk-test-privileged
```

### Success Indicator
```
✓ Test completed successfully!
Summary:
  - Single device binding: ✓ PASS
  - Multiple device binding: ✓ PASS
  - Device reset: ✓ PASS
```

---

## Test 2: NVMe-oF RDMA (10-12 minutes)

### Commands
```bash
# 1. Get node name
NODE=$(kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x -o name | head -1 | cut -d/ -f2)
echo "Using node: $NODE"

# 2. Edit pod YAML and deploy
sed "s/YOUR-MI355X-NODE-NAME-HERE/$NODE/" spdk-nvmeof-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/spdk-nvmeof-test --timeout=120s

# 3. Run test (builds SPDK from source)
chmod +x run-spdk-nvmeof-rdma-test.sh cleanup-spdk-nvmeof.sh
./run-spdk-nvmeof-rdma-test.sh

# 4. Cleanup (REQUIRED!)
./cleanup-spdk-nvmeof.sh
kubectl delete pod spdk-nvmeof-test
```

### Success Indicator
```
✓ NVMe-oF RDMA Test Completed Successfully!
Test Results:
  ✓ Hugepage mmap validation: PASS
  ✓ Ionic RDMA provider: 8 devices
  ✓ Real NVMe device attachment: PASS
  ✓ RDMA listener: <ip>:4420
```

---

## What Each Test Validates

| Test 1 | Test 2 |
|--------|--------|
| vfio-pci binding | Everything in Test 1, plus: |
| Mount protection | Hugepage allocation |
| Device reset | SPDK build with RDMA |
| | 8× ionic RDMA NICs |
| | Real 3.8TB NVMe attachment |
| | NVMe-oF subsystem over RDMA |

**Duration:** Test 1 = ~2 min | Test 2 = ~10-12 min (SPDK build takes ~7 min)

---

## Prerequisites

- `kubectl` configured for CMK cluster
- MI355X node in `Ready` state (bundle 2.2+)
- Cluster-admin permissions

---

## Troubleshooting

**Pod won't start:**
```bash
kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x  # Verify nodes exist
kubectl describe pod <pod-name>  # Check why pod is pending
```

**Test 1 fails:**
```bash
kubectl exec spdk-test-privileged -- chroot /host lsblk | grep nvme  # Verify NVMe visible
```

**Test 2 build fails:**
```bash
kubectl logs spdk-nvmeof-test  # Check for errors
```

**Test 2 cleanup fails:**
```bash
kubectl exec spdk-nvmeof-test -- readlink /sys/bus/pci/devices/0003:00:05.0/driver
# Should show: ../../../bus/pci/drivers/nvme (not vfio-pci)
```

**Scripts not executable:**
```bash
chmod +x *.sh
```

---

## Full Documentation

- **Complete guide:** [README.md](README.md) - Hardware details, safety mechanisms, production considerations
- **Test 2 deep dive:** [NVMEOF-RDMA.md](NVMEOF-RDMA.md) - Technical details, performance testing, troubleshooting
- **Test results:** [RESULTS.md](RESULTS.md) - Validation history

---

## Manual Deployment (if sed not available)

**Test 1:**
1. Open `spdk-test-pod.yaml` in editor
2. Replace `YOUR-MI355X-NODE-NAME-HERE` with your node name
3. Save and run: `kubectl apply -f spdk-test-pod.yaml`

**Test 2:**
1. Open `spdk-nvmeof-pod.yaml` in editor
2. Replace `YOUR-MI355X-NODE-NAME-HERE` with your node name
3. Save and run: `kubectl apply -f spdk-nvmeof-pod.yaml`
