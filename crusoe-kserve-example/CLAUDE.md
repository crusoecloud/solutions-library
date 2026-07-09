# CLAUDE.md — KServe LLM Serving on Crusoe

This project deploys open-source LLMs on Crusoe Managed Kubernetes (CMK) using KServe and vLLM. It supports both NVIDIA and AMD GPU clusters.

## What This Does

Provisions a CMK cluster with GPU node pools and installs KServe for LLM inference. Supports these deployment modes:
- **Basic (NVIDIA)**: Single-GPU serving (e.g., Qwen2.5-0.5B on 1x A100)
- **Large (NVIDIA)**: Multi-GPU single-node serving (e.g., Qwen2.5-72B on 8x H100, TP=8)
- **Multi-Node (NVIDIA)**: Tensor-parallel across multiple nodes (e.g., Qwen2.5-72B on 16 GPUs)
- **Disaggregated Prefill-Decode**: H100 for prefill, A100 for decode (cost-optimized)
- **Basic (AMD)**: Single-GPU serving on MI300X (e.g., Qwen2.5-0.5B on 1x MI300X)
- **Large (AMD)**: Multi-GPU single-node serving on MI300X (e.g., MiniMax-M2 on 8x MI300X, TP=8)
- **Multi-Node (AMD)**: Multi-node tensor-parallel on MI300X (e.g., MiniMax-M2 on 2x8 MI300X)
- **Large (AMD MI355X)**: Multi-GPU single-node serving on MI355X gfx950 (e.g., Qwen3-235B on 8x MI355X, TP=8+EP) — gfx950 ROCm image, RWX shared disk, tool calling

## Setup Flow

There are two independent setup paths: NVIDIA (default) and AMD. They use separate Terraform directories.

### NVIDIA Setup

#### 1. Configure `terraform/terraform.tfvars`

Copy the example and fill in values:
```bash
cd terraform && cp terraform.tfvars.example terraform.tfvars
```

Required values the user must provide:
- `project_id` — Crusoe project ID (get via `crusoe projects list`)
- `hf_token` — HuggingFace API token
- `ssh_public_key` — User's SSH public key string; provisioned onto nodes at creation time so the user can SSH in for debugging (e.g. checking driver issues, running `nvidia-smi`)
- `a100_ib_partition_id` — InfiniBand partition ID for A100 nodes (only needed if `a100_node_count > 0`)
- `h100_ib_partition_id` — InfiniBand partition ID for H100 nodes (only needed if `h100_node_count > 0`)

To find the right IB partition, match the partition's IB network location and VM type:
```bash
crusoe networking ib-partitions list --project-id <project-id>
crusoe networking ib-networks get <ib-network-id> --project-id <project-id> -f json
```
Look for a network with the correct location and `slice_type` (e.g., `a100-80gb-sxm-ib.8x`).

#### 2. Provision Infrastructure + Install KServe

```bash
make setup
```

This runs `terraform apply` which:
1. Creates the CMK cluster with `nvidia_gpu_operator`, `nvidia_network_operator`, and `crusoe_csi` add-ons
2. Creates node pools (A100, H100, CPU — counts configurable in tfvars)
3. Fetches kubeconfig
4. Installs KServe v0.19.0 (standard mode + LLMInferenceService CRDs)
5. Creates the `kserve-test` namespace with the HuggingFace secret

#### 3. Deploy a Model

```bash
make deploy-basic          # Qwen2.5-0.5B on 1x GPU (GPU type set via basic.nodeSelector in values.yaml)
make deploy-large          # Qwen2.5-72B on 8x GPU TP=8 (GPU type set via large.nodeSelector in values.yaml)
make deploy-multi-node     # Qwen2.5-72B on 2x8 GPU (GPU type set via multiNode.nodeSelector in values.yaml)
make deploy-disaggregated  # Qwen2.5-72B with H100 prefill + A100 decode (needs h100_node_count=1)
```

#### 4. Test

```bash
make test   # Port-forward + single curl request
```

#### 5. Benchmark

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

---

### AMD Setup

AMD clusters use a separate Terraform directory (`terraform-amd/`) and require the AMD GPU operator (not the NVIDIA operator). Docker Hub credentials are needed to push the AMD GPU driver image.

#### 1. Configure `terraform-amd/terraform.tfvars`

```bash
cd terraform-amd && cp terraform.tfvars.example terraform.tfvars
```

