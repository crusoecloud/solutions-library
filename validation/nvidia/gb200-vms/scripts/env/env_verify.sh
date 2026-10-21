#!/usr/bin/env bash
# env_verify.sh -- per-node checks for a GB200 VM: software versions vs bundle-gb200-1.0.env,
# GPUs, ECC / row remapping, NVLink fabric state, IMEX, IB rails, limits, dmesg.
# Runs locally, changes nothing. Uses sudo (non-interactive) only to read dmesg.
#
# Output: one line per check   <host>|<check>|<expected>|<actual>|PASS|FAIL|WARN|INFO
#         plus                 FABRIC|<host>|<state>|<status>|<cluster_uuid>|<clique_id>
#         and a final          <host>|summary|0 FAIL|<n> FAIL, <m> WARN|PASS|FAIL
# Exit: 0 no FAIL, 1 any FAIL.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bundle-gb200-1.0.env
. "${BUNDLE_ENV:-$HERE/bundle-gb200-1.0.env}"

HOST=$(hostname -s)
FAILS=0; WARNS=0
emit(){  # emit <check> <expected> <actual> <status>
  printf '%s|%s|%s|%s|%s\n' "$HOST" "$1" "$2" "$3" "$4"
  case "$4" in FAIL) FAILS=$((FAILS+1));; WARN) WARNS=$((WARNS+1));; esac
}
ver_check(){  # ver_check <check> <expected-prefix> <actual>
  local c="$1" e="$2" a="$3"
  if [ -z "$e" ]; then emit "$c" "report-only" "${a:-not found}" INFO
  elif [ -z "$a" ]; then emit "$c" "$e" "not found" "$VERSION_SEVERITY"
  elif [ "${a#"$e"}" != "$a" ]; then emit "$c" "$e" "$a" PASS
  else emit "$c" "$e" "$a" "$VERSION_SEVERITY"; fi
}
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

# ---------------------------------------------------------------- platform / versions
. /etc/os-release 2>/dev/null
ver_check os_version_id "$OS_VERSION_ID_EXPECTED" "${VERSION_ID:-}"
ver_check arch "$ARCH_EXPECTED" "$(uname -m)"
ver_check kernel "$KERNEL_EXPECTED" "$(uname -r)"

if ! command -v nvidia-smi >/dev/null; then
  emit nvidia_smi "present" "not found" FAIL
else
  drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')
  ver_check driver "$DRIVER_EXPECTED" "$drv"
  [ "$(echo "$drv" | wc -w | tr -d ' ')" -le 1 ] || emit driver_uniform "1 version" "$drv" FAIL
  cuda=$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: *[0-9.]+' | awk '{print $NF}')
  ver_check cuda "$CUDA_EXPECTED" "$cuda"
fi
dcgm=$(dcgmi --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
ver_check dcgm "$DCGM_EXPECTED" "$dcgm"
# DOCA version comes from the doca-ofed package (ofed_info reports the internal OFED version).
doca=$(dpkg-query -W -f='${Version}\n' doca-ofed doca-host 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)
ver_check doca "$DOCA_EXPECTED" "$doca"

# ---------------------------------------------------------------- GPUs
if command -v nvidia-smi >/dev/null; then
  n=0; t=5
  while :; do
    n=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU" || true)
    [ "$n" -ge "$GPU_COUNT_EXPECTED" ] || [ "$t" -le 0 ] && break
    t=$((t-1)); sleep 10
  done
  [ "$n" = "$GPU_COUNT_EXPECTED" ] && emit gpu_count "$GPU_COUNT_EXPECTED" "$n" PASS || emit gpu_count "$GPU_COUNT_EXPECTED" "$n" FAIL
  names=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ';')
  echo "$names" | grep -qE "$GPU_NAME_REGEX" && emit gpu_model "$GPU_NAME_REGEX" "$names" PASS || emit gpu_model "$GPU_NAME_REGEX" "$names" FAIL

  ecc=$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {s+=$1} END{print s+0}')
  [ "$ecc" = 0 ] && emit ecc_uncorrectable 0 "$ecc" PASS || emit ecc_uncorrectable 0 "$ecc" FAIL
  rr=$(nvidia-smi --query-remapped-rows=remapped_rows.failure,remapped_rows.pending --format=csv,noheader 2>/dev/null \
       | awk -F', *' '{f+=($1=="Yes"||$1+0>0); p+=($2=="Yes"||$2+0>0)} END{printf "failure=%d pending=%d", f, p}')
  case "$rr" in "failure=0 pending=0") emit row_remap "failure=0 pending=0" "$rr" PASS;;
                "") emit row_remap "failure=0 pending=0" "n/a" INFO;;
                failure=0*) emit row_remap "failure=0 pending=0" "$rr (reboot to apply pending remaps)" WARN;;
                *) emit row_remap "failure=0 pending=0" "$rr" FAIL;; esac

  # NVLink fabric (multi-node NVLink): State Completed, Status Success; all nodes share a clique.
  fab=$(nvidia-smi -q 2>/dev/null | grep -v GUID | grep -A5 -E '^ *Fabric *$')
  fstate=$(echo "$fab" | awk -F': *' '/^ *State/{print $2; exit}')
  fstatus=$(echo "$fab" | awk -F': *' '/^ *Status/{print $2; exit}')
  fclu=$(echo "$fab" | awk -F': *' '/ClusterUUID/{print $2; exit}')
  fcli=$(echo "$fab" | awk -F': *' '/CliqueId/{print $2; exit}')
  [ "$fstate" = Completed ] && [ "${fstatus:-Success}" = Success ] \
    && emit nvlink_fabric "Completed/Success" "$fstate/${fstatus:-?}" PASS \
    || emit nvlink_fabric "Completed/Success" "${fstate:-none}/${fstatus:-none}" FAIL
  printf 'FABRIC|%s|%s|%s|%s|%s\n' "$HOST" "${fstate:-none}" "${fstatus:-none}" "${fclu:-none}" "${fcli:-none}"

  pers=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ' ')
  case "$pers" in "Enabled ") emit persistence_mode Enabled Enabled PASS;; *) emit persistence_mode Enabled "${pers:-?}" WARN;; esac
