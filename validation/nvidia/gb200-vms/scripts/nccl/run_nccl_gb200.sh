#!/usr/bin/env bash
# run_nccl_gb200.sh -- one NCCL collective (nccl-tests) across GB200 VMs in one NVLink domain,
# launched from the anchor node with mpirun over SSH. Traffic must stay on multi-node NVLink
# (MNNVL): the run FAILS if NCCL does not report "MNNVL 1 ... cliqueSize <ranks>". Parses the
# table, gates it, and reports known failure signatures.
#
# Usage:
#   run_nccl_gb200.sh [options]
#     -c, --collective  all_reduce|all_gather|reduce_scatter|alltoall   (default all_reduce)
#     -n, --nodes N     use the first N hosts of the hostfile           (default: all)
#     -f, --hostfile F  hostfile, lines "<ip> slots=4"                   (default ~/hostfile)
#     -H, --hosts LIST  explicit hosts "ip1,ip2,..." (overrides -f/-n)
#     -b, --min-bytes   e.g. 2G                                          (default $NCCL_MIN_BYTES)
#     -e, --max-bytes   e.g. 32G                                         (default $NCCL_MAX_BYTES)
#     -i, --iters N     timed iterations                                 (default $NCCL_ITERS)
#     -w, --warmup N    warmup iterations                                (default $NCCL_WARMUP)
#     -t, --timeout S   wall-clock deadline; exceeded = HANG             (default $NCCL_TIMEOUT_S)
#     -g, --min-busbw X override the gate (GB/s; applies to the gate metric). 0 = completion only
#     -o, --results DIR results dir                                      (default ./results)
#         --tag NAME    run name prefix (default nccl-<coll>-n<N>)
#         --analyze LOG re-analyze an existing log (no run); use -n/-c to pick the gate
#     -h, --help
#
# Exit: 0 PASS | 1 FAIL (completed, but below gate / #wrong>0 / not on MNNVL / fabric errors)
#       2 HANG or ERROR (timeout, mpirun rc!=0, no table, segfault, preflight error)
#
# Env overrides: everything in nccl_env.sh and thresholds.env, plus NCCL_TESTS_DIR, MPI_HOME,
#   NET_CIDR (VPC subnet used by MPI; auto-detected), GPN (GPUs per node, 4), MPI_EXTRA_ARGS, NCCL_TEST_EXTRA_ARGS, PREFLIGHT=0,
#   ALLOW_BUSY=1, BUSY_GPU_MIB (GPU memory in use that counts as busy, 1024), CLEANUP=0,
#   REQUIRE_MNNVL=0 (allow multi-node runs that are not on MNNVL).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=thresholds.env
source "$HERE/thresholds.env"
GPN="${GPN:-4}"

COLL=all_reduce; NODES=""; HOSTFILE="${HOSTFILE:-$HOME/hostfile}"; HOSTS_CSV=""
MINB="$NCCL_MIN_BYTES"; MAXB="$NCCL_MAX_BYTES"; ITERS="$NCCL_ITERS"; WARMUP="$NCCL_WARMUP"
TIMEOUT_S="$NCCL_TIMEOUT_S"; GATE_OVERRIDE=""; RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"
TAG=""; ANALYZE=""

usage(){ sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--collective) COLL="${2%_perf}"; shift 2;;
    -n|--nodes) NODES="$2"; shift 2;;
    -f|--hostfile) HOSTFILE="$2"; shift 2;;
    -H|--hosts) HOSTS_CSV="$2"; shift 2;;
    -b|--min-bytes) MINB="$2"; shift 2;;
    -e|--max-bytes) MAXB="$2"; shift 2;;
    -i|--iters) ITERS="$2"; shift 2;;
    -w|--warmup) WARMUP="$2"; shift 2;;
    -t|--timeout) TIMEOUT_S="$2"; shift 2;;
    -g|--min-busbw) GATE_OVERRIDE="$2"; shift 2;;
    -o|--results) RESULTS_DIR="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --analyze) ANALYZE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

case "$COLL" in
  all_reduce) CTAG="ar"; GPFX="AR";; all_gather) CTAG="ag"; GPFX="AG";;
  reduce_scatter) CTAG="rs"; GPFX="RS";; alltoall) CTAG="a2a"; GPFX="A2A";;
  *) echo "collective must be all_reduce|all_gather|reduce_scatter|alltoall" >&2; exit 2;;
