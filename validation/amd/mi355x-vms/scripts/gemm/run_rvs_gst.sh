#!/usr/bin/env bash
# run_rvs_gst.sh -- per-node GEMM validation on 8x MI355X using ROCm Validation Suite (RVS)
# GST (GPU Stress Test). Each GST action runs a GEMM at a given size/dtype and compares
# achieved GFLOPS against the AMD-provided target_stress in the MI355X config.
#
# Usage: run_rvs_gst.sh [--smoke] [-c CONF] [-o RESULTS_DIR]
#   default CONF : /opt/rocm/share/rocm-validation-suite/conf/MI355X/gst_single.conf
#                  (15 actions, GPUs one at a time: ~45 min/node)
#   --smoke      : derive a config from CONF keeping only actions with a non-zero
#                  target_stress (fp8/bf8/fp16/bf16 at 8Kx8Kx16K) and run all 8 GPUs in
#                  parallel (~3-5 min/node). Actions without a target are informational only.
#
# Output: one line per (test, gpu): GEMM|host|test|gpu_id|gflops|target|met
#         then GEMM_VERDICT|host|PASS/FAIL/ERROR|detail
# Exit: 0 all targets met | 1 any target missed | 2 RVS error / no results
set -uo pipefail

CONF=/opt/rocm/share/rocm-validation-suite/conf/MI355X/gst_single.conf
RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"
SMOKE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1; shift;;
    -c) CONF="$2"; shift 2;;
    -o) RESULTS_DIR="$2"; shift 2;;
    *) sed -n '2,17p' "$0"; exit 0;;
  esac
done

RVS="${RVS:-$(command -v rvs || echo /opt/rocm/bin/rvs)}"
[ -x "$RVS" ] || { echo "rvs not found" >&2; exit 2; }
[ -r "$CONF" ] || { echo "config not found: $CONF" >&2; exit 2; }

HOST=$(hostname -s)
TS=$(date +%m%d%H%M%S)
mkdir -p "$RESULTS_DIR"

if [ "$SMOKE" = 1 ]; then
  SMOKE_CONF="$RESULTS_DIR/gst_smoke-$HOST-$TS.conf"
  # Split into action blocks on "- name:"; keep the header and blocks with target_stress > 0;
  # add "parallel: true" after the module line so all GPUs run concurrently.
  awk '
    function flush() { if (blk != "" && keep) printf "%s", blk; blk=""; keep=0 }
    /^- name:/ { flush(); inblk=1 }
    !inblk { print; next }
    {
      line=$0
      if ($1 == "target_stress:" && ($2 + 0) > 0) keep=1
      blk = blk line "\n"
      if ($1 == "module:") blk = blk "  parallel: true\n"
    }
    END { flush() }' "$CONF" > "$SMOKE_CONF"
  n_act=$(grep -c '^- name:' "$SMOKE_CONF")
  [ "$n_act" -gt 0 ] || { echo "smoke config has no actions" >&2; exit 2; }
  CONF="$SMOKE_CONF"
fi

LOG="$RESULTS_DIR/gemm-rvs-gst-$HOST-$TS.log"
echo "== RVS GST on $HOST ($CONF)"
"$RVS" -c "$CONF" -d 3 >"$LOG" 2>&1
rc=$?

# Final per-GPU result line for each action, e.g.:
#   [RESULT] [ 4821.2] [gst-2061Tflops-8K8K16K-trig-fp8] [GPU:: 16161] GFLOPS 3530305 Target GFLOPS: 2061000 met: TRUE
# Actions with target 0 report "met: TRUE" trivially; they are kept in the table for reference.
awk -v host="$HOST" '
  /\[RESULT\]/ && /met: *(TRUE|FALSE)/ {
    test=""; gpu=""; gf=""; tgt=""; met=""
    if (match($0, /\[gst-[^]]+\]/))           test=substr($0, RSTART+1, RLENGTH-2)
    if (match($0, /GPU:: *[0-9]+/))           { gpu=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", gpu) }
    if (match($0, /\] GFLOPS [0-9.]+/))       { gf=substr($0, RSTART, RLENGTH); gsub(/[^0-9.]/, "", gf) }
    if (match($0, /Target GFLOPS: *[0-9.]+/)) { tgt=substr($0, RSTART, RLENGTH); sub(/.*: */, "", tgt) }
    if (match($0, /met: *(TRUE|FALSE)/))      { met=substr($0, RSTART, RLENGTH); sub(/.*: */, "", met) }
    printf "GEMM|%s|%s|%s|%s|%s|%s\n", host, test, gpu, gf, tgt, met
  }' "$LOG" > "$LOG.summary"

# Compact table: per test, min achieved TFLOPS across GPUs vs target.
printf "  %-36s %5s %12s %12s %5s\n" "test" "gpus" "min_TFLOPS" "target" "fail"
awk -F'|' '
  { t=$3; v=$5+0; if (!(t in mn) || v < mn[t]) mn[t]=v; tg[t]=$6; n[t]++; if ($7=="FALSE") f[t]++ }
  END { for (t in mn) printf "  %-36s %5d %12.0f %12s %5d\n", t, n[t], mn[t]/1000, (tg[t]>0 ? sprintf("%.0f", tg[t]/1000) : "-"), f[t] }' \
  "$LOG.summary" | sort -k1,1

n=$(grep -c '^GEMM|' "$LOG.summary" || true)
nfail=$(grep -c '|FALSE$' "$LOG.summary" || true)
if [ "$rc" -ne 0 ] || [ "$n" -eq 0 ]; then
  echo "GEMM_VERDICT|$HOST|ERROR|rvs_rc=$rc results=$n log=$LOG"
  tail -20 "$LOG"
  exit 2
fi
if [ "$nfail" -gt 0 ]; then
  grep '|FALSE$' "$LOG.summary"
  echo "GEMM_VERDICT|$HOST|FAIL|$nfail/$n gpu-results below target|log=$LOG"
  exit 1
fi
echo "GEMM_VERDICT|$HOST|PASS|$n/$n gpu-results met target|log=$LOG"