fi

# ---------------------------------------------------------------- IMEX
if command -v nvidia-imex >/dev/null || [ -x /usr/bin/nvidia-imex ]; then
  st=$(systemctl is-active nvidia-imex 2>/dev/null)
  [ "$st" = active ] && emit imex_service active "$st" PASS || emit imex_service active "${st:-unknown}" FAIL
  [ -s /etc/nvidia-imex/nodes_config.cfg ] && emit imex_nodes_config "present" "$(grep -c . /etc/nvidia-imex/nodes_config.cfg) nodes" PASS \
    || emit imex_nodes_config "present" "missing/empty (run ansible/00-prep.yml)" FAIL
  [ -e /dev/nvidia-caps-imex-channels/channel0 ] && emit imex_channel0 present present PASS \
    || emit imex_channel0 present missing FAIL
  # DEGRADED usually means peers disagree on nodes_config.cfg (e.g. a node that was down when
  # 00-prep last ran came back with an old peer list) -- re-run ansible/00-prep.yml.
  dom=$(nvidia-imex-ctl -N 2>/dev/null | awk -F': *' '/Domain State/{print $2; exit}')
  bad=$(nvidia-imex-ctl -N 2>/dev/null | awk '/^ *[0-9]+ +([CINDRA]|![VMAR]!)( +([CINDRA]|![VMAR]!))+ *$/ {for(i=2;i<=NF;i++) if($i!="C") b++} END{print b+0}')
  if [ "$dom" = UP ] && [ "$bad" = 0 ]; then emit imex_domain "UP, all pairs Connected" "UP" PASS
  else emit imex_domain "UP, all pairs Connected" "${dom:-unknown}, $bad non-connected pairs (re-run ansible/00-prep.yml)" FAIL; fi
else
  emit imex "nvidia-imex installed" "not found" FAIL
fi