Required values:
- `project_id` — Crusoe project ID
- `hf_token` — HuggingFace API token
- `amd_node_type` — AMD GPU instance type (e.g., `mi300x-192gb-ib.8x`)
- `amd_ib_partition_id` — InfiniBand partition ID for AMD nodes
- `ssh_public_key` — User's SSH public key string; provisioned onto nodes at creation time so the user can SSH in for debugging (e.g. checking driver issues, running `rocm-smi`)
- `docker_username`, `docker_email`, `docker_password` — Docker Hub credentials (for pushing AMD GPU driver image)

#### 2. Provision Infrastructure + Install AMD GPU Operator + KServe

```bash
make setup-amd
```

This runs three steps:
1. `terraform apply` in `terraform-amd/` — creates CMK cluster with **`crusoe_csi` add-on only** (no NVIDIA add-ons), AMD GPU node pool, CPU node pool, fetches kubeconfig
2. `install-amd-gpu-operator` — installs cert-manager v1.15.1, AMD GPU operator v1.4.2, creates Docker registry secret in `kube-amd-gpu`, applies AMD DeviceConfig
3. `install-kserve` — installs KServe v0.19.0, patches storage-initializer, creates `kserve-test` namespace with HuggingFace secret

**Key difference from NVIDIA**: AMD clusters use `amd.com/gpu` resource limits instead of `nvidia.com/gpu`, and use the `vllm/vllm-openai-rocm:latest` image (ROCm-based).

#### 3. Deploy a Model on AMD

```bash
make deploy-amd-basic      # Qwen2.5-0.5B on 1x MI300X
make deploy-amd-large      # MiniMax-M2 on 8x MI300X (TP=8, EP, 1500Gi PVC) — deletes existing PVC first
make redeploy-amd-large    # Update AMD large model args WITHOUT deleting PVC (preserves downloaded model)
make deploy-amd-multi-node # MiniMax-M2 on 2x8 MI300X (TP=8, 2 replicas)
make deploy-amd-mi355x     # Qwen3-235B on 8x MI355X gfx950 (TP=8, EP, tool calling) — RWX shared disk; re-run to update args (weights persist)
make deploy-amd-mi355x REPLICAS=2  # Scale to 2 data-parallel replicas (use both nodes) — run AFTER the first deploy
```

**Note**: `deploy-amd-large` deletes the PVC before deploying. Use `redeploy-amd-large` to update args while preserving already-downloaded model weights.

**MI355X (`deploy-amd-mi355x`) differs from `deploy-amd-large`**: it uses a gfx950-specific ROCm image (`rocm/vllm:...gfx950-dcgpu...`), a **ReadWriteMany** shared disk (`fs.csi.crusoe.ai`, 1 TiB min) instead of a RWO PVC, and a long startupProbe budget for the 235B AITER MoE compile. The RWX disk lets a rolling update stage the new pod on an idle node before the old one exits (zero-downtime, no single-GPU-node deadlock), so `deploy-amd-mi355x` is safe to re-run to update args — it does **not** delete the PVC and weights persist. Model/resources/labels live in the `amd.mi355x:` block of `values.yaml`; vLLM args are set via `--set` in the Makefile target.

**Using all nodes (data parallelism)**: Qwen3-235B fits on one 8-GPU node, so `replicas: 1` leaves other nodes idle and only one node is stressed under load. To use every node, scale to `REPLICAS=<node count>` — each replica is a full TP=8 model copy on one node, and the router's scheduler (EPP) load-balances across them. This is the right lever here; **multi-node tensor parallel is wrong** for a model that fits on one node (it only adds inter-node comms overhead). Because all replicas share the one RWX disk, added replicas **skip the download** — verified: replica 2's storage-initializer completed in ~1 min (`snapshot_download` sees the weights present) vs ~14 min for the first. **Deploy at `REPLICAS=1` first, then scale**: a fresh `REPLICAS>1` deploy would have every replica's storage-initializer racing to write the same shared volume.

#### 4. Test AMD

```bash
make test  # Port-forward + curl (works for any deployed model)
```

#### 5. Benchmark AMD

```bash
make bench-amd                    # MI300X: 50 req/s, 512 input, 150 output (served-model-name=minimax)
make bench-amd BENCH_RATE=10 BENCH_INPUT_LEN=128
make bench-amd-mi355x             # MI355X (served-model-name=qwen3)
make bench-amd BENCH_MODEL=<name> # override served-model-name on any bench target
```

