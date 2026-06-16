#!/usr/bin/env bash
# run-nccl-test.sh — submit an NCCL all_reduce_perf MPIJob scaled to NUM_NODES B300 nodes.
#
# Usage:
#   ./run-nccl-test.sh <NUM_NODES>
#
# Example (4-node cluster):
#   ./run-nccl-test.sh 4

set -euo pipefail

GPUS_PER_NODE=8

usage() {
  echo "Usage: $0 <NUM_NODES>"
  echo "  NUM_NODES  Number of B300 worker nodes (each has ${GPUS_PER_NODE} GPUs)"
  exit 1
}

[[ $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ ]] || usage

NUM_NODES=$1
TOTAL_GPUS=$(( NUM_NODES * GPUS_PER_NODE ))
JOB_NAME="nccl-tests-gdr-${TOTAL_GPUS}-b300"

echo "Submitting MPIJob '${JOB_NAME}': ${NUM_NODES} nodes × ${GPUS_PER_NODE} GPUs = ${TOTAL_GPUS} total processes"

kubectl apply -f - <<EOF
apiVersion: kubeflow.org/v1
kind: MPIJob
metadata:
  name: ${JOB_NAME}
spec:
  slotsPerWorker: ${GPUS_PER_NODE}
  runPolicy:
    cleanPodPolicy: Running
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          restartPolicy: OnFailure
          initContainers:
          - image: abesharphpe/nccl-tests-b300:latest
            imagePullPolicy: Always
            name: init
            command: ["sh", "-c", "sleep 5"]
          containers:
          - image: abesharphpe/nccl-tests-b300:latest
            imagePullPolicy: Always
            name: nccl-test-launcher
            securityContext:
              capabilities:
                add: ["IPC_LOCK"]
            env:
            - name: NCCL_TOPO_FILE
              value: /opt/nccl_topo/b300-288gb-sxm-ib-cloud-hypervisor.xml
            - name: UCX_RNDV_SCHEME
              value: "get_zcopy"
            command:
            - mpirun
            - --allow-run-as-root
            - --tag-output
            - -np
            - "${TOTAL_GPUS}"
            - -N
            - "${GPUS_PER_NODE}"
            - -bind-to
            - none
            - -map-by
            - slot
            - -mca
            - coll_hcoll_enable
            - "0"
            - -x
            - NCCL_IB_PCI_RELAXED_ORDERING=1
            - -x
            - NCCL_IB_SPLIT_DATA_ON_QPS=0
            - -x
            - NCCL_IB_QPS_PER_CONNECTION=2
            - -x
            - NCCL_IB_MERGE_VFS=0
            - -x
            - NCCL_IB_HCA=mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_12
            - -x
            - NCCL_IBEXT_DISABLE=1
            - -x
            - NCCL_TOPO_FILE
            - -x
            - PATH
            - -x
            - LD_LIBRARY_PATH
            - -x
            - NCCL_DEBUG=INFO
            - -x
            - NCCL_NVLS_ENABLE=1
            - -x
            - NCCL_IB_SL=1
            - /opt/nccl-tests/build/all_reduce_perf
            - -b
            - "2G"
            - -e
            - "32G"
            - -f
            - "2"
            - -t
            - "1"
            - -g
            - "1"
            - -c
            - "1"
            - -n
            - "100"
    Worker:
      replicas: ${NUM_NODES}
      template:
        spec:
          restartPolicy: OnFailure
          runtimeClassName: nvidia
          volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 64Gi
          containers:
          - image: abesharphpe/nccl-tests-b300:latest
            imagePullPolicy: Always
            name: nccl-worker
            securityContext:
              capabilities:
                add: ["IPC_LOCK"]
            env:
            - name: NCCL_TOPO_FILE
              value: /opt/nccl_topo/b300-288gb-sxm-ib-cloud-hypervisor.xml
            - name: NCCL_DEBUG
              value: INFO
            - name: UCX_RNDV_SCHEME
              value: "get_zcopy"
            volumeMounts:
            - mountPath: /dev/shm
              name: dshm
            resources:
              limits:
                nvidia.com/gpu: ${GPUS_PER_NODE}
                nvidia.com/hostdev: ${GPUS_PER_NODE}
                memory: 128000Mi
              requests:
                nvidia.com/gpu: ${GPUS_PER_NODE}
                nvidia.com/hostdev: ${GPUS_PER_NODE}
                memory: 128000Mi
EOF

echo ""
echo "Job submitted. Watch pod status:"
echo "  kubectl get pods -l training.kubeflow.org/job-name=${JOB_NAME} -w"
echo ""
echo "Stream launcher logs (once the launcher pod is Running):"
echo "  kubectl logs -f \$(kubectl get pods -l training.kubeflow.org/job-name=${JOB_NAME},training.kubeflow.org/replica-type=launcher -o name)"
echo ""
echo "After completion, retrieve full results:"
echo "  kubectl logs \$(kubectl get pods -l training.kubeflow.org/job-name=${JOB_NAME},training.kubeflow.org/replica-type=launcher -o name)"