# ---------------------------------------------------------------- IB rails
if [ "$IB_RAILS_EXPECTED" -gt 0 ]; then
  rails=0; up=0; detail=""
  for d in /sys/class/infiniband/*; do
    [ -e "$d" ] || continue
    for p in "$d"/ports/*; do
      rate=$(cut -d' ' -f1 "$p/rate" 2>/dev/null); state=$(cat "$p/state" 2>/dev/null)
      ll=$(cat "$p/link_layer" 2>/dev/null)
      [ "$ll" = InfiniBand ] || continue
      [ "${rate%.*}" -ge "$IB_RAIL_RATE_GBPS" ] 2>/dev/null || continue
      rails=$((rails+1)); case "$state" in *ACTIVE*) up=$((up+1));; *) detail="$detail $(basename "$d"):${state#*: }";; esac
    done
  done
  if [ "$rails" = "$IB_RAILS_EXPECTED" ] && [ "$up" = "$rails" ]; then emit ib_rails "$IB_RAILS_EXPECTED x ${IB_RAIL_RATE_GBPS}G ACTIVE" "$up/$rails" PASS
  else emit ib_rails "$IB_RAILS_EXPECTED x ${IB_RAIL_RATE_GBPS}G ACTIVE" "$up/$rails${detail:+ down:$detail}" FAIL; fi
fi

# ---------------------------------------------------------------- tools / limits
[ -x /opt/nccl-tests/build/all_reduce_perf ] || [ -n "${NCCL_TESTS_DIR:-}" ] \
  && emit nccl_tests present "${NCCL_TESTS_DIR:-/opt/nccl-tests/build}" PASS || emit nccl_tests present "not found" FAIL
mpi=$(ls -d /usr/mpi/gcc/openmpi-*/bin/mpirun /opt/openmpi/bin/mpirun /usr/bin/mpirun 2>/dev/null | head -1)
[ -n "$mpi" ] && emit mpirun present "$mpi" PASS || emit mpirun present "not found" FAIL
dpt=$(ls /usr/bin/dcgmproftester* 2>/dev/null | head -1)
[ -n "$dpt" ] && emit dcgmproftester present "$dpt" PASS || emit dcgmproftester present "not found" FAIL
stk=$(ulimit -s)
[ "$stk" = unlimited ] && emit stack_limit "8192 (not unlimited)" "$stk (runner sets 8192 per rank)" WARN || emit stack_limit "not unlimited" "$stk" PASS

# ---------------------------------------------------------------- local NVMe
# A RAID0 array keeps reporting "clean" after its drives drop off the bus, so check the
# controllers themselves and that /scratch/local still answers.
NVME_CLASS="${NVME_CLASS:-/sys/class/nvme}"
nvme_n=0; nvme_bad=""
for c in "$NVME_CLASS"/nvme*; do
  [ -e "$c/state" ] || continue
  s=$(cat "$c/state" 2>/dev/null); nvme_n=$((nvme_n+1))
  [ "$s" = live ] || nvme_bad="$nvme_bad $(basename "$c")=${s:-unknown}"
done
if [ "$nvme_n" = 0 ]; then emit nvme_state "all live" "no NVMe controllers" INFO
elif [ -z "$nvme_bad" ]; then emit nvme_state "all live" "$nvme_n live" PASS
else emit nvme_state "all live" "not live:$nvme_bad" FAIL; fi
if mountpoint -q /scratch/local 2>/dev/null; then
  timeout 5 ls /scratch/local >/dev/null 2>&1 && emit scratch_local readable readable PASS \
    || emit scratch_local readable "I/O error or hung (drives lost? see dmesg)" FAIL
fi

# ---------------------------------------------------------------- dmesg
DMESG=$($SUDO dmesg 2>/dev/null)
if [ -z "$DMESG" ]; then emit dmesg_errors "0 matches" "unreadable (no passwordless sudo)" WARN
else
  hits=$(grep -E "$DMESG_FAIL_REGEX" <<<"$DMESG")
  [ -n "$DMESG_IGNORE_REGEX" ] && hits=$(grep -vE "$DMESG_IGNORE_REGEX" <<<"$hits")
  # Split Xids by code: application-level (WARN) vs everything else (FAIL).
  app_re=$(echo "$XID_APP_CODES" | tr ' ' '|')
  xid_app=$(grep -E "NVRM: Xid \([^)]*\): ($app_re)," <<<"$hits")
  rest=$(grep -vE "NVRM: Xid \([^)]*\): ($app_re)," <<<"$hits")
  na=$(grep -c . <<<"$xid_app"); nr=$(grep -c . <<<"$rest")
  if [ "$nr" -gt 0 ]; then
    emit dmesg_errors "0 matches" "$nr, first: $(head -1 <<<"$rest" | cut -c1-160)" FAIL
  else
    emit dmesg_errors "0 matches" 0 PASS
  fi
  if [ "$na" -gt 0 ]; then
    codes=$(grep -oE "Xid \([^)]*\): [0-9]+" <<<"$xid_app" | awk '{print $NF}' | sort | uniq -c | xargs)
    procs=$(grep -oE "name=[^,]+" <<<"$xid_app" | sort -u | xargs)
    emit xid_app "none" "$na application-level Xids (code count: $codes; $procs) -- a GPU job was killed/crashed; not a hardware fault" WARN
  fi
fi

printf '%s|summary|0 FAIL|%d FAIL, %d WARN|%s\n' "$HOST" "$FAILS" "$WARNS" "$([ "$FAILS" = 0 ] && echo PASS || echo FAIL)"
[ "$FAILS" = 0 ]
