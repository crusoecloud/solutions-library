#!/bin/bash
# Run a 2-node, 16-GPU RCCL all_reduce_perf test
# Mirrors the fabric env vars from launch-distributed.sh.
# Runs 1 MPI rank per GPU (16 total: 2 nodes × 8 GPUs).

ALL_REDUCE_PERF=/root/rccl-tests/build/all_reduce_perf

# --- fabric / RCCL env ---
export NCCL_IB_DISABLE=0
export NCCL_IB_HCA=ionic_0,ionic_1,ionic_2,ionic_3,ionic_4,ionic_5,ionic_6,ionic_7
export NCCL_IB_GID_INDEX=1
export NCCL_IB_QPS_PER_CONNECTION=2
export NCCL_NET_GDR_LEVEL=4
export NCCL_TOPO_FILE=/etc/crusoe/rccl_topo/mi355x-288gb-ib.xml
export NCCL_SOCKET_IFNAME=eth0
export NCCL_DEBUG=WARN
export NCCL_BUFFSIZE=33554432
export NCCL_ALGO=Ring
export HSA_FORCE_FINE_GRAIN_PCIE=1
export NCCL_PXN_DISABLE=1

# prepend custom RCCL + ANP plugin so rccl-tests picks up the built libs
export LD_LIBRARY_PATH=/root/rccl/build/release/build/lib:/root/amd-anp/build:${LD_LIBRARY_PATH:-}

mpirun \
  -np 16 \
  --hostfile /home/clouduser/hostfile \
  --map-by ppr:8:node \
  --bind-to none \
  --mca orte_keep_fqdn_hostnames t \
  --mca btl_tcp_if_include eth0 \
  --mca plm_rsh_num_concurrent 1024 \
  --mca routed direct \
  -x PATH \
  -x LD_LIBRARY_PATH \
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
  "$ALL_REDUCE_PERF" \
    --minbytes 8G \
    --maxbytes 32G \
    --stepfactor 2 \
    --iters 50 \
    --warmup_iters 10 \
    --check 1 \
    --ngpus 1
