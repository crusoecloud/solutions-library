#!/usr/bin/env bash
# Render templates and apply the IB health probe Job to the current kubectl context.
# Waits for the Job to complete and writes a timestamped results file (gitignored).
#
# Usage:
#   ./apply.sh <pool-label> <nccl-topo-filename> [parallelism]
#
# Required arguments:
#   pool-label          value of the crusoe.ai/nodepool.name label on your
#                       GPU workers. Find with: kubectl get nodes -L crusoe.ai/nodepool.name
#   nccl-topo-filename  NCCL topology XML filename in /etc/crusoe/nccl_topo/
#                       on the host. Common values:
#                         h200-141gb-sxm-ib-cloud-hypervisor.xml
#                         b200-180gb-sxm-ib-cloud-hypervisor.xml
#
# Optional:
#   parallelism         number of nodes to probe (default: all nodes in the pool)
#
# Env overrides:
#   PROBE_IMAGE is auto-selected from the pool label:
#       h100/h200 pools → nccl-tests:12.8.1-ubuntu24.04-nccl-2.26.5-1  (CUDA 12.8)
#       all other pools → nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1  (CUDA 13.0)
#   TIMEOUT_SECS        default 600  (Job wait cap)
#   NO_WAIT=1           submit and exit; don't tail / write results

set -euo pipefail

cd "$(dirname "$0")"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <pool-label> <nccl-topo-filename> [parallelism]" >&2
    echo >&2
    echo "Discover values on your cluster:" >&2
    echo "  pool-label:   kubectl get nodes -L crusoe.ai/nodepool.name" >&2
    echo "  topo XMLs:    kubectl debug node/<one-gpu-node> --image=busybox -- ls /host/etc/crusoe/nccl_topo" >&2
    exit 1
fi

POOL_LABEL=$1
NCCL_TOPO_FILE=$2
if [ -z "${PROBE_IMAGE:-}" ]; then
    if echo "$POOL_LABEL" | grep -qiE 'h100|h200'; then
        PROBE_IMAGE=ghcr.io/crusoecloud/nccl-tests:12.8.1-ubuntu24.04-nccl-2.26.5-1
    else
        PROBE_IMAGE=ghcr.io/crusoecloud/nccl-tests:13.0.1-ubuntu24.04-nccl-2.29.2-1
    fi
fi
DCGM_LEVEL=${DCGM_LEVEL:-2}
OUTPUT_FILE=${OUTPUT_FILE:-results-$(date -u +%Y%m%d-%H%M%S).txt}
TIMEOUT_SECS=${TIMEOUT_SECS:-600}

# Auto-detect node count if not provided
if [ -n "${3:-}" ]; then
    PARALLELISM=$3
