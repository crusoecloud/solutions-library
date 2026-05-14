# Serving HuggingFace Models on CMK with KServe

Deploy open-source LLMs from HuggingFace on Crusoe Managed Kubernetes (CMK) using [KServe](https://kserve.github.io/) and [vLLM](https://docs.vllm.ai/), from a single-GPU endpoint to disaggregated prefill-decode across heterogeneous GPU pools. Supports both NVIDIA and AMD GPU clusters.

## Features

- One command for full infrastructure + KServe setup (NVIDIA or AMD)
- One command to deploy HuggingFace model
  - Single-GPU LLM serving (Qwen2.5-0.5B on 1x H100, A100, MI300X, etc.)
  - Single-node multi-GPU inference (Qwen2.5-72B on 8x H100, TP=8)
  - Multi-node tensor-parallel inference (Qwen2.5-72B across 16 GPUs)
  - Disaggregated prefill-decode with H100 (prefill) and A100 (decode)
- AMD MI300X support with ROCm vLLM (MiniMax-M2)
- Helm chart for model deployments
- OpenAI-compatible `/v1/chat/completions` endpoint

## Prerequisites

- [Crusoe CLI](https://docs.crusoecloud.com/quickstart/install-the-cli) installed and configured
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- A [HuggingFace](https://huggingface.co/) account and API token
- **AMD only**: Docker Hub account (for building AMD GPU driver image)

## Quick Start — NVIDIA

### 1. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
```
Edit `terraform.tfvars` with your project ID, HuggingFace token, IB partition IDs, and node types/count.

### 2. Provision cluster + install KServe

Navigate back to `crusoe-kserve-example/` and run:
```bash
make setup
```

This single command:
- Creates the CMK cluster and node pools (A100, H100, CPU)
- Fetches kubeconfig
- Installs KServe v0.17.0 (standard mode + LLMInferenceService CRDs)
- Creates the workload namespace and HuggingFace secret

### 3. Deploy a model

```bash
# Single-GPU (Qwen2.5-0.5B, 1x H100)
make deploy-basic

# Large single-node (Qwen2.5-72B, 8x H100 TP=8, with PVC storage)
make deploy-large

# Multi-node (Qwen2.5-72B, 2x8 H100)
make deploy-multi-node

# Disaggregated prefill-decode (H100 prefill + A100 decode)
make deploy-disaggregated
```

Large models (70B+) require persistent storage. `deploy-large` automatically provisions a 250Gi SSD PVC via the Crusoe CSI driver to store model weights.

> **Using a different GPU type?** The defaults in `helm/crusoe-kserve-example/values.yaml` target H100 nodes. If your cluster uses another GPU SKU, update the `nodeSelector` for the relevant profile, for example:
> ```yaml
> basic:
>   nodeSelector:
>     crusoe.ai/accelerator: nvidia-a100-80gb-sxm-ib
> ```
> You can print the GPU types in your node pools by running:
> ```bash
> kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.crusoe\.ai/accelerator}{"\n"}{end}'
> ```
> ```
> np-520db221-1.us-east1-a.compute.internal       nvidia-a100-80gb-sxm-ib
> np-59eb87e7-1.us-east1-a.compute.internal
> np-59eb87e7-2.us-east1-a.compute.internal
> ```

### 4. Test

Send a single chat completion request.
```bash
make test
```

### 5. Chat
Enter an interactive chat interface.
```bash
make chat
```

### 6. Benchmark

Uses vLLM's built-in `vllm bench serve` running inside the serving pod:

```bash
make bench                                      # Default: 200 prompts, 50 req/s, 512 input / 150 output tokens
make bench BENCH_RATE=10 BENCH_INPUT_LEN=128    # Low-latency profile
make bench BENCH_RATE=inf BENCH_NUM_PROMPTS=300 # Max throughput
```

---

## Quick Start — AMD

AMD clusters use a separate Terraform directory and require the AMD GPU operator instead of the NVIDIA operator.

### 1. Configure

```bash
cd terraform-amd
cp terraform.tfvars.example terraform.tfvars
```
Edit terraform.tfvars with your project ID, HuggingFace token, AMD node type/count, IB partition ID, and Docker Hub credentials.

### 2. Provision cluster + install AMD GPU operator + KServe

```bash
make setup-amd
```

This single command:
- Creates the CMK cluster and node pools (MI300X, CPU)
- Installs cert-manager + AMD GPU operator v1.4.2
- Installs KServe v0.17.0

### 3. Deploy a model

```bash
# Small model (Qwen2.5-0.5B on 1x MI300X)
make deploy-amd-basic

# Large single-node (MiniMax-M2 on 8x MI300X — TP=8, expert parallel, 1500Gi PVC)
make deploy-amd-large

# Multi-node (MiniMax-M2 on 2x8 MI300X)
make deploy-amd-multi-node
```

### 4. Chat
Enter an interactive chat interface.
```bash
make chat
```

### 5. Test and benchmark

```bash
make bench-amd                                      # 50 req/s, 512 input, 150 output
make bench-amd BENCH_RATE=10 BENCH_INPUT_LEN=128
```

---

## Installing on an Existing Cluster

If you already have a Crusoe CMK cluster with GPU node pools, skip `make setup` / `make setup-amd` and install KServe directly. The cluster must already have the correct add-ons enabled — Terraform sets these automatically, but if you created the cluster manually ensure they are present.

### NVIDIA — Required Add-ons

| Add-on | Purpose |
|--------|---------|
| `nvidia_gpu_operator` | GPU driver and device plugin (`nvidia.com/gpu` resource) |
| `nvidia_network_operator` | RDMA / InfiniBand networking for multi-node TP |
| `crusoe_csi` | Persistent SSD storage for large model weights |

```bash
make install-kserve HF_TOKEN=hf_...
```

### AMD — Required Add-ons

| Add-on | Purpose |
|--------|---------|
| `crusoe_csi` | Persistent SSD storage for large model weights |

```bash
make install-amd-gpu-operator DOCKER_USERNAME=you DOCKER_EMAIL=you@example.com DOCKER_PASSWORD=...
make install-kserve HF_TOKEN=hf_...
```

Once KServe is installed, proceed directly to the deploy commands (`make deploy-basic`, `make deploy-large`, etc.).

---

## Architecture

### Deployment Modes

| Mode | GPU | Model | Use Case |
|------|-----|-------|----------|
| **Basic (NVIDIA)** | 1x A100 | Qwen2.5-0.5B | Dev/test, small models |
| **Large (NVIDIA)** | 8x A100 TP=8 | Qwen2.5-72B | Single-node large model |
| **Multi-Node (NVIDIA)** | 16x A100 (2 nodes) | Qwen2.5-72B | Large models exceeding single-node VRAM |
| **Disaggregated (NVIDIA)** | 8x H100 + 16x A100 | Qwen2.5-72B | Production, cost-optimized latency |
| **Basic (AMD)** | 1x MI300X | Qwen2.5-0.5B | Dev/test on AMD |
| **Large (AMD)** | 8x MI300X TP=8 | MiniMax-M2 | Large MoE models, high-memory serving |
| **Multi-Node (AMD)** | 16x MI300X (2 nodes) | MiniMax-M2 | Multi-node MoE on AMD |

### NVIDIA Cluster Layout

```
CMK Cluster (terraform/)
├── 2x CPU (c1a.4x)           — KServe control plane
├── 2x A100-80GB-SXM-IB.8x    — Decode / general inference pool (16 GPUs)
└── 1x H100-80GB-SXM-IB.8x    — Prefill pool (8 GPUs)
```

### AMD Cluster Layout

```
CMK Cluster (terraform-amd/)
├── 2x CPU (c1a.4x)            — KServe control plane
└── 1x MI300X-192GB-IB.8x      — AMD GPU pool (8 GPUs, 1536GB VRAM)
```

## Customization

Edit `helm/crusoe-kserve-example/values.yaml` to change models, GPU counts, or resource limits, then re-run the deploy command. vLLM args (e.g. `--tensor-parallel-size`, `--gpu-memory-utilization`) are set via `--set` flags in the Makefile deploy targets, not in `values.yaml`.

### Changing the model

To use a different model, update `model.uri` and `model.name` in `values.yaml` for the relevant profile:

```yaml
# For deploy-basic:
basic:
  model:
    uri: hf://meta-llama/Llama-3.1-8B-Instruct
    name: llama

# For deploy-large:
large:
  model:
    uri: hf://meta-llama/Llama-3.1-70B-Instruct
    name: llama
```

For `deploy-large`, also review the vLLM args in the `deploy-large` target in `Makefile` — `--tensor-parallel-size` must match the number of GPUs, and `modelStorage.size` may need adjustment depending on model weight size.

## Networking

This example uses `kubectl port-forward` for local access. For production, provision a [Crusoe load balancer](https://docs.crusoecloud.com/) pointed at the Envoy Gateway NodePort.

## Cleanup

This will destroy all resources to stop billing.
```bash
make destroy
```

## Project Structure

```
crusoe-kserve-example/
├── CLAUDE.md                          # Context for Claude Code
├── Makefile                           # All commands: setup, deploy-*, test, bench, monitor-*, destroy
├── chat-test.json                     # Sample request payload for testing
├── scripts/
│   └── chat.py                        # Interactive streaming chat REPL
├── terraform/                         # NVIDIA cluster infrastructure
│   ├── main.tf                        # Cluster, node pools, KServe install, namespace
│   ├── variables.tf
│   └── terraform.tfvars.example
├── terraform-amd/                     # AMD cluster infrastructure
│   ├── main.tf                        # Cluster + node pools (KServe installed by make setup-amd)
│   ├── variables.tf
│   └── terraform.tfvars.example
├── helm/crusoe-kserve-example/
│   ├── values.yaml                    # Model + resource config (NVIDIA and AMD modes)
│   └── templates/
│       ├── model-storage.yaml         # StorageClass + PVC for large models
│       ├── basic-llm.yaml             # NVIDIA single-GPU deployment
│       ├── large-llm.yaml             # NVIDIA multi-GPU single-node deployment
│       ├── multi-node-llm.yaml        # NVIDIA multi-node tensor parallel
│       ├── disaggregated-llm.yaml     # NVIDIA prefill-decode split
│       ├── amd-basic-llm.yaml         # AMD single-GPU deployment
│       ├── amd-large-llm.yaml         # AMD multi-GPU single-node deployment
│       └── amd-multi-node-llm.yaml    # AMD multi-node tensor parallel
└── monitoring/
    ├── docker-compose.yml             # Grafana container (port 3000)
    ├── env                            # Crusoe credentials (not committed)
    ├── setup.py                       # Configures Grafana datasource at startup
    └── grafana/
        ├── dashboards/nvidia/         # NVIDIA GPU inference dashboard
        └── dashboards/amd/            # AMD GPU inference dashboard
```
