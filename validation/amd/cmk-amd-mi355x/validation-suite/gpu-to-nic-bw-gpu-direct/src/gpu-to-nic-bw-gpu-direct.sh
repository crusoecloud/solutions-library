#!/usr/bin/env bash
# ============================================================================
# gpu-to-nic-bw-gpu-direct.sh
# ----------------------------------------------------------------------------
# Per-rail GPU-DIRECT dma-buf bidirectional bandwidth across all 8 Pollara VFs
# (node1↔node2). GPU HBM is the RDMA buffer, dma-buf is the export path, so
# the NIC DMAs straight into/out of device memory with no PCIe DRAM hop.
#
# This is the customer-facing HEADLINE test — hits ~779 Gb/s per rail
# (105 % of Crusoe engineering's published 740 Gb/s number, 97 % of the
# 800 Gb/s theoretical bidirectional line rate for 400 Gbps × 2 dir).
#
# Required image (built from ../build-image/):
#   IMAGE=<CCR>/roce-workload:a-77-crusoe-amdperftest
# Stock upstream perftest 6.25 has --use_rocm flag scaffolding but the
# ROCm memory-type factory function isn't registered — every invocation
# returns "Unsupported memory type". The image referenced above bundles
# perftest from github.com/ROCm/rdma-perftest branch
# master-dmabuf-rocm-20250114, configured with
# --enable-rocm --enable-rocm-dmabuf --with-rocm=/opt/rocm, so the
# --use_rocm=N --use_rocm_dmabuf flags actually work end-to-end.
#
# Three settings are load-bearing here and each will silently crush the
# number if you drop them:
#   -q 4        four QPs (defaults to 1 → halves BW to ~400 Gb/s)
#   -m 4096     MTU 4096 (perftest auto-negotiates down to 2048 with
#               GPU-direct on some ROCm versions → halves BW again)
#   /boot mount perftest reads /boot/config-$(uname -r) at startup and
#               aborts silently before binding its TCP port if absent;
#               client then sees "Couldn't connect". Same mount pattern
#               as mlcommons rccl-mpijob-bundle2.yaml worker template.
#
# Inputs (env):
#   NAMESPACE   default
#   IMAGE       [REQUIRED] full URL of the a-77-crusoe-amdperftest image
#   PULL_SECRET ccr-cred
#   NODE1,NODE2 auto-picked from `amd.com/gpu` nodes if unset
#   SIZE        8388608 (8 MiB)
#   ITERS       5000
#   QPS         4
#   MTU         4096
# ============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
: "${IMAGE:?IMAGE=<CCR>/roce-workload:a-77-crusoe-amdperftest is required (build via ../build-image/src/build-kaniko-amdperftest.sh)}"
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
OUT="$LOG_DIR/gpu-to-nic-bw-gpu-direct-${TS}.log"

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

SRV_POD="ibwb-gd-srv-${TS_LC}"
CLI_POD="ibwb-gd-cli-${TS_LC}"

echo "==> NODE1 (server) = $NODE1"
echo "==> NODE2 (client) = $NODE2"
echo "==> image           = $IMAGE"
echo "==> size, iters     = $SIZE, $ITERS"
echo "==> QPs, MTU        = $QPS, $MTU"
echo "==> log             = $OUT"

# ---- deploy server pod (all 8 GPUs + all 8 vnics + /boot hostPath) --------
cat <<EOF | kubectl -n "$NAMESPACE" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $SRV_POD
  labels: { app: gpu-to-nic-bw-gpu-direct, role: server }
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
            ib_write_bw -d ionic_\$RAIL -F -b --report_gbits -s $SIZE -n $ITERS -p \$PORT \\
              -x 1 -q $QPS -m $MTU --use_rocm=\$RAIL --use_rocm_dmabuf
            echo "=== SERVER rail=\$RAIL DONE ==="
          done
          echo "=== ALL SERVERS DONE — sleeping 30 min for post-run inspection ==="
          sleep 1800
      securityContext: { capabilities: { add: [IPC_LOCK] } }
      resources:
        requests: { amd.com/gpu: 8, amd.com/vnic: 8 }
        limits:   { amd.com/gpu: 8, amd.com/vnic: 8 }
      volumeMounts:
        - { name: boot, mountPath: /boot, readOnly: true }
  volumes:
    - name: boot
      hostPath: { path: /boot, type: Directory }
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
  labels: { app: gpu-to-nic-bw-gpu-direct, role: client }
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
              if ib_write_bw -d ionic_\$RAIL -F -b --report_gbits -s $SIZE -n $ITERS -p \$PORT \\
                   -x 1 -q $QPS -m $MTU --use_rocm=\$RAIL --use_rocm_dmabuf $SRV_IP; then
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
        requests: { amd.com/gpu: 8, amd.com/vnic: 8 }
        limits:   { amd.com/gpu: 8, amd.com/vnic: 8 }
      volumeMounts:
        - { name: boot, mountPath: /boot, readOnly: true }
  volumes:
    - name: boot
      hostPath: { path: /boot, type: Directory }
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
