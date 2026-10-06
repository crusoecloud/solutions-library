#!/bin/bash

# 'nodes' is a file of nodes, 1 IP address per line
# IMPORTANT: The 'master node' that the script is being run on should be 'known good', i.e all of its nics
# ionic_0 through ionic_7 should have already passed this test, or a multinode RCCL test.
# Configure passwordless SSH from the master node to all the other nodes

MASTER_IP=$(ip -o -4 addr show dev ens3 | awk '{split($4,a,"/"); print a[1]}')
RESULTS_LOG="ib-write-test-results.log"
SUMMARY_FILE="ib-write-test-summary.txt"
THRESHOLD=320
TMP_RESULTS=$(mktemp /tmp/ib-write-results.XXXXXX)

for node in $(cat ./nodes); do

  # Ignore this host's IP in the list
  if [[ $node == $MASTER_IP ]]; then
    continue
  fi

  echo "Testing node $node"
  ssh $node "hostname -f; for interface in \$(seq 0 7); do ib_write_bw -d ionic_\$interface -p \$((18515 + interface)) -x 1 -F --report_gbits & done | sed -u \"s/^/$node | /\"" &
  sleep 2
  for interface in $(seq 0 7); do
    (
      out=$(ib_write_bw -d ionic_$interface -p $((18515 + interface)) -x 1 -F --report_gbits $node 2>&1)
      echo "$out" | sed "s/^/$node | /"
      bw=$(echo "$out" | awk '/^\s*[0-9]+\s+[0-9]+\s+[0-9]+\.[0-9]+/ {print $3; exit}')
      printf "%s ionic_%d %s\n" "$node" "$interface" "${bw:-ERROR}" >> "$TMP_RESULTS"
    ) &
  done
  echo "Waiting for tests on $node to complete.."
  wait
done |& tee "$RESULTS_LOG"

# Generate and print summary, and save to file
sort "$TMP_RESULTS" | awk -v threshold="$THRESHOLD" -v date="$(date)" '
BEGIN {
  fail_count = 0; pass_count = 0; error_count = 0
}
{
  node = $1; nic = $2; bw = $3
  if (bw == "ERROR") {
    err_node[error_count] = node; err_nic[error_count] = nic; error_count++
  } else if (bw + 0 < threshold + 0) {
    fail_node[fail_count] = node; fail_nic[fail_count] = nic; fail_bw[fail_count] = bw; fail_count++
  } else {
    pass_count++
  }
}
END {
  total = pass_count + fail_count + error_count
  print ""
  print "========================================================"
  print "  IB Write BW Test Summary"
  print "  Threshold : " threshold " Gb/sec"
  print "  Generated : " date
  print "========================================================"
  print ""
  if (fail_count == 0 && error_count == 0) {
    print "  STATUS: ALL " total " NICs PASSED"
  } else {
    print "  STATUS: FAILURES DETECTED"
    if (fail_count > 0) {
      print ""
      print "  NICs below " threshold " Gb/sec:"
      print "  --------------------------------------------------------"
      for (i = 0; i < fail_count; i++)
        printf "  %-20s  %-10s  %.2f Gb/sec\n", fail_node[i], fail_nic[i], fail_bw[i]
    }
    if (error_count > 0) {
      print ""
      print "  NICs with errors (no result captured):"
      print "  --------------------------------------------------------"
      for (i = 0; i < error_count; i++)
        printf "  %-20s  %-10s\n", err_node[i], err_nic[i]
    }
  }
  print ""
  print "  Total: " pass_count " passed, " fail_count " failed, " error_count " errors"
  print "========================================================"
  print ""
}
' | tee "$SUMMARY_FILE"

rm -f "$TMP_RESULTS"