else
    PARALLELISM=$(kubectl get nodes \
        -l "crusoe.ai/nodepool.name=${POOL_LABEL}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
fi

if [ -z "$PARALLELISM" ] || [ "$PARALLELISM" -lt 1 ]; then
    echo "ERROR: no nodes match crusoe.ai/nodepool.name=${POOL_LABEL}" >&2
    echo "Available pools in this cluster:" >&2
    kubectl get nodes -L crusoe.ai/nodepool.name --no-headers 2>&1 | awk '{print "  "$NF}' | sort -u >&2
    exit 1
fi

echo ">>> context:      $(kubectl config current-context)"
echo ">>> pool:         $POOL_LABEL"
echo ">>> nccl topo:    $NCCL_TOPO_FILE"
echo ">>> parallelism:  $PARALLELISM (= node count)"
echo ">>> probe image:  $PROBE_IMAGE"

kubectl delete job ib-probe --ignore-not-found 2>/dev/null
kubectl delete configmap ib-probe-script --ignore-not-found 2>/dev/null

kubectl create configmap ib-probe-script --from-file=probe.sh=probe.sh

export POOL_LABEL NCCL_TOPO_FILE PARALLELISM PROBE_IMAGE DCGM_LEVEL
envsubst < ib-probe-job.yaml | kubectl apply -f -

if [ "${NO_WAIT:-0}" = "1" ]; then
    echo
    echo ">>> Job submitted. NO_WAIT=1 set — exiting without waiting."
    echo "    Tail logs:    kubectl logs -l app=ib-probe -f --max-log-requests=$PARALLELISM"
    echo "    Parse later:  kubectl logs -l app=ib-probe --tail=-1 | ./parse-results.sh"
    exit 0
fi

echo
echo ">>> waiting for Job (timeout=${TIMEOUT_SECS}s) ..."
sleep 3   # let the Job controller create pods before polling

START=$(date +%s)
while true; do
    STATUS=$(kubectl get job ib-probe -o jsonpath='{.status.conditions[*].type}' 2>/dev/null)
    SUCC=$(kubectl get job ib-probe -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)
    FAIL=$(kubectl get job ib-probe -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)
    ACTIVE=$(kubectl get job ib-probe -o jsonpath='{.status.active}' 2>/dev/null || echo 0)
    ELAPSED=$(( $(date +%s) - START ))
    printf "    t=%3ds  active=%s succeeded=%s failed=%s  cond=[%s]\n" \
        "$ELAPSED" "${ACTIVE:-0}" "${SUCC:-0}" "${FAIL:-0}" "${STATUS:-?}"
    case "$STATUS" in
        *Complete*) echo ">>> COMPLETE"; JOB_OK=1; break;;
        *Failed*)   echo ">>> FAILED";   JOB_OK=0; break;;
    esac
    if [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
        echo ">>> TIMEOUT after ${TIMEOUT_SECS}s"
        JOB_OK=0
        break
    fi
    sleep 15
done

# backoffLimit=0 + per-node failure → Job marked Failed as soon as ONE pod exits 1.
# Other pods may still be pulling images / running. Wait for ALL pods to reach a
# terminal phase before collecting logs, so the output file covers every node.
echo
echo ">>> waiting for all $PARALLELISM pods to reach terminal phase ..."
PHASE_WAIT_DEADLINE=$(( $(date +%s) + 180 ))
while [ $(date +%s) -lt "$PHASE_WAIT_DEADLINE" ]; do
    phases=$(kubectl get pods -l app=ib-probe -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    n_done=$(echo "$phases" | tr ' ' '\n' | grep -cE '^(Succeeded|Failed)$' || echo 0)
    n_total=$(echo "$phases" | tr ' ' '\n' | grep -c . || echo 0)
    echo "    pod phases: [$phases]  ($n_done/$n_total terminal)"
    [ "$n_done" -ge "$PARALLELISM" ] && break
    sleep 10
done

echo
echo ">>> writing $OUTPUT_FILE"

# Capture logs once so parse-results.sh and the raw dump see the same data.
RAW_LOGS=$(kubectl logs -l app=ib-probe --tail=-1 2>&1)

{
    echo "# ib-health-probe results"
    echo "# context:      $(kubectl config current-context)"
    echo "# pool:         $POOL_LABEL"
    echo "# nccl topo:    $NCCL_TOPO_FILE"
    echo "# nodes:        $PARALLELISM"
    echo "# image:        $PROBE_IMAGE"
    echo "# generated:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "$RAW_LOGS" | ./parse-results.sh || true
    echo
    echo "## Raw per-pod output (for debugging)"
    echo
    for pod in $(kubectl get pods -l app=ib-probe -o name 2>/dev/null); do
        echo "--- $pod ---"
        kubectl logs "$pod" 2>&1
        echo
    done
} > "$OUTPUT_FILE"

# Re-run parse-results.sh to get its exit code (above runs inside the heredoc subshell).
# Disable set -e locally so a nonzero exit doesn't abort before we capture it.
set +e
echo "$RAW_LOGS" | ./parse-results.sh >/dev/null 2>&1
HEALTH_OK=${PIPESTATUS[1]}
set -e

echo ">>> $OUTPUT_FILE written ($(wc -l < "$OUTPUT_FILE") lines)"
echo
echo "--- summary ---"
head -60 "$OUTPUT_FILE"

# Exit nonzero if EITHER the Job didn't reach a clean terminal state OR the
# parse step found health failures. Lets CI/scripts detect "real" problems.
if [ "$JOB_OK" != "1" ] || [ "$HEALTH_OK" != "0" ]; then
    exit 1
fi
