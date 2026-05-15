# 02 — TorchTitan Llama 3.1 8B end-to-end training

Runs a 1000-step Llama 3.1 8B pretraining job on 2× GPU nodes (16 GPUs) using
FSDP-16, BF16, and (optional) `torch.compile`. Exercises the full training stack:
GPU compute → NCCL collectives → dataloader → optimizer → checkpoint I/O.

This builds on [`01-nccl-test/`](../01-nccl-test/). If you haven't validated the fabric
yet, run that first — 5 minutes saves you 30 if the IB stack is misconfigured.

## When to run

- **After** the NCCL test passes
- For customer-facing "this cluster trains at H200/H100 baseline rates" sign-off
- To validate FSDP + checkpoint + dataloader correctness end-to-end

## Prerequisites

- Kubeflow Training Operator v1.8.1 (PyTorchJob CRD):
  ```bash
  kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.8.1"
  kubectl -n kubeflow wait --for=condition=Available deploy/training-operator --timeout=120s
  ```
- A Hugging Face token with **approved access** to `meta-llama/Llama-3.1-8B`
  (request access at <https://huggingface.co/meta-llama/Llama-3.1-8B>, then create a
  Read token at <https://huggingface.co/settings/tokens>)
- ≥2 GPU worker nodes of the same SKU

## Pick your SKU and apply

| SKU | Manifest | Reference (16-GPU baseline) |
|---|---|---|
| H200 141GB SXM | `pytorchjob-streaming-h200.yaml` | MFU ~51.5%, tps ~8,800/GPU, 1000 steps in ~30 min |

H100, B200, B300 variants are not yet provided here. Use the standalone
[`../../torchtitan-llama3_1_8B-kubernetes-pytorchjob/`](../../torchtitan-llama3_1_8B-kubernetes-pytorchjob/)
in this repo for B200/B300 (it's still B300-defaulted). H100 variants behave
identically to H200 from a NCCL config perspective; if you need one, copy this
H200 manifest and swap the topology filename to `h100-80gb-sxm-ib-cloud-hypervisor.xml`.

## Steps

```bash
# 1. Edit the manifest to insert your HF token
#    (replace "<YOUR HF TOKEN HERE>" in both Master and Worker env blocks).
#    For production, use a Kubernetes Secret instead — see "Hardening" below.
vim pytorchjob-streaming-h200.yaml

# 2. Apply
kubectl apply -f pytorchjob-streaming-h200.yaml

# 3. Watch pod startup (~5 min first time for image pull)
kubectl get pods -l job-name=torchtitan-llama3-8b-streaming -w

# 4. Tail the master logs once both pods are Running
kubectl logs -f $(kubectl get pods \
  -l training.kubeflow.org/job-name=torchtitan-llama3-8b-streaming,training.kubeflow.org/replica-type=master \
  -o name)
```

## Reading the output

Every 10 steps, the master rank prints a line:

```
step: 100  loss: 6.27  grad_norm: 1.08  memory: 86.44GiB(61.83%)  tps: 8,811  tflops: 510.30  mfu: 51.60%
```

**Look for:**
- **MFU** should hold ~51–53% in steady state on H200 16-GPU. Drops to ~5% indicate the
  cluster has the GID-3 misconfig — see "Hardening" below.
- **Loss** should drop monotonically (warmup ~12 → ~4 by step 1000). Spikes or NaN = bad.
- **grad_norm** should drop into the single digits after warmup. > 50 sustained = unstable.
- **memory** should stabilize around 62% at batch=2 (this manifest). > 95% = OOM risk.
- One brief MFU dip every 100 steps is normal (profile-trace dump).
- One ~10pp MFU dip at step 500 is normal (async DCP checkpoint write).

## What the manifest configures vs the standalone example

This manifest is the **`-streamingdata`** variant (C4 dataset streams from Hugging Face at
runtime — no PVC required). It differs from the upstream
[`torchtitan-llama3_1_8B-kubernetes-pytorchjob/torchtitan-llama3-8b-streamingdata.yaml`](../../torchtitan-llama3_1_8B-kubernetes-pytorchjob/torchtitan-llama3-8b-streamingdata.yaml)
in three ways, all calibrated for **2-node H200 SXM IB**:

1. **`local_batch_size = 2`** (upstream default `1`). At batch=1 you only utilize ~47% of
   HBM and leave throughput on the table. At batch=2 you hit ~62% HBM and ~52% MFU.
   Batch=4 OOMs at 16 GPUs (the upstream `tps: 9,044, mfu: 52.96%` numbers are at 128 GPUs
   where each GPU's FSDP shard is 8× smaller).
2. **`[compile] enable = true`** (upstream default `false`). torch.compile fuses small
   kernels and adds ~1–2 min to step 1 but lifts MFU by several pp.
3. **NCCL env corrected for native IB**: no `NCCL_IB_GID_INDEX=3`, no `NCCL_NET_GDR_LEVEL=SYS`,
   `NCCL_BUFFSIZE=2097152`. These are the fixes documented in the parent branch's PR.

## Hardening for production / repeat runs

- **Replace HF_TOKEN placeholder with a Secret**:
  ```bash
  kubectl create secret generic hf-token --from-literal=token=<your_token>
  ```
  Then in the manifest:
  ```yaml
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-token
        key: token
  ```
- **Swap to the local-data variant** for repeat runs to avoid HF egress on every job.
  See `../../torchtitan-llama3_1_8B-kubernetes-pytorchjob/setup-local-c4-datavol.yaml`
  for the one-time data download Job pattern.
- **Persist outputs**: the manifest currently uses `emptyDir` for `/outputs`. Replace with
  a PVC if you want checkpoints or TensorBoard logs to survive pod deletion.

## Cleanup

```bash
kubectl delete pytorchjob torchtitan-llama3-8b-streaming
```
