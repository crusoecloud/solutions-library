#!/usr/bin/env bash
# rail_census.sh -- quick per-node state of the 8 ionic RoCE rails.
#
# Reads each rail's link state, GID, MTU and neighbor state from sysfs, plus a read-only
# IPv6 neighbor-discovery check. Runs locally, changes nothing.
#
#   ./rail_census.sh                 # one line per rail + a node summary line
#   DELTA_S=20 ./rail_census.sh      # also sample RDMA tx/rx bytes over 20 s
#                                    # (hung-vs-slow check while a job is running)
#   SHOW_COUNTERS=1 ./rail_census.sh # dump every non-zero error-ish hw counter
#
# Output (pipe-delimited):
#   RAIL|host|ionic_N|netdev|state|phys|gid<idx>|gid_type|ipv4|ipv6_global|mtu|ndisc_notify|nbr|fw|pcie|err_counters[|tx_bytes_delta|rx_bytes_delta]
#   CENSUS|host|rails=N/8|active=A/8|gid=G/8|ndisc_notify=X|fw=<v or MIXED>|nbr0=K|VERDICT
# Exit: 0 = all rails ACTIVE/LinkUp with a valid GID; 1 otherwise.
#
# Reading it:
#  * non-ACTIVE / Polling is a verdict: the link never trained.
#  * nbr=0 is a question, not a verdict: IPv6 neighbour entries age out on an
#    idle fabric. Only a rail that stays nbr=0 right after real traffic is a
#    wedge suspect -- confirm with pair_rail.sh before acting.
#  * On ionic the sysfs port_xmit_* counters read 0; `rdma statistic` /
#    hw_counters are the real byte counters.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bundle-2.2.env
[ -r "${BUNDLE_ENV:-$HERE/bundle-2.2.env}" ] && . "${BUNDLE_ENV:-$HERE/bundle-2.2.env}"
RAIL_PREFIX="${RAIL_PREFIX:-ionic_}"; GID_INDEX="${GID_INDEX:-1}"
RAIL_COUNT_EXPECTED="${RAIL_COUNT_EXPECTED:-8}"; GID_PREFIX_EXPECTED="${GID_PREFIX_EXPECTED:-}"
DELTA_S="${DELTA_S:-0}"; SHOW_COUNTERS="${SHOW_COUNTERS:-0}"
export PATH="$PATH:/usr/sbin:/sbin"
HOST=$(hostname -s 2>/dev/null || hostname)

RAILS=(); for p in /sys/class/infiniband/"${RAIL_PREFIX}"*; do [ -e "$p" ] && RAILS+=("${p##*/}"); done
netdev_of(){ local x; for x in /sys/class/infiniband/"$1"/device/net/*; do [ -e "$x" ] && { echo "${x##*/}"; return; }; done; }

