# ROCm GPU Workload

This repo contains scripts and manifests for deploying ROCm-based GPU workload pods on a Kubernetes cluster (Crusoe Cloud).

## Files

### `install.sh`
Run this once to bootstrap the workload on the cluster. It:
1. Creates a ConfigMap from `pod-setup.sh` so each pod can run it at startup
2. Applies the Crusoe shared filesystem StorageClass (used for the persistent `/home` volume)
3. Applies `rocm-gpu-workload.yaml` to create the PVC, SSH ConfigMap, and workload pods
4. Waits for `rocm-workload-0` to be ready, then copies `train.py` into `/home/clouduser/`

### `pod-setup.sh`
Startup script that runs inside each pod on launch. It:
- Expands `/dev/shm` to 16 GB for RCCL/NCCL multi-GPU shared memory
- Installs and configures `openssh-server`
- Creates the `clouduser` account (uid 1010) with a persistent home directory on the shared PVC
- Adds `clouduser` to the `video`, `render`, and `kfd` groups for GPU device access
- Grants `clouduser` passwordless sudo
- Starts `sshd` and keeps the container alive

### `rocm-gpu-workload.yaml`
Kubernetes manifest that deploys the full workload. It creates:
- A **Secret** containing the authorized SSH public keys
- A **ConfigMap** with the `sshd_config`
- A **PersistentVolumeClaim** (`rocm-home`) — a 10 TiB shared ReadWriteMany filesystem mounted at `/home` across all pods
- A **StatefulSet** (`rocm-workload`) with 2 replicas, each requesting 8 AMD GPUs, 96 CPU cores, and 768 GiB RAM
- A headless **Service** for pod DNS within the StatefulSet
- Individual **LoadBalancer Services** for SSH access to each pod (`rocm-workload-0-ssh`, `rocm-workload-1-ssh`)

### `train.py`
A PyTorch training script. It is copied into `/home/clouduser/train.py` on the shared PVC by `install.sh`, making it available in every pod.

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