esac
BIN_NAME="${COLL}_perf"

ts(){ printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die(){ ts "ERROR: $*"; exit 2; }

# ------------------------------------------------------------------ gate selection
gate_for(){  # gate_for <nodes>
  local n="$1" v
  if [ -n "$GATE_OVERRIDE" ]; then echo "$GATE_OVERRIDE"; return; fi
  if [ "$n" -le 1 ]; then v="${GPFX}_MIN_GBPS_1N"; elif [ "$n" -le 8 ]; then v="${GPFX}_MIN_GBPS_LE8"; else v="${GPFX}_MIN_GBPS_GT8"; fi
  echo "${!v}"
}
# Which statistic the gate applies to: avg (mean out-of-place busbw across the sweep) or
# peak (best size). Runs above 8 nodes default to peak: at scale the smallest sizes of a
# 2G-32G sweep are latency-bound and drag the mean down without indicating a fault.
metric_for(){  # metric_for <nodes>
  local n="$1"
  if [ -n "${GATE_METRIC:-}" ]; then echo "$GATE_METRIC"; return; fi
  if [ "$n" -gt 8 ]; then echo "${GATE_METRIC_GT8:-peak}"; else echo "${GATE_METRIC_LE8:-avg}"; fi
}

# size string (1G / 512M / 4096) -> bytes, nccl-tests semantics (K/M/G = 1024^n)
to_bytes(){
  local s="$1" n u
  n="${s%[KkMmGg]}"; u="${s#"$n"}"
  case "$u" in K|k) echo $((n*1024));; M|m) echo $((n*1024*1024));; G|g) echo $((n*1024*1024*1024));; *) echo "$n";; esac
}
expected_rows(){  # number of distinct sizes in the sweep
  local lo hi f c=0
  lo=$(to_bytes "$MINB"); hi=$(to_bytes "$MAXB"); f="${NCCL_STEP_FACTOR}"
  while [ "$lo" -le "$hi" ]; do c=$((c+1)); lo=$((lo*f)); done
  echo "$c"
}

