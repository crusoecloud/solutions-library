#!/bin/bash
# Same-HCA ib_write_bw (host memory) from this node (the client) to its targets in the
# hostfile. One target and one HCA at a time: running all HCAs at once saturates VM
# host memory and under-reports each one. Reports the measured bandwidth; no pass/fail.
#
# Env:
#   IB_TOPOLOGY=ring     ring: the next node in the hostfile (the last node wraps to the
#                        first); mesh or star: every other node
#   IB_DURATION=10       seconds per pair (ib_write_bw -D)
#   IB_QPS=4             queue pairs per test; one QP does not reach line rate
#   IB_PORT=18515        TCP port for the ib_write_bw handshake
#
# Exit: 0 every pair gave a result, 1 a pair gave no result, 2 setup error.
set -euo pipefail

HOSTFILE=${HOSTFILE:-/home/ubuntu/fabric-validation/hostfile}
TOPOLOGY=${IB_TOPOLOGY:-ring}
DURATION=${IB_DURATION:-10}
QPS=${IB_QPS:-4}
PORT=${IB_PORT:-18515}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)

command -v ib_write_bw >/dev/null || { echo "ERROR: ib_write_bw not found (perftest)"; exit 2; }
[ -r "$HOSTFILE" ] || { echo "ERROR: $HOSTFILE not found"; exit 2; }

# Compute HCAs: InfiniBand link layer, port ACTIVE, highest rate. Lower-rate HCAs
# (storage or management) are left out.
declare -A RATE
for dev in /sys/class/infiniband/*; do
  port=$dev/ports/1
  [ "$(cat "$port/link_layer" 2>/dev/null)" = "InfiniBand" ] || continue
  grep -q ACTIVE "$port/state" 2>/dev/null || continue
  RATE[$(basename "$dev")]=$(awk '{print int($1)}' "$port/rate")
done
[ "${#RATE[@]}" -gt 0 ] || { echo "ERROR: no active InfiniBand HCA found"; exit 2; }

MAX_RATE=$(printf '%s\n' "${RATE[@]}" | sort -n | tail -1)
mapfile -t HCAS < <(for h in "${!RATE[@]}"; do [ "${RATE[$h]}" -eq "$MAX_RATE" ] && echo "$h"; done | sort -V)

mapfile -t LOCAL_IPS < <(hostname -I | tr ' ' '\n' | grep -v '^$')
mapfile -t NODES < <(awk 'NF {print $1}' "$HOSTFILE")
self=-1
for i in "${!NODES[@]}"; do
  for ip in "${LOCAL_IPS[@]}"; do [ "${NODES[$i]}" = "$ip" ] && self=$i; done
done
[ "$self" -ge 0 ] || { echo "ERROR: none of this node's IPs (${LOCAL_IPS[*]}) is in $HOSTFILE"; exit 2; }

TARGETS=()
case "$TOPOLOGY" in
  ring)
    next=$(( (self + 1) % ${#NODES[@]} ))
    [ "$next" -eq "$self" ] || TARGETS=("${NODES[$next]}")
    ;;
  mesh|star)
    for i in "${!NODES[@]}"; do [ "$i" -eq "$self" ] || TARGETS+=("${NODES[$i]}"); done
    ;;
  *)
    echo "ERROR: IB_TOPOLOGY must be ring, mesh or star (got '$TOPOLOGY')"
    exit 2
    ;;
esac

echo "HCAs: ${HCAS[*]}"
echo "Client: $(hostname) (${NODES[$self]}) | topology: $TOPOLOGY | targets: ${TARGETS[*]:-none} | ${DURATION}s per pair, ${QPS} QPs"

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "SUMMARY: skipped, needs 2 or more nodes"
  exit 0
fi

results=()
errors=0
for target in "${TARGETS[@]}"; do
  for hca in "${HCAS[@]}"; do
    args=(-d "$hca" -p "$PORT" -q "$QPS" -D "$DURATION" -F --report_gbits)
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$target" "timeout $(( DURATION + 30 )) ib_write_bw ${args[*]}" >/dev/null 2>&1 &
    server=$!
    sleep 2
    out=$(timeout $(( DURATION + 20 )) ib_write_bw "${args[@]}" "$target" 2>&1) || true
    wait "$server" || true

    # Data line: #bytes #iterations BW_peak BW_average MsgRate
    bw=$(awk '$1 ~ /^[0-9]+$/ && NF >= 5 {v=$4} END {print v}' <<< "$out")
    if [ -n "$bw" ]; then
      results+=("$bw")
      printf '%-16s %-10s %8s Gb/s\n' "$target" "$hca" "$bw"
    else
      errors=$(( errors + 1 ))
      printf '%-16s %-10s %8s\n' "$target" "$hca" "ERROR"
      echo "$out" | tail -5 | sed 's/^/    /'
    fi
  done
done

total=$(( ${#results[@]} + errors ))
if [ "${#results[@]}" -gt 0 ]; then
  stats=$(printf '%s\n' "${results[@]}" | sort -n | awk '{v[NR]=$1} END {printf "min %s / median %s / max %s Gb/s", v[1], v[int((NR+1)/2)], v[NR]}')
else
  stats="no results"
fi
echo "SUMMARY: ${#results[@]}/${total} HCA pairs measured: ${stats}$([ "$errors" -eq 0 ] || echo ", ${errors} ERROR")"
[ "$errors" -eq 0 ] || exit 1
