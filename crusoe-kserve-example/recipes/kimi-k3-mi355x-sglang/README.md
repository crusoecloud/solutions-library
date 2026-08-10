# Kimi K3 on MI355X — SGLang recipe (TP=8)

Serve **Moonshot AI Kimi K3** (2.8T-param MoE, native MXFP4, 1M context) on a single **8-GPU AMD
MI355X (gfx950)** node with **SGLang** (ROCm), OpenAI-compatible, TP=8.

**Why SGLang here:** under long-context *agentic* load (large system prompt + tools, many turns),
the day-0 vLLM ROCm image can corrupt into repeated-token garbage. SGLang serves K3 cleanly —
verified on the same request that broke vLLM — with a proper `reasoning_content` / `content`
split and working tool calls. That makes it the right backend for coding agents (opencode, etc.).

Config is the quality-gated **`fp8kv`** cell (GPQA Diamond 94.71% PASS): `--attention-backend triton`,
`--kv-cache-dtype fp8_e4m3`, `--mamba-ssm-dtype bfloat16`, `kimi_k3` reasoning + tool parsers.

## Prerequisites

- A Crusoe Managed Kubernetes cluster with an **MI355X node pool**, and a `hf-secret`
  (key `HF_TOKEN`) with HuggingFace access to `moonshotai/Kimi-K3`. The repo root's
  `make setup-amd` provisions the cluster + secret.
- A container registry your cluster can pull from (to host the derived image below).

## 1. Build the derived image

The stock SGLang image needs two fixes for network-backed storage (both in the `Dockerfile`):
**fastsafetensors** (parallel load: **~5 min** vs **~2 h** for the default multi-thread loader),
and a one-line **nogds** patch (SGLang's fastsafetensors path deadlocks on ROCm without it —
no GPU Direct Storage). Build and push:

```bash
docker build -t <registry>/kimi-k3-sglang-fss:20260727 recipes/kimi-k3-mi355x-sglang/
docker push  <registry>/kimi-k3-sglang-fss:20260727
```

## 2. Deploy

Set your image in `kimi-k3-sglang.yaml` (the two `REPLACE_WITH_YOUR_REGISTRY` lines; add an
`imagePullSecret` if the registry is private), then:

```bash
kubectl apply -n kserve-test -f recipes/kimi-k3-mi355x-sglang/kimi-k3-sglang.yaml
kubectl -n kserve-test rollout status deploy/kimi-k3-sglang --timeout=90m
```

First boot: the init container downloads the ~1.5 TB weights to the RWX disk **once**, then
fastsafetensors loads them (~5 min) and SGLang captures CUDA graphs. Restarts skip the download.

## 3. Use

Served OpenAI-compatibly as `kimi-k3`:

```bash
kubectl -n kserve-test exec deploy/kimi-k3-sglang -- \
  curl -s http://localhost:30000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"kimi-k3","messages":[{"role":"user","content":"Reverse a string in Python"}]}'
```

The service `kimi-k3-sglang-workload-svc:8000` fronts it in-cluster. Reasoning is returned in
`reasoning_content`; the final answer is in `content`. Tool calls come back as OpenAI `tool_calls`.

## Benchmark

Load-test this (or any) served variant with the harness in `load-test/`:

```bash
kubectl apply -n kserve-test -f load-test/kimi-bench-client.yaml   # CPU-only client: vllm bench serve + K3 tokenizer
VARIANT=kimi-k3-sglang-fss SVC=kimi-k3-sglang-fss-workload-svc \
  python3 load-test/kimi_pareto_bench.py
```

It sweeps concurrency × input/output shapes (`vllm bench serve`, closed-loop), recording
output-throughput / TTFT / TPOT with errors as their own column and stopping each shape at
saturation. On this fp8-KV config, single-node peak is ~9.5k tok/s (512/128, c256) and
per-token latency (TPOT) beats the vLLM ROCm arm by ~2× at high concurrency. Note: the plain
ClusterIP workload Service is L4 and keep-alive pins connections to one pod — for aggregate
load across replicas, drive through an L7 gateway/proxy, not the ClusterIP.

## Notes & gotchas

- **fastsafetensors is mandatory** on network storage — `--load-format auto` uses a multi-thread
  loader that reads shards ~84 s each (~2 h total) and gets killed by the startup probe.
- **nogds patch is required** — without it SGLang's fastsafetensors loader hangs at 0/12 shards on
  ROCm. Baked into the derived image.
- **Probe timeouts matter** — `/health` runs a 1-token generation (~1 s); the default 1 s readiness
  timeout makes the pod never go Ready. The manifest sets readiness `timeoutSeconds: 8`.
- **Two known SGLang engine bugs** (present on all configs, not fatal): tool-call IDs can collide
  across concurrent requests, and `/tokenize` returns HTTP 500 (`/detokenize` is fine).
- **Speculative decoding (DSPARK) is omitted** here — it needs a draft model staged and is a
  throughput lever, not a correctness one. Add `--speculative-algorithm DSPARK` + the draft path
  once you've staged `Kimi-K3-DSpark-sgl` (see the MI355X optimization notes).
- Single-node TP=8 is the layout; to add capacity, run more replicas behind a router rather than
  multi-node tensor/expert parallel.
