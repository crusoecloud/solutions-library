#!/usr/bin/env bash
# pair_rail.sh -- 2-node SAME-RAIL ib_write_bw for all 8 ionic rails.
#
# Run on an ANCHOR node that is known-good (its 8 rails already passed this test
# or a multi-node RCCL run). The anchor is the ib_write_bw client; each target
# runs the server, started over passwordless SSH. Host memory only (no GPU).
#
#   ./pair_rail.sh <target-ip>               # anchor (this node) vs one target
#   ./pair_rail.sh -f <ip-file>              # every IP in the file, ONE TARGET AT A TIME
#
# Env (defaults in bundle-2.2.env):
#   RAILS="0 1 2 3 4 5 6 7"   rails to test, one at a time
#   PAIR_DUR_S=8              ib_write_bw -D seconds per rail
#   PAIR_RAIL_MIN_GBPS=320    per-rail floor (BW average column)
#   PARALLEL_RAILS=0          1 = run the 8 rails of ONE target concurrently (faster;
#                             planes are isolated). Targets are still sequential.
#   SSH_USER=<user>           default: current user
#   IBWB_EXTRA="..."          extra ib_write_bw flags for both ends (e.g. "-q 4 -m 4096")
#   OUT_DIR=<dir>             also write the run to <dir>/pair_rail-<anchor>-<ts>.txt
#
# Output, one line per rail (pipe-delimited, same shape as env_verify.sh):
#   <target-host>[<ip>]|pair_rail:ionic_N:anchor=<anchor-host>|>=320 Gb/s|<bw> Gb/s <err>|PASS|FAIL|SKIP
# then a per-target and an overall summary line. Exit: 0 all PASS, 1 any FAIL,
# 3 anchor rail unhealthy (results for that rail are meaningless).
#
# Design rules:
#  * NEVER an all-parallel ring across the pool. Concurrent pairs measure the
#    harness and congestion, not the NICs.
#  * One rail at a time by default: 8 rails at ~390 Gb/s in parallel saturate VM host
#    memory and under-report every rail (set PARALLEL_RAILS=1 only for a quick sweep).
#  * 4 QPs per rail (IBWB_EXTRA="-q 4" in bundle-2.2.env): one QP tops out ~260 Gb/s.
#  * Same rail both ends (ionic_i <-> ionic_i). Cross-rail fails BY DESIGN: the
#    8 planes are isolated.
#  * Convict a target rail only when it fails against >= 2 different known-good
#    anchors. The same rail failing for EVERY target = that plane's leaf/anchor.
#  * Do not probe the server port with nc / /dev/tcp: ib_write_bw's server
#    accepts exactly one connection and the probe consumes it.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bundle-2.2.env
[ -r "${BUNDLE_ENV:-$HERE/bundle-2.2.env}" ] && . "${BUNDLE_ENV:-$HERE/bundle-2.2.env}"
RAILS="${RAILS:-0 1 2 3 4 5 6 7}"
DUR="${PAIR_DUR_S:-8}"; MIN="${PAIR_RAIL_MIN_GBPS:-320}"; PORT_BASE="${PAIR_PORT_BASE:-18800}"
GID_INDEX="${GID_INDEX:-1}"; RAIL_PREFIX="${RAIL_PREFIX:-ionic_}"
PARALLEL_RAILS="${PARALLEL_RAILS:-0}"; IBWB_EXTRA="${IBWB_EXTRA:-}"
SSH_USER="${SSH_USER:-$(id -un)}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
IBWB="${IBWB:-$(command -v ib_write_bw || echo ib_write_bw)}"

usage(){ sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
TARGETS=()
case "${1:-}" in
  -f) [ -r "${2:-}" ] || usage; mapfile -t TARGETS < <(grep -vE '^[[:space:]]*(#|$)' "$2" | awk '{print $1}') ;;
  ""|-h|--help) usage ;;
  *) TARGETS=("$@") ;;
esac

