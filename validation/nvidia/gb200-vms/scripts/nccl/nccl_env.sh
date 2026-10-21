# shellcheck shell=bash
# nccl_env.sh -- NCCL environment for multi-node NVLink (MNNVL) on GB200 VMs in one NVLink
# domain, plus auto-detection of the interface, MPI install and nccl-tests.
#
#   source nccl_env.sh        # exports the env (anything already exported wins)
#   nccl_env_print            # what will be passed to every rank
#
# NOTES ON THE SETTINGS
#   * NCCL_MNNVL_ENABLE=1: require multi-node NVLink (default 2 = auto would silently fall back
#     to IB). Needs the IMEX domain up and /dev/nvidia-caps-imex-channels/channel0 on every node.
#   * NCCL_CUMEM_ENABLE=1: cuMem allocations, required for MNNVL.
#   * NCCL_NVLS_ENABLE=1: NVLink SHARP (NVLS) multicast; ~920 vs ~680 GB/s all_reduce without it.
#   * NCCL_DEBUG=INFO with SUBSYS INIT,NVLS: the runner checks the log for
#     "MNNVL 1 cliqueId <x> cliqueSize <ranks>" and "NVLS multicast support is available".
#   * MPI is only a TCP bootstrap (pml ob1, btl self,tcp, UCX_TLS=self,tcp): UCX over the
#     IB devices can break MPI_Init on these VMs.

: "${NCCL_MNNVL_ENABLE:=1}"
: "${NCCL_CUMEM_ENABLE:=1}"
: "${NCCL_NVLS_ENABLE:=1}"
: "${NCCL_DEBUG:=INFO}"
: "${NCCL_DEBUG_SUBSYS:=INIT,NVLS}"
: "${UCX_TLS:=self,tcp}"
export NCCL_MNNVL_ENABLE NCCL_CUMEM_ENABLE NCCL_NVLS_ENABLE NCCL_DEBUG NCCL_DEBUG_SUBSYS UCX_TLS

nccl_detect_iface(){ ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
# VPC subnet of the default-route interface, e.g. 10.0.0.0/20. MPI selects interfaces by this
# CIDR, not by name: NIC names differ between hypervisors (enp50s0 on QEMU hosts, ens3 on
# cloud-hypervisor hosts), so a name taken from the anchor does not exist on every node.
nccl_detect_cidr(){ local i; i=$(nccl_detect_iface); [ -n "$i" ] && ip -o -4 route show dev "$i" scope link 2>/dev/null | awk '$1 ~ /\// {print $1; exit}'; }
# MPI is only the launcher/bootstrap; NCCL carries the data. Prefer the image's DOCA Open MPI
# (works as installed). HPC-X is relocatable: its mpirun rejects every option unless
# hpcx-init.sh has been sourced (OPAL_PREFIX set), so it is only used in that case.
nccl_find_mpi_home(){
  local c
  for c in ${MPI_HOME:-} /usr/mpi/gcc/openmpi-* /opt/openmpi ${OPAL_PREFIX:-} /usr/local /usr; do
    [ -x "$c/bin/mpirun" ] && { echo "$c"; return 0; }
  done
  return 1
}
nccl_find_tests_dir(){
  local c
  for c in ${NCCL_TESTS_DIR:-} /opt/nccl-tests/build /opt/nccl_tests/build /usr/local/nccl-tests/build "$HOME/nccl-tests/build"; do
    [ -x "$c/all_reduce_perf" ] && { echo "$c"; return 0; }
  done
  return 1
}

: "${NET_IFACE:=$(nccl_detect_iface)}"
: "${NET_CIDR:=$(nccl_detect_cidr)}"
: "${MPI_HOME:=$(nccl_find_mpi_home || true)}"
: "${NCCL_TESTS_DIR:=$(nccl_find_tests_dir || true)}"
export NET_IFACE NET_CIDR MPI_HOME NCCL_TESTS_DIR
# NCCL bootstrap socket: exclude container/loopback interfaces; whatever carries the VPC address
# is used on each node regardless of its name.
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-^docker,lo,br-,veth,virbr}"

# IB HCAs for NCCL (scale-out beyond one NVLink domain), chosen by property not by mlx5_N name:
# InfiniBand link layer, >= NCCL_IB_MIN_GBPS (400), port ACTIVE. The lower-rate Ethernet frontend
# NIC (an mlx5 device too) is excluded automatically. Opt-in: NCCL_IB_HCA=auto.
nccl_detect_ib_hcas(){
  local d p rate out=()
  for d in /sys/class/infiniband/*; do
    [ -e "$d" ] || continue
    for p in "$d"/ports/*; do
      [ "$(cat "$p/link_layer" 2>/dev/null)" = InfiniBand ] || continue
      rate=$(cut -d' ' -f1 "$p/rate" 2>/dev/null); [ "${rate%.*}" -ge "${NCCL_IB_MIN_GBPS:-400}" ] 2>/dev/null || continue
      case "$(cat "$p/state" 2>/dev/null)" in *ACTIVE*) out+=("$(basename "$d"):$(basename "$p")");; esac
    done
  done
  (IFS=,; echo "${out[*]}")
}
[ "${NCCL_IB_HCA:-}" = auto ] && NCCL_IB_HCA="=$(nccl_detect_ib_hcas)"

# HPC-X keeps its OpenMPI libs next to the binary; make them visible to every rank.
if [ -n "${MPI_HOME:-}" ] && [ "$MPI_HOME" != /usr ] && [ -d "$MPI_HOME/lib" ]; then
  case ":${LD_LIBRARY_PATH:-}:" in *":$MPI_HOME/lib:"*) ;; *) export LD_LIBRARY_PATH="$MPI_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac
  case ":$PATH:" in *":$MPI_HOME/bin:"*) ;; *) export PATH="$MPI_HOME/bin:$PATH";; esac
fi

# Forwarded to every rank with mpirun -x. Optional knobs are forwarded only when set.
NCCL_ENV_VARS=(NCCL_MNNVL_ENABLE NCCL_CUMEM_ENABLE NCCL_NVLS_ENABLE NCCL_DEBUG NCCL_DEBUG_SUBSYS
  NCCL_SOCKET_IFNAME UCX_TLS PATH LD_LIBRARY_PATH)
for _v in NCCL_P2P_LEVEL NCCL_IB_DISABLE NCCL_IB_HCA NCCL_ALGO NCCL_PROTO NCCL_TOPO_FILE NCCL_NET_GDR_LEVEL; do
  [ -n "${!_v:-}" ] && { export "${_v?}"; NCCL_ENV_VARS+=("$_v"); }
done
unset _v

nccl_env_print(){
  local v
  for v in "${NCCL_ENV_VARS[@]}"; do [ "$v" = PATH ] || [ "$v" = LD_LIBRARY_PATH ] || echo "$v=${!v:-}"; done
  echo "MPI_HOME=${MPI_HOME:-<not found>} NCCL_TESTS_DIR=${NCCL_TESTS_DIR:-<not found>} NET_IFACE=${NET_IFACE:-?} NET_CIDR=${NET_CIDR:-?}"
}
