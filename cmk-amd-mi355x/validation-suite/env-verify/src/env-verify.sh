#!/usr/bin/env bash
# ============================================================================
# env-verify.sh
# ----------------------------------------------------------------------------
# Environment sanity dump for both MI355X nodes. Deploys one privileged
# debug pod per node (upstream AMD roce-workload a-56 image, no auth needed)
# and captures:
#   - Kernel version + relevant boot params
#   - Loaded modules (amdgpu, ionic, ionic_rdma, dma-buf helpers, ib_peer_mem)
#   - GPU health (amd-smi static + dynamic)
#   - GPU-to-NIC PCIe affinity (lspci walk)
#   - Every Pollara VF: ethtool -i, ethtool link state, MTU, ibv_devinfo
#   - RoCE GID indices (show_gids)
#   - dmesg errors last hour (amdgpu, ionic, ib*)
#   - HugePages state
#   - The topology XML we intend to reference is readable from a pod mount
#
# Output: results/env-report-<node>-<ts>.txt (one per node) + a summary index.
#
# Notes:
#   * Uses the upstream `-a-56` image because our target `-a-77` isn't built
#     yet AND all inspection binaries are identical between a-56/a-77.
#   * Pods run with hostPID + hostNetwork + hostPath so we see host-level
#     state, not per-container namespace.
# ============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
IMAGE="${IMAGE:-mirror.gcr.io/rocm/roce-workload:ubuntu24_rocm-7.2_rccl-7.2.0_anp-v1.3.0_ainic-1.117.5-a-56}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script now lives at <test>/src/, so logs are ../logs relative to it
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../logs}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$RESULTS_DIR"