# ------------------------------------------------------------------ analysis
# analyze <log> <nodes> <rc> <summary-file>  -> prints the summary block, returns 0/1/2
analyze(){
  local log="$1" n="$2" rc="$3" sumf="$4" gate exp
  local gmetric
  gate=$(gate_for "$n"); exp=$(expected_rows); gmetric=$(metric_for "$n")

  # table rows: <size> <count> <type> <redop> <root> | oop: time algbw busbw #wrong | ip: time algbw busbw #wrong
  # Parse from the end of the line so extra leading columns in newer nccl-tests don't shift it.
  local table
  table=$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[a-z]/ && NF >= 13 {
      print $1, $(NF-5), $(NF-4), $(NF-1), $NF }' "$log")

  local rows sizes avg wrong minrow
  rows=$(printf '%s\n' "$table" | awk 'NF{c++} END{print c+0}')
  sizes=$(printf '%s\n' "$table" | awk 'NF{if(!($1 in s)){s[$1]=1;c++}} END{print c+0}')
  avg=$(printf '%s\n' "$table" | awk 'NF && $2 ~ /^[0-9.]+$/ {s+=$2;c++} END{if(c) printf "%.2f", s/c; else print "none"}')
  wrong=$(printf '%s\n' "$table" | awk 'NF{ if($3 ~ /^[0-9]+$/) w+=$3; if($5 ~ /^[0-9]+$/) w+=$5 } END{print w+0}')
  minrow=$(printf '%s\n' "$table" | awk 'NF && $2 ~ /^[0-9.]+$/ {if(m==""||$2<m)m=$2} END{print (m==""?"none":m)}')
  # Peak out-of-place busbw and the message size it occurred at (e.g. "383.74@32G").
  local peak peaksz
  peak=$(printf '%s\n' "$table" | awk 'NF && $2 ~ /^[0-9.]+$/ {if(m==""||$2>m){m=$2; s=$1}} END{print (m==""?"none":m)}')
  peaksz=$(printf '%s\n' "$table" | awk 'NF && $2 ~ /^[0-9.]+$/ {if(m==""||$2>m){m=$2; s=$1}} END{if(s=="") print "none"; else if(s>=1073741824) printf "%gG", s/1073741824; else printf "%gM", s/1048576}')
  local nccl_avg oob ncclver
  nccl_avg=$(grep -E 'Avg bus bandwidth' "$log" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1 || true)
  oob=$(grep -E 'Out of bounds values' "$log" | tail -1 | grep -oE ': *[0-9]+' | grep -oE '[0-9]+' || true)
  ncclver=$(grep -m1 -oE 'NCCL version [^ ]+' "$log" | awk '{print $3}' || true)
  # Multi-node NVLink proof: every rank logs "MNNVL 1 cliqueId <x> cliqueSize <n>".
  local mnnvl_on mnnvl_sizes nvls
  mnnvl_on=$(grep -cE 'MNNVL 1 cliqueId' "$log" || true)
  mnnvl_sizes=$(grep -oE 'MNNVL 1 cliqueId [^ ]+ cliqueSize [0-9]+' "$log" | awk '{print $NF}' | sort -un | tr '\n' ' ' || true)
  nvls=$(grep -ciE 'NVLS multicast support is available' "$log" || true)

  # ---- failure signatures ----
  local s12 s5 cqe porterr segv oom launch ncclerr plugerr mnnvlerr cuda800
  s12=$(grep -cE 'status=12' "$log" || true)
  cqe=$(grep -ciE 'cqe with error|cqe error' "$log" || true)
  s5=$(grep -cE 'status=5 ' "$log" || true)
  porterr=$(grep -cE 'async error event: port error' "$log" || true)
  segv=$(grep -cE 'Segmentation fault|signal 11|exited on signal' "$log" || true)
  oom=$(grep -ciE 'out of memory|hipErrorOutOfMemory' "$log" || true)
  launch=$(grep -cE 'ORTE was unable to reliably start|ORTE does not know how to route|Host key verification failed|Permission denied \(publickey|There are not enough slots|orted: command not found|daemon did not report back' "$log" || true)
  ncclerr=$(grep -cE 'unhandled system error|ncclSystemError|ncclRemoteError|ncclInternalError|remote process exited|Test NCCL failure|Test HIP failure' "$log" || true)
  # "NET/Plugin: Could not find: libnccl-net.so" is informational (no external plugin) -- not counted.
  plugerr=$(grep -cE 'NET/Plugin.*Failed|Failed to open libibverbs' "$log" || true)
  mnnvlerr=$(grep -ciE 'MNNVL.*(not working|not supported)|nvidia-imex-ctl|IMEX channel' "$log" || true)
  cuda800=$(grep -cE "Cuda failure 800|operation not permitted" "$log" || true)

  local verdict reason="" code
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then verdict=HANG; reason="no completion within ${TIMEOUT_S}s"
  elif [ "$segv" -gt 0 ]; then verdict=ERROR; reason="segfault (node-level fault; one bad node poisons every set it joins)"
  elif [ "$rc" != 0 ]; then verdict=ERROR; reason="mpirun rc=$rc"
  elif [ "$rows" -eq 0 ]; then verdict=ERROR; reason="no bandwidth table (a log without errors is not a pass)"
  else
    verdict=PASS
    [ "$sizes" -lt "$exp" ] && { verdict=FAIL; reason="$reason only $sizes/$exp sizes;"; }
    [ "$wrong" -gt 0 ] && { verdict=FAIL; reason="$reason #wrong=$wrong;"; }
    [ -n "$oob" ] && [ "$oob" != 0 ] && { verdict=FAIL; reason="$reason out-of-bounds=$oob;"; }
    local gval="$avg"; [ "$gmetric" = peak ] && gval="$peak"
    if [ "$gate" != 0 ] && awk -v a="$gval" -v g="$gate" 'BEGIN{exit !(a=="none" || a+0 < g+0)}'; then
      verdict=FAIL; reason="$reason $gmetric busbw $gval < gate $gate;"
    fi
    [ $((s12 + cqe + porterr)) -gt 0 ] && { verdict=FAIL; reason="$reason fabric errors logged (status=12/cqe/port error) even though it completed;"; }
    if [ "${REQUIRE_MNNVL:-1}" = 1 ] && [ "$n" -gt 1 ]; then
      case " $mnnvl_sizes " in
        *" $((n * GPN)) "*) ;;
        *) verdict=FAIL; reason="$reason MNNVL not in use across all $((n * GPN)) ranks (clique sizes seen: ${mnnvl_sizes:-none}) -- traffic did not stay on NVLink;";;
      esac
    fi
  fi
  case "$verdict" in PASS) code=0;; FAIL) code=1;; *) code=2;; esac

  {
    echo "==================== NCCL ${BIN_NAME} ===================="
    echo "nodes=$n ranks=$((n*GPN)) sizes=${MINB}-${MAXB} iters=$ITERS nccl=${ncclver:-?} mnnvl_ranks=$mnnvl_on clique_sizes=${mnnvl_sizes:-none} nvls_lines=$nvls"
    echo "log: $log"
    if [ "$rows" -gt 0 ]; then
      printf '%14s %12s %12s %8s\n' "size(B)" "oop_busbw" "ip_busbw" "#wrong"
      printf '%s\n' "$table" | awk 'NF{
          if(!($1 in seen)){seen[$1]=1; ord[++k]=$1}
          ob[$1]+=$2; ib[$1]+=($4 ~ /^[0-9.]+$/ ? $4 : 0); c[$1]++
          if($3 ~ /^[0-9]+$/) w[$1]+=$3; if($5 ~ /^[0-9]+$/) w[$1]+=$5 }
        END{ for(i=1;i<=k;i++){s=ord[i]; printf "%14s %12.2f %12.2f %8d\n", s, ob[s]/c[s], ib[s]/c[s], w[s]+0} }'
    fi
    echo "avg out-of-place busbw : ${avg} GB/s   (nccl-tests Avg bus bandwidth: ${nccl_avg:-none})"
    echo "peak busbw             : ${peak} GB/s @ ${peaksz}"
    echo "min row busbw          : ${minrow} GB/s"
    echo "#wrong total           : ${wrong}   out-of-bounds: ${oob:-n/a}   rows: ${rows} (expected sizes: ${exp})"
    if [ "$gate" = 0 ]; then echo "gate                   : none (report only / completion only)"
    else echo "gate                   : ${gmetric} >= ${gate} GB/s"; fi
    echo "-- failure signatures --"
    local any=0
    if [ "$s12" -gt 0 ] || [ "$cqe" -gt 0 ]; then any=1
      echo "  status=12 / cqe error 12 : $s12 / $cqe  -> IB retry-exceeded: traffic went over IB (not NVLink) and a peer stopped ACKing."
      echo "     The PEER named in the line is the suspect, not the reporter. (peer, hca) counts:"
      grep -E 'status=12' "$log" | sed -nE 's/.*from peer ([0-9.]+)[^ ]* .*hca (mlx5_[0-9]+).*/\1 \2/p' | sort | uniq -c | sort -rn | head -10 | sed 's/^/       /'
    fi
    [ "$s5" -gt 0 ] && { any=1; echo "  status=5 (flush)         : $s5  -> secondary: QPs flushed after an earlier error; find the first status=12/port error"; }
    if [ "$porterr" -gt 0 ]; then any=1
      echo "  async port error         : $porterr  -> a rail link flapped during the run:"
      grep -E 'async error event: port error' "$log" | awk '{h="?"; r="?"
          for(i=1;i<=NF;i++){ if(h=="?" && $i ~ /^[^:\[]+:[0-9]+:[0-9]+$/){split($i,a,":"); h=a[1]}
                              if($i ~ /^mlx5_[0-9]+/){r=$i; sub(/:.*/,"",r)} }
          print h, r}' | sort | uniq -c | sort -rn | head -10 | sed 's/^/       /'
    fi
    if [ "$segv" -gt 0 ]; then any=1
      echo "  segfault / signal 11     : $segv  -> node-level fault at init; bisect, the node segfaults with ANY partner:"
      grep -E 'Caught signal 11|exited on signal' "$log" | sed -nE 's/^\[([^]:]+)[: ].*Caught signal 11.*/\1/p; s/.* on node ([^ ]+) exited on signal.*/\1/p' | sort | uniq -c | head -10 | sed 's/^/       /'
    fi
    [ "$oom" -gt 0 ] && { any=1; echo "  out of memory            : $oom  -> stale ranks still holding GPU memory? check for leftover *_perf / training processes"; }
    [ "$launch" -gt 0 ] && { any=1; echo "  MPI launch failure       : $launch  -> SSH / orted / hostfile problem, not the fabric"; }
    [ "$ncclerr" -gt 0 ] && { any=1; echo "  NCCL error               : $ncclerr  -> see 'NCCL WARN' lines in the log"; }
    [ "$plugerr" -gt 0 ] && { any=1; echo "  net plugin / verbs error : $plugerr  -> libibverbs/mlx5 provider not loadable on some host"; }
    [ "$mnnvlerr" -gt 0 ] && { any=1; echo "  MNNVL / IMEX error       : $mnnvlerr  -> IMEX domain not up or channel missing: check 'nvidia-imex-ctl -N' and /dev/nvidia-caps-imex-channels/channel0 on every node"; }
    [ "$cuda800" -gt 0 ] && { any=1; echo "  CUDA 800 not permitted   : $cuda800  -> IMEX channel0 missing or wrong permissions on some host"; }
    [ "$any" = 0 ] && echo "  none"
    [ "$n" -gt 1 ] && [ "$nvls" = 0 ] && echo "  note: no 'NVLS multicast support is available' line (NVLS off or NCCL_DEBUG_SUBSYS lacks NVLS)"
    echo "VERDICT: $verdict${reason:+  ($reason)}"
    echo "=========================================================="
  } | tee "${sumf%.summary}.report"

  {
    echo "collective=$COLL"; echo "nodes=$n"; echo "verdict=$verdict"; echo "exit_code=$code"
    echo "avg_busbw=$avg"; echo "nccl_avg_busbw=${nccl_avg:-none}"; echo "min_row_busbw=$minrow"
    echo "peak_busbw=$peak"; echo "peak_size=$peaksz"
    echo "gate=$gate"; echo "gate_metric=$gmetric"; echo "rows=$rows"; echo "expected_sizes=$exp"; echo "wrong=$wrong"
    echo "mpirun_rc=$rc"; echo "status12=$s12"; echo "cqe_err=$cqe"; echo "port_error=$porterr"
    echo "segfault=$segv"; echo "mnnvl_ranks=$mnnvl_on"; echo "clique_sizes=${mnnvl_sizes:-none}"; echo "nvls_lines=$nvls"; echo "nccl_version=${ncclver:-}"; echo "log=$log"
    echo "reason=${reason}"
  } > "$sumf"
  return "$code"
}