**Note on `served-model-name`**: `bench` defaults to `qwen`, `bench-amd` to `minimax`, `bench-amd-mi355x` to `qwen3`. If your deployment serves a different name, pass `BENCH_MODEL=<name>` — `vllm bench serve` 404s if the name doesn't match what `/v1/models` reports.

#### AMD-Specific vLLM Environment Variables

The AMD templates inject these env vars automatically:
- `VLLM_ROCM_USE_AITER=1` — enables AMD's AITER kernel acceleration (significant throughput improvement on MI300X)

## Model Storage (PVC)

Large models (70B+) exceed the node's ephemeral storage (~120GB). The `deploy-large`, `deploy-amd-large`, `deploy-multi-node`, and `deploy-disaggregated` targets use a PersistentVolumeClaim backed by the Crusoe SSD CSI driver (`ssd.csi.crusoe.ai`).

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

- `terraform/main.tf` — NVIDIA cluster, node pools, KServe install, namespace setup (all-in-one)
- `terraform/variables.tf` — NVIDIA Terraform variables
- `terraform/terraform.tfvars.example` — NVIDIA template for user configuration
- `terraform-amd/main.tf` — AMD cluster + node pools (KServe installed separately by `make setup-amd`)
- `terraform-amd/variables.tf` — AMD Terraform variables (includes Docker Hub credentials)
- `terraform-amd/terraform.tfvars.example` — AMD template for user configuration
- `helm/crusoe-kserve-example/values.yaml` — All deployment mode configs (NVIDIA + AMD); vLLM args are set via Makefile `--set` flags, not here
- `helm/crusoe-kserve-example/templates/basic-llm.yaml` — NVIDIA single-GPU manifest
- `helm/crusoe-kserve-example/templates/large-llm.yaml` — NVIDIA multi-GPU single-node manifest
- `helm/crusoe-kserve-example/templates/multi-node-llm.yaml` — NVIDIA multi-node manifest
- `helm/crusoe-kserve-example/templates/disaggregated-llm.yaml` — NVIDIA disaggregated manifest
- `helm/crusoe-kserve-example/templates/amd-basic-llm.yaml` — AMD single-GPU manifest
- `helm/crusoe-kserve-example/templates/amd-large-llm.yaml` — AMD multi-GPU single-node manifest
- `helm/crusoe-kserve-example/templates/amd-multi-node-llm.yaml` — AMD multi-node manifest
- `helm/crusoe-kserve-example/templates/amd-mi355x-llm.yaml` — AMD MI355X gfx950 single-node manifest (RWX disk, startupProbe, tool calling)
- `helm/crusoe-kserve-example/templates/amd-mi355x-storage.yaml` — RWX shared disk (crusoe-fs StorageClass + `model-storage-shared` PVC) for MI355X weights
- `monitoring/docker-compose.yml` — Grafana container (port 3000)
- `monitoring/setup.py` — Configures Grafana datasource + prints dashboard URL
- `monitoring/env.example` — Template for monitoring credentials (copy to `env` and fill in values)
- `monitoring/env` — Crusoe credentials for monitoring (not committed)
- `monitoring/grafana/dashboards/` — Pre-built dashboards (nvidia/, amd/)
- `scripts/chat.py` — Interactive streaming chat REPL
- `chat-test.json` — Sample OpenAI-compatible chat request
- `Makefile` — All commands: `setup`, `setup-amd`, `deploy-*`, `test`, `bench`, `monitor-*`, `destroy`

## Crusoe CLI Notes

- Locations use zone suffixes: `us-east1-a`, `us-southcentral1-a`, `eu-iceland1-a`, `us-west1-a`
- Cluster versions use format: `MAJOR.MINOR.PATCH-cmk.NUM` (e.g., `1.33.4-cmk.43`)
- `crusoe kubernetes clusters get-credentials <name>` — positional arg, not `--name` flag
- GPU node types (`*-ib.*`) require an InfiniBand partition ID
- CPU node types (e.g., `c1a.4x`) do not require IB partitions

## Available GPU SKUs

### NVIDIA

| Node Type                | GPU             | GPUs | VRAM     | BW (TB/s) | Best For                    |
|--------------------------|-----------------|------|----------|-----------|-----------------------------|
| a100-80gb-sxm-ib.8x     | A100 SXM 80GB   | 8    | 640 GB   | 2.0       | Decode, general inference   |
| h100-80gb-sxm-ib.8x     | H100 SXM 80GB   | 8    | 640 GB   | 3.35      | Prefill, compute-heavy      |
| h200-141gb-sxm-ib.8x    | H200 SXM 141GB  | 8    | 1128 GB  | 4.8       | Large models, max throughput |
| l40s-48gb.1x             | L40S 48GB       | 1    | 48 GB    | 0.86      | Cost-effective small models |
| a100-80gb.1x             | A100 PCIe 80GB  | 1    | 80 GB    | 2.0       | Single-GPU inference        |

