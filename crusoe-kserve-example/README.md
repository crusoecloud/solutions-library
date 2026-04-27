# Serving HuggingFace Models on CMK with KServe

Deploy open-source LLMs from HuggingFace on Crusoe Managed Kubernetes (CMK) using [KServe](https://kserve.github.io/) and [vLLM](https://docs.vllm.ai/), from a single-GPU endpoint to disaggregated prefill-decode across heterogeneous GPU pools.

## Features

- Single-GPU LLM serving (Qwen2.5-0.5B on 1x A100)
- Multi-node tensor-parallel inference (Qwen2.5-72B across 16 GPUs)
- Disaggregated prefill-decode with H100 (prefill) and A100 (decode)
- One `terraform apply` for full infrastructure + KServe setup
- Helm chart for model deployments
- OpenAI-compatible `/v1/chat/completions` endpoint

## Prerequisites

- [Crusoe CLI](https://docs.crusoecloud.com/quickstart/install-the-cli) installed and configured
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- A [HuggingFace](https://huggingface.co/) account and API token

## Quick Start

### 1. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your project ID and HuggingFace token
```

### 2. Provision cluster + install KServe

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
# Single-GPU (Qwen2.5-0.5B, 1x A100)
make deploy-basic

# Single-node 72B (Qwen2.5-72B, 8x A100 TP=8, with PVC storage)
make deploy-70b

# Multi-node (Qwen2.5-72B, 2x8 A100)
make deploy-multi-node

# Disaggregated prefill-decode (H100 prefill + A100 decode)
make deploy-disaggregated
```

Large models (70B+) require persistent storage. `deploy-70b` automatically provisions a 250Gi SSD PVC via the Crusoe CSI driver to store model weights.

### 4. Test

```bash
make test
```

### 5. Benchmark

Uses vLLM's built-in `vllm bench serve` running inside the serving pod:

```bash
# Default: 200 prompts, 50 req/s, 512 input / 150 output tokens
make bench

# Low-latency profile
make bench BENCH_RATE=10 BENCH_INPUT_LEN=128

# Max throughput
make bench BENCH_RATE=inf BENCH_NUM_PROMPTS=300
```

## Architecture

### Deployment Modes

| Mode | Model | GPUs | Nodes | Use Case |
|------|-------|------|-------|----------|
| **Basic** | Qwen2.5-0.5B | 1x A100 | 1 | Dev/test, small models |
| **70B** | Qwen2.5-72B | 8x A100 (TP=8) | 1 | Single-node large model |
| **Multi-Node** | Qwen2.5-72B | 16x A100 | 2 | Large models that exceed single-node VRAM |
| **Disaggregated** | Qwen2.5-72B | 8x H100 + 16x A100 | 3 | Production, cost-optimized latency |

### Why Disaggregated Prefill-Decode?

LLM inference has two phases with different hardware needs:

- **Prefill** processes the full input prompt at once — compute-bound. H100s are ideal (high FP16/FP8 throughput).
- **Decode** generates one token at a time — memory-bandwidth-bound. A100s deliver sufficient bandwidth at lower cost.

Both A100 SXM and H100 SXM have 80GB HBM, but the H100 provides 3.35 TB/s bandwidth vs the A100's 2 TB/s. Using A100s for decode avoids paying the H100 premium for bandwidth you don't need.

### Cluster Layout

```
CMK Cluster
├── 2x CPU (c1a.4x)           — KServe control plane
├── 2x A100-80GB-SXM-IB.8x    — Decode pool (16 GPUs)
└── 1x H100-80GB-SXM-IB.8x    — Prefill pool (8 GPUs)
```

## Customization

Edit `helm/crusoe-kserve-example/values.yaml` to change models, GPU counts, or resource limits. Then re-run the deploy command.

For example, to serve a different model on basic mode:

```yaml
basic:
  enabled: true
  model:
    uri: hf://meta-llama/Llama-3.1-8B-Instruct
    name: llama
```

## Networking

This example uses `kubectl port-forward` for local access. For production, provision a [Crusoe load balancer](https://docs.crusoecloud.com/) pointed at the Envoy Gateway NodePort.

## Cleanup

```bash
make destroy
```

## Project Structure

```
crusoe-kserve-example/
├── CLAUDE.md                          # Context for Claude Code to set this up
├── Makefile                           # make setup / deploy-* / test / bench / destroy
├── chat-test.json                     # Sample request payload for testing
├── terraform/
│   ├── main.tf                        # Cluster, node pools, KServe install, namespace
│   ├── variables.tf                   # All Terraform variables
│   └── terraform.tfvars.example       # Example values (copy to terraform.tfvars)
└── helm/crusoe-kserve-example/
    ├── Chart.yaml
    ├── values.yaml                    # Model + resource config
    └── templates/
        ├── model-storage.yaml         # StorageClass + PVC for large models
        ├── basic-llm.yaml             # Single-GPU / single-node deployment
        ├── multi-node-llm.yaml        # Multi-node tensor parallel
        └── disaggregated-llm.yaml     # Prefill-decode split
```
