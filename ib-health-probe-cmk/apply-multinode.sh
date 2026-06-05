#!/usr/bin/env bash
# Render + apply the multi-node NCCL MPIJob, tail launcher, write results-multinode.txt.
#
# Usage:
#   ./apply-multinode.sh <pool-label> <nccl-topo-filename> <nccl-ib-list> [worker-replicas]
#
# Required arguments:
#   pool-label          value of the crusoe.ai/nodepool.name label on GPU workers.
#                       Find with: kubectl get nodes -L crusoe.ai/nodepool.name
#   nccl-topo-filename  NCCL topology XML filename under /etc/crusoe/nccl_topo/ on host.
#                       Common values:
#                         h200-141gb-sxm-ib-cloud-hypervisor.xml
#                         b200-180gb-sxm-ib-cloud-hypervisor.xml
#   nccl-ib-list        comma-separated NDR IB HCA allowlist with :port suffix.
#                       Standard layouts:
#                         H200:  mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1
#                         B200:  mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1,mlx5_9:1,mlx5_10:1,mlx5_11:1,mlx5_12:1
#
# Optional:
#   worker-replicas     number of nodes (default: all nodes in the pool)
#
# Env overrides:
#   PROBE_IMAGE                 default: ghcr.io/crusoecloud/nccl-tests:13.0.1-...
#   NCCL_NITERS                 default 20  (set to 5 at >100 nodes for a quick smoke test)
#   NCCL_BOOTSTRAP_TIMEOUT_SEC  default 120 (bump to 600 at 340 nodes)
#   NO_WAIT=1                   submit and exit; don't tail / write results
#   TIMEOUT_SECS                default 1800 (launcher wait cap; raise at large scale)
#
# Prereqs:
#   - MPI Operator installed:
#       kubectl apply --server-side -f \
#         https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
#   - Cluster's GPU/hostdev resources free (drain workloads first — this manifest
#     uses device-plugin allocation, NOT coexist mode)

set -euo pipefail
cd "$(dirname "$0")"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <pool-label> <nccl-topo-filename> <nccl-ib-list> [worker-replicas]" >&2
    echo >&2
    echo "Discover values on your cluster:" >&2
    echo "  pool-label:   kubectl get nodes -L crusoe.ai/nodepool.name" >&2
    echo "  topo XMLs:    kubectl debug node/<one-gpu-node> --image=busybox -- ls /host/etc/crusoe/nccl_topo" >&2
    echo "  HCA layout:   run ./apply.sh first — its log lists active HCAs" >&2
    exit 1
fi

POOL_LABEL=$1
NCCL_TOPO_FILE=$2
NCCL_IB_LIST=$3
WORKER_REPLICAS=${4:-}

PROBE_IMAGE=${PROBE_IMAGE:-ghcr.io/crusoecloud/nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1}
NCCL_NITERS=${NCCL_NITERS:-20}
NCCL_BOOTSTRAP_TIMEOUT_SEC=${NCCL_BOOTSTRAP_TIMEOUT_SEC:-120}
TIMEOUT_SECS=${TIMEOUT_SECS:-1800}

if [ -z "$WORKER_REPLICAS" ]; then
    WORKER_REPLICAS=$(kubectl get nodes \
        -l "crusoe.ai/nodepool.name=${POOL_LABEL}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
fi
if [ -z "$WORKER_REPLICAS" ] || [ "$WORKER_REPLICAS" -lt 1 ]; then
    echo "ERROR: no nodes match crusoe.ai/nodepool.name=${POOL_LABEL}" >&2
    exit 1
fi

TOTAL_GPUS=$((WORKER_REPLICAS * 8))

echo ">>> context:                $(kubectl config current-context)"
echo ">>> pool:                   $POOL_LABEL"
echo ">>> nccl topo:              $NCCL_TOPO_FILE"
echo ">>> nccl ib hca allowlist:  $NCCL_IB_LIST"
echo ">>> worker replicas:        $WORKER_REPLICAS  (= TOTAL_GPUS $TOTAL_GPUS)"
echo ">>> iters per size:         $NCCL_NITERS"
echo ">>> bootstrap timeout:      ${NCCL_BOOTSTRAP_TIMEOUT_SEC}s"
echo ">>> image:                  $PROBE_IMAGE"

if ! kubectl get crd mpijobs.kubeflow.org >/dev/null 2>&1; then
    echo "ERROR: MPI Operator not installed. Install with:" >&2
    echo "  kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml" >&2
    exit 1
fi

kubectl delete mpijob nccl-integration --ignore-not-found 2>/dev/null

export POOL_LABEL NCCL_TOPO_FILE WORKER_REPLICAS TOTAL_GPUS PROBE_IMAGE \
       NCCL_IB_LIST NCCL_NITERS NCCL_BOOTSTRAP_TIMEOUT_SEC
envsubst < multi-node-nccl-job.yaml | kubectl apply -f -

if [ "${NO_WAIT:-0}" = "1" ]; then
    echo
    echo ">>> Submitted. Tail with:"
    echo "    kubectl logs -f -l training.kubeflow.org/job-role=launcher"
    exit 0
fi

echo
echo ">>> waiting for launcher (timeout=${TIMEOUT_SECS}s) ..."
# Launcher pod takes a few seconds to appear after MPIJob create
sleep 5
LAUNCHER=$(kubectl get pods -l training.kubeflow.org/job-role=launcher -o name 2>/dev/null | head -1)
if [ -z "$LAUNCHER" ]; then
    echo "ERROR: launcher pod didn't appear within 5s. Check 'kubectl get mpijob'." >&2
    exit 1
fi

START=$(date +%s)
while [ $(date +%s) -lt $((START + TIMEOUT_SECS)) ]; do
    P=$(kubectl get "$LAUNCHER" -o jsonpath='{.status.phase}' 2>/dev/null)
    ELAPSED=$(( $(date +%s) - START ))
    LAST=$(kubectl logs "$LAUNCHER" --tail=1 2>/dev/null | tr -d '\r' | head -c 80)
    printf "    t=%4ds  phase=%-10s  %s\n" "$ELAPSED" "${P:-?}" "$LAST"
    case "$P" in
        Succeeded) JOB_OK=1; break;;
        Failed)    JOB_OK=0; break;;
    esac
    sleep 30
done
JOB_OK=${JOB_OK:-0}

echo
echo ">>> writing results-multinode.txt"
{
    echo "# multi-node NCCL all_reduce_perf"
    echo "# context:        $(kubectl config current-context)"
    echo "# pool:           $POOL_LABEL"
    echo "# nccl topo:      $NCCL_TOPO_FILE"
    echo "# replicas:       $WORKER_REPLICAS  (TOTAL_GPUS=$TOTAL_GPUS)"
    echo "# image:          $PROBE_IMAGE"
    echo "# generated:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Per-size results"
    kubectl logs "$LAUNCHER" 2>&1 | grep -E "^\[1,0\]<stdout>:[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+(float|half)" \
        | sed 's|^\[1,0\]<stdout>:||'
    echo
    echo "## Summary"
    kubectl logs "$LAUNCHER" 2>&1 | grep -E "NCCL version|Avg bus bandwidth|test concluded|Out of bounds|ERROR|abort" \
        | sed 's|^\[1,0\]<stdout>:||' | head -10
    echo
    echo "## Full launcher log (tail 200)"
    kubectl logs "$LAUNCHER" --tail=200 2>&1
} > results-multinode.txt

echo ">>> results-multinode.txt written ($(wc -l < results-multinode.txt) lines)"
echo
head -25 results-multinode.txt

[ "$JOB_OK" = "1" ] || exit 1
