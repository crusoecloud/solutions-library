# NCCL Tests on Crusoe Managed Kubernetes (B300 Nodepool)

End-to-end guide for running an `all_reduce_perf` NCCL benchmark across multiple B300 nodes using the Kubeflow Training Operator MPIJob API.

---

## Prerequisites

- An existing Crusoe Managed Kubernetes (CMK) cluster with a B300 nodepool
- `kubectl` configured to talk to that cluster (`kubectl get nodes` returns your B300 nodes)
- The nodes are labeled/tainted correctly so that GPU workloads land there (CMK does this by default)

---

## 1. Install the Kubeflow Training Operator

Apply the standalone overlay directly from the upstream repo:

```bash
kubectl apply --server-side -k \
  "github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.8.1"
```

This creates the `kubeflow` namespace and deploys the Training Operator controller, which adds support for MPIJob (and other job types) to your cluster.

### Verify the operator is running

```bash
kubectl get pods -n kubeflow
```

Expected output (controller pod should be `Running`):

```
NAME                                   READY   STATUS    RESTARTS   AGE
training-operator-<hash>               1/1     Running   0          60s
```

Wait until `READY` is `1/1` before proceeding.

---

## 2. (Optional) Build a custom image

The job uses a pre-built image (`abesharphpe/nccl-tests-b300:latest`) that bundles:

- CUDA 12.8 + NCCL
- OpenMPI with SSH transport
- `nccl-tests` compiled for B300 (`sm_100`)
- The B300 topology file (`b300-288gb-sxm-ib-cloud-hypervisor.xml`)

If you want to push to your own registry:

```bash
docker build -t <YOUR_REGISTRY>/nccl-tests-b300:latest -f Dockerfile .
docker push <YOUR_REGISTRY>/nccl-tests-b300:latest
```

Then update the `image:` fields in `run-nccl-test.sh` (or `nccl-test.yaml`) before submitting.

---

## 3. Submit the NCCL test

Use the helper script, passing the number of B300 worker nodes you want to use:

```bash
chmod +x run-nccl-test.sh
./run-nccl-test.sh <NUM_NODES>
```

**Example — 4-node run (32 GPUs):**

```bash
./run-nccl-test.sh 4
```

The script calculates `TOTAL_GPUS = NUM_NODES × 8`, names the job accordingly (e.g. `nccl-tests-gdr-32-b300`), and applies the MPIJob manifest to the cluster.

What the test runs:

```
all_reduce_perf -b 2G -e 32G -f 2 -t 1 -g 1 -c 1 -n 100
```

This sweeps message sizes from **2 GB to 32 GB** (doubling each step), running **100 iterations** per size — a thorough bandwidth characterization.

---

## 4. Monitor progress

Watch pods come up:

```bash
kubectl get pods -l training.kubeflow.org/job-name=nccl-tests-gdr-<TOTAL_GPUS>-b300 -w
```

You will see one launcher pod and `NUM_NODES` worker pods. All workers start first; the launcher begins after SSH connectivity is established (the 5-second init container provides a small delay).

Stream live launcher output:

```bash
kubectl logs -f \
  $(kubectl get pods \
      -l training.kubeflow.org/job-name=nccl-tests-gdr-<TOTAL_GPUS>-b300,training.kubeflow.org/replica-type=launcher \
      -o name)
```

The job is complete when the launcher pod transitions to `Completed`.

---

## 5. Retrieve results

```bash
kubectl logs \
  $(kubectl get pods \
      -l training.kubeflow.org/job-name=nccl-tests-gdr-<TOTAL_GPUS>-b300,training.kubeflow.org/replica-type=launcher \
      -o name)
```

---

## 6. Interpret the output

NCCL test output has a header followed by one row per message size:

```
#                                                              out-of-place                       in-place
#       size         count    type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                             (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
  2147483648     536870912   float     sum      -1   5432.1  395.3   741.2      0   5429.8  395.5   741.5      0
  4294967296    1073741824   float     sum      -1   9801.0  438.2   821.7      0   9796.4  438.4   822.1      0
...
```

### Key columns

| Column | Meaning |
|--------|---------|
| `size` | Message size in bytes |
| `time` | Measured latency in microseconds |
| `algbw` | Algorithm bandwidth: `size / time` — raw data moved per second |
| `busbw` | Bus bandwidth: `algbw × 2(N-1)/N` — effective interconnect utilization accounting for all-reduce communication pattern |
| `#wrong` | Number of verification errors — should always be `0` |

### What to look for

- **`busbw`** is the primary health metric. It accounts for the theoretical traffic pattern of an all-reduce and is directly comparable across different cluster sizes. On a B300 cluster with InfiniBand, healthy `busbw` at large message sizes (16 GB–32 GB) is the key indicator of full rail utilization.
- **`#wrong > 0`** indicates a correctness failure — stop and investigate before using the cluster for training.
- **Scaling efficiency**: compare `algbw` at the same message size across different `NUM_NODES` runs. Near-linear scaling indicates a healthy fabric.
- **Small message latency** (rows at the top of the table, 2 GB range) is typically dominated by latency; focus on large-message rows for bandwidth health.

### Cleanup

```bash
kubectl delete mpijob nccl-tests-gdr-<TOTAL_GPUS>-b300
```
