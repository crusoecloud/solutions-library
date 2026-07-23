#!/usr/bin/env bash
# Monitoring-pollable health check. Run ON the VPN VM (or via: ssh vm sudo healthcheck.sh).
# Exit 0 only if every IKE SA ESTABLISHED, every CHILD_SA INSTALLED,
# every BGP peer Established, every ipsec* interface up.
set -uo pipefail
rc=0

sas=$(swanctl --list-sas 2>/dev/null)
# Count configured connections (lines of the form "name:").
conns=$(swanctl --list-conns 2>/dev/null | grep -cE '^[a-z0-9_-]+:' || true)
est=$(grep -c ESTABLISHED <<<"$sas" || true)
inst=$(grep -c INSTALLED <<<"$sas" || true)

[ "${est:-0}" -ge "${conns:-0}" ] && [ "${conns:-0}" -gt 0 ] || { echo "CRIT: IKE SAs $est/$conns established"; rc=1; }
[ "${inst:-0}" -ge "${conns:-0}" ] || { echo "CRIT: CHILD_SAs $inst/$conns installed"; rc=1; }

vtysh -c 'show bgp summary json' 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
peers=d.get("ipv4Unicast",{}).get("peers",{})
bad=[ip for ip,p in peers.items() if p["state"]!="Established"]
if not peers: print("CRIT: no BGP peers configured"); sys.exit(1)
if bad: print("CRIT: BGP not Established:", ",".join(bad)); sys.exit(1)' || rc=1

for ifc in $(ip -o link show type xfrm | awk -F': ' '{print $2}'); do
  ip link show "$ifc" | grep -q 'state UP\|UNKNOWN' || { echo "CRIT: $ifc down"; rc=1; }
done

[ $rc -eq 0 ] && echo "OK: all tunnels, SAs, BGP sessions healthy"
exit $rc
