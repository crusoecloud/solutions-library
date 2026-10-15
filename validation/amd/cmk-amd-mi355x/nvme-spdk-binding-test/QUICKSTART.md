# Quick Start - SPDK NVMe Binding Test

Get started in 5 minutes.

## Prerequisites

- `kubectl` configured for your CMK cluster
- MI355X nodepool with at least one `Ready` node
- Cluster-admin permissions

## Steps

### 1. Find an MI355X node

```bash
kubectl get nodes -l node.kubernetes.io/instance-type=a40.8x
```

Example output:
```
NAME                                         STATUS   ROLES    AGE   VERSION
your-mi355x-node-1.region.compute.internal   Ready    <none>   4h    v1.30.0
your-mi355x-node-2.region.compute.internal   Ready    <none>   4h    v1.30.0
```

### 2. Edit the pod manifest

Open `spdk-test-pod.yaml` and replace `YOUR-MI355X-NODE-NAME-HERE` with your node name:

```yaml
spec:
  nodeName: your-mi355x-node-1.region.compute.internal  # <-- Replace with your actual node name
```

### 3. Deploy the test pod

```bash
kubectl apply -f spdk-test-pod.yaml
kubectl wait --for=condition=Ready pod/spdk-test-privileged --timeout=60s
```

### 4. Run the automated test

```bash
./run-spdk-binding-test.sh
```

Expected output:
```
[INFO] STEP 1: Mapping NVMe topology...
[INFO] STEP 2: Loading vfio-pci kernel module...
[INFO] STEP 3: Setting up SPDK...
[INFO] STEP 4: Testing single device binding...
[INFO] STEP 5: Testing multiple device binding...
[INFO] STEP 6: Cleaning up...
[INFO] ✓ Test completed successfully!
```

### 5. Cleanup

```bash
kubectl delete -f spdk-test-pod.yaml
```

## What You Just Tested

✓ SPDK can bind NVMe devices to vfio-pci driver
✓ Mount detection protects containerd drive automatically
✓ Multiple devices can be bound simultaneously
✓ Device reset works correctly
✓ Node returns to original state

## Next Steps

- Read [README.md](./README.md) for full technical details
- Understand the safety mechanisms
- Learn about production deployment considerations

## Troubleshooting

**Pod stays in Pending:**
- Check node name is correct in `spdk-test-pod.yaml`
- Verify node is in `Ready` state

**Script fails at module loading:**
- Ensure pod has `privileged: true` set
- Check pod is running: `kubectl get pod spdk-test-privileged`

**"Permission denied" errors:**
- Verify you have cluster-admin permissions
- Check pod's securityContext includes all required capabilities

For more help, see the [README](./README.md) troubleshooting section.
