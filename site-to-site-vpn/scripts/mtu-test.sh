#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: all bash -c '...' strings are intentionally single-quoted so that
# $VPN_HOST / $REMOTE_TEST_IP expand in the child shell (vars are exported).
# MTU/MSS validation: DF-bit boundary probes + large transfer must not stall.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST REMOTE_TEST_IP
: "${TUNNEL_MTU:=1400}"
# TRANSFER_URL (optional): HTTP URL reachable through the tunnel for the large
# transfer proof, e.g. http://<remote>:5201/blob served by python3 -m
# http.server. Used when no iperf3 server runs on the remote side.
: "${TRANSFER_URL:=}"

export VPN_HOST REMOTE_TEST_IP TUNNEL_MTU TRANSFER_URL

# ICMP payload = MTU - 28 (20-byte IP + 8-byte ICMP headers).
FIT=$((TUNNEL_MTU - 28))
TOOBIG=$((TUNNEL_MTU + 100 - 28))

export FIT TOOBIG

# Pin probe source to the VM's VPC address (VM-originated probes otherwise
# source from the 169.254 tunnel address, which the peer filters).
SRC_IP=$(vssh "$VPN_HOST" "hostname -I" | awk '{print $1}')
export SRC_IP
assert "resolved VPN VM source address" bash -c '[ -n "$SRC_IP" ]'

assert "DF ping at tunnel MTU (${FIT}B payload) succeeds" bash -c '
  vssh "$VPN_HOST" "ping -M do -s $FIT -c 3 -W 2 -I $SRC_IP $REMOTE_TEST_IP" > /dev/null
'

# Plan bug fix: an oversized DF ping through the tunnel may be silently dropped
# (ICMP too-big may not be returned to the sender, depending on path MTU probing
# and the remote gateway's behaviour).  We therefore accept EITHER:
#   (a) a local "message too long / frag needed" error from the sending kernel, OR
#   (b) 100% packet loss (all probes timed out — tunnel silently dropped them).
# Both outcomes prove there is no MTU black-hole blowing up larger frames silently.
assert "DF ping above tunnel MTU (${TOOBIG}B payload) is rejected or dropped (no silent pass-through)" bash -c '
  output=$(vssh "$VPN_HOST" "ping -M do -s $TOOBIG -c 2 -W 2 -I $SRC_IP $REMOTE_TEST_IP" 2>&1 || true)
  # Pass if local ICMP error was returned (too-big message) OR if all packets were lost.
  echo "$output" | grep -qiE "message too long|frag needed" && exit 0
  echo "$output" | grep -qE "100% packet loss" && exit 0
  # A partial loss is suspicious — reject it so the operator investigates.
  exit 1
'

# Large transfer proves MSS clamp end-to-end (>=10MB over TCP must complete).
assert "large TCP transfer completes without stalling" bash -c '
  if [ -n "$TRANSFER_URL" ]; then
    vssh "$VPN_HOST" "curl -sf --interface $SRC_IP -o /dev/null --max-time 60 $TRANSFER_URL"
  else
    vssh "$VPN_HOST" "timeout 60 iperf3 -B $SRC_IP -c $REMOTE_TEST_IP -n 10M" > /dev/null
  fi
'

summary
