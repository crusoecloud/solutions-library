#!/usr/bin/env bash
# ============================================================================
# deploy-rccl-allreduce.sh
# ----------------------------------------------------------------------------
# Render the MPIJob template with envsubst, apply it, wait for the
# launcher to finish, extract the Avg bus bandwidth from the log, and
# compare against the pass threshold.
#
# Pass criterion for 2 nodes × 8 MI355X + 8 Pollara rails per node:
#   busbw >= 300 GB/s at 8 GiB message size
#     (each node has 8×400 Gbps = 400 GB/s of RoCE bandwidth; 300 GB/s
#      is a conservative Rail-Optimized 75 % efficiency target)
#
# Inputs (env or defaults):
#   NAMESPACE     default
#   IMAGE         [REQUIRED] full image ref, e.g.
#                 registry.<region>.ccr.crusoecloudcompute.com/<registry>.<project-short>/roce-workload:<tag>
#   PULL_SECRET   k8s docker-registry secret name (default: ccr-cred)
#   N             number of worker pods (default: 2 = one per MI355X node)
#   MANIFEST      path to rccl-allreduce-mpijob-generic.yaml
#   RESULTS_DIR   where to save logs (default validation-suite/results)
#   BUSBW_MIN_GBPS pass threshold in GB/s (default: 300)
# ============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
PULL_SECRET="${PULL_SECRET:-ccr-cred}"
N="${N:-2}"
BUSBW_MIN_GBPS="${BUSBW_MIN_GBPS:-300}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script now lives at <test>/src/, so manifest is a sibling in src/, logs at ../logs
MANIFEST="${MANIFEST:-$SCRIPT_DIR/rccl-allreduce-mpijob-generic.yaml}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../logs}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG="$RESULTS_DIR/rccl-allreduce-${TS}.log"
mkdir -p "$RESULTS_DIR"

: "${IMAGE:?IMAGE=<full CCR image ref> required. See tokens list; ccr-cred must exist.}"

echo "==> IMAGE       : $IMAGE"
echo "==> PULL_SECRET : $PULL_SECRET"
echo "==> N (workers) : $N"
echo "==> namespace   : $NAMESPACE"
echo "==> manifest    : $MANIFEST"
echo "==> log         : $LOG"

command -v envsubst >/dev/null || { echo "ERR: envsubst not found (install gettext)"; exit 1; }
kubectl get ns "$NAMESPACE" >/dev/null || { echo "ERR: namespace $NAMESPACE missing"; exit 1; }
kubectl -n "$NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1 || {
  echo "ERR: docker-registry secret $PULL_SECRET missing in $NAMESPACE"; exit 1;
}

# ---- clean prior run --------------------------------------------------------
if kubectl -n "$NAMESPACE" get mpijob rccl-test >/dev/null 2>&1; then
  echo "==> deleting prior MPIJob rccl-test"
  kubectl -n "$NAMESPACE" delete mpijob rccl-test --wait=true
fi

# ---- apply ------------------------------------------------------------------
echo "==> envsubst + apply"
N="$N" IMAGE="$IMAGE" PULL_SECRET="$PULL_SECRET" \
  envsubst '${N} ${IMAGE} ${PULL_SECRET}' < "$MANIFEST" | tee "$RESULTS_DIR/rccl-allreduce-${TS}.rendered.yaml" | kubectl -n "$NAMESPACE" apply -f -

# ---- wait for launcher completion -------------------------------------------
echo "==> waiting for launcher pod to appear (up to 5 min)"
LAUNCHER=""
for i in $(seq 1 60); do
  LAUNCHER=$(kubectl -n "$NAMESPACE" get pod -l training.kubeflow.org/job-name=rccl-test,training.kubeflow.org/job-role=launcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$LAUNCHER" ]] && break
  sleep 5
done
[[ -n "$LAUNCHER" ]] || { echo "ERR: launcher pod never appeared"; exit 1; }
echo "  launcher = $LAUNCHER"

echo "==> wait for launcher container to actually start (not just be scheduled)"
# The launcher container may still be in ContainerCreating; kubectl logs -f errors
# with "waiting to start" until it's Running. Poll every 5 s up to 5 min.
for i in $(seq 1 60); do
  PHASE=$(kubectl -n "$NAMESPACE" get pod "$LAUNCHER" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
    echo "  launcher phase = $PHASE"
    break
  fi
  sleep 5
done

echo "==> streaming launcher logs (kubectl logs -f blocks until the container exits) -> $LOG"
# This is the correct wait pattern: `kubectl logs -f` follows until the target
# container terminates, then returns. No separate `kubectl wait` race.
kubectl -n "$NAMESPACE" logs -f "$LAUNCHER" > "$LOG" 2>&1 || true

# ---- parse busbw ------------------------------------------------------------
echo
echo "==> parsing Avg bus bandwidth"
BUSBW=$(awk '/Avg bus bandwidth/ {print $NF; exit}' "$LOG")
if [[ -z "$BUSBW" ]]; then
  echo "FAIL: no 'Avg bus bandwidth' line in launcher log — see $LOG"
  exit 2
fi
echo "  Avg busbw = $BUSBW GB/s"

# ---- pass/fail --------------------------------------------------------------
if python3 -c "import sys; sys.exit(0 if float('$BUSBW') >= float('$BUSBW_MIN_GBPS') else 1)"; then
  echo "PASS: busbw $BUSBW GB/s >= threshold $BUSBW_MIN_GBPS GB/s"
  exit 0
else
  echo "FAIL: busbw $BUSBW GB/s < threshold $BUSBW_MIN_GBPS GB/s"
  exit 3
fi
