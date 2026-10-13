#!/usr/bin/env bash
# Shared helpers for VPN test scripts. Source, don't execute.

: "${VPN_SSH_USER:=ubuntu}"
: "${VPN_SSH_OPTS:=-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes}"
export VPN_SSH_USER VPN_SSH_OPTS
export VPN_SSH_KEY="${VPN_SSH_KEY:-}"

PASS_COUNT=0
FAIL_COUNT=0

vssh() { # vssh <host> <cmd...>
  local host=$1; shift
  # SC2086: VPN_SSH_OPTS is intentionally word-split (it is a space-separated option list).
  # SC2029: "$@" expands on the client side — that is the intended behaviour for an SSH wrapper.
  # shellcheck disable=SC2086,SC2029
  ssh $VPN_SSH_OPTS ${VPN_SSH_KEY:+-i "$VPN_SSH_KEY"} "${VPN_SSH_USER}@${host}" "$@"
}
# Export vssh so that `bash -c` subshells can call it (assert uses bash -c).
export -f vssh

assert() { # assert <description> <cmd...>
  local desc=$1; shift
  if "$@"; then
    echo "PASS: $desc"; PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "FAIL: $desc"; FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}
export -f assert

retry() { # retry <attempts> <sleep_s> <cmd...>
  local n=$1 s=$2; shift 2
  local i
  for ((i=1; i<=n; i++)); do
    if "$@"; then return 0; fi
    if (( i < n )); then sleep "$s"; fi
  done
  return 1
}
export -f retry

summary() {
  echo "----------------------------------------"
  echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}

require_env() {
  local missing=0 v
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then echo "ERROR: env $v is required" >&2; missing=1; fi
  done
  [ "$missing" -eq 0 ] || exit 2
}