# ------------------------------------------------------------------ analyze-only mode
if [ -n "$ANALYZE" ]; then
  [ -r "$ANALYZE" ] || die "cannot read $ANALYZE"
  rc=$(grep -oE 'mpirun rc=[0-9]+' "$ANALYZE" | tail -1 | grep -oE '[0-9]+$' || true)
  if [ -z "$rc" ]; then grep -q 'Avg bus bandwidth' "$ANALYZE" && rc=0 || rc=124; fi
  n="${NODES:-$(grep -E '^# +Rank ' "$ANALYZE" | awk '{for(i=1;i<NF;i++) if($i=="on"){print $(i+1); break}}' | sort -u | wc -l | tr -d ' ' || true)}"
  [ "${n:-0}" -ge 1 ] || n=1
  mkdir -p "$RESULTS_DIR"
  set +e; analyze "$ANALYZE" "$n" "$rc" "$RESULTS_DIR/$(basename "${ANALYZE%.log}").summary"; ec=$?; set -e
  exit "$ec"
fi

# ------------------------------------------------------------------ env + host list
# alltoall at rack scale needs P2P restricted to NVLink, otherwise it fails with CUDA error 400.
[ "$COLL" = alltoall ] && export NCCL_P2P_LEVEL="${NCCL_P2P_LEVEL:-NVL}"
# shellcheck source=nccl_env.sh
source "$HERE/nccl_env.sh"

