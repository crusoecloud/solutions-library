#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: all bash -c '...' strings are intentionally single-quoted so that
# env vars expand in the child shell (vars are exported before these calls).
# Force IKE and CHILD rekey; assert a concurrent ping sees no drop.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
: "${TUNNEL_A_NAME:=tunnel-a}"
require_env VPN_HOST REMOTE_TEST_IP

export VPN_HOST REMOTE_TEST_IP TUNNEL_A_NAME


# Pin probe source to the VM's VPC address (see verify.sh).
SRC_IP=$(vssh "$VPN_HOST" "hostname -I" | awk '{print $1}')
[ -n "$SRC_IP" ] || { echo "ERROR: could not resolve VPN VM source IP" >&2; exit 2; }
export SRC_IP
vssh "$VPN_HOST" "nohup ping -i 0.2 -w 60 -I $SRC_IP $REMOTE_TEST_IP > /tmp/rekey-ping.log 2>&1 &"
sleep 3

assert "CHILD_SA rekey succeeds" bash -c '
  vssh "$VPN_HOST" "sudo swanctl --rekey --child $TUNNEL_A_NAME 2>/dev/null"
'

sleep 5

assert "IKE_SA rekey succeeds" bash -c '
  vssh "$VPN_HOST" "sudo swanctl --rekey --ike $TUNNEL_A_NAME 2>/dev/null"
'

# Wait for the 60s ping window to complete.
sleep 55

LOSS=$(vssh "$VPN_HOST" "grep -o '[0-9.]*% packet loss' /tmp/rekey-ping.log | grep -o '^[0-9.]*'" 2>/dev/null || echo 100)
assert "zero packet loss across rekeys (got ${LOSS}%)" bash -c "
  awk -v l=$LOSS 'BEGIN{exit !(l==0)}'
"

assert "SAs still ESTABLISHED post-rekey" bash -c '
  vssh "$VPN_HOST" sudo swanctl --list-sas | grep -q ESTABLISHED
'

summary