nodeSelector labels: `nvidia-a100-80gb-sxm-ib`, `nvidia-h100-80gb-sxm-ib`, `nvidia-h200-141gb-sxm-ib`, `nvidia-l40s`

### AMD

| Node Type              | GPU          | GPUs | VRAM     | Best For                              |
|------------------------|--------------|------|----------|---------------------------------------|
| mi300x-192gb-ib.8x     | MI300X       | 8    | 1536 GB  | Large MoE models, high-memory serving |
| mi355x-288gb-roce.8x   | MI355X (gfx950) | 8 | 2304 GB  | Large MoE (235B+), gfx950/CDNA4       |

nodeSelector labels: `amd-mi300x-192gb-ib`, `amd-mi355x-288gb-roce`

MI355X requires a gfx950-specific ROCm image (`rocm/vllm:...gfx950-dcgpu...`); the default `vllm/vllm-openai-rocm:latest` lacks MI355X kernels.

Resource key: `amd.com/gpu` (not `nvidia.com/gpu`)
vLLM image: `vllm/vllm-openai-rocm:latest`

## Node Count Guidelines

| Deployment Mode | a100_node_count | h100_node_count | cpu_node_count |
|----------------|-----------------|-----------------|----------------|
| Basic          | 1 (or 0 if using H100) | 1 (or 0 if using A100) | 2 |
| Large          | 1 (or 0 if using H100) | 1 (or 0 if using A100) | 2 |
| Multi-Node     | 2 (or 0 if using H100) | 2 (or 0 if using A100) | 2 |
| Disaggregated  | 2               | 1               | 2              |

## Performance Tuning

### vLLM args (set via `--set <profile>.args[N]=...` in the Makefile deploy targets)

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

## Monitoring (Grafana + Prometheus)

Local monitoring stack runs Grafana + a Crusoe-managed Prometheus datasource via Docker Compose. No in-cluster components needed.

### Prerequisites

Create `monitoring/env` with your Crusoe credentials:
```
CRUSOE_PROJECT_ID=<your-project-id>
CRUSOE_MONITORING_TOKEN=<your-monitoring-token>
```

Get the monitoring token from the Crusoe console or API.

### Start / Stop

```bash
make monitor-up-nvidia   # Start with NVIDIA GPU dashboard (default)
make monitor-up-amd      # Start with AMD GPU dashboard
make monitor-up          # Alias for monitor-up-nvidia

make monitor-down        # Stop Grafana
make monitor-clean       # Wipe Grafana state and restart fresh
```

After starting, `setup.py` automatically:
1. Waits for Grafana to be ready at `localhost:3000`
2. Configures the Crusoe Prometheus datasource (pointing at `api.crusoecloud.com/v1alpha5/projects/<id>/metrics/timeseries`)
3. Prints the dashboard URL

Dashboard URLs (login: admin / admin):
- NVIDIA: `http://localhost:3000/d/gpu-inference`
- AMD: `http://localhost:3000/d/amd-gpu-inference`

### Dashboard Files

- `monitoring/grafana/dashboards/nvidia/gpu-inference.json` — NVIDIA GPU inference dashboard
- `monitoring/grafana/dashboards/amd/amd-gpu-inference.json` — AMD GPU inference dashboard
- `monitoring/grafana/provisioning/datasources/prometheus.yml` — empty placeholder (datasource is configured at runtime by `setup.py` via Grafana API)

## Scripts

