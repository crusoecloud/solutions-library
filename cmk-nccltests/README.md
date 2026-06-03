# NCCL Tests for Crusoe SKUs on CMK

This directory contains Kubernetes manifests for running [NCCL tests](https://github.com/NVIDIA/nccl-tests) on Crusoe Managed Kubernetes (CMK) clusters. Each manifest runs an `all_reduce_perf` benchmark as an `MPIJob` and is tuned for a specific Crusoe GPU SKU.

| File | SKU | GPUs per node |
|---|---|---|
| [nccl-b200.yaml](nccl-b200.yaml) | B200 180GB SXM | 8 |
| [nccl-gb200.yaml](nccl-gb200.yaml) | GB200 (NVL72) | 4 |
| [nccl-h100.yaml](nccl-h100.yaml) | H100 80GB SXM | 8 |
| [nccl-h200.yaml](nccl-h200.yaml) | H200 141GB SXM | 8 |

## Prerequisites

- A functional **Crusoe Managed Kubernetes (CMK)** cluster with GPU node pools provisioned for the target SKU.
- **MPI Operator** installed on the cluster. The manifests use `kubeflow.org/v2beta1 MPIJob`. Install via:
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/kubeflow/mpi-operator/master/deploy/v2beta1/mpi-operator.yaml
  ```
- For GB200: the **NVIDIA GPU Feature Discovery** and **Dynamic Resource Allocation (DRA)** components must be enabled, as the GB200 manifest uses `resource.nvidia.com/v1beta1 ComputeDomain`.
- `kubectl` configured to talk to your CMK cluster (`kubeconfig` set up).

## Usage

1. Choose the manifest for your SKU.
2. Adjust the `replicas` field under `Worker` to match the number of GPU nodes in your cluster.
3. For B200, H100, and H200, update `-np` in the launcher command to equal `<GPUs per node> × <worker replicas>` (e.g. `8 × 2 = 16`).
4. For GB200, update `-np` to equal `<slotsPerWorker> × <worker replicas>` (e.g. `4 × 36 = 144`).
5. Apply the manifest:
   ```bash
   kubectl apply -f nccl-<sku>.yaml
   ```
6. Watch progress:
   ```bash
   kubectl get pods -w
   kubectl logs -f <launcher-pod-name>
   ```
7. Clean up after the job completes:
   ```bash
   kubectl delete -f nccl-<sku>.yaml
   ```

## Configuration notes

- **Topology file**: B200, H100, and H200 jobs mount `/etc/crusoe/nccl_topo` from the host and set `NCCL_TOPO_FILE` to the SKU-specific XML. This path is pre-populated on Crusoe GPU nodes.
- **CUDA image**: B200 and H200 use `nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1`; H100 uses `nccl-tests:12.8.1-ubuntu24.04-nccl-2.26.5-1`. Both images are hosted at `ghcr.io/crusoecloud/nccl-tests`.