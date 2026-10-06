#!/usr/bin/env bash
# ============================================================================
# gpu-to-nic-bw-hostmem.sh
# ----------------------------------------------------------------------------
# Per-rail RDMA bidirectional bandwidth across all 8 Pollara VFs (node1↔node2)
# using HOST MEMORY as the RDMA buffer. This is the simple, no-CCR-auth,
# no-image-build baseline that proves each rail is physically healthy.
#
# For the full-fat GPU-direct dma-buf number (~779 Gb/s per rail, the
# customer-facing headline), see the sibling test:
#   ../gpu-to-nic-bw-gpu-direct/src/gpu-to-nic-bw-gpu-direct.sh
#
# Design (avoids two traps that bit us earlier):
#   - ONE pod per node holds all 8 vnics (matches the RCCL worker spec) and
#     iterates 8 rails serially internally. Trying to run one pod per rail on
#     the same node deadlocks on `amd.com/vnic` availability — the device
#     plugin grants ALL 8 rails to a single pod, and a second pod can't
#     schedule until the first releases.
#   - Client waits a fixed 4 s before each rail's ib_write_bw invocation.
#     Do NOT probe the server port with nc / /dev/tcp — ib_write_bw's server
#     accepts exactly ONE TCP connection, so a probe consumes the real
#     client's slot.
#
# Inputs (env):
#   NAMESPACE   default
#   IMAGE       upstream a-56 roce-workload (public, no auth needed)
#   PULL_SECRET ccr-cred (unused for the public image, but the pod spec
#               declares it for symmetry with the RCCL manifest)
#   NODE1,NODE2 auto-picked from `amd.com/gpu` nodes if unset
#   SIZE        8388608 (8 MiB message)
#   ITERS       5000
#   QPS         4 (matches NCCL_IB_QPS_PER_CONNECTION)
#   MTU         4096 (Pollara max active_mtu — force it to prevent
#               perftest auto-negotiating down)
# ============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
IMAGE="${IMAGE:-mirror.gcr.io/rocm/roce-workload:ubuntu24_rocm-7.2_rccl-7.2.0_anp-v1.3.0_ainic-1.117.5-a-56}"
PULL_SECRET="${PULL_SECRET:-ccr-cred}"
SIZE="${SIZE:-8388608}"
ITERS="${ITERS:-5000}"
QPS="${QPS:-4}"
MTU="${MTU:-4096}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/../logs}"
mkdir -p "$LOG_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
TS_LC=$(date -u +%Y%m%d-%H%M%S)
OUT="$LOG_DIR/gpu-to-nic-bw-hostmem-${TS}.log"

# Auto-pick 2 amd.com/gpu nodes
if [[ -z "${NODE1:-}" || -z "${NODE2:-}" ]]; then
  NODES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && NODES+=("$line")
  done < <(kubectl get nodes -o jsonpath='{range .items[?(@.status.allocatable.amd\.com/gpu)]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  NODE1="${NODE1:-${NODES[0]:-}}"
  NODE2="${NODE2:-${NODES[1]:-}}"
fi
[[ -n "$NODE1" && -n "$NODE2" ]] || { echo "ERR: need NODE1/NODE2"; exit 1; }

SRV_POD="ibwb-hm-srv-${TS_LC}"
CLI_POD="ibwb-hm-cli-${TS_LC}"

echo "==> NODE1 (server) = $NODE1"
echo "==> NODE2 (client) = $NODE2"
echo "==> image           = $IMAGE"
echo "==> size, iters     = $SIZE, $ITERS"
echo "==> QPs, MTU        = $QPS, $MTU"
echo "==> log             = $OUT"

# ---- deploy server pod ----------------------------------------------------
cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $SRV_POD
  labels: { app: gpu-to-nic-bw-hostmem, role: server }
  annotations:
    k8s.v1.cni.cncf.io/networks: >-
      rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad
spec:
  nodeName: $NODE1
  restartPolicy: Never
  hostIPC: true
  imagePullSecrets: [{ name: $PULL_SECRET }]
  containers:
    - name: srv
      image: $IMAGE
      command: ["/bin/bash","-c"]
      args:
        - |
          for RAIL in 0 1 2 3 4 5 6 7; do
            PORT=\$((18500 + RAIL))
            echo "=== SERVER rail=\$RAIL port=\$PORT ==="
            ib_write_bw -d ionic_\$RAIL -F -b --report_gbits -s $SIZE -n $ITERS -p \$PORT -x 1 -q $QPS -m $MTU
            echo "=== SERVER rail=\$RAIL DONE ==="
          done
          echo "=== ALL SERVERS DONE — sleeping 30 min for post-run inspection ==="
          sleep 1800
      securityContext: { capabilities: { add: [IPC_LOCK] } }
      resources:
        requests: { amd.com/vnic: 8 }
        limits:   { amd.com/vnic: 8 }
EOF

echo "==> waiting for server pod Ready"
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/"$SRV_POD" --timeout=180s

SRV_IP=$(kubectl -n "$NAMESPACE" get pod "$SRV_POD" -o jsonpath='{.status.podIP}')
echo "==> server pod IP = $SRV_IP"

sleep 4

# ---- deploy client pod ----------------------------------------------------
cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $CLI_POD
  labels: { app: gpu-to-nic-bw-hostmem, role: client }
  annotations:
    k8s.v1.cni.cncf.io/networks: >-
      rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad,rdma-rail-nad
spec:
  nodeName: $NODE2
  restartPolicy: Never
  hostIPC: true
  imagePullSecrets: [{ name: $PULL_SECRET }]
  containers:
    - name: cli
      image: $IMAGE
      command: ["/bin/bash","-c"]
      args:
        - |
          for RAIL in 0 1 2 3 4 5 6 7; do
            PORT=\$((18500 + RAIL))
            echo "=== CLIENT rail=\$RAIL port=\$PORT srv=$SRV_IP ==="
            sleep 4
            for attempt in 1 2 3 4 5; do
              if ib_write_bw -d ionic_\$RAIL -F -b --report_gbits -s $SIZE -n $ITERS -p \$PORT -x 1 -q $QPS -m $MTU $SRV_IP; then
                break
              fi
              echo "  rail \$RAIL attempt \$attempt failed; sleep 2 and retry"
              sleep 2
            done
            echo "=== CLIENT rail=\$RAIL DONE ==="
          done
          echo "=== ALL CLIENTS DONE ==="
      securityContext: { capabilities: { add: [IPC_LOCK] } }
      resources:
        requests: { amd.com/vnic: 8 }
        limits:   { amd.com/vnic: 8 }
EOF

echo "==> streaming client logs (blocks until container exits)"
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}=Running' pod/"$CLI_POD" --timeout=180s
kubectl -n "$NAMESPACE" logs -f "$CLI_POD" > "$OUT" 2>&1

echo
echo "==> per-rail summary:"
grep " $SIZE " "$OUT" | awk 'BEGIN{r=0}
  {printf "  ionic_%d : peak=%7s Gb/s   avg=%7s Gb/s\n", r++, $3, $4}'

echo
echo "==> teardown pods"
kubectl -n "$NAMESPACE" delete pod "$SRV_POD" "$CLI_POD" --wait=false >/dev/null 2>&1 || true
echo "==> log: $OUT"