HOSTS=()
if [ -n "$HOSTS_CSV" ]; then
  IFS=', ' read -r -a HOSTS <<< "$HOSTS_CSV"
else
  [ -r "$HOSTFILE" ] || die "hostfile $HOSTFILE not found (lines: '<private-ip> slots=4')"
  while read -r h _; do
    case "$h" in ""|\#*) continue;; esac
    case " ${HOSTS[*]:-} " in *" $h "*) continue;; esac
    HOSTS+=("$h")
  done < "$HOSTFILE"
fi
[ "${#HOSTS[@]}" -ge 1 ] || die "no hosts"
if [ -n "$NODES" ]; then
  [ "$NODES" -le "${#HOSTS[@]}" ] || die "asked for $NODES nodes, hostfile has ${#HOSTS[@]}"
  HOSTS=("${HOSTS[@]:0:$NODES}")
fi
N=${#HOSTS[@]}; NP=$((N*GPN))

[ -n "${NCCL_TESTS_DIR:-}" ] && [ -x "$NCCL_TESTS_DIR/$BIN_NAME" ] || \
  die "nccl-tests not found (looked for $BIN_NAME in NCCL_TESTS_DIR and common paths); set NCCL_TESTS_DIR."
BIN="$NCCL_TESTS_DIR/$BIN_NAME"
[ -n "${MPI_HOME:-}" ] && [ -x "$MPI_HOME/bin/mpirun" ] || die "mpirun not found; set MPI_HOME"
[ -n "${NET_CIDR:-}" ] || die "could not detect the VPC subnet; set NET_CIDR (e.g. 10.0.0.0/20)"

mkdir -p "$RESULTS_DIR"
RUN="${TAG:-nccl-${CTAG}-n${N}}-$(date -u +%m%d%H%M%S)"
LOG="$RESULTS_DIR/$RUN.log"; SUMF="$RESULTS_DIR/$RUN.summary"; HF="$RESULTS_DIR/$RUN.hosts"
for h in "${HOSTS[@]}"; do echo "$h slots=$GPN"; done > "$HF"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
on_all(){  # on_all <cmd>  -> "<host> <output>" lines
  local h; for h in "${HOSTS[@]}"; do ( out=$("${SSH[@]}" "$h" "$1" 2>&1 | tr '\n' ' '); echo "$h $out" ) & done; wait
}

# ------------------------------------------------------------------ preflight
if [ "${PREFLIGHT:-1}" = 1 ]; then
  ts "preflight on $N host(s): binary, GPUs, fabric, IMEX channel, idle"
  # shellcheck disable=SC2016  # expands on the remote host
  chk='b='"$BIN"'; [ -x "$b" ] || echo "MISSING_BIN"
    n='"$NET_CIDR"'; pfx=${n%/*}; len=${n#*/}
    vif=$(ip -o -4 addr show | awk -v p="$pfx" -v l="$len" "function ip2n(a,  o){split(a,o,\".\"); return ((o[1]*256+o[2])*256+o[3])*256+o[4]} {split(\$4,x,\"/\"); m=2^(32-l); if (int(ip2n(x[1])/m)==int(ip2n(p)/m)) {print \$2; exit}}")
    [ -n "$vif" ] && echo "vpc_if=$vif" || echo "NO_VPC_IF"
    g=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU"); echo "gpus=$g"
    f=$(nvidia-smi -q 2>/dev/null | grep -A3 -i "^ *Fabric" | grep -m1 -E "^ *State" | sed "s/.*: *//"); echo "fabric=${f:-none}"
    c=$(nvidia-smi -q 2>/dev/null | grep -m1 -i "CliqueId" | sed "s/.*: *//"); echo "clique=${c:-none}"
    [ -e /dev/nvidia-caps-imex-channels/channel0 ] && echo "imex_ch=1" || echo "imex_ch=0"
    p=$(pgrep -fa "/(all_reduce|all_gather|reduce_scatter|alltoall|sendrecv|broadcast)_perf( |$)|dcgmproftester|dcgmi diag" 2>/dev/null | grep -v pgrep | head -3)
    [ -n "$p" ] && echo "BUSY:[$p]"
    m=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null | awk -F", *" -v t='"${BUSY_GPU_MIB:-1024}"' "\$2>t{printf \"gpu%s=%sMiB \", \$1, \$2}")
    a=$(nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null | sed "s|.*/||;s/::.*//" | sort -u | xargs)
    [ -n "$m" ] && echo "BUSY:[${m}apps: ${a:-?}]"; true'
  pf=$(on_all "$chk")
  while IFS= read -r l; do printf '  %s\n' "$l"; done <<< "$pf" >&2
  nonet=$(echo "$pf" | awk '/NO_VPC_IF/{print $1}' | tr '\n' ' ')
  [ -z "$nonet" ] || die "no interface in the VPC subnet $NET_CIDR on: $nonet(set NET_CIDR to the private subnet all hosts share)"
  bad=$(echo "$pf" | awk -v g="$GPN" '/MISSING_BIN/ || $0 !~ ("gpus=" g " ") || !/fabric=Completed/ || (/imex_ch=0/ && n>1) {print $1}' n="$N" | sort -u | tr '\n' ' ')
  busy=$(echo "$pf" | awk '/BUSY:/{print $1}' | sort -u | tr '\n' ' ')
  cliques=$(echo "$pf" | grep -oE 'clique=[^ ]+' | sort -u | wc -l | tr -d ' ')
  { echo "# preflight"; echo "$pf"; } > "$RESULTS_DIR/$RUN.preflight"
  [ -z "$bad" ] || die "preflight failed on: $bad(need $BIN, $GPN GPUs, Fabric State Completed, and IMEX channel0 for multi-node)"
  [ "$cliques" -le 1 ] || die "hosts span $cliques NVLink cliques -- they are not all in one NVLink domain"
  if [ -n "$busy" ] && [ "${ALLOW_BUSY:-0}" != 1 ]; then
    die "GPUs in use on: $busy(another test, or a workload holding GPU memory; see $RUN.preflight) -- stop it or set ALLOW_BUSY=1."
  fi