# total tx/rx RDMA bytes for one device: prefer `rdma statistic`, fall back to hw_counters
rdma_bytes(){ # dev -> "tx rx"
  local d=$1 s tx rx
  s=$(rdma statistic show link "$d/1" 2>/dev/null | tr ' ' '\n' | paste - - 2>/dev/null)
  tx=$(awk '$1 ~ /tx_rdma_ucast_bytes|tx_rdma_bytes|tx_bytes/ {s+=$2} END{print s+0}' <<<"$s")
  rx=$(awk '$1 ~ /rx_rdma_ucast_bytes|rx_rdma_bytes|rx_bytes/ {s+=$2} END{print s+0}' <<<"$s")
  if [ "$tx" = 0 ] && [ "$rx" = 0 ]; then
    local hc=/sys/class/infiniband/$d/ports/1/hw_counters
    tx=$(cat "$hc"/tx_rdma_ucast_bytes 2>/dev/null || echo 0)
    rx=$(cat "$hc"/rx_rdma_ucast_bytes 2>/dev/null || echo 0)
  fi
  echo "$tx $rx"
}
err_counters(){ # dev -> "name=val,..." for non-zero error-ish hw counters
  local hc=/sys/class/infiniband/$1/ports/1/hw_counters f v out=""
  [ -d "$hc" ] || { echo "-"; return; }
  for f in "$hc"/*; do
    case "$(basename "$f")" in *err*|*retry*|*timeout*|*nak*|*drop*|*discard*|*seq*|*oos*|*cnp*|*ecn*) ;; *) [ "$SHOW_COUNTERS" = 1 ] || continue ;; esac
    v=$(cat "$f" 2>/dev/null); [ "${v:-0}" != 0 ] && out="$out${out:+,}$(basename "$f")=$v"
  done
  echo "${out:--}"
}

declare -A T0 R0
if [ "$DELTA_S" -gt 0 ] 2>/dev/null; then
  for d in "${RAILS[@]}"; do read -r "T0[$d]" "R0[$d]" < <(rdma_bytes "$d"); done
  sleep "$DELTA_S"
fi

act=0; gok=0; nbr0=0; fws=""
for d in "${RAILS[@]}"; do
  P=/sys/class/infiniband/$d/ports/1
  st=$(awk '{print $NF}' "$P/state" 2>/dev/null)
  ph=$(cut -d: -f2- "$P/phys_state" 2>/dev/null | tr -d ' ')
  gid=$(cat "$P/gids/$GID_INDEX" 2>/dev/null)
  gty=$(tr ' ' '_' < "$P/gid_attrs/types/$GID_INDEX" 2>/dev/null)
  fw=$(cat "/sys/class/infiniband/$d/fw_ver" 2>/dev/null); fws="$fws $fw"
  ifc=$(netdev_of "$d")
  v4=-; v6=-; mtu=-; nd=-; nbr=-1
  if [ -n "$ifc" ]; then
    v4=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | paste -sd, -); v4=${v4:--}
    v6=$(ip -o -6 addr show dev "$ifc" scope global 2>/dev/null | awk '{print $4}' | paste -sd, -); v6=${v6:--}
    mtu=$(cat "/sys/class/net/$ifc/mtu" 2>/dev/null)
    nd=$(cat "/proc/sys/net/ipv6/conf/$ifc/ndisc_notify" 2>/dev/null)
    nbr=$(ip -6 neigh show dev "$ifc" 2>/dev/null | grep -cE 'REACHABLE|STALE|DELAY|PROBE')
  fi
  dev=/sys/class/infiniband/$d/device
  pcie="x$(cat "$dev/current_link_width" 2>/dev/null)/x$(cat "$dev/max_link_width" 2>/dev/null)"
  [ "$st" = ACTIVE ] && [ "$ph" = LinkUp ] && act=$((act+1))
  if [ -n "$gid" ] && [ "$gid" != "0000:0000:0000:0000:0000:0000:0000:0000" ] && [[ "$gid" != fe80:* ]] \
     && { [ -z "$GID_PREFIX_EXPECTED" ] || [[ "$gid" == "$GID_PREFIX_EXPECTED"* ]]; }; then gok=$((gok+1)); fi
  [ "$nbr" = 0 ] && nbr0=$((nbr0+1))
  line="RAIL|$HOST|$d|${ifc:-none}|${st:-?}|${ph:-?}|gid$GID_INDEX=${gid:-missing}|${gty:-?}|$v4|$v6|${mtu:-?}|${nd:-?}|nbr=$nbr|${fw:-?}|$pcie|$(err_counters "$d")"
  if [ "$DELTA_S" -gt 0 ] 2>/dev/null; then
    read -r t1 r1 < <(rdma_bytes "$d")
    line="$line|tx_delta=$(( t1 - ${T0[$d]:-0} ))|rx_delta=$(( r1 - ${R0[$d]:-0} ))"
  fi
  echo "$line"
done

nfw=$(tr ' ' '\n' <<<"$fws" | grep -v '^$' | sort -u)
[ "$(grep -c . <<<"$nfw")" -gt 1 ] && nfw=MIXED
ndall=$(cat /proc/sys/net/ipv6/conf/all/ndisc_notify 2>/dev/null)
n=${#RAILS[@]}; exp=$RAIL_COUNT_EXPECTED
if [ "$n" = "$exp" ] && [ "$act" = "$exp" ] && [ "$gok" = "$exp" ]; then v=PASS; else v=FAIL; fi
echo "CENSUS|$HOST|rails=$n/$exp|active=$act/$exp|gid=$gok/$exp|ndisc_notify=${ndall:-?}|fw=${nfw:-?}|nbr0=$nbr0|$v"
[ "$v" = PASS ]
