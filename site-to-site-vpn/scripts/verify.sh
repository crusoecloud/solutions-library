#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: all bash -c '...' strings are intentionally single-quoted so that
# $VPN_HOST / $REMOTE_TEST_IP expand in the child shell (vars are exported).
# End-to-end control+data plane verification. Exits non-zero on any failure.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_env VPN_HOST REMOTE_TEST_IP

# Export env vars consumed inside bash -c subshells.
export VPN_HOST REMOTE_TEST_IP

echo "== Control plane =="

# Count ESTABLISHED IKE SAs and compare to number of configured connections.
# Plan bug fix: original `grep -c ESTABLISHED | grep -qvw 0` was convoluted and
# could spuriously pass.  Instead we compare established count >= conn count.
assert "IKE SAs ESTABLISHED for all tunnels" bash -c '
  est=$(vssh "$VPN_HOST" sudo swanctl --list-sas 2>/dev/null | grep -c ESTABLISHED || true)
  conns=$(vssh "$VPN_HOST" sudo swanctl --list-conns 2>/dev/null | grep -cE "^[a-z0-9_-]+:" || true)
  [ "${conns:-0}" -gt 0 ] && [ "${est:-0}" -ge "$conns" ]
'

assert "CHILD_SAs INSTALLED" bash -c '
  vssh "$VPN_HOST" sudo swanctl --list-sas 2>/dev/null | grep -q INSTALLED
'

assert "all BGP sessions Established" \
  bash -c 'vssh "$VPN_HOST" "sudo vtysh -c \"show bgp summary json\"" | python3 -c "
import json,sys
d=json.load(sys.stdin)
peers=d.get(\"ipv4Unicast\",{}).get(\"peers\",{})
sys.exit(0 if peers and all(p[\"state\"]==\"Established\" for p in peers.values()) else 1)"'

assert "customer prefixes present in RIB via BGP" bash -c '
  vssh "$VPN_HOST" ip route show proto bgp | grep -q .
'

echo "== Data plane =="

assert "ICMP to remote test host" bash -c '
  vssh "$VPN_HOST" ping -c 4 -W 2 "$REMOTE_TEST_IP" > /dev/null
'

assert "TCP path works (ssh port probe or iperf3)" bash -c '
  vssh "$VPN_HOST" "timeout 10 bash -c \"exec 3<>/dev/tcp/$REMOTE_TEST_IP/22\" 2>/dev/null || timeout 15 iperf3 -c $REMOTE_TEST_IP -t 3 >/dev/null 2>&1"
'

summary
