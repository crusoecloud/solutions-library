#!/bin/bash

echo -e "\e[32mCrusoe Cluster Validation Test\e[0m"

echo -e "\e[33mChecking kernel messages of all hosts for Xid errors\e[0m"

for host in $(cat hostfile|awk '{print $1}');do ssh $host "sudo dmesg|grep NVRM"; done
echo -e "\e[33mNCCL all-reduce perfomance tests between all GPUs in cluster\e[0m"

source /opt/hpcx/hpcx-init.sh
hpcx_load

export NCCL_DEBUG=INFO
export LD_LIBRARY_PATH=/opt/hpcx/ucx/lib:$LD_LIBRARY_PATH
# export UCX_NET_DEVICES=mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1,mlx5_9:1,mlx5_10:1,mlx5_11:1,mlx5_12:1 # uncomment for B200 or adapt based on ibstat -v
# export NCCL_IB_HCA=mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1,mlx5_9:1,mlx5_10:1,mlx5_11:1,mlx5_12:1 # uncomment for B200 or adapt based on ibstat -v
# export NCCL_TOPO_FILE=/etc/crusoe/nccl_topo/b200-180gb-sxm-ib-cloud-hypervisor.xml # uncomment and changed per gpu type, ls /etc/crusoe/nccl_topo to see choices
# export NCCL_TOPO_FILE=/etc/crusoe/nccl_topo/b300-288gb-sxm-ib-cloud-hypervisor.xml
# export NCCL_TOPO_FILE=/etc/crusoe/nccl_topo/h200-141gb-sxm-ib-cloud-hypervisor.xml
# export NCCL_TOPO_FILE=/etc/crusoe/nccl_topo/h100-80gb-sxm-ib-cloud-hypervisor.xml

export NCCL_IB_MERGE_VFS=0
export NCCL_SOCKET_NTHREADS=4
export NCCL_NSOCKS_PERTHREAD=8

NUM_NODES=$(cat /home/ubuntu/hostfile | wc -l)
GPU_PER_NODE=$(nvidia-smi -L | wc -l)

/opt/hpcx/ompi/bin/mpirun --hostfile /home/ubuntu/hostfile -np $(( $NUM_NODES * $GPU_PER_NODE )) -N $GPU_PER_NODE \
         --bind-to none -x LD_LIBRARY_PATH -x UCX_NET_DEVICES -x NCCL_IB_HCA -x NCCL_TOPO_FILE -x NCCL_DEBUG \
        /opt/nccl-tests/build/all_reduce_perf -b 8G -e 32G -f 2 -g 1
