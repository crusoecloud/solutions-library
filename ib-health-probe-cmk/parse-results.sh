#!/usr/bin/env bash
# Parse aggregated `kubectl logs -l app=ib-probe` output into a per-node summary table.
#
# Usage:
#   kubectl logs -l app=ib-probe --tail=-1 | ./parse-results.sh
#   ./parse-results.sh < /tmp/probe-output.log
#
# Output:
#   Per-host summary table
#   List of every failing HCA / NCCL test with detail

set -euo pipefail

INPUT=$(cat)

# All hosts seen
HOSTS=$(echo "$INPUT" | awk -F'|' '/^(IBHEALTH|NCCLHEALTH|DCGMHEALTH|DCGMDIAG|SUMMARY)/{print $2}' | sort -u)
N_HOSTS=$(echo "$HOSTS" | grep -c . || true)

echo "=== IB HEALTH REPORT ==="
echo "Hosts probed:  $N_HOSTS"
echo

# Per-host summary
printf "%-30s | %-9s | %-8s | %-10s | %-6s | %s\n" "HOST" "STATUS" "HCAs" "NCCL GB/s" "DCGM" "FAILS"
printf "%-30s-+-%-9s-+-%-8s-+-%-10s-+-%-6s-+-%s\n" \
    "------------------------------" \
    "---------" "--------" "----------" "------" "----------------------------------"

for host in $HOSTS; do
    summary=$(echo "$INPUT" | awk -F'|' -v h="$host" '/^SUMMARY/ && $2==h {print}' | head -1)
    if [ -z "$summary" ]; then
        printf "%-30s | %-9s | %-8s | %-10s | %-6s | %s\n" "$host" "?" "-" "-" "-" "(no SUMMARY line)"
        continue
    fi
    status=$(echo "$summary" | awk -F'|' '{print $3}')
    hcas=$(echo "$summary"  | awk -F'|' '{print $4}' | sed 's/hcas=//')
    nccl=$(echo "$INPUT" | awk -F'|' -v h="$host" '/^NCCLHEALTH/ && $2==h {print $4}' | head -1)
    dcgm=$(echo "$INPUT" | awk -F'|' -v h="$host" '/^DCGMHEALTH/ && $2==h {print $4}' | head -1)
    fails=$(echo "$INPUT" | awk -F'|' -v h="$host" '
        /^IBHEALTH/   && $2==h && $NF ~ /FAIL/ {n++}
        /^NCCLHEALTH/ && $2==h && $NF ~ /FAIL/ {n++}
        /^DCGMHEALTH/ && $2==h && $NF ~ /FAIL/ {n++}
        /^DCGMDIAG/   && $2==h && $NF ~ /FAIL/ {n++}
        END {print n+0}')
    printf "%-30s | %-9s | %-8s | %-10s | %-6s | %s\n" "$host" "$status" "$hcas" "${nccl:-?}" "${dcgm:--}" "$fails"
done

echo
echo "=== FAILURES (if any) ==="
FAIL_LINES=$(echo "$INPUT" | awk -F'|' '
    /^IBHEALTH/   && $NF ~ /FAIL/ {print}
    /^NCCLHEALTH/ && $NF ~ /FAIL/ {print}
    /^DCGMHEALTH/ && $NF ~ /FAIL/ {print}
    /^DCGMDIAG/   && $NF ~ /FAIL/ {print}
')
if [ -z "$FAIL_LINES" ]; then
    echo "  (none — all HCAs pass threshold, NCCL OK on every node)"
else
    echo "$FAIL_LINES"
fi

echo
echo "=== PER-HCA BANDWIDTH DETAIL ==="
echo "$INPUT" | awk -F'|' '
    /^IBHEALTH/ {
        host=$2; pair=$3; numa=$4; bw=$5; rate=$6; status=$7
        printf "%-30s | %-22s | %-7s | %6.1f / %3d Gbps | %s\n", host, pair, numa, bw, rate, status
    }
' | sort

# Exit nonzero if any FAIL line seen — that's the CI/scripting signal.
if [ -n "$FAIL_LINES" ]; then
    exit 1
fi
exit 0
