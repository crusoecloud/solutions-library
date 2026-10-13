#!/bin/bash
#SBATCH --job-name=gpu-burn
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --output=logs/%x_%j.out
#SBATCH --time=02:00:00
#SBATCH --exclusive

# ---------------------------------------------------------------------------
# NCCL tuning for Crusoe H100 SXM (InfiniBand + NVLink)
# ---------------------------------------------------------------------------
export NCCL_IB_PCI_RELAXED_ORDERING=1
export NCCL_IB_SPLIT_DATA_ON_QPS=0
export NCCL_IB_QPS_PER_CONNECTION=2
export NCCL_IBEXT_DISABLE=1
export NCCL_NVLS_ENABLE=1
export NCCL_IB_SL=1
export NCCL_IB_MERGE_VFS=0
export NCCL_DEBUG=WARN
export NCCL_TOPO_FILE=/etc/crusoe/nccl_topo/h100-80gb-sxm-ib-cloud-hypervisor.xml
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_HCA="mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1"
export OMPI_MCA_coll_hcoll_enable=0
export PMIX_MCA_gds="^ds12"
export UCX_NET_DEVICES="mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1"
export TORCH_NCCL_ASYNC_ERROR_HANDLING=0

# ---------------------------------------------------------------------------
# Job config — override at submit time with --export=ALL,MODEL_SIZE=small
# ---------------------------------------------------------------------------
MODEL_SIZE=${MODEL_SIZE:-large}     # small (~1.3B) or large (~5B, default)
WANDB_FLAG=""
[ -f "$HOME/.wandb_env" ] && source "$HOME/.wandb_env"
[ -n "$WANDB_API_KEY" ] && WANDB_FLAG="--wandb"

CONTAINER_IMAGE="nvcr.io/nvidia/pytorch:25.01-py3"
GPUS_PER_NODE=8
NNODES=$SLURM_NNODES
MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)
MASTER_PORT=6001

echo "Job $SLURM_JOB_ID | model_size=$MODEL_SIZE | $NNODES nodes × $GPUS_PER_NODE GPUs | master=$MASTER_ADDR:$MASTER_PORT"
mkdir -p logs

CMD="pip install -q --upgrade wandb 2>/dev/null; python -u -m torch.distributed.run \
  --nproc_per_node ${GPUS_PER_NODE} \
  --nnodes ${NNODES} \
  --rdzv_endpoint ${MASTER_ADDR}:${MASTER_PORT} \
  --rdzv_backend c10d \
  --max_restarts 0 \
  --tee 3 \
  /workspace/train.py \
  --model-size ${MODEL_SIZE} \
  --epochs 5 \
  --batch-size 2 \
  --seq-len 2048 \
  --dataset-size 16384 \
  ${WANDB_FLAG}"

srun \
  --container-writable \
  --container-image="${CONTAINER_IMAGE}" \
  --container-mounts="$PWD:/workspace,/etc/crusoe:/etc/crusoe:ro" \
  --container-env=WANDB_API_KEY \
  bash -c "$CMD"
