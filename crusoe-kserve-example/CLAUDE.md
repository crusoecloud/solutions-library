# CLAUDE.md — KServe LLM Serving on Crusoe

This project deploys open-source LLMs on Crusoe Managed Kubernetes (CMK) using KServe and vLLM.

## What This Does

Provisions a CMK cluster with GPU node pools and installs KServe for LLM inference. Supports three deployment modes:
- **Basic**: Single-GPU serving (e.g., Qwen2.5-0.5B on 1x A100)
- **Multi-Node**: Tensor-parallel across multiple nodes (e.g., Qwen2.5-72B on 16 GPUs)
- **Disaggregated Prefill-Decode**: H100 for prefill, A100 for decode (cost-optimized)

## Setup Flow

### 1. Configure `terraform/terraform.tfvars`

Copy the example and fill in values:
```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars
```

Required values the user must provide:
- `project_id` — Crusoe project ID (get via `crusoe projects list`)
- `hf_token` — HuggingFace API token
- `ssh_public_key` — User's SSH public key string
- `a100_ib_partition_id` — InfiniBand partition ID for A100 nodes (get via `crusoe networking ib-partitions list`)
- `h100_ib_partition_id` — InfiniBand partition ID for H100 nodes (only needed if `h100_node_count > 0`)

To find the right IB partition, match the partition's IB network location and VM type:
```bash
crusoe networking ib-partitions list --project-id <project-id>
crusoe networking ib-networks get <ib-network-id> --project-id <project-id> -f json
```
Look for a network with the correct location and `slice_type` (e.g., `a100-80gb-sxm-ib.8x`).

### 2. Provision Infrastructure + Install KServe

```bash
make setup
```

This runs `terraform apply` which:
1. Creates the CMK cluster with `nvidia_gpu_operator`, `nvidia_network_operator`, and `crusoe_csi` add-ons
2. Creates node pools (A100, H100, CPU — counts configurable in tfvars)
3. Fetches kubeconfig
4. Installs KServe v0.17.0 (standard mode + LLMInferenceService CRDs)
5. Creates the `kserve-test` namespace with the HuggingFace secret

### 3. Deploy a Model

```bash
make deploy-basic          # Qwen2.5-0.5B on 1x A100
make deploy-70b            # Qwen2.5-72B on 8x A100, TP=8 (with PVC for model storage)
make deploy-multi-node     # Qwen2.5-72B on 2x8 A100 (needs a100_node_count=2)
make deploy-disaggregated  # Qwen2.5-72B with H100 prefill + A100 decode (needs h100_node_count=1)
```

### 4. Test

```bash
make test   # Port-forward + single curl request
```

### 5. Benchmark

Uses vLLM's built-in `vllm bench serve` running inside the serving pod — no port-forward overhead, proper statistical analysis.

```bash
# Default: 200 prompts, 50 req/s, 512 input / 150 output tokens
make bench

# Custom parameters
make bench BENCH_RATE=10 BENCH_INPUT_LEN=128 BENCH_OUTPUT_LEN=150 BENCH_NUM_PROMPTS=100

# Max throughput (send all at once)
make bench BENCH_RATE=inf BENCH_NUM_PROMPTS=300
```

Reports TTFT, TPOT (time per output token), ITL (inter-token latency), and throughput with percentiles.

## Model Storage (PVC)

Large models (70B+) exceed the node's ephemeral storage (~120GB). The `deploy-70b`, `deploy-multi-node`, and `deploy-disaggregated` targets use a PersistentVolumeClaim backed by the Crusoe SSD CSI driver (`ssd.csi.crusoe.ai`).

This is controlled by `modelStorage.enabled` and `modelStorage.size` in values.yaml:
```yaml
modelStorage:
  enabled: true   # Creates StorageClass + PVC
  size: 250Gi     # Enough for 72B model weights (~144GB) plus buffer
```

The Helm chart creates:
- A `crusoe-ssd` StorageClass using the Crusoe SSD CSI driver (`ssd.csi.crusoe.ai`)
- A `model-storage` PVC in the workload namespace
- A volume override on `kserve-provision-location` that replaces KServe's default emptyDir with the PVC

**Important**: KServe internally uses a volume named `kserve-provision-location` mounted at `/mnt/models` for model downloads. To use a PVC, we override this volume name (not add a new mount), otherwise Kubernetes rejects the duplicate mountPath. Do NOT add a separate volumeMount to `/mnt/models`.

For basic mode (small models <100GB), `modelStorage.enabled` defaults to `false` — ephemeral storage (~120GB per node) is sufficient.

The Terraform setup also patches the KServe `inferenceservice-config` configmap to give the storage-initializer init container 64Gi memory and 8 CPU cores (defaults of 1Gi/1 CPU are too low for large model downloads).

## Key Files

- `terraform/main.tf` — Cluster, node pools, KServe install, namespace setup (all-in-one)
- `terraform/variables.tf` — All configurable variables with defaults
- `terraform/terraform.tfvars.example` — Template for user configuration
- `helm/crusoe-kserve-example/values.yaml` — Model config, GPU resources, deployment mode toggles
- `helm/crusoe-kserve-example/templates/` — LLMInferenceService manifests for each mode
- `chat-test.json` — Sample OpenAI-compatible chat request
- `Makefile` — All commands: `setup`, `deploy-*`, `test`, `bench`, `destroy`

## Crusoe CLI Notes

- Locations use zone suffixes: `us-east1-a`, `us-southcentral1-a`, `eu-iceland1-a`, `us-west1-a`
- Cluster versions use format: `MAJOR.MINOR.PATCH-cmk.NUM` (e.g., `1.33.4-cmk.43`)
- `crusoe kubernetes clusters get-credentials <name>` — positional arg, not `--name` flag
- GPU node types (`*-ib.*`) require an InfiniBand partition ID
- CPU node types (e.g., `c1a.4x`) do not require IB partitions