fi

# ------------------------------------------------------------------ mpirun
MPIRUN=("$MPI_HOME/bin/mpirun")
[ "$MPI_HOME" != /usr ] && MPIRUN+=(--prefix "$MPI_HOME")
# shellcheck disable=SC2054  # "self,tcp" is one MCA value, not two elements
MPIRUN+=(
  --np "$NP" --hostfile "$HF" --map-by "ppr:${GPN}:node" --bind-to none
  --mca pml ob1 --mca btl self,tcp --mca coll ^hcoll
  --mca btl_tcp_if_include "$NET_CIDR" --mca oob_tcp_if_include "$NET_CIDR"
  --mca plm_rsh_args "-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
)
[ "$(id -u)" = 0 ] && MPIRUN+=(--allow-run-as-root)
for v in "${NCCL_ENV_VARS[@]}"; do MPIRUN+=(-x "$v"); done
# shellcheck disable=SC2206
[ -n "${MPI_EXTRA_ARGS:-}" ] && MPIRUN+=($MPI_EXTRA_ARGS)
TESTARGS=(-b "$MINB" -e "$MAXB" -f "$NCCL_STEP_FACTOR" -n "$ITERS" -w "$WARMUP" -c 1 -g 1)
# shellcheck disable=SC2206
[ -n "${NCCL_TEST_EXTRA_ARGS:-}" ] && TESTARGS+=($NCCL_TEST_EXTRA_ARGS)
# An unlimited stack size crashes NCCL init on GB200; every rank runs with 8 MiB.
WRAP=(bash -c 'ulimit -s 8192; exec "$0" "$@"')

