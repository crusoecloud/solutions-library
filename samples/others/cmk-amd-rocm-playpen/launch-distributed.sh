#!/bin/bash
# Launch a 2-node, 16-GPU distributed training job.
# mpirun starts one process per node; each process launches torchrun with 8 workers.

export NCCL_IB_DISABLE=0
export NCCL_IB_HCA=ionic_0,ionic_1,ionic_2,ionic_3,ionic_4,ionic_5,ionic_6,ionic_7
export NCCL_IB_GID_INDEX=1
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_NET_GDR_LEVEL=4
export NCCL_TOPO_FILE=/etc/crusoe/rccl_topo/mi355x-288gb-ib.xml
export NCCL_SOCKET_IFNAME=eth0
export NCCL_DEBUG=INFO
export NCCL_BUFFSIZE=33554432
export HSA_FORCE_FINE_GRAIN_PCIE=1
export NCCL_ALGO=Ring
export NCCL_PXN_DISABLE=1

mpirun \
  -np 2 \
  --mca orte_keep_fqdn_hostnames t \
  --hostfile ~/hostfile \
  --map-by node \
  --bind-to none \
  -x PATH \
  -x NCCL_IB_DISABLE \
  -x NCCL_IB_HCA \
  -x NCCL_IB_GID_INDEX \
  -x NCCL_IB_QPS_PER_CONNECTION \
  -x NCCL_NET_GDR_LEVEL \
  -x NCCL_TOPO_FILE \
  -x NCCL_SOCKET_IFNAME \
  -x NCCL_DEBUG \
  -x NCCL_BUFFSIZE \
  -x HSA_FORCE_FINE_GRAIN_PCIE \
  -x NCCL_ALGO \
  -x NCCL_PXN_DISABLE \
  bash -c "
    source ~/.venv/bin/activate
    torchrun \\
      --nnodes=2 \\
      --nproc_per_node=8 \\
      --node_rank=\${OMPI_COMM_WORLD_RANK} \\
      --master_addr=rocm-workload-0.rocm-workload-headless \\
      --master_port=29500 \\
      ~/train-distributed.py
  "