## Available GPU SKUs

| Node Type                | GPU             | GPUs | VRAM     | BW (TB/s) | Best For                    |
|--------------------------|-----------------|------|----------|-----------|-----------------------------|
| a100-80gb-sxm-ib.8x     | A100 SXM 80GB   | 8    | 640 GB   | 2.0       | Decode, general inference   |
| h100-80gb-sxm-ib.8x     | H100 SXM 80GB   | 8    | 640 GB   | 3.35      | Prefill, compute-heavy      |
| h200-141gb-sxm-ib.8x    | H200 SXM 141GB  | 8    | 1128 GB  | 4.8       | Large models, max throughput |
| l40s-48gb.1x             | L40S 48GB       | 1    | 48 GB    | 0.86      | Cost-effective small models |
| a100-80gb.1x             | A100 PCIe 80GB  | 1    | 80 GB    | 2.0       | Single-GPU inference        |

nodeSelector labels: `nvidia-a100-80gb-sxm-ib`, `nvidia-h100-80gb-sxm-ib`, `nvidia-h200-141gb-sxm-ib`, `nvidia-l40s`

## Node Count Guidelines

| Deployment Mode | a100_node_count | h100_node_count | cpu_node_count |
|----------------|-----------------|-----------------|----------------|
| Basic          | 1               | 0               | 2              |
| Multi-Node     | 2               | 0               | 2              |
| Disaggregated  | 2               | 1               | 2              |

## Performance Tuning

### vLLM args (set in `values.yaml` under `basic.args`, `disaggregated.decode.args`, etc.)

| Flag | What it does | When to use |
|------|-------------|-------------|
| `--gpu-memory-utilization 0.95` | Allocate more VRAM for KV cache | Always (default 0.9 wastes 10%) |
| `--enable-chunked-prefill` | Break prefill into chunks so decode isn't starved | High concurrency workloads |
| `--max-num-batched-tokens 4096` | Max tokens in a prefill batch | Tune for prefill throughput |
| `--enable-prefix-caching` | Cache KV for shared prefixes (e.g., system prompts) | Chat workloads (enabled by default in vLLM 0.19+) |
| `--enforce-eager` | Disable CUDA graphs | Debugging; avoid in production |
| `--dtype float16` / `--quantization fp8` | Reduce precision | When VRAM is tight or on H100 (native FP8) |
| `--max-num-seqs 512` | Max concurrent sequences in a batch | Increase for high-concurrency |

**Important**: KServe automatically injects `--model /mnt/models` and `--served-model-name`. Do NOT include `--model` in your args — it will cause a startup crash.

### Benchmark results — Qwen2.5-72B on 8x A100 SXM 80GB, TP=8

Measured with `vllm bench serve` running inside the serving pod (dataset: random, 200 prompts):

| Profile | Rate | Input len | Output tok/s | Peak tok/s | TTFT (median) | TPOT (median) |
|---------|------|-----------|-------------|-----------|---------------|---------------|
| Low load | 10 req/s | 128 | 1,130 | 1,745 | 66ms | 22ms |
| Medium | 50 req/s | 512 | 1,714 | 4,600 | 4,186ms | 74ms |
| High load | 100 req/s | 2048 | 729 | 4,000 | 16,155ms | 158ms |
| Max saturated | inf | 512 | 2,614 | **5,120** | 3,951ms | 67ms |

Key numbers:
- **Peak output throughput: 5,120 tok/s** at max saturation
- **Best per-request speed: 45 tok/s** (22ms TPOT at 10 req/s) — faster than DeepInfra's 35.9 tok/s on Artificial Analysis
- **Long inputs (2048 tokens) crush TTFT** at high concurrency — this is where disaggregated prefill-decode helps
- TPOT stays consistent (22-67ms) across load levels; TTFT is what degrades under load

Run benchmarks with:
```bash
make bench                                          # Default: 50 req/s, 512 input, 150 output
make bench BENCH_RATE=10 BENCH_INPUT_LEN=128        # Low-latency profile
make bench BENCH_RATE=inf BENCH_NUM_PROMPTS=300      # Max throughput
```

## Cleanup

```bash
make destroy
```

This uninstalls the Helm release and runs `terraform destroy` to tear down all infrastructure.

## Troubleshooting

- If KServe CRD install fails with "no matches for kind", rerun `make setup` — it's a CRD propagation race condition. The install script waits for CRDs and webhook readiness but occasional races still happen.
- If pods are stuck in `Pending`, check GPU node readiness: `kubectl get nodes` and `kubectl describe node <name>`
- If model download fails, verify the HF token: `kubectl get secret hf-secret -n kserve-test -o jsonpath='{.data.HF_TOKEN}' | base64 -d`
- If storage-initializer OOM kills on large models (70B+), the `inferenceservice-config` configmap needs `memoryLimit: 16Gi`. This is done automatically by `make setup`, but if you installed KServe manually, patch it:
  ```bash
  kubectl patch configmap inferenceservice-config -n kserve --type merge -p '{"data":{"storageInitializer":"{\"memoryLimit\":\"16Gi\",\"cpuLimit\":\"4\"}"}}'
  kubectl rollout restart deployment kserve-controller-manager -n kserve
  ```
- If vLLM crashes with "unrecognized arguments: /mnt/models", you have `--model` in your args — remove it, KServe injects this automatically
- Check KServe controller logs: `kubectl logs -n kserve -l control-plane=kserve-controller-manager`
- Check vLLM logs: `kubectl logs -n kserve-test deploy/<model>-kserve -c main`
