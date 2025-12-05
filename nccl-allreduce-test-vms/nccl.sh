#!/bin/bash

HOSTFILE='./hostfile'
GPUS_PER_NODE=8
NP=$(( $(grep -c -v '^$' "$HOSTFILE") * GPUS_PER_NODE ))

echo "============================="
echo "GPUs Per Node: $GPUS_PER_NODE"
echo "Number of Processes: $NP"
echo "============================="

mpirun \
    -x LD_LIBRARY_PATH \
    -x UCX_TLS=tcp,self \
    --mca plm_rsh_agent "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    --mca coll ^hcoll \
    --allow-run-as-root \
    -np $NP \
    -N $GPUS_PER_NODE \
    --hostfile $HOSTFILE \
    /opt/nccl-tests/build/all_reduce_perf -b 2G -e 32G -f 2 -g 1