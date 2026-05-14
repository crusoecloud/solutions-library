# TorchTitan Pretraining benchmark as a PyTorchJob on Crusoe Managed Kubernetes

This example runs a two-node, 16-GPU pre-training job for Meta's Llama 3.1 8B model using [TorchTitan](https://github.com/crusoecloud/torchtitan) on Crusoe Managed Kubernetes, orchestrated via the [Kubeflow Training Operator](https://github.com/kubeflow/training-operator) `PyTorchJob` CRD. The intention is to make it simple to run TorchTitan benchmarking directly on a Crusoe Managed Kubernetes cluster without having to set up any Slurm capabilities (the standard TorchTitan examples are all Slurm-based). The job can easily be adapted to run on larger models such as Llama 3.1 70B (although the size of GPU cluster available to you will dictate your choice here).

## Quick Start

1. Set up the prerequisites: A Crusoe Managed Kubernetes cluster with a nodepool containing one or more Hopper or Blackwell GPU nodes, Kubeflow training operator V1 and (optionally) CSI for shared disk and a storage class installed.
2. Check that Nvidia GPU Operator is successfully installed and running ('kubectl -n nvidia-gpu-operator' should show all pods in Running or Completed state).
3. Clone this repo and cd into the resulting directory, then edit either the '-streamingdata' or the '-localdata' variant of the PyTorchJob to suit your GPU type (topology filename and Mellanox interfaces)  - and huggingface token if using the streaming option - see reference below.
4. The -streamingdata variant of the job streams the c4 dataset direct from Huggingface as the job runs. To run this option, ```kubectl apply -f torchtitan-llama3-8b-streamingdata.yaml``` and tail the logs of the master pod to follow job progress.
5. The '-localdata' variant of the job reads the training data from a local PVC as the job runs. So first of all, run ```kubectl apply -f setup-local-c4-datavol.yaml``` which creates the PVC and copies the data onto it from Huggingface using GIT LFS (it will take at least several minutes to download the c4/en dataset from Huggingface to the PVC). When the downloader job is complete, ```kubectl apply -f torchtitan-llama3-8b-localdata.yaml``` then tail the logs of the master pod to see progress of the Torchtitan job. You can also kubectl exec inside any of the Pytorchjob pods to see the contents of the outputs directory (checkpoints etc).

The yaml files in the repo specify a prebuilt version of the same container image described in the Dockerfile. You can edit the Dockerfile to suit your own needs, push it to your registry and update the YAML files to use your new image.

Note: if Autoscaling is enabled on your cluster, you might appear to have fewer running CMK nodes than your reservation allows for. Run the job anyway, configured to use your expected number of nodes, and the autoscaler will create additional nodes as needed up to the limit of your capacity. It takes approx 10 minutes for a new node to be created and the Nvidia GPU Operator pods to start up, so it will take at least that long for your job to start up in this scenario.

## Topology filenames and Infiniband interfaces for different Crusoe GPU SKUs

### Topology files  
```
a100-80gb-sxm-ib-cloud-hypervisor.xml  
a100-80gb-sxm-ib-qemu.xml  
b200-180gb-sxm-ib-cloud-hypervisor.xml  
b300-288gb-sxm-ib-cloud-hypervisor.xml  
h100-80gb-sxm-ib-cloud-hypervisor.xml  
h100-80gb-sxm-ib-qemu.xml  
h200-141gb-sxm-ib-cloud-hypervisor.xml  
```
### Mellanox/IB interfaces
**H100, H200:** mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8  
**B200, B300:** mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_12

## What is TorchTitan?

