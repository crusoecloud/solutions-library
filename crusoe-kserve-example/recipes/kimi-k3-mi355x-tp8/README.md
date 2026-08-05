# Kimi K3 on MI355X — one-click TP=8 recipe

Serve **Moonshot AI Kimi K3** (2.8T-param MoE, ~104B active, native MXFP4, 1M context) on a
**single 8-GPU AMD MI355X (gfx950/CDNA4)** node with KServe + vLLM (ROCm), using the model's
**native tiktoken tokenizer**. One `LLMInferenceService`, tensor-parallel across the 8 GPUs.

## Prerequisites

- A Crusoe Managed Kubernetes cluster with an **MI355X node pool** and **KServe v0.19+** installed,
  plus a namespace holding a HuggingFace secret named `hf-secret`. The repo root automates this:
  `make setup-amd` then confirm the AMD add-ons advertise `amd.com/gpu: 8` per node.
- HuggingFace access to `moonshotai/Kimi-K3` (the token in `hf-secret`).

## Deploy

```bash
kubectl apply -n kserve-test -f kimi-k3.yaml
```

This creates a ReadWriteMany weights disk (`kimi-k3-weights`, 2 TiB) and the `kimi-k3`
`LLMInferenceService`. **First start is ~15–20 min** — the ~1.56 TB MXFP4 weights download to the
shared disk once, then the AITER MoE kernels compile. Watch it:

```bash
kubectl -n kserve-test get llminferenceservice kimi-k3 -w
kubectl -n kserve-test logs -l app.kubernetes.io/instance=kimi-k3 -c main -f   # or the workload pod
```

## Use

The model is served OpenAI-compatibly as `kimi-k3`. In-cluster:

```bash
curl http://kimi-k3-kserve-workload-svc.kserve-test.svc.cluster.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"kimi-k3","messages":[{"role":"user","content":"Hello"}],"max_tokens":64}'
```

Externally it is reachable through the KServe gateway at `/<namespace>/kimi-k3` (see the repo's
benchmark/monitoring docs). Tool calling and reasoning parsing are enabled.

## Notes

- **Day-0 image caveats** are baked into `kimi-k3.yaml` as comments: use the hyphen image
  `vllm/vllm-openai-rocm:kimi-k3`, keep **bf16 KV** (no `--kv-cache-dtype fp8`), and
  `VLLM_USE_BREAKABLE_CUDAGRAPH=0`. Treat throughput as day-0 — AITER improves fast post-launch.
- **Prefix caching** is enabled and runs on K3's hybrid KDA(mamba)+MLA attention via an
  **experimental** Mamba "align" cache mode. It helps stable-prefix (RAG / API) traffic; remove the
  `--enable-prefix-caching` arg to disable.
- **Weights on network storage:** the RWX disk lets a rolling `kubectl apply` (e.g. to change args)
  stage the new pod on a second node before the old one exits — zero downtime, weights are not
  re-downloaded. Avoid `--model-loader-extra-config` multithread loading here: concurrent readers
  contend on the shared filesystem and load *slower*, not faster.
- Single-node TP=8 is the recommended layout for K3 on MI355X. To add capacity, run more replicas
  (independent full copies behind the router), rather than multi-node tensor/expert parallel.
