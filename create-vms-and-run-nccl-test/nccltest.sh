#!/bin/bash

echo -e "\e[32mCrusoe Cluster Validation Test\e[0m"

echo -e "\e[33mChecking kernel messages of all hosts for Xid errors\e[0m"

for host in $(cat hostfile|awk '{print $1}');do ssh $host "sudo dmesg|grep NVRM"; done

echo -e "\e[33mNCCL all-reduce perfomance tests between all GPUs in cluster\e[0m"

source /opt/hpcx/hpcx-init.sh
hpcx_load
/opt/hpcx/ompi/bin/mpirun --hostfile /home/ubuntu/hostfile -np $(cat /home/ubuntu/hostfile|wc -l) \
	-x LD_LIBRARY_PATH=/opt/hpcx/ucx/lib:$LD_LIBRARY_PATH \
#	-x UCX_NET_DEVICES=mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1,mlx5_9:1,mlx5_10:1,mlx5_11:1,mlx5_12:1 \ #uncomment only if using B200
	/opt/nccl-tests/build/all_reduce_perf -b 1G -e 32G -f 2 -g $(nvidia-smi -L|wc -l)
