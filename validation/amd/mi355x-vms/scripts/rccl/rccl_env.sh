# shellcheck shell=bash
# rccl_env.sh -- validated AINIC (Pensando Pollara / ionic) RCCL environment for
# MI355X VMs (mi355x-288gb-roce.8x), plus auto-detection helpers.
#
#   source rccl_env.sh            # exports the env, fills auto-detected values
#   rccl_env_print                # show what will be passed to every rank
#
# Every value is "${VAR:-default}", so anything already exported wins. Auto-detected
# values (interface, GID index, ANP plugin, MPI, rccl-tests) are only detected when
# the corresponding variable is unset.
#
# NOTES ON THE SETTINGS
#   * NCCL_IB_TIMEOUT=23 / NCCL_IB_RETRY_CNT=7: ~34 s per ack wait x 7 retries, so a
#     transient rail hiccup is ridden out instead of aborting with status=12.
#   * --mca pml ob1 + UCX_TLS=tcp,self,sm: MPI is a pure TCP bootstrap; RCCL owns the
#     RDMA NICs.
#   * NCCL_NET_PLUGIN: absolute path to the AMD ANP plugin (librccl-anp.so) shipped in
#     the image; the log line "ANP plugin loaded successfully" confirms it is in use.
#   * NCCL_SOCKET_FAMILY=AF_INET keeps the bootstrap socket on IPv4.
#   * NCCL_PXN_DISABLE=1 for ring collectives (rail-aligned traffic). The runner flips it
#     to 0 for alltoall, which needs cross-rail forwarding over xGMI.
#   * Interface and NCCL_IB_GID_INDEX are auto-detected (RoCE v2, non link-local).
#   * NCCL_NET_OPTIONAL_RECV_COMPLETION=0 and NET_OPTIONAL_RECV_COMPLETION=1 are two
#     DIFFERENT knobs (RCCL core vs ANP plugin); the opposite values are intentional.

# ---------------------------------------------------------------- constants
: "${RCCL_TOPO_FILE_DEFAULT:=/etc/crusoe/rccl_topo/mi355x-288gb-ib.xml}"
: "${ROCM_PATH:=/opt/rocm}"
export ROCM_PATH

# ---------------------------------------------------------------- helpers
_rccl_log() { printf '[rccl_env] %s\n' "$*" >&2; }

# Default-route IPv4 interface (ens3 / eth0 / ... -- differs between images).
rccl_detect_iface() {
  local i
  i=$(ip -o -4 route show to default 2>/dev/null | awk '{for(k=1;k<=NF;k++) if($k=="dev"){print $(k+1); exit}}')
  [ -n "$i" ] || i=$(ip -o -4 addr show scope global 2>/dev/null | awk '$2!~/^(lo|docker|virbr)/{print $2; exit}')
  printf '%s' "$i"
}

# Is GID <idx> on <dev> a RoCE v2, non-link-local, non-zero GID?
rccl_gid_ok() {
  local dev="$1" idx="$2" base gid typ
  base="/sys/class/infiniband/$dev/ports/1"
  gid=$(cat "$base/gids/$idx" 2>/dev/null) || return 1
  typ=$(cat "$base/gid_attrs/types/$idx" 2>/dev/null || echo "")
  case "$gid" in ""|0000:0000:0000:0000:0000:0000:0000:0000|fe80:*) return 1;; esac
  case "$typ" in *"v2"*|"") return 0;; *) return 1;; esac
}

# Pick the RoCE v2 global GID index on the first ionic device. Prefers 1 (the index the
# platform has always used); scans 0..15 only if 1 is not usable.
rccl_detect_gid_index() {
  local dev="" d idx
  for d in /sys/class/infiniband/ionic_*; do [ -e "$d" ] && { dev="${d##*/}"; break; }; done
  if [ -z "$dev" ]; then echo 1; return 0; fi
  if rccl_gid_ok "$dev" 1; then echo 1; return 0; fi
  for idx in $(seq 0 15); do
    if rccl_gid_ok "$dev" "$idx"; then _rccl_log "GID index 1 unusable on $dev; using $idx"; echo "$idx"; return 0; fi
  done
  _rccl_log "WARNING: no RoCE v2 global GID found on $dev; defaulting to 1 (rail is probably wedged)"
  echo 1
}

