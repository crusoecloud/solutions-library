# Example CMK 'playpen' workload for Crusoe AMD MI355X nodes

A stateful set of pods based on AMD's rocm/roce-workload:ubuntu24_rocm-7.0.2_rccl-7.0.2_anp-v1.2.0_ainic-1.117.1-a-63 image with a front-end SSH service on external load balancer. The pods have MPI installed and SSH configured for distributed training. launch-distributed.sh starts a simple distributed pytorch job using RCCL and GPU Direct RDMA.

**Prerequisites:** a working CMK cluster with at least 2 AMD MI355X nodes in Ready state, CSI drivers installed, and Load Balancer Helm chart from https://github.com/crusoecloud/crusoe-load-balancer-controller-helm-charts. (if you just have 1 node, that's fine for creating the playpen but train-distributed.py won't work).

## Quick start

From your local copy of this directly, ensure that your current Kubernetes context points at your target cluster and that its AMD MD355X nodepool is Ready.
Run `install.sh` to create the pods and run the test workload.

---

## Using the workload pods

### 1. SSH into a pod

Get the external IP for a pod:

```bash
kubectl get svc rocm-workload-0-ssh rocm-workload-1-ssh
```

Then connect as `clouduser`:

```bash
ssh clouduser@<EXTERNAL-IP>
```

### 2. Install uv

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### 3. Create a virtual environment

```bash
uv venv
```

### 4. Activate the virtual environment

```bash
source .venv/bin/activate
```

### 5. Install PyTorch for ROCm 7.2

```bash
uv pip install \
    "torch==2.13.0+rocm7.2" \
    "torchvision==0.28.0+rocm7.2" \
    "torchaudio==2.11.0+rocm7.2" \
    "triton-rocm==3.7.1" \
    --index-url https://download-r2.pytorch.org/whl/rocm7.2
```

### 6. Run the training script

```bash
torchrun --standalone --nproc_per_node=8 train.py
```

### Verify GPU visibility

To confirm that all 8 AMD GPUs in the pod are visible to PyTorch:

```bash
python -c "import torch; print('Version:', torch.__version__); print('HIP:', torch.version.hip); print('GPUs:', torch.cuda.device_count())"
```