[TorchTitan](https://arxiv.org/html/2410.06511v1) is an open-source, PyTorch-native framework for large language model pre-training at scale. Its central design goal is **composable N-D parallelism**: it lets you freely combine Fully Sharded Data Parallelism (FSDP2), Tensor Parallelism (TP), and Pipeline Parallelism (PP) into 1D, 2D, or 3D configurations by expressing all sharding through PyTorch's `DTensor` and `DeviceMesh` abstractions. This means the same codebase scales from a single node up to thousands of GPUs without requiring framework-specific extensions or patched model code.

Beyond parallelism, TorchTitan ships production-ready training infrastructure out of the box: distributed checkpointing via PyTorch Distributed Checkpoint (DCP), `torch.compile` integration for graph-level kernel fusion, asynchronous Tensor Parallel communication overlap via `SymmetricMemory`, and Float8 mixed-precision support for Blackwell-generation hardware. A built-in Flight Recorder captures NCCL collective metadata, making it practical to diagnose hangs and timeouts in large clusters without attaching a debugger.

The paper benchmarks TorchTitan at 65% MFU training Llama 3.1 8B on 128 H100 GPUs with 1D FSDP, rising further with 2D and 3D parallelism on larger models. Its PyTorch-native architecture keeps the dependency footprint minimal — no Megatron-LM, no custom C++ extensions — so it integrates cleanly with standard Python tooling, containerised environments, and Kubernetes-native orchestration.

## Why Kubernetes-native training?

Running distributed GPU training as a Kubernetes `PyTorchJob` rather than bare `torchrun` on VMs gives you:

- **Fault tolerance** — `restartPolicy: OnFailure` on each replica automatically restarts crashed workers and re-joins them to the rendezvous without manual intervention.
- **Resource isolation** — GPU, CPU, and memory limits are enforced by the scheduler; jobs queue cleanly and do not interfere with each other.
- **Declarative configuration** — training hyperparameters, parallelism settings, and NCCL tuning are captured in a versioned YAML and a `ConfigMap`-mounted TOML, making runs reproducible and auditable.
- **Cluster-aware scheduling** — the Training Operator co-schedules all replicas as a gang, so Master and Worker pods always land on separate nodes with InfiniBand connectivity.
- **Operational consistency** — the same `kubectl apply` workflow used for inference, serving, and data pipelines also manages training jobs.
- **No Slurm required** — TorchTitan's own documentation describes a Slurm-based launch path for multi-node jobs. Running it as a `PyTorchJob` replaces that entirely: the Training Operator handles rendezvous, rank assignment, and worker lifecycle natively in Kubernetes. There is no need to install or operate a Slurm cluster alongside Kubernetes to run TorchTitan at scale.

## Files

| File | Purpose |
|---|---|
| [Dockerfile](Dockerfile) | Builds the training container image |
| [torchtitan-llama3-8b-streamingdata.yaml](torchtitan-llama3-8b-streamingdata.yaml) | PyTorchJob that streams the C4 dataset from Hugging Face at runtime |
| [torchtitan-llama3-8b-localdata.yaml](torchtitan-llama3-8b-localdata.yaml) | PyTorchJob that reads C4 from a pre-populated persistent volume |
| [setup-local-c4-datavol.yaml](setup-local-c4-datavol.yaml) | One-time Job + PVC that downloads the C4 dataset for the local-data variant |

---

## Dockerfile

The image is built from the NVIDIA NGC PyTorch base image (`nvcr.io/nvidia/pytorch:26.03-py3`), which ships with pre-compiled CUDA, cuDNN, NCCL, and PyTorch. On top of that:

1. **System packages** — `git`, `infiniband-diags`, `wget`, and TLS certificates are installed for network-aware debugging and secure fetches.
2. **TorchTitan source** — the Crusoe-maintained fork is cloned at the pinned `release-v0.2.2` tag into `/workspace/torchtitan`. This release is the latest version of TorchTitan that still supports the toml-based job configuration format.
3. **Python dependencies** — `torchdata`, `datasets`, `tokenizers`, and supporting libraries are installed. A nightly `torchtitan` wheel is pulled from PyTorch's CUDA 13.0 nightly index.
4. **Tokenizer assets** — the Llama 3.1 8B tokenizer and model config are downloaded from Hugging Face **at build time** using a [BuildKit secret](https://docs.docker.com/build/building/secrets/). The token is never written into an image layer.

### Building the image

```bash
export HF_TOKEN=hf_...   # your Hugging Face token with Llama 3.1 access

DOCKER_BUILDKIT=1 docker build \
  --secret id=hf_token,env=HF_TOKEN \
  -t <YOUR_REGISTRY>/torchtitan-llama3-8b:latest .

docker push <YOUR_REGISTRY>/torchtitan-llama3-8b:latest
```

Update the `image:` field in both PyTorchJob manifests to point to your registry.

---

## PyTorchJob: streaming data (`torchtitan-llama3-8b-streamingdata.yaml`)

This manifest is **self-contained** — no data volume setup is required. The training process streams the C4 dataset directly from Hugging Face's dataset hub at runtime using the `datasets` library.

**When to use:** quick experiments, jobs where you do not want to manage a data volume, or environments where egress to Hugging Face is available throughout training.

**Requirements:**
- Set `HF_TOKEN` in the `env:` block for both Master and Worker to your Hugging Face token. The placeholder `<YOUR HF TOKEN HERE>` must be replaced before applying the manifest. For production use, source this from a Kubernetes `Secret` instead of a plaintext value.

**Apply:**
```bash
kubectl apply -f torchtitan-llama3-8b-streamingdata.yaml
```

---

## PyTorchJob: local data (`torchtitan-llama3-8b-localdata.yaml`)

This variant reads the C4 dataset from a `PersistentVolumeClaim` (`data-disk`) mounted at `/data/c4`. The dataset must be pre-downloaded before the first training run.

**When to use:** repeated training runs where you want to avoid re-downloading hundreds of gigabytes each time, or air-gapped environments without outbound internet access during training.

### Step 1 — populate the data volume

`setup-local-c4-datavol.yaml` creates:
- A `100Ti` `ReadWriteMany` `PersistentVolumeClaim` named `data-disk` backed by `crusoe-csi-driver-fs-sc` (Crusoe's distributed filesystem storage class).
- A one-time Kubernetes `Job` (`c4-dataset-download`) that uses `git lfs` to clone the full C4 English split from Hugging Face into `/data/c4`.

```bash
kubectl apply -f setup-local-c4-datavol.yaml

# Wait for the download job to complete (this transfers ~300GB and may take 30–60 minutes)
kubectl wait --for=condition=complete job/c4-dataset-download --timeout=3600s
```

### Step 2 — run the training job

```bash
kubectl apply -f torchtitan-llama3-8b-localdata.yaml
```

---

## Training configuration

Both jobs inject a TOML configuration file via a `ConfigMap`. Key training settings:

| Setting | Value | Notes |
|---|---|---|
| Model | Llama 3.1 8B | Tokenizer baked into image |
| Sequence length | 8192 tokens | |
| Local batch size | 1 | Per GPU |
| Steps | 1000 | Extend for real training runs |
| Parallelism | 16-way FSDP | `data_parallel_shard_degree = -1` across both nodes |
| Checkpointing | Every 500 steps | Saved to `/outputs/checkpoint` |
| TensorBoard | Enabled | Logs to `/outputs/tb` |

> **Note:** The `outputs` volume is an `emptyDir`, meaning checkpoints are lost if the pod is deleted. For production runs, replace it with a `PersistentVolumeClaim`.

---

## Adapting for Crusoe GPU SKU types

The two NCCL environment variables that must be tuned per SKU are `NCCL_IB_HCA` and `NCCL_TOPO_FILE`. Both appear in the `env:` block of the Master and Worker containers and must match on every replica.

On **Blackwell SKUs only (B200/B300)**, you may additionally need to re-add `NCCL_IB_GID_INDEX=3` (and optionally `NCCL_NET_GDR_LEVEL=SYS`) if you see NCCL transport warnings. These variables were previously set by default but caused a **~10× MFU degradation on H100/H200 native InfiniBand**, so they have been removed from the default manifests. See the per-SKU sections below.

### `NCCL_TOPO_FILE`

Crusoe nodes ship with pre-generated NCCL topology XML files under `/etc/crusoe/nccl_topo/`. The manifests mount this directory as a `hostPath` volume at `/opt/nccl_topo`. Set `NCCL_TOPO_FILE` to the correct filename for your node type. To discover available files:

```bash
# SSH to a worker node, or run in a privileged pod:
ls /etc/crusoe/nccl_topo/
```

### `NCCL_IB_HCA`

This tells NCCL which InfiniBand HCAs to use for inter-node communication. The correct value depends on how the HCA ports are enumerated on each SKU.

---

### H100 (80 GB SXM5)

```yaml
- name: NCCL_IB_HCA
  value: "^mlx5_0"          # exclude the first port; use all remaining IB HCAs
- name: NCCL_TOPO_FILE
  value: /opt/nccl_topo/<h100-topo-filename>.xml
```

Run `ibstat -v` on a node to confirm port enumeration and select the matching topology file from `/etc/crusoe/nccl_topo/`.

**Memory:** 80 GB per GPU (640 GB per 8-GPU node). The default `local_batch_size = 1` and `seq_len = 8192` are well-suited for this SKU.

**Native IB note:** the default manifests do **not** set `NCCL_IB_GID_INDEX` or `NCCL_NET_GDR_LEVEL`. Both are intentionally omitted because Crusoe H100 nodes use native InfiniBand (GID index 0), where the previously-shipped value of `NCCL_IB_GID_INDEX=3` forced a RoCE-flavoured codepath and caused a ~10× slowdown. Do not re-add them on H100.

---

### H200 (141 GB SXM5)

```yaml
- name: NCCL_IB_HCA
  value: "^mlx5_0"          # same exclusion pattern as H100
- name: NCCL_TOPO_FILE
  value: /opt/nccl_topo/<h200-topo-filename>.xml
```

**Memory:** 141 GB per GPU (1.1 TB per 8-GPU node). The additional HBM3e headroom lets you increase `seq_len` (e.g. 16384 or 32768) or `local_batch_size` without triggering OOM. Consider enabling `torch.compile` (`[compile] enable = true`) and float8 FSDP all-gather (`enable_fsdp_float8_all_gather = true`) to improve throughput.

**Native IB note:** same as H100 — the default manifests intentionally omit `NCCL_IB_GID_INDEX` and `NCCL_NET_GDR_LEVEL` for H200 native IB. Do not re-add them.

**Sizing example for small clusters:** at 16 GPUs (2 nodes), the README's headline 53% MFU baseline is achievable with `local_batch_size = 2`, `[compile] enable = true`, and no activation checkpointing — peaks around ~52% MFU, ~8,800 tps/GPU, with HBM at ~62%. `local_batch_size = 4` requires activation checkpointing at this scale because per-GPU FSDP shards are 8× larger than the 128-GPU baseline.

---

### B200 (192 GB SXM)

```yaml
- name: NCCL_IB_HCA
  value: "mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_12"
- name: NCCL_TOPO_FILE
  value: /opt/nccl_topo/<b200-topo-filename>.xml
```

**Memory:** 192 GB per GPU (1.5 TB per 8-GPU node). The explicit HCA list is used on Blackwell nodes (rather than the exclusion syntax used on Hopper). Verify the port list with `ibstat -v`. The large HBM capacity enables longer sequences and larger batches; you may also want to experiment with tensor parallelism (`tensor_parallel_degree = 2` or `4`) to better utilize NVLink bandwidth.

**Blackwell GID note:** if you observe NCCL transport warnings or unexpectedly low MFU on B200, re-add the following env vars to both Master and Worker (they were removed from the defaults because they are wrong on H100/H200):

```yaml
- name: NCCL_IB_GID_INDEX
  value: "3"
- name: NCCL_NET_GDR_LEVEL
  value: "SYS"
```

---

### B300 (288 GB SXM) — default in this example

```yaml
- name: NCCL_IB_HCA
  value: "mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_12"
- name: NCCL_TOPO_FILE
  value: /opt/nccl_topo/b300-288gb-sxm-ib-cloud-hypervisor.xml
```

**Memory:** 288 GB per GPU (2.3 TB per 8-GPU node). The manifests in this repo are configured for B300 out of the box. The enormous HBM capacity makes it practical to train much larger models without activation checkpointing; for Llama 3.1 8B you can increase `local_batch_size` substantially or train longer sequences. Float8 linear layers (`enable_fsdp_float8_all_gather = true`, `precompute_float8_dynamic_scale_for_fsdp = true`) are recommended on Blackwell to exploit the native FP8 tensor cores.

**Blackwell GID note:** same as B200 — if you observe NCCL transport warnings or unexpectedly low MFU on B300, re-add `NCCL_IB_GID_INDEX=3` and `NCCL_NET_GDR_LEVEL=SYS` to both Master and Worker. They were removed from the defaults because they cause a ~10× slowdown on H100/H200 native IB.

---

### GB200 NVL72

The GB200 NVL72 is a rack-scale system: 36 Grace CPU sockets and 72 B200 GPUs connected by NVLink Switch chips, forming a single flat NVLink domain. This changes several assumptions:

**Node count and GPU count:** A single NVL72 rack can be addressed as a single "super-node" of 72 GPUs or as multiple smaller logical nodes depending on how Crusoe partitions them. Adjust `--nnodes`, `--nproc_per_node`, and the `replicas` count accordingly.

**Parallelism:** With a 72-GPU NVLink domain, tensor parallelism (`tensor_parallel_degree`) and pipeline parallelism (`pipeline_parallel_degree`) can be increased significantly beyond what is practical with IB-only connectivity. For an 8B model you may prefer pure FSDP, but larger models benefit from combined TP + PP + FSDP (3D parallelism).

**NCCL topology and HCA:** Verify the available topology files and HCA enumeration on the specific GB200 partition you are allocated.

```yaml
- name: NCCL_IB_HCA
  value: "<verify with ibstat -v on GB200 node>"
- name: NCCL_TOPO_FILE
  value: /opt/nccl_topo/<gb200-topo-filename>.xml
```

**`dshm` size:** The 20 Gi shared memory limit in the manifests is conservative. On high-core-count Grace CPUs with large collective buffers, consider increasing `sizeLimit` to 64 Gi or more.

---

## Monitoring

```bash
# Watch pod status
kubectl get pods -l job-name=torchtitan-llama3-8b -w

# Tail Master logs
kubectl logs -f $(kubectl get pods -l training.kubeflow.org/job-name=torchtitan-llama3-8b,training.kubeflow.org/replica-type=master -o name)
```

TensorBoard logs are written to `/outputs/tb` inside the container. Forward the port or mount a persistent volume at `/outputs` to access them externally.

## References

- [TorchTitan (Crusoe fork)](https://github.com/crusoecloud/torchtitan)
- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator)
- [Crusoe Cloud Kubernetes documentation](https://docs.crusoe.ai)
- [NCCL environment variable reference](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html)