# Locate the AMD ANP net plugin (amd-anp). Prints the absolute path or nothing.
rccl_find_anp_plugin() {
  local c
  for c in \
    /opt/amd-anp/build/librccl-anp.so /opt/amd-anp/lib/librccl-anp.so /opt/amd-anp/librccl-anp.so \
    /opt/rocm/lib/librccl-anp.so /usr/local/lib/librccl-anp.so /usr/lib/x86_64-linux-gnu/librccl-anp.so \
    /root/amd-anp/build/librccl-anp.so "$HOME/amd-anp/build/librccl-anp.so"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c=$(ldconfig -p 2>/dev/null | awk '/librccl-anp\.so/{print $NF; exit}')
  [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  c=$(find /opt /usr/local /usr/lib -maxdepth 5 -name 'librccl-anp.so*' 2>/dev/null | head -1)
  [ -n "$c" ] && printf '%s' "$c"
  return 0
}

# Locate an OpenMPI install that has bin/mpirun. Prints MPI_HOME.
rccl_find_mpi_home() {
  local c m
  for c in ${MPI_HOME:-} /opt/ompi /opt/openmpi /opt/ompi/install /opt/openmpi-4.1.6 /usr/mpi/gcc/openmpi-* /usr/local; do
    [ -x "$c/bin/mpirun" ] && { printf '%s' "$c"; return 0; }
  done
  m=$(command -v mpirun 2>/dev/null || true)
  # use the unresolved path: Ubuntu's /usr/bin/mpirun is an alternatives symlink to orterun
  [ -n "$m" ] && { dirname "$(dirname "$m")" | tr -d '\n'; return 0; }
  return 1
}

# Locate the rccl-tests build dir (contains all_reduce_perf). RCCL_TESTS_DIR wins.
rccl_find_tests_dir() {
  local c
  for c in ${RCCL_TESTS_DIR:-} /opt/rccl-tests/build /opt/rccl-tests /usr/local/rccl-tests/build \
           /usr/local/rccl-tests /opt/rocm/share/rccl-tests /opt/rocm/bin "$HOME/rccl-tests/build" \
           /root/rccl-tests/build /workspace/rccl-tests/build /usr/local/bin; do
    [ -x "$c/all_reduce_perf" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- auto-detected
: "${NET_IFACE:=$(rccl_detect_iface)}"
: "${NCCL_IB_GID_INDEX:=$(rccl_detect_gid_index)}"
: "${ANP_PLUGIN:=$(rccl_find_anp_plugin)}"
: "${MPI_HOME:=$(rccl_find_mpi_home || true)}"
: "${RCCL_TESTS_DIR:=$(rccl_find_tests_dir || true)}"
export NET_IFACE MPI_HOME RCCL_TESTS_DIR ANP_PLUGIN

# ---------------------------------------------------------------- RCCL env
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"                 # INFO to debug; WARN keeps the table readable
export NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"
export NCCL_IB_GID_INDEX                                 # RoCE v2 global GID (fc01:... on this platform)
export NCCL_IB_HCA="${NCCL_IB_HCA:-ionic_0,ionic_1,ionic_2,ionic_3,ionic_4,ionic_5,ionic_6,ionic_7}"
export NCCL_TOPO_FILE="${NCCL_TOPO_FILE:-$RCCL_TOPO_FILE_DEFAULT}"   # pins GPUn <-> ionic_n (guest PCIe is flattened)
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-$NET_IFACE}"
export NCCL_SOCKET_FAMILY="${NCCL_SOCKET_FAMILY:-AF_INET}"
export NCCL_IB_TIMEOUT="${NCCL_IB_TIMEOUT:-23}"
export NCCL_IB_RETRY_CNT="${NCCL_IB_RETRY_CNT:-7}"
export NCCL_NET_OPTIONAL_RECV_COMPLETION="${NCCL_NET_OPTIONAL_RECV_COMPLETION:-0}"
export NET_OPTIONAL_RECV_COMPLETION="${NET_OPTIONAL_RECV_COMPLETION:-1}"
export NCCL_GDR_FLUSH_DISABLE="${NCCL_GDR_FLUSH_DISABLE:-1}"
export RCCL_GDR_FLUSH_GPU_MEM_NO_RELAXED_ORDERING="${RCCL_GDR_FLUSH_GPU_MEM_NO_RELAXED_ORDERING:-0}"
export NCCL_IB_USE_INLINE="${NCCL_IB_USE_INLINE:-1}"
export IONIC_LOCKFREE="${IONIC_LOCKFREE:-all}"
export NCCL_DMABUF_ENABLE="${NCCL_DMABUF_ENABLE:-1}"     # kernel 6.8+: dma-buf is the GDR path
export NCCL_GDRCOPY_ENABLE="${NCCL_GDRCOPY_ENABLE:-0}"
export NCCL_PXN_DISABLE="${NCCL_PXN_DISABLE:-1}"
export NCCL_IB_QPS_PER_CONNECTION="${NCCL_IB_QPS_PER_CONNECTION:-4}"
export HSA_NO_SCRATCH_RECLAIM="${HSA_NO_SCRATCH_RECLAIM:-1}"
export NCCL_IB_TC="${NCCL_IB_TC:-96}"
export NCCL_IB_FIFO_TC="${NCCL_IB_FIFO_TC:-184}"
export NCCL_IGNORE_CPU_AFFINITY="${NCCL_IGNORE_CPU_AFFINITY:-1}"
export RCCL_AINIC_ROCE="${RCCL_AINIC_ROCE:-1}"
export RCCL_CTS_OFFLOAD_ENABLED="${RCCL_CTS_OFFLOAD_ENABLED:-0}"
export RCCL_CTS_INLINE_DATA="${RCCL_CTS_INLINE_DATA:-0}"
export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
export NCCL_IB_SPLIT_DATA_ON_QPS="${NCCL_IB_SPLIT_DATA_ON_QPS:-0}"
export NCCL_NSOCKS_PERTHREAD="${NCCL_NSOCKS_PERTHREAD:-4}"
export NCCL_P2P_NET_CHUNKSIZE="${NCCL_P2P_NET_CHUNKSIZE:-131072}"
export NCCL_SHM_DISABLE="${NCCL_SHM_DISABLE:-1}"
export NCCL_SOCKET_NTHREADS="${NCCL_SOCKET_NTHREADS:-2}"
export RCCL_DIRECT_ALLGATHER_THRESHOLD="${RCCL_DIRECT_ALLGATHER_THRESHOLD:--1}"
export RCCL_DISABLE_REDUCE_COPY_PIPELINING="${RCCL_DISABLE_REDUCE_COPY_PIPELINING:-1}"
export RCCL_IB_QPS_PER_P2P="${RCCL_IB_QPS_PER_P2P:-1}"
export RCCL_MSCCL_ENABLE="${RCCL_MSCCL_ENABLE:-0}"
export RCCL_P2P_BATCH_ENABLE="${RCCL_P2P_BATCH_ENABLE:-0}"
export RSMI_MUTEX_THREAD_ONLY="${RSMI_MUTEX_THREAD_ONLY:-1}"
# MPI is bootstrap only: keep any UCX use on TCP over the VPC interface.
export UCX_TLS="${UCX_TLS:-tcp,self,sm}"
export UCX_NET_DEVICES="${UCX_NET_DEVICES:-$NET_IFACE}"

# ANP plugin: absolute path, and its dir on LD_LIBRARY_PATH (RCCL dlopens it on every rank).
if [ -n "${ANP_PLUGIN:-}" ]; then
  export NCCL_NET_PLUGIN="${NCCL_NET_PLUGIN:-$ANP_PLUGIN}"
  _anp_dir=$(dirname "$ANP_PLUGIN")
  case ":${LD_LIBRARY_PATH:-}:" in *":$_anp_dir:"*) ;; *) LD_LIBRARY_PATH="$_anp_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac
  unset _anp_dir
