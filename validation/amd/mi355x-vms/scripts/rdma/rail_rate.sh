#!/usr/bin/env bash
# rail_rate.sh -- live per-rail RDMA throughput and error/congestion counter deltas on one
# node, from `rdma statistic show`. Use while a collective is running to confirm traffic is
# actually on the ionic rails (and spread across all 8), and that no errors accrue now.
# The raw counters are cumulative since boot; only the deltas over the window matter.
#
# Usage: rail_rate.sh [seconds]        (default 5)
# Output: one line per rail:
#   RATE|<host>|ionic_N|tx=<Gb/s>|rx=<Gb/s>|retx=<Gb/s>|retry_excd=<d>|cqe_err=<d>|seq_err=<d>|cnp_rx=<d>|ecn_rx=<d>
set -uo pipefail
WIN="${1:-5}"
HOST=$(hostname -s)

snap() {
  # "link ionic_0/1 key val key val ..." -> "ionic_0 key val" lines
  rdma statistic show 2>/dev/null | awk '$1=="link" && $2 ~ /^ionic_/ {
    d=$2; sub(/\/.*/, "", d)
    for (i=3; i<NF; i+=2) print d, $i, $(i+1) }'
}

a=$(snap); sleep "$WIN"; b=$(snap)
[ -n "$a" ] || { echo "RATE|$HOST|no ionic counters (rdma statistic show failed)"; exit 2; }

awk -v win="$WIN" -v host="$HOST" '
  NR==FNR { v0[$1" "$2]=$3; next }
          { k=$1" "$2; dv[k]=$3-v0[k]; devs[$1]=1 }
  END {
    for (d in devs) {
      printf "RATE|%s|%s|tx=%.1f|rx=%.1f|retx=%.2f|retry_excd=%d|cqe_err=%d|seq_err=%d|cnp_rx=%d|ecn_rx=%d\n", host, d,
        dv[d" tx_rdma_ucast_bytes"]*8/win/1e9, dv[d" rx_rdma_ucast_bytes"]*8/win/1e9,
        dv[d" tx_rdma_retx_bytes"]*8/win/1e9,
        dv[d" req_tx_retry_excd_err"], dv[d" req_rx_cqe_err"], dv[d" req_rx_pkt_seq_err"],
        dv[d" rx_rdma_cnp_pkts"], dv[d" rx_rdma_ecn_pkts"]
    }
  }' <(echo "$a") <(echo "$b") | sort -t'|' -k3,3
