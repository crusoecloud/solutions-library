#!/usr/bin/env python3
"""
Synthetic multi-node GPU training benchmark for Crusoe Managed Slurm.

Requires only torch — pre-installed in nvcr.io/nvidia/pytorch containers.
No model downloads, no HuggingFace token, no pip install needed.
W&B is optional: set WANDB_API_KEY and pass --wandb to enable.

Usage (via train.sbatch):
    sbatch train.sbatch
    sbatch --export=ALL,MODEL_SIZE=small train.sbatch
"""

import math
import os
import time
import argparse

import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP


# ---------------------------------------------------------------------------
# Model architecture — synthetic GPT-style transformer
# ---------------------------------------------------------------------------

class CausalSelfAttention(nn.Module):
    def __init__(self, d_model: int, n_heads: int):
        super().__init__()
        self.n_heads = n_heads
        self.d_head = d_model // n_heads
        self.qkv = nn.Linear(d_model, 3 * d_model, bias=False)
        self.proj = nn.Linear(d_model, d_model, bias=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        B, T, C = x.shape
        qkv = self.qkv(x).reshape(B, T, 3, self.n_heads, self.d_head).permute(2, 0, 3, 1, 4)
        q, k, v = qkv.unbind(0)
        # Uses FlashAttention kernel when available (torch >= 2.0 on H100)
        x = F.scaled_dot_product_attention(q, k, v, is_causal=True)
        return self.proj(x.transpose(1, 2).reshape(B, T, C))


class TransformerBlock(nn.Module):
    def __init__(self, d_model: int, n_heads: int):
        super().__init__()
        self.ln1 = nn.LayerNorm(d_model)
        self.attn = CausalSelfAttention(d_model, n_heads)
        self.ln2 = nn.LayerNorm(d_model)
        self.ffn = nn.Sequential(
            nn.Linear(d_model, 4 * d_model, bias=False),
            nn.GELU(),
            nn.Linear(4 * d_model, d_model, bias=False),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.attn(self.ln1(x))
        x = x + self.ffn(self.ln2(x))
        return x


class SyntheticGPT(nn.Module):
    def __init__(self, vocab_size: int, d_model: int, n_layers: int, n_heads: int, seq_len: int):
        super().__init__()
        self.tok_emb = nn.Embedding(vocab_size, d_model)
        self.pos_emb = nn.Embedding(seq_len, d_model)
        self.blocks = nn.ModuleList([TransformerBlock(d_model, n_heads) for _ in range(n_layers)])
        self.ln_f = nn.LayerNorm(d_model)
        self.head = nn.Linear(d_model, vocab_size, bias=False)
        self.head.weight = self.tok_emb.weight  # weight tying

    def forward(self, idx: torch.Tensor) -> torch.Tensor:
        B, T = idx.shape
        pos = torch.arange(T, device=idx.device)
        x = self.tok_emb(idx) + self.pos_emb(pos)
        for block in self.blocks:
            x = block(x)
        return self.head(self.ln_f(x))


# ---------------------------------------------------------------------------
# Model size presets
# ---------------------------------------------------------------------------

MODEL_CONFIGS = {
    # ~1.3B params — fits in ~14 GB/GPU with AdamW, good for quick validation
    "small": dict(d_model=2048, n_layers=16, n_heads=16),
    # ~5.0B params — uses ~55 GB/GPU with AdamW, realistic H100 workload (default)
    "large": dict(d_model=4096, n_layers=24, n_heads=32),
}


# ---------------------------------------------------------------------------
# Synthetic dataset — deterministic random tokens, no disk I/O
# ---------------------------------------------------------------------------

class SyntheticTokens(torch.utils.data.Dataset):
    def __init__(self, vocab_size: int, seq_len: int, size: int):
        self.vocab_size = vocab_size
        self.seq_len = seq_len
        self.size = size

    def __len__(self) -> int:
        return self.size

    def __getitem__(self, idx: int):
        g = torch.Generator()
        g.manual_seed(idx)
        tokens = torch.randint(0, self.vocab_size, (self.seq_len + 1,), generator=g)
        return tokens[:-1], tokens[1:]


# ---------------------------------------------------------------------------
# Training loop
# ---------------------------------------------------------------------------

def run_epoch(epoch, model, loader, optimizer, scheduler, local_rank, global_rank):
    model.train()
    total_loss = 0.0
    total_tokens = 0
    steps = 0
    t0 = time.time()

    for x, y in loader:
        x = x.to(local_rank, non_blocking=True)
        y = y.to(local_rank, non_blocking=True)
        optimizer.zero_grad(set_to_none=True)

        with torch.autocast("cuda", dtype=torch.bfloat16):
            logits = model(x)
            loss = F.cross_entropy(logits.reshape(-1, logits.size(-1)), y.reshape(-1))

        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
        optimizer.step()

        total_loss += loss.item()
        total_tokens += x.numel()
        steps += 1

    scheduler.step()

    elapsed = time.time() - t0
    avg_loss = total_loss / steps
    tok_per_s = total_tokens / elapsed

    if global_rank == 0:
        mem_gb = torch.cuda.max_memory_allocated(local_rank) / 1e9
        lr = scheduler.get_last_lr()[0]
        print(
            f"Epoch {epoch:3d} | loss={avg_loss:.4f} | ppl={math.exp(min(avg_loss, 20)):.1f} | "
            f"lr={lr:.2e} | {tok_per_s:.0f} tok/s | mem={mem_gb:.1f}GB | {elapsed:.1f}s",
            flush=True,
        )
        torch.cuda.reset_peak_memory_stats(local_rank)
        return avg_loss, tok_per_s, mem_gb, lr

    return None, None, None, None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Synthetic GPU training benchmark")
    parser.add_argument("--model-size",    choices=["small", "large"], default="large")
    parser.add_argument("--vocab-size",    type=int,   default=32000)
    parser.add_argument("--seq-len",       type=int,   default=2048)
    parser.add_argument("--batch-size",    type=int,   default=2,
                        help="Per-GPU batch size")
    parser.add_argument("--dataset-size",  type=int,   default=16384,
                        help="Number of synthetic sequences (per run, not per GPU)")
    parser.add_argument("--epochs",        type=int,   default=5)
    parser.add_argument("--lr",            type=float, default=3e-4)
    parser.add_argument("--wandb",         action="store_true",
                        help="Enable W&B logging (requires WANDB_API_KEY env var)")
    args = parser.parse_args()

    # --- distributed setup ---
    dist.init_process_group("nccl")
    local_rank  = int(os.environ["LOCAL_RANK"])
    global_rank = dist.get_rank()
    world_size  = dist.get_world_size()
    torch.cuda.set_device(local_rank)

    cfg = MODEL_CONFIGS[args.model_size]

    if global_rank == 0:
        d, L = cfg["d_model"], cfg["n_layers"]
        # approximate: L*(4d²+8d²) + 2*vocab*d (weight-tied head)
        n_params = L * 12 * d * d + 2 * args.vocab_size * d
        print(
            f"[gpu-burn] model={args.model_size} d={d} layers={L} "
            f"params≈{n_params/1e9:.2f}B | world_size={world_size} | "
            f"epochs={args.epochs} dataset_size={args.dataset_size} "
            f"batch={args.batch_size} seq={args.seq_len}",
            flush=True,
        )

    # --- model ---
    # Cast to bf16 before DDP: halves parameter + gradient memory (10 GB vs 20 GB for 5B model)
    # AdamW(fused=True) keeps exp_avg/exp_avg_sq in fp32 internally for stability.
    model = SyntheticGPT(
        vocab_size=args.vocab_size,
        seq_len=args.seq_len,
        **cfg,
    ).to(local_rank, dtype=torch.bfloat16)
    model = DDP(model, device_ids=[local_rank])

    # --- data ---
    dataset = SyntheticTokens(args.vocab_size, args.seq_len, args.dataset_size)
    sampler = torch.utils.data.distributed.DistributedSampler(
        dataset, num_replicas=world_size, rank=global_rank, shuffle=True,
    )
    loader = torch.utils.data.DataLoader(
        dataset, batch_size=args.batch_size, sampler=sampler,
        num_workers=4, pin_memory=True,
    )

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, fused=True)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=args.epochs, eta_min=args.lr * 0.1,
    )

    # --- optional W&B ---
    wandb_run = None
    if args.wandb and global_rank == 0:
        try:
            import wandb
            job_id = os.environ.get("SLURM_JOB_ID", "local")
            wandb_run = wandb.init(
                project="crusoe-gpu-burn",
                name=f"{args.model_size}-job{job_id}",
                config={**vars(args), **cfg},
            )
        except Exception as e:
            print(f"[gpu-burn] W&B init failed (continuing without it): {e}", flush=True)

    # --- training ---
    for epoch in range(args.epochs):
        sampler.set_epoch(epoch)
        avg_loss, tok_per_s, mem_gb, lr = run_epoch(
            epoch, model, loader, optimizer, scheduler, local_rank, global_rank,
        )
        if wandb_run and avg_loss is not None:
            wandb_run.log({
                "epoch":                  epoch,
                "train/loss":             avg_loss,
                "throughput/tok_per_sec": tok_per_s,
                "gpu/mem_gb":             mem_gb,
                "lr":                     lr,
            })

    if wandb_run:
        wandb_run.finish()
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
