# Serving HuggingFace Models on CMK with KServe

Deploy open-source LLMs from HuggingFace on Crusoe Managed Kubernetes (CMK) using [KServe](https://kserve.github.io/) and [vLLM](https://docs.vllm.ai/), from a single-GPU endpoint to disaggregated prefill-decode across heterogeneous GPU pools. Supports both NVIDIA and AMD GPU clusters.

## Features

- One command for full infrastructure + KServe setup (NVIDIA or AMD)
- One command to deploy HuggingFace model
  - Single-GPU LLM serving (Qwen2.5-0.5B on 1x H100, A100, MI300X, etc.)
  - Single-node multi-GPU inference (Qwen2.5-72B on 8x H100, TP=8)
  - Multi-node tensor-parallel inference (Qwen2.5-72B across 16 GPUs)
  - Disaggregated prefill-decode with H100 (prefill) and A100 (decode)
- AMD MI300X and MI355X (gfx950) support with ROCm vLLM (MiniMax-M2, Qwen3-235B)
- Helm chart for model deployments
- OpenAI-compatible `/v1/chat/completions` endpoint

## Prerequisites

- [Crusoe CLI](https://docs.crusoecloud.com/quickstart/install-the-cli) installed and configured
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- A [HuggingFace](https://huggingface.co/) account and API token
- **AMD legacy path only**: Docker Hub account (not needed with the default managed AMD add-ons)

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
- Installs KServe v0.19.0 (standard mode + LLMInferenceService CRDs)
- Creates the workload namespace and HuggingFace secret

### 3. Deploy a model

```bash
# Single-GPU (Qwen2.5-0.5B, 1x A100)
make deploy-basic

# Large single-node (Qwen2.5-72B, 8x H100 TP=8, with PVC storage)
make deploy-large

# Multi-node (Qwen2.5-72B, 2x8 H100)
make deploy-multi-node

# Disaggregated prefill-decode across separate GPU pools (needs KServe v0.19.0+)
make deploy-disaggregated
```

Large models (70B+) require persistent storage. `deploy-large` automatically provisions a 250Gi SSD PVC via the Crusoe CSI driver to store model weights.

> **Disaggregated serving** splits prefill and decode onto separate GPU pools via KServe's inference scheduler. It requires **KServe v0.19.0+** (the earlier scheduler crashes on disaggregated configs) and a NIXL-capable vLLM image (`llm-d-cuda`, preset in `values.yaml`). Set the model, tensor-parallel size, GPU counts, and per-pool `nodeSelector` labels in the `disaggregated:` block of `values.yaml` to match your cluster. On pools with a single GPU per node, set the deployments' update strategy to `Recreate` (a rolling update can't surge onto a busy GPU).

> **Using a different GPU type?** Each profile in `helm/crusoe-kserve-example/values.yaml` sets its own `nodeSelector` (basic defaults to A100; large / multi-node / disaggregated to H100). If your cluster uses another GPU SKU, update the `nodeSelector` for the relevant profile, for example:
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
> np-xxxxxxxx-1.<region>.compute.internal       nvidia-a100-80gb-sxm-ib
> np-yyyyyyyy-1.<region>.compute.internal
> np-yyyyyyyy-2.<region>.compute.internal
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

AMD clusters use a separate Terraform directory (`terraform-amd/`). By default the cluster enables the **CMK-managed AMD add-ons** (`amd_gpu_operator`, `amd_network_operator`, `crusoe_csi`), so CMK installs and maintains the GPU driver/operator — no manual operator install and **no Docker Hub credentials**.

### 1. Configure

```bash
cd terraform-amd
cp terraform.tfvars.example terraform.tfvars
```
Edit terraform.tfvars with your project **UUID** (`crusoe projects list`), HuggingFace token, AMD node type/count, IB/RoCE partition ID, and SSH key. For MI355X use an AMD "Bundle 1" `cluster_version` (e.g. `1.33.4-cmk.93`). Docker Hub credentials are only needed for the legacy path (`cluster_add_ons = ["crusoe_csi"]` + `make install-amd-gpu-operator`).

### 2. Provision cluster + KServe

```bash
export CRUSOE_PROFILE=<your-profile>   # selects the target org for Terraform
make setup-amd
```

This single command:
- Creates the CMK cluster (managed AMD GPU + network operators) and node pools (MI355X, CPU)
- Installs KServe v0.19.0

Verify GPUs are advertised before deploying: `kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:'.status.allocatable.amd\.com/gpu'`

### 3. Deploy a model

```bash
# Small model (Qwen2.5-0.5B on 1x MI300X)
make deploy-amd-basic

# Large single-node (MiniMax-M2 on 8x MI300X — TP=8, expert parallel, 1500Gi PVC)
make deploy-amd-large

# Multi-node (MiniMax-M2 on 2x8 MI300X)
make deploy-amd-multi-node

# Large single-node on MI355X gfx950 (Qwen3-235B on 8x MI355X — TP=8, expert parallel, tool calling)
make deploy-amd-mi355x

# Use every node: scale to N data-parallel replicas (one full model per node), after the first deploy
make deploy-amd-mi355x REPLICAS=2
```

> **MI355X (gfx950)** uses a gfx950-specific ROCm image (the default `vllm-openai-rocm` lacks MI355X kernels) and a **ReadWriteMany shared disk** instead of a single-attach PVC — so a rolling update can bring the new pod up on an idle node before the old one exits (zero downtime, no single-GPU-node deadlock). The first-run AITER MoE kernel compile for a 235B model gets a longer startup-probe budget so it isn't probe-killed mid-compile. Re-run `make deploy-amd-mi355x` to change args; weights persist on the shared disk (no re-download). Set model/resources/labels in the `amd.mi355x:` block of `values.yaml`.
>
> **Using all nodes (data parallelism):** Qwen3-235B fits on one 8-GPU node, so the way to use additional nodes is **horizontal replicas**, not multi-node tensor parallel. Each replica is a full TP=8 model copy on one node; the router's scheduler load-balances across them. Deploy at `REPLICAS=1` first so the weights download once to the shared disk, then `make deploy-amd-mi355x REPLICAS=<node count>` — added replicas mount the same shared disk and **skip the download** (verified: the second replica's storage-initializer finishes in ~1 min instead of re-pulling 235GB). Avoid a fresh `REPLICAS>1` deploy — every replica's storage-initializer would race to write the same shared volume.

### Autoscaling & the gateway bottleneck (experimental)

Two tiers make scaling hands-off — the cluster-autoscaler provisions on-demand MI355X nodes, and a pod autoscaler adjusts vLLM replicas. **But load-testing showed the KServe gateway/EPP — not the GPUs — is the binding constraint**, so read the caveats before relying on this for throughput.

```bash
make install-crusoe-autoscaler        # node tier: cluster-autoscaler (bounds via AUTOSCALER_MIN/MAX/POOL)
make install-gateway-scaling          # scale the Envoy gateway data plane (removes the ~128-concurrent 500-cliff)
make install-vllm-hpa                  # pod tier: KEDA + Prometheus metric pipeline (see caveat 3)
make deploy-amd-mi355x AUTOSCALE=1     # emit spec.scaling.wva.hpa (KServe-native) instead of a fixed replicas
```

**What load-testing found (Qwen3-235B on 2× MI355X, 512-in/150-out):**

1. **Gateway 500-cliff — fixed.** The default single Envoy proxy (100m CPU) collapsed to ~95% HTTP-500 at ~128 concurrent. Scaling it to 3×2CPU + raising circuit breakers (`make install-gateway-scaling`) gives **0 failures through 256 concurrent**.
2. **EPP throughput ceiling — architectural.** The single leader-elected endpoint-picker (`llm-d-inference-scheduler`) serializes per-request routing and caps end-to-end throughput at **~1.6k tok/s (~12–17% of the ~9.7k tok/s the two replicas deliver when driven directly)**, independent of its CPU (3 vs 8: no change) or scoring config. Bumping it 256m→3 CPU (chart default; it scales *up*, not out) still roughly halved TPOT and lifted req/s ~25–46%. For max throughput, **load-balance clients across replica endpoints directly** (`bench-amd-mi355x-all` path); use the gateway for smart prefix/queue-aware routing at moderate load.
3. **Pod autoscaling is blocked three ways on a base CMK cluster.** `vllm:num_requests_waiting` stays ~0 under gateway load (the EPP gates admission, so congestion sits in the gateway, not the vLLM queue); a standalone KEDA ScaledObject can't actuate (KServe owns `spec.replicas` and reverts external scaling in <10s); and the native `spec.scaling.wva.hpa` path (`AUTOSCALE=1`) needs a **`VariantAutoscaling` CRD** (llm-d workload-variant-autoscaler operator) **and** a **metrics-server** — neither ships with base KServe or CMK, so the ISVC goes `Ready=False` (`ScalingCRDNotFound`) until they're installed. `install-vllm-hpa` installs the metric pipeline (on the more reliable `num_requests_running`) for observability; enabling `AUTOSCALE=1` requires installing those operators first.

> **⚠️ Known issue — shared-disk topology-label lag.** New autoscaled nodes receive the `fs.csi.crusoe.ai/*` labels that the RWX weights PV's `nodeAffinity` requires ~4.5 min *after* the node is `Ready` (the driver works immediately, only the labels lag). During that gap the new replica can't schedule **and the autoscaler over-provisions** (adds a 2nd node for 1 replica) before reclaiming the extra. Scale-up to a serving replica is ~26 min (dominated by the 30 GB image pull + AITER compile, not node provisioning).

### 4. Chat
Enter an interactive chat interface.
```bash
make chat
```

### 5. Test and benchmark

```bash
make bench-amd                                      # MI300X: 50 req/s, 512 input, 150 output (served-model-name minimax)
make bench-amd BENCH_RATE=10 BENCH_INPUT_LEN=128
make bench-amd-mi355x                               # MI355X: benchmark one node (single replica)
make bench-amd-mi355x-all                           # MI355X: benchmark every node at once (per-pod + aggregate)
make bench-amd-mi355x-lb                            # MI355X: benchmark through the Envoy gateway (production path)
make bench-amd BENCH_MODEL=<name>                   # override the served-model-name for any bench target

# Simulate hundreds of concurrent users hitting the load-balanced endpoint:
make bench-amd-mi355x-lb BENCH_CONCURRENCY=300 BENCH_RATE=inf BENCH_NUM_PROMPTS=3000
```

> **Which one?** `bench-amd-mi355x` loads a single node (localhost). `bench-amd-mi355x-all` fans out to every replica pod concurrently for raw multi-node capacity. `bench-amd-mi355x-lb` drives traffic **through the Envoy gateway** so requests are load-balanced per-request across replicas (the real production path) — use it once you've scaled with `REPLICAS=<node count>`.
>
> **Load model:** requests are concurrent, not serial. `BENCH_RATE` is the arrival rate (open-loop; in-flight count floats and can pile up). `BENCH_CONCURRENCY` caps in-flight requests — with `BENCH_RATE=inf` that's a closed-loop **N-concurrent-users** test. The result's "Peak concurrent requests" shows actual in-flight load, and TPOT (per-token latency) rising with concurrency is your signal to add replicas.

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

> **Managing an existing cluster with Terraform (optional):** to bring a cluster created outside Terraform under `make destroy` lifecycle management, add `import` blocks for the cluster and its node pools, set the matching values in `terraform.tfvars`, and run `terraform plan` — confirm it reports **0 to destroy** before applying. The node-pool resources ignore changes to `ssh_key` / `ib_partition_id` (write-only in the Crusoe API) so import doesn't force node replacement.

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
| **Large (AMD MI355X)** | 8x MI355X TP=8 | Qwen3-235B | Large MoE on gfx950, RWX shared disk, tool calling |

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
│       ├── amd-large-llm.yaml         # AMD MI300X multi-GPU single-node deployment
│       ├── amd-multi-node-llm.yaml    # AMD multi-node tensor parallel
│       ├── amd-mi355x-llm.yaml        # AMD MI355X gfx950 single-node deployment
│       └── amd-mi355x-storage.yaml    # RWX shared disk for MI355X model weights
└── monitoring/
    ├── docker-compose.yml             # Grafana container (port 3000)
    ├── env                            # Crusoe credentials (not committed)
    ├── setup.py                       # Configures Grafana datasource at startup
    └── grafana/
        ├── dashboards/nvidia/         # NVIDIA GPU inference dashboard
        └── dashboards/amd/            # AMD GPU inference dashboard
```
