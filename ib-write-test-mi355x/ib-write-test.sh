#!/bin/bash

# 'nodes' is a file of nodes, 1 IP address per line, of which the first is assumed to be the node
# that this script is being run on, and which is configured for passwordless SSH to all the other nodes
# IMPORTANT: The node that the script is being run on should be 'known good', i.e all of its nics ionic_0
# through ionic_7 should have already passed this test, or a multinode RCCL test.

for node in $(tail -n +2 ./nodes); do
  echo "Testing node $node"
  ssh $node 'hostname -f;for interface in $(seq 0 7); do ib_write_bw -d ionic_$interface -x 1 -F --report_gbits;done' &
  pid=$!
  sleep 2
  for interface in $(seq 0 7); do
    echo "Testing interface $interface on node $node"
    ib_write_bw -d ionic_$interface -x 1 -F --report_gbits $node;sleep 2
  done
  echo "Waiting for PID $pid"
  wait $pid
done |& tee ib-write-test-results.log