{
  echo "# run=$RUN collective=$COLL nodes=$N np=$NP started=$(date -u +%FT%TZ)"
  echo "# hosts: ${HOSTS[*]}"
  nccl_env_print | sed 's/^/# env: /'
  echo "# cmd: ${MPIRUN[*]} ${WRAP[*]} $BIN ${TESTARGS[*]}"
} > "$LOG"
ts "$RUN: $BIN_NAME on $N node(s) ($NP ranks), ${MINB}-${MAXB}, iters=$ITERS, timeout=${TIMEOUT_S}s"
ts "log: $LOG"

set +e
timeout --signal=TERM --kill-after=60 "$TIMEOUT_S" "${MPIRUN[@]}" "${WRAP[@]}" "$BIN" "${TESTARGS[@]}" >> "$LOG" 2>&1
rc=$?
set -e
echo "# mpirun rc=$rc ended=$(date -u +%FT%TZ)" >> "$LOG"

if [ "$rc" != 0 ] && [ "${CLEANUP:-1}" = 1 ]; then
  ts "cleaning up stray $BIN_NAME ranks"
  on_all "pkill -9 -f '$NCCL_TESTS_DIR/$BIN_NAME' 2>/dev/null; true" >/dev/null || true
fi

set +e; analyze "$LOG" "$N" "$rc" "$SUMF"; ec=$?; set -e
echo "RESULT run=$RUN collective=$COLL nodes=$N verdict=$(sed -n 's/^verdict=//p' "$SUMF") avg_busbw=$(sed -n 's/^avg_busbw=//p' "$SUMF") peak_busbw=$(sed -n 's/^peak_busbw=//p' "$SUMF")@$(sed -n 's/^peak_size=//p' "$SUMF") gate=$(sed -n 's/^gate_metric=//p' "$SUMF")>=$(sed -n 's/^gate=//p' "$SUMF") exit=$ec summary=$SUMF"
exit "$ec"