fi
case ":${LD_LIBRARY_PATH:-}:" in *":$ROCM_PATH/lib:"*) ;; *) LD_LIBRARY_PATH="$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac
if [ -n "${MPI_HOME:-}" ] && [ "$MPI_HOME" != /usr ] && [ -d "$MPI_HOME/lib" ]; then
  case ":$LD_LIBRARY_PATH:" in *":$MPI_HOME/lib:"*) ;; *) LD_LIBRARY_PATH="$MPI_HOME/lib:$LD_LIBRARY_PATH";; esac
  case ":$PATH:" in *":$MPI_HOME/bin:"*) ;; *) PATH="$MPI_HOME/bin:$PATH";; esac
fi
export LD_LIBRARY_PATH PATH

# Every variable forwarded to the ranks with `mpirun -x`. Add your own with
# RCCL_EXTRA_ENV="VAR1 VAR2" (they must be exported).
RCCL_ENV_VARS=(
  PATH LD_LIBRARY_PATH ROCM_PATH
  NCCL_DEBUG NCCL_DEBUG_SUBSYS NCCL_IB_GID_INDEX NCCL_IB_HCA NCCL_TOPO_FILE
  NCCL_SOCKET_IFNAME NCCL_SOCKET_FAMILY NCCL_IB_TIMEOUT NCCL_IB_RETRY_CNT
  NCCL_NET_OPTIONAL_RECV_COMPLETION NET_OPTIONAL_RECV_COMPLETION NCCL_GDR_FLUSH_DISABLE
  RCCL_GDR_FLUSH_GPU_MEM_NO_RELAXED_ORDERING NCCL_IB_USE_INLINE IONIC_LOCKFREE
  NCCL_DMABUF_ENABLE NCCL_GDRCOPY_ENABLE NCCL_PXN_DISABLE NCCL_IB_QPS_PER_CONNECTION
  HSA_NO_SCRATCH_RECLAIM NCCL_IB_TC NCCL_IB_FIFO_TC NCCL_IGNORE_CPU_AFFINITY
  RCCL_AINIC_ROCE RCCL_CTS_OFFLOAD_ENABLED RCCL_CTS_INLINE_DATA NCCL_IB_DISABLE
  NCCL_IB_SPLIT_DATA_ON_QPS NCCL_NSOCKS_PERTHREAD NCCL_P2P_NET_CHUNKSIZE NCCL_SHM_DISABLE
  NCCL_SOCKET_NTHREADS RCCL_DIRECT_ALLGATHER_THRESHOLD RCCL_DISABLE_REDUCE_COPY_PIPELINING
  RCCL_IB_QPS_PER_P2P RCCL_MSCCL_ENABLE RCCL_P2P_BATCH_ENABLE RSMI_MUTEX_THREAD_ONLY
  UCX_TLS UCX_NET_DEVICES
)
[ -n "${NCCL_NET_PLUGIN:-}" ] && RCCL_ENV_VARS+=(NCCL_NET_PLUGIN)
[ -n "${NCCL_TOPO_DUMP_FILE:-}" ] && { export NCCL_TOPO_DUMP_FILE; RCCL_ENV_VARS+=(NCCL_TOPO_DUMP_FILE); }
for _v in ${RCCL_EXTRA_ENV:-}; do RCCL_ENV_VARS+=("$_v"); done
unset _v

rccl_env_print() {
  local v
  echo "# auto: NET_IFACE=${NET_IFACE:-?} GID_INDEX=$NCCL_IB_GID_INDEX MPI_HOME=${MPI_HOME:-?}"
  echo "# auto: RCCL_TESTS_DIR=${RCCL_TESTS_DIR:-<not found>} ANP_PLUGIN=${ANP_PLUGIN:-<not found>}"
  for v in "${RCCL_ENV_VARS[@]}"; do
    case "$v" in PATH|LD_LIBRARY_PATH) continue;; esac
    printf '%s=%s\n' "$v" "${!v-}"
  done
}

[ -n "${NET_IFACE:-}" ] || _rccl_log "WARNING: could not detect the default-route interface; set NET_IFACE"
[ -n "${ANP_PLUGIN:-}" ] || _rccl_log "WARNING: librccl-anp.so not found; RCCL will use its built-in IB transport (set ANP_PLUGIN=<path>)"
