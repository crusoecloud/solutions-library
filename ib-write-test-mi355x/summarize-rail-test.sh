#!/usr/bin/env bash
# Usage: ./summarize-rail-test.sh [ib-write-test-results.log]
# Summarizes ib_write_bw test output, flagging failures and results below threshold.

FILE="${1:-ib-write-test-results.log}"
THRESHOLD=320

if [[ ! -f "$FILE" ]]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

# Arrays to hold parsed results
declare -a R_NODE R_IFACE R_BW R_STATUS

current_node=""
current_iface=""
got_result=0
next_is_bw=0
idx=0

flush_pending() {
    # Called when we move to a new test without having seen a BW result
    if [[ -n "$current_iface" && "$got_result" -eq 0 ]]; then
        R_NODE[$idx]="$current_node"
        R_IFACE[$idx]="ionic_$current_iface"
        R_BW[$idx]="--"
        R_STATUS[$idx]="FAILED"
        ((idx++))
    fi
}

while IFS= read -r line; do
    if [[ "$line" =~ ^Testing\ interface\ ([0-9]+)\ on\ node\ ([0-9.]+) ]]; then
        flush_pending
        current_iface="${BASH_REMATCH[1]}"
        current_node="${BASH_REMATCH[2]}"
        got_result=0
        next_is_bw=0

    elif [[ "$line" =~ "#bytes" && "$line" =~ "BW average" ]]; then
        next_is_bw=1

    elif [[ "$next_is_bw" -eq 1 && "$got_result" -eq 0 ]]; then
        next_is_bw=0
        # BW result line: <bytes> <iters> <peak> <avg> <msgrate>
        # May have trailing text (server output runs onto same line) — awk handles it
        bw_peak=$(awk '{print $3}' <<< "$line")
        if [[ "$bw_peak" =~ ^[0-9]+\.[0-9]+$ ]]; then
            got_result=1
            R_NODE[$idx]="$current_node"
            R_IFACE[$idx]="ionic_$current_iface"
            R_BW[$idx]="$bw_peak"
            if (( $(bc -l <<< "$bw_peak < $THRESHOLD") )); then
                R_STATUS[$idx]="LOW"
            else
                R_STATUS[$idx]="OK"
            fi
            ((idx++))
        fi
    fi
done < "$FILE"

flush_pending  # handle last test

# ── Print results ─────────────────────────────────────────────────────────────

count_ok=0; count_low=0; count_failed=0

echo ""
echo "IB Write BW Peak Test Results  (threshold: ${THRESHOLD} Gb/s)"
echo "========================================================="
printf "%-18s  %-10s  %-14s  %s\n" "Node" "Interface" "BW peak(Gb/s)" "Status"
printf "%-18s  %-10s  %-14s  %s\n" "------------------" "----------" "--------------" "------"

prev_node=""
for ((i = 0; i < idx; i++)); do
    node="${R_NODE[$i]}"
    iface="${R_IFACE[$i]}"
    bw="${R_BW[$i]}"
    status="${R_STATUS[$i]}"

    # Blank line between nodes for readability
    if [[ "$node" != "$prev_node" && -n "$prev_node" ]]; then
        echo ""
    fi
    prev_node="$node"

    case "$status" in
        OK)
            flag=""
            ((count_ok++))
            ;;
        LOW)
            flag="  <<< BELOW ${THRESHOLD} Gb/s"
            ((count_low++))
            ;;
        FAILED)
            flag="  *** TEST FAILED ***"
            ((count_failed++))
            ;;
    esac

    printf "%-18s  %-10s  %-14s  %s%s\n" "$node" "$iface" "$bw" "$status" "$flag"
done

echo ""
echo "========================================================="
total=$((count_ok + count_low + count_failed))
echo "Total NICs tested : $total"
echo "  OK              : $count_ok"
echo "  Below threshold : $count_low"
echo "  Failed          : $count_failed"

if [[ $((count_low + count_failed)) -eq 0 ]]; then
    echo ""
    echo "All tests passed."
else
    echo ""
    echo "ATTENTION: $((count_low + count_failed)) NIC(s) require investigation."
fi
echo ""
