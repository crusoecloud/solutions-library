#!/usr/bin/env bash
# run_dcgm_gemm.sh -- per-node GEMM smoke test on all GPUs at once with DCGM's dcgmproftester
# (tensor-core GEMM load, test 1004). Reports achieved TFLOPS per GPU and gates on:
#   * every GPU >= GEMM_MIN_TFLOPS              (default 1100; GB200 measures ~1270-1290 on test 1004)
#   * every GPU within GEMM_MAX_SPREAD_PCT of this node's best GPU
# Fleet-wide outliers (a node well below the others) are flagged by parse_results.py.
#
# Usage: run_dcgm_gemm.sh [-d SECONDS] [-t TEST_ID] [-o RESULTS_DIR]
#   defaults: -d 60  -t 1004 (tensor core)  -o ./results
# Env: DCGMPROFTESTER (binary), GEMM_MIN_TFLOPS (1100, 0 = no floor), GEMM_MAX_SPREAD_PCT (10), GEMM_WARMUP_SAMPLES (5)
#
# Output: GEMM|<host>|gpu<N>|<TFLOPS>   per GPU, then GEMM_VERDICT|<host>|PASS|FAIL|ERROR|<detail>
# Exit: 0 PASS | 1 FAIL | 2 ERROR (tool missing, no samples parsed)
set -uo pipefail

DUR=60; TEST=1004; RESULTS_DIR="${RESULTS_DIR:-$PWD/results}"
while getopts "d:t:o:h" opt; do
  case "$opt" in d) DUR="$OPTARG";; t) TEST="$OPTARG";; o) RESULTS_DIR="$OPTARG";; *) sed -n '2,15p' "$0"; exit 0;; esac
done
MIN="${GEMM_MIN_TFLOPS:-1100}"; SPREAD="${GEMM_MAX_SPREAD_PCT:-10}"; SKIP="${GEMM_WARMUP_SAMPLES:-5}"

HOST=$(hostname -s)
DPT="${DCGMPROFTESTER:-$(ls /usr/bin/dcgmproftester[0-9]* 2>/dev/null | sort -V | tail -1)}"
[ -n "$DPT" ] && [ -x "$DPT" ] || { echo "GEMM_VERDICT|$HOST|ERROR|dcgmproftester not found (set DCGMPROFTESTER)"; exit 2; }

mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/gemm-dcgmproftester-$TEST-$HOST-$(date +%m%d%H%M%S).log"
echo "== $DPT -t $TEST -d $DUR on $HOST (all GPUs)"
"$DPT" --no-dcgm-validation -t "$TEST" -d "$DUR" > "$LOG" 2>&1
rc=$?

# Sample lines look like (dcgmproftester13 on GB200):
#   Worker 3:0 [1004]: TensorEngineActive:  generated ???, dcgm 0 (1.26e+06 gflops).
# Per GPU: drop the first SKIP samples (ramp-up), report the median of the rest in TFLOPS.
awk -v host="$HOST" -v skip="$SKIP" '
  match($0, /Worker [0-9]+:[0-9]+ ?\[[0-9]+\]/) {
    w=substr($0, RSTART+7, RLENGTH-7); split(w, a, ":"); g=a[1]
    if (match($0, /\([0-9.eE+-]+ gflops\)/)) {
      v=substr($0, RSTART+1); sub(/ gflops\).*/, "", v)
      n[g]++; if (n[g] > skip) { k[g]++; s[g, k[g]] = v + 0 }
    }
  }
  END {
    for (g in k) {
      m = k[g]; for (i=1;i<=m;i++) arr[i]=s[g,i]
      for (i=1;i<=m;i++) for (j=i+1;j<=m;j++) if (arr[j]<arr[i]) { t=arr[i]; arr[i]=arr[j]; arr[j]=t }
      med = (m%2) ? arr[(m+1)/2] : (arr[m/2]+arr[m/2+1])/2
      printf "GEMM|%s|gpu%s|%.0f\n", host, g, med/1000
      delete arr
    }
  }' "$LOG" | sort -t'|' -k3,3V | tee "$LOG.summary"

n=$(grep -c '^GEMM|' "$LOG.summary" || true)
if [ "$n" -eq 0 ]; then
  echo "GEMM_VERDICT|$HOST|ERROR|no per-GPU samples parsed (dcgmproftester rc=$rc); raw output: $LOG"
  tail -15 "$LOG"
  exit 2
fi
read -r lo hi < <(awk -F'|' '{v=$4+0; if(lo==""||v<lo)lo=v; if(v>hi)hi=v} END{print lo, hi}' "$LOG.summary")
reason=""
awk -v lo="$lo" -v m="$MIN" 'BEGIN{exit !(m>0 && lo<m)}' && reason="$reason min GPU ${lo} TFLOPS < floor ${MIN};"
awk -v lo="$lo" -v hi="$hi" -v s="$SPREAD" 'BEGIN{exit !(hi>0 && (hi-lo)/hi*100 > s)}' && reason="$reason spread ${lo}-${hi} TFLOPS > ${SPREAD}%;"
if [ "$n" -lt "${GPU_COUNT_EXPECTED:-4}" ]; then reason="$reason only $n GPU(s) reported;"; fi

if [ -n "$reason" ]; then
  echo "GEMM_VERDICT|$HOST|FAIL|min=${lo} max=${hi} TFLOPS;${reason}|log=$LOG"; exit 1
fi
echo "GEMM_VERDICT|$HOST|PASS|min=${lo} max=${hi} TFLOPS over $n GPUs|log=$LOG"