ANCHOR=$(hostname -s 2>/dev/null || hostname)
# all local addresses, so the anchor skips itself when it appears in the IP file
LOCAL_IPS=" $(ip -o addr show 2>/dev/null | awk '{split($4,a,"/"); printf "%s ", a[1]}') "
MGMT_IF=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
ANCHOR_IP=$(ip -o -4 addr show dev "${MGMT_IF:-lo}" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
TS=$(date -u +%Y%m%dT%H%M%SZ)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pair_rail.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
OUTF=/dev/null
if [ -n "${OUT_DIR:-}" ]; then mkdir -p "$OUT_DIR" && OUTF="$OUT_DIR/pair_rail-$ANCHOR-$TS.txt"; fi
say(){ echo "$*" | tee -a "$OUTF"; }
log(){ echo ">> $*" | tee -a "$OUTF" >&2; }

rail_state(){ # dev -> "STATE GID" (local)
  local P=/sys/class/infiniband/$1/ports/1
  echo "$(awk '{print $NF}' "$P/state" 2>/dev/null || echo MISSING) $(cat "$P/gids/$GID_INDEX" 2>/dev/null || echo none)"
}
# shellcheck disable=SC2029  # callers build remote commands on purpose
rssh(){ local h=$1; shift; ssh "${SSH_OPTS[@]}" "$SSH_USER@$h" "$@"; }
# remote snippet: kill only the ib_write_bw bound to one port (pkill -f would also
# match the ssh shell's own command line, which contains the same string)
kill_port(){ printf '%s' "for p in \$(pgrep -x ib_write_bw); do tr '\\0' ' ' </proc/\$p/cmdline 2>/dev/null | grep -q -- ' -p $1 ' && kill \$p; done"; }

# ---- anchor sanity: its rails must be healthy or every verdict is suspect ----
declare -A ANCHOR_OK
anchor_bad=0
for r in $RAILS; do
  read -r st gid < <(rail_state "$RAIL_PREFIX$r")
  if [ "$st" = ACTIVE ] && [ "$gid" != none ] && [[ "$gid" != 0000:* ]]; then ANCHOR_OK[$r]=1
  else ANCHOR_OK[$r]=0; anchor_bad=1; log "ANCHOR $ANCHOR $RAIL_PREFIX$r unhealthy (state=$st gid=$gid) -- that rail will be SKIP"; fi
done
log "anchor=$ANCHOR ip=${ANCHOR_IP:-?} mgmt_if=${MGMT_IF:-?} rails='$RAILS' dur=${DUR}s floor=${MIN} Gb/s parallel_rails=$PARALLEL_RAILS ib_write_bw=$IBWB"

# ---- one rail: remote server + local client --------------------------------
# writes "<bw-or-DEAD> <err>" to $TMP/<ip>.<rail>
run_rail(){
  local ip=$1 r=$2 dev=$RAIL_PREFIX$2 port=$((PORT_BASE + $2)) out bw err try
  for try in 1 2; do
    # shellcheck disable=SC2029  # remote expansion is intended
    rssh "$ip" "$(kill_port "$port") >/dev/null 2>&1; nohup timeout $((DUR + 45)) $IBWB -d $dev -x $GID_INDEX -F -p $port -D $DUR --report_gbits $IBWB_EXTRA >/tmp/pair_rail_srv_$r.log 2>&1 </dev/null &" \
      >/dev/null 2>&1
    sleep 2
    # shellcheck disable=SC2086  # IBWB_EXTRA is a word list
    out=$(timeout $((DUR + 25)) "$IBWB" -d "$dev" -x "$GID_INDEX" -F -p "$port" -D "$DUR" --report_gbits $IBWB_EXTRA "$ip" 2>&1)
    echo "$out" > "$TMP/$ip.$r.raw.$try"
    bw=$(awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+/{x=$4} END{print x}' <<<"$out")
    err=$(grep -oiE 'error 12|status=12|timed out|Couldn.t connect[^.]*|Failed to [a-z ]+|Unable to [a-z ]+|Unsupported [a-z ]+|No such device' <<<"$out" | head -1)
    # a connect race on the first try (server not yet listening) is retried once
    if [ -n "$bw" ] || ! grep -qi "couldn.t connect" <<<"$err"; then break; fi
    sleep 3
  done
  rssh "$ip" "$(kill_port "$port")" >/dev/null 2>&1
  echo "${bw:-DEAD} ${err:-}" > "$TMP/$ip.$r"
}

TOTAL_FAIL=0; TOTAL_PASS=0; TOTAL_SKIP=0; FAILED_TARGETS=""
n_t=0
for ip in "${TARGETS[@]}"; do
  case "$LOCAL_IPS" in *" $ip "*) log "skip $ip (this anchor)"; continue ;; esac
  n_t=$((n_t+1))
  th=$(rssh "$ip" 'hostname -s' 2>/dev/null)
  if [ -z "$th" ]; then
    for r in $RAILS; do say "?[$ip]|pair_rail:$RAIL_PREFIX$r:anchor=$ANCHOR|>=$MIN Gb/s|ssh unreachable|FAIL"; TOTAL_FAIL=$((TOTAL_FAIL+1)); done
    FAILED_TARGETS="$FAILED_TARGETS $ip"; continue
  fi
  log "[$n_t/${#TARGETS[@]}] target $th ($ip)"
  # remote rail precheck in one round trip
  declare -A RST=()
  while read -r d st gid; do RST[$d]="$st $gid"; done < <(rssh "$ip" "for r in $RAILS; do P=/sys/class/infiniband/$RAIL_PREFIX\$r/ports/1; echo \$r \$(awk '{print \$NF}' \$P/state 2>/dev/null || echo MISSING) \$(cat \$P/gids/$GID_INDEX 2>/dev/null || echo none); done" 2>/dev/null)
  rails_to_run=""
  for r in $RAILS; do
    [ "${ANCHOR_OK[$r]}" = 1 ] || continue
    read -r st _ <<<"${RST[$r]:-MISSING none}"
    if [ "$st" != ACTIVE ]; then echo "DEAD target port $st" > "$TMP/$ip.$r"; continue; fi
    rails_to_run="$rails_to_run $r"
  done
  if [ "$PARALLEL_RAILS" = 1 ]; then
    for r in $rails_to_run; do run_rail "$ip" "$r" & done; wait
  else
    for r in $rails_to_run; do run_rail "$ip" "$r"; done
  fi
  tf=0
  for r in $RAILS; do
    chk="pair_rail:$RAIL_PREFIX$r:anchor=$ANCHOR"
    if [ "${ANCHOR_OK[$r]}" != 1 ]; then say "${th}[$ip]|$chk|>=$MIN Gb/s|anchor rail unhealthy|SKIP"; TOTAL_SKIP=$((TOTAL_SKIP+1)); continue; fi
    read -r bw err < "$TMP/$ip.$r"
    if [ "$bw" != DEAD ] && awk -v b="$bw" -v m="$MIN" 'BEGIN{exit !(b+0 >= m+0)}'; then
      say "${th}[$ip]|$chk|>=$MIN Gb/s|$bw Gb/s|PASS"; TOTAL_PASS=$((TOTAL_PASS+1))
    else
      act="$bw Gb/s"; [ "$bw" = DEAD ] && act=DEAD
      say "${th}[$ip]|$chk|>=$MIN Gb/s|$act${err:+ ($err)}|FAIL"; TOTAL_FAIL=$((TOTAL_FAIL+1)); tf=$((tf+1))
    fi
  done
  say "${th}[$ip]|pair_rail:summary:anchor=$ANCHOR|0 FAIL|$tf FAIL|$([ $tf = 0 ] && echo PASS || echo FAIL)"
  [ $tf -gt 0 ] && FAILED_TARGETS="$FAILED_TARGETS ${th}[$ip]"
done

say "$ANCHOR|pair_rail:overall|0 FAIL|targets=$n_t pass=$TOTAL_PASS fail=$TOTAL_FAIL skip=$TOTAL_SKIP|$([ $TOTAL_FAIL = 0 ] && echo PASS || echo FAIL)"
if [ -n "$FAILED_TARGETS" ]; then
  log "failing targets:$FAILED_TARGETS"
  log "convict a rail only after it also fails vs a SECOND known-good anchor; the same rail failing for every target points at the anchor or that plane's leaf"
fi
[ "$anchor_bad" = 1 ] && exit 3
[ "$TOTAL_FAIL" = 0 ]
