<!--
  Licensed under the terms of the parent repository. See the LICENSE file in
  the root of crusoecloud/solutions-library for details.
-->

# GPU Burn — Grafana Dashboard Validator for Crusoe Managed Slurm

A zero-dependency two-node GPU training benchmark. Copy two files to your cluster and run one command. No HuggingFace token, no model downloads, no pip install.

Use this to validate that your Grafana dashboards (DCGM metrics) are working correctly after cluster setup.

Tested configuration: 2× H100 SXM nodes (16 GPUs total), Crusoe Managed Slurm, PyTorch 25.01 container via Pyxis/enroot.

---

## What it does

Trains a synthetic GPT-style transformer on random token sequences. No real dataset or model weights are used — everything is generated in-memory. The job runs for ~10–20 minutes to produce sustained Grafana metrics.

**Grafana panels exercised:**

| Panel | What drives it |
|---|---|
| GPU SM Utilization | FlashAttention + large FFN matmuls |
| GPU Memory Used | ~14 GB (small) or ~55 GB (large) per GPU |
| NVLink Bandwidth | NCCL all-reduce within each node |
| RoCE / IB Bandwidth | NCCL all-reduce across the 2-node boundary |
| GPU Power Draw | Sustained compute → near TDP |
| GPU Temperature | Sustained load → thermal ramp visible |

---

## Setup

### 1. Copy files to the cluster

```bash
scp train.py train.sbatch <user>@<login-node-ip>:~/
```

### 2. (Optional) Enable Weights & Biases

```bash
printf "export WANDB_API_KEY=<your-key>" > ~/.wandb_env
chmod 600 ~/.wandb_env
```

If `.wandb_env` is absent or `WANDB_API_KEY` is unset, W&B is silently skipped.

### 3. Submit

`sbatch` uses the current working directory at submission time as the job's working dir, which is where output logs and the container-mounted `/workspace` resolve to. Submit from the directory containing `train.sbatch` and `train.py`:

```bash
cd ~
sbatch train.sbatch
```

That's it. No other configuration needed.

---

## Model sizes

| `MODEL_SIZE` | Params | GPU mem (per GPU) | Runtime (2×H100, 16 GPUs) |
|---|---|---|---|
| `large` (default) | ~5B | ~55 GB | ~20 min |
| `small` | ~1.3B | ~14 GB | ~5 min |

Override at submit time:

```bash
sbatch --export=ALL,MODEL_SIZE=small train.sbatch
```

---

## Monitoring

```bash
squeue                                # job status
tail -f logs/gpu-burn_<jobid>.out    # streaming log (relative to submission dir)
```

Per-epoch output (rank 0):

```
Epoch   0 | loss=10.2334 | ppl=27874.2 | lr=3.00e-04 | 4821 tok/s | mem=54.3GB | 198.4s
```

---

## Troubleshooting

**`Requested topology configuration is not available`**

Run `scontrol reconfig` on the login node to refresh the Slurm topology tree.

**Job stuck with `(BadConstraints)`**

Remove `#SBATCH --gpus-per-node=8` if present — GRES registration can be inconsistent after node replacement. GPU count is set via `GPUS_PER_NODE=8` in the script body.

**Container pull is slow on first run**

The ~10 GB `nvcr.io/nvidia/pytorch:25.01-py3` image is pulled once and cached on each node's NVMe array. Subsequent runs start in under 30 seconds.