- `scripts/chat.py` — Interactive streaming chat client. Port-forwards to the serving pod and opens a REPL.
  ```bash
  make chat              # Auto-detects deployed service
  make chat MODEL=qwen   # Override model name
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
- If a model pod is stuck in `CreateContainerConfigError` with "container has runAsNonRoot and image will run as root", KServe v0.19.0's hardened pod securityContext conflicts with the root `vllm/vllm-openai` image. The chart relaxes this via `containerSecurityContext` in values.yaml (applied to basic/large/multi-node); don't remove it unless you switch to a non-root image
- Check KServe controller logs: `kubectl logs -n kserve -l control-plane=kserve-controller-manager`
- Check vLLM logs: `kubectl logs -n kserve-test deploy/<model>-kserve -c main`

### Disaggregated Serving

- Requires **KServe v0.19.0+**. On v0.17.0 the router's scheduler (EPP) CrashLoopBackOffs with `invalid decider plugin type: always-disagg-pd-decider` — the bundled scheduler image predates the config the controller generates. `make setup` / `make install-kserve` install v0.19.0 by default (override with `KSERVE_VERSION`).
- Disaggregated pods use the NIXL-capable `ghcr.io/llm-d/llm-d-cuda` image (set via `disaggregated.image` in values.yaml), not `vllm/vllm-openai`. The plain vLLM image lacks the KV connector and the scheduler warns `no KVConnector found`.
- If the vLLM engine crashes at startup with `ld: cannot find -l:libcuda.so.1`, the linker can't find the driver lib. The `LIBRARY_PATH=/usr/lib/x86_64-linux-gnu` env in the `disaggregated:` values fixes this — ensure it's set on both prefill and decode (the UBI-based llm-d image searches `/usr/lib64`, but the driver ships `libcuda.so.1` under `/usr/lib/x86_64-linux-gnu`).
- On single-GPU-per-node pools, a rolling update deadlocks (the new pod can't schedule onto the GPU held by the old one). Set the deployments' strategy to `Recreate`, or delete the old ReplicaSet's pods to force convergence.
- **Known limitation:** the current config provides prefill/decode *routing* via the scheduler but does not fully wire vLLM's `--kv-transfer-config`, so decode does not yet reuse prefill's KV cache over NIXL. Enabling true KV transfer requires passing a per-role `--kv-transfer-config` to the engines plus NIXL transport config (RDMA on IB fabrics, TCP on non-IB).

### AMD-Specific

- If AMD GPU nodes show no GPU resources (`amd.com/gpu: 0`), the AMD GPU operator DeviceConfig hasn't finished reconciling. Check: `kubectl get deviceconfig -n kube-amd-gpu` and `kubectl get pods -n kube-amd-gpu`
- If the AMD driver pod is in `ImagePullBackOff`, the Docker registry secret is wrong or the image wasn't pushed. Verify: `kubectl get secret my-docker-secret -n kube-amd-gpu` and re-run `make install-amd-gpu-operator`
- `VLLM_ROCM_USE_AITER=1` is injected automatically by the AMD Helm templates. Do not set it to `0` unless debugging — it significantly reduces throughput on MI300X
- AMD clusters use `crusoe_csi` add-on only — no `nvidia_gpu_operator` or `nvidia_network_operator`. If you accidentally create an AMD cluster with NVIDIA add-ons, recreate it
- For MiniMax-M2 (MoE model), `--enable-expert-parallel` is required alongside `--tensor-parallel-size 8`. Without it, the model may OOM or perform poorly

#### MI355X (gfx950) — `deploy-amd-mi355x`

- Must use a **gfx950-specific ROCm image** (`rocm/vllm:...gfx950-dcgpu...`, set in `amd.mi355x.image`). The default `vllm/vllm-openai-rocm:latest` lacks MI355X kernels and will fail to load
- If the pod restarts in a loop with **exit 137** during first startup, it's the **startup probe timing out**, not OOM: the 235B AITER MoE kernel compile exceeds KServe's default 10-min budget. The `amd.mi355x.startupProbe` (periodSeconds 15 × failureThreshold 200 ≈ 50 min) covers it. A restart recompiles (~10-15 min) but does not re-download (weights are on the shared disk)
- Uses a **ReadWriteMany** shared disk (`fs.csi.crusoe.ai`, StorageClass `crusoe-fs`, min **1 TiB**), not the RWO `model-storage` PVC. If the PVC is stuck `Pending`, check the size is ≥ 1 TiB (`disk size too small: minimum size: 1099511627776`)
- On a **2-node** MI355X pool, a re-run of `deploy-amd-mi355x` cuts over with zero downtime (new pod stages on the idle node, then the old one exits). On a **single-node** pool there's no idle node to stage onto — delete the old pod to free the 8 GPUs, or expect the new pod to stay `Pending` until it does
- Open WebUI (and other clients) send `tool_choice: auto`; the target passes `--enable-auto-tool-choice --tool-call-parser hermes` so vLLM accepts it. Qwen3 emits Hermes-style `<tool_call>` blocks, so `hermes` is the correct parser
- Benchmark with `make bench-amd-mi355x` (served-model-name `qwen3`), not `make bench`/`bench-amd` (those default to `qwen`/`minimax` and will 404)
