# Kimi K3 on MI355X — AMD ATOM (vLLM plugin), fast + correct with CUDA graph capture

Serve **Moonshot AI Kimi K3** (2.8T-param MoE, native MXFP4, 1M context) on a **single 8-GPU AMD
MI355X (gfx950/CDNA4)** node using **AMD's ATOM engine** (its vLLM out-of-tree plugin), tensor-parallel
across the 8 GPUs, OpenAI-compatible.

## Why ATOM

Kimi K3's MXFP4 latent MoE **corrupts under CUDA-graph capture** on the day-0 vLLM ROCm stack, and
even SGLang has to run **eager** (capture off) to stay correct — which costs a large amount of decode
throughput. ATOM ships an AITER MXFP4 MoE path that is correct **with** `FULL_AND_PIECEWISE` graph
capture (AMD validates GSM8K 0.9553 on 8×MI355 TP8), so you keep both correctness and speed.

Measured here (8×MI355X TP8, random 512-in/200-out) vs the same model on SGLang eager:

| Metric | ATOM (capture ON) | SGLang eager |
|---|---|---|
| TPOT @ 1 concurrent (per-user) | **~20 ms (~50 tok/s)** | ~143 ms (~7 tok/s) |
| TPOT @ 32 concurrent | ~29 ms | — |
| Aggregate output @ 32 concurrent | **~950 tok/s** | — |

Correctness spot-checks: deterministic `42` smoke test, exact recall at ~97k-token context, coherent
tool calls with populated `content`, and a 32-way concurrency burst clean.

## Prerequisites

- A Crusoe Managed Kubernetes cluster with an **MI355X node pool** and a namespace holding a
  HuggingFace secret named `hf-secret` (HF access to `moonshotai/Kimi-K3`). The repo root's
  `make setup-amd` provisions the cluster and secret.
- The image `rocm/atom-dev:vllm-kimi-k3-20260807` is **public** on Docker Hub. If your nodes can't
  reach Docker Hub (or you hit rate limits), mirror it into your own registry and update `image:` in
  `kimi-k3-atom.yaml` (2 places). Mirror in-cluster with skopeo (no local Docker needed):

  ```bash
  skopeo copy --authfile /path/to/dockerconfig.json \
    docker://docker.io/rocm/atom-dev:vllm-kimi-k3-20260807 \
    docker://<your-registry>/kimi-k3-atom:vllm-k3-20260807
  ```

## Deploy

```bash
kubectl apply -n kserve-test -f kimi-k3-atom.yaml
```

This creates a ReadWriteMany weights disk (`kimi-k3-weights`, 2 TiB) and the `kimi-k3-atom`
Deployment + Service. **First boot is ~45–50 min**: a one-time ~1.5 TB weight download (init
container), then ATOM's staging loader reads the weights (network-disk bound), online-quantizes
non-MXFP4 tensors to `ptpc_fp8`, JIT-compiles the AITER kernels, and captures CUDA graphs. Watch it:

```bash
kubectl -n kserve-test get pods -l app=kimi-k3-atom -w
kubectl -n kserve-test logs -l app=kimi-k3-atom -c main -f
```

## Use

Served OpenAI-compatibly as `kimi-k3`. In-cluster:

```bash
curl http://kimi-k3-atom-workload-svc.kserve-test.svc.cluster.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"kimi-k3","messages":[{"role":"user","content":"Hello"}],"max_tokens":64}'
```

Tool calling and reasoning parsing are enabled: thinking is separated into `reasoning_content`, and
`content` carries the clean answer — so agent clients (e.g. opencode) that read `content` + `tool_calls`
work directly.

## Notes / gotchas

- **The critical flags** (baked into `kimi-k3-atom.yaml`, from the image's own recipe at
  `/app/ATOM/recipes/atom_vllm/Kimi-K3.md`):
  - `--additional-config '{"online_quant_config":{"global_quant_config":"ptpc_fp8",...}}'` — routes the
    MoE through ATOM's AITER path. **Without it every token is garbage**: vLLM otherwise dispatches the
    MXFP4 MoE to a generic Triton kernel that isn't present in the image.
  - env `AITER_SITUV2_A4W4=1` (K3 MoE is A4W4, **not** A8W4) and `VLLM_USE_BREAKABLE_CUDAGRAPH=0`.
  - `--kv-cache-dtype fp8` is validated on this build's aiter branch (it ships the fp8 MLA kernels).
  - `--mamba-cache-mode align` is required for prefix caching on K3's hybrid KDA+MLA attention.
- **Single-node rolling update:** with one 8-GPU node the Deployment uses `strategy: Recreate`. If a
  re-apply appears stuck, the old pod may be lingering in `Succeeded` (the server exits 0 on SIGTERM),
  blocking Recreate — clear it with `kubectl delete pod <old-pod> --grace-period=0 --force`.
- **Load time** (~30 min of the boot) is the network-disk weight read; it dominates restart time and is
  independent of serving speed. `--load-format fastsafetensors` is overridden by ATOM's staging loader.
- **Scaling:** K3 fits on one 8-GPU node, so add capacity with more `replicas` (independent full copies
  behind a router), not multi-node tensor/expert parallel.