# Auto-pick amd.com/gpu nodes. Portable to macOS bash 3.2 (no mapfile).
NODES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && NODES+=("$line")
done < <(kubectl get nodes -o jsonpath='{range .items[?(@.status.allocatable.amd\.com/gpu)]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [[ "${#NODES[@]}" -lt 1 ]]; then
  # fallback: just take all Ready nodes
  while IFS= read -r line; do
    [[ -n "$line" ]] && NODES+=("$line")
  done < <(kubectl get nodes -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi
echo "==> nodes: ${NODES[*]}"

# ---- pod template -----------------------------------------------------------
pod_yaml() {
  local NAME=$1 NODE=$2
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $NAME
  namespace: $NAMESPACE
  labels: { app: env-verify }
spec:
  nodeName: $NODE
  hostPID: true
  hostNetwork: true
  restartPolicy: Never
  automountServiceAccountToken: false
  tolerations: [{operator: "Exists"}]
  containers:
    - name: peek
      image: $IMAGE
      command: ["sleep","600"]
      securityContext:
        privileged: true
        capabilities: { add: [SYS_ADMIN, NET_ADMIN, IPC_LOCK] }
      volumeMounts:
        - { name: proc,       mountPath: /host/proc,       readOnly: true }
        - { name: sys,        mountPath: /host/sys,        readOnly: true }
        - { name: dev,        mountPath: /host/dev }
        - { name: crusoe,     mountPath: /host/etc/crusoe, readOnly: true }
        - { name: kernel-log, mountPath: /host/var/log/kern.log, readOnly: true }
        - { name: modules,    mountPath: /host/lib/modules, readOnly: true }
      resources:
        requests: { amd.com/gpu: 8, amd.com/vnic: 8 }
        limits:   { amd.com/gpu: 8, amd.com/vnic: 8 }
  volumes:
    - { name: proc,       hostPath: { path: /proc, type: Directory } }
    - { name: sys,        hostPath: { path: /sys,  type: Directory } }
    - { name: dev,        hostPath: { path: /dev,  type: Directory } }
    - { name: crusoe,     hostPath: { path: /etc/crusoe, type: Directory } }
    - { name: kernel-log, hostPath: { path: /var/log/kern.log, type: FileOrCreate } }
    - { name: modules,    hostPath: { path: /lib/modules, type: Directory } }
EOF
}

# ---- deploy pods ------------------------------------------------------------
for NODE in "${NODES[@]}"; do
  NAME="env-verify-${NODE%%.*}"
  echo "==> deploy $NAME on $NODE"
  pod_yaml "$NAME" "$NODE" | kubectl -n "$NAMESPACE" apply -f - >/dev/null
done

# ---- wait for Ready ---------------------------------------------------------
for NODE in "${NODES[@]}"; do
  NAME="env-verify-${NODE%%.*}"
  echo "==> wait Ready: $NAME"
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/"$NAME" --timeout=600s
done

# ---- collect ---------------------------------------------------------------
collect_for_node() {
  local NODE=$1
  local NAME="env-verify-${NODE%%.*}"
  local OUT="$RESULTS_DIR/env-report-${NODE%%.*}-${TS}.txt"

  echo "==> collect from $NAME -> $OUT"
  {
    echo "# node        : $NODE"
    echo "# pod         : $NAME"
    echo "# image       : $IMAGE"
    echo "# timestamp   : $TS"
    echo

    echo "===================================================================="
    echo " KERNEL"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      uname -a
      echo "--- boot cmdline ---"; cat /host/proc/cmdline
      echo "--- kernel taint ---"; cat /host/proc/sys/kernel/tainted
    '

    echo
    echo "===================================================================="
    echo " KERNEL MODULES"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      grep -E "^(amdgpu|amd_sched|amdttm|amdkcl|amddrm|ionic|ionic_rdma|ib_peer_mem|ib_uverbs|ib_core|mlx5|dma_buf|drm|xnack)" /host/proc/modules \
        | sort | awk "{printf \"  %-24s size=%s used=%s by=%s\n\", \$1, \$2, \$3, \$4}"
    '

    echo
    echo "===================================================================="
    echo " GPU HEALTH (amd-smi)"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      amd-smi version | head -3 || true
      echo
      echo "--- amd-smi static (bus, subsys, vbios, firmware) ---"
      amd-smi static -a --json 2>/dev/null | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for g in d:
    print(f\"GPU {g.get(\\\"gpu\\\",\\\"?\\\")}: bus={g.get(\\\"bus\\\",{}).get(\\\"bdf\\\",\\\"?\\\")} vbios={g.get(\\\"vbios\\\",{}).get(\\\"version\\\",\\\"?\\\")}\")
" 2>/dev/null || amd-smi static -a 2>&1 | head -20
      echo
      echo "--- amd-smi monitor (util, mem, temp, power) ---"
      amd-smi monitor -u -m -t -p 2>&1 | head -30
      echo
      echo "--- amd-smi bad-pages / ecc ---"
      amd-smi bad-pages 2>&1 | head -20 || true
      echo
      amd-smi metric --ecc 2>&1 | head -30 || true
    '

    echo
    echo "===================================================================="
    echo " RDMA / POLLARA VFs"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      echo "--- ibv_devinfo -l ---"
      ibv_devinfo -l
      echo
      echo "--- ibv_devinfo -v (per device summary) ---"
      for d in $(ibv_devinfo -l | tail -n +2); do
        echo "=== $d ==="
        ibv_devinfo -d "$d" | grep -E "^\s+(state|link_layer|phys_state|max_mtu|active_mtu|node_guid|sys_image_guid|fw_ver|hca_id)" | head -20
      done
      echo
      echo "--- show_gids | head -30 (RoCEv2 GIDs) ---"
      show_gids 2>&1 | head -30 || true
      echo
      echo "--- per-NIC ethtool -i / link / MTU ---"
      for iface in $(ls /host/sys/class/net/ 2>/dev/null | grep -E "^(ionic|eth|enp)" | head -12); do
        echo "=== $iface ==="
        # ethtool -i uses the netlink socket, needs the interface visible
        ethtool -i "$iface" 2>&1 | head -6
        ip -o link show "$iface" 2>&1 | head -2
      done
    '

    echo
    echo "===================================================================="
    echo " GPU <-> NIC PCIe TOPOLOGY (as seen inside the guest)"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      echo "--- lspci -Dvvv | AMD Instinct MI3* + Pensando ionic ---"
      lspci -Dvvv 2>/dev/null | awk "/^[0-9a-f]/{keep=0} /1002:75/ || /1dd8:1003/ {keep=1} keep" | head -80
      echo
      echo "--- topology XML we plan to reference ---"
      ls -la /host/etc/crusoe/rccl_topo/
      wc -l /host/etc/crusoe/rccl_topo/mi355x-288gb-ib.xml
      # sanity: is device 0x75a3 (MI355X) actually in the XML?
      grep -c "0x75a3" /host/etc/crusoe/rccl_topo/mi355x-288gb-ib.xml && echo "  MI355X device IDs found"
    '

    echo
    echo "===================================================================="
    echo " HUGEPAGES"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      grep -E "^Huge" /host/proc/meminfo
      cat /host/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    '

    echo
    echo "===================================================================="
    echo " DMESG last 200 (amdgpu / ionic / rdma / mlx / dma-buf errors)"
    echo "===================================================================="
    kubectl -n "$NAMESPACE" exec "$NAME" -- bash -c '
      dmesg -T 2>/dev/null | grep -Ei "(amdgpu|ionic|rdma|mlx|dma-buf|iommu|numa)" | tail -100
    '

    echo
    echo "===================================================================="
    echo " END ($NODE)"
    echo "===================================================================="
  } > "$OUT" 2>&1
  echo "  wrote $(wc -l < "$OUT") lines to $OUT"
}

for NODE in "${NODES[@]}"; do
  collect_for_node "$NODE"
done

# ---- teardown pods ----------------------------------------------------------
echo
echo "==> teardown env-verify pods"
kubectl -n "$NAMESPACE" delete pod -l app=env-verify --wait=false >/dev/null

echo
echo "==> reports written under $RESULTS_DIR:"
ls -la "$RESULTS_DIR"/env-report-*.txt 2>/dev/null | tail -10
