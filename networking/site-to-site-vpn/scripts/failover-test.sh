#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: all bash -c '...' strings are intentionally single-quoted so that
# env vars expand in the child shell (vars are exported before these calls).
# Bring tunnel A down, assert traffic continues over tunnel B, restore, assert re-establishment.
#
# Environment variables:
#   VPN_HOST          (required) Crusoe VPN VM public IP
#   REMOTE_TEST_IP    (required) Private IP of a test host on the customer side
#   TUNNEL_A_NAME     (optional, default tunnel-a) Name of the IKE SA / connection to take down (e.g. "tunnel-a")
#   TUNNEL_A_IF_ID    (required) XFRM interface ID for tunnel A (e.g. 101).
#                     Set this to the xfrm_if_id assigned to tunnel A in your Terraform config.
#                     Without it the script cannot bring the XFRM interface down and will abort.
#   MAX_LOSS_PCT      (optional, default 25) Max acceptable ping loss % during failover
#   RECONVERGE_TIMEOUT (optional, default 90) Seconds allowed for BGP reconvergence
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
: "${TUNNEL_A_NAME:=tunnel-a}"
require_env VPN_HOST REMOTE_TEST_IP
: "${MAX_LOSS_PCT:=25}"       # documented bound: reconverge within ~30s of a 120s ping window
: "${RECONVERGE_TIMEOUT:=90}"

if [ -z "${TUNNEL_A_IF_ID:-}" ]; then
  echo "ERROR: TUNNEL_A_IF_ID is required. Set it to the xfrm_if_id of $TUNNEL_A_NAME (e.g. 101)." >&2
  echo "       Check your Terraform config (tunnels[*].xfrm_if_id) or 'sudo swanctl --list-conns'." >&2
  exit 2
fi

export VPN_HOST REMOTE_TEST_IP TUNNEL_A_NAME MAX_LOSS_PCT RECONVERGE_TIMEOUT TUNNEL_A_IF_ID


# Pin probe source to the VM's VPC address (see verify.sh).
SRC_IP=$(vssh "$VPN_HOST" "hostname -I" | awk '{print $1}')
[ -n "$SRC_IP" ] || { echo "ERROR: could not resolve VPN VM source IP" >&2; exit 2; }
export SRC_IP
echo "Starting background ping (120s window)..."
vssh "$VPN_HOST" "nohup ping -i 0.5 -w 120 -I $SRC_IP $REMOTE_TEST_IP > /tmp/failover-ping.log 2>&1 &"
sleep 5

echo "Terminating IKE SA for $TUNNEL_A_NAME..."
vssh "$VPN_HOST" "sudo swanctl --terminate --ike $TUNNEL_A_NAME --timeout 10 || true"
# Prevent immediate trap re-establishment by taking the XFRM interface down.
vssh "$VPN_HOST" "sudo ip link set ipsec${TUNNEL_A_IF_ID} down"

# Assert the induced failure is real. Note: the IKE SA re-establishes almost
# immediately (start_action=trap here, and cloud peers re-initiate), so SA
# state is NOT the failover signal — the downed XFRM interface (data path) is.
assert "tunnel A data path is down (xfrm link DOWN)" bash -c '
  vssh "$VPN_HOST" "ip link show ipsec${TUNNEL_A_IF_ID}" | grep -q "state DOWN"
'

echo "Waiting for BGP reconvergence..."
assert "BGP reconverges within ${RECONVERGE_TIMEOUT}s (route still present)" \
  retry $((RECONVERGE_TIMEOUT / 5)) 5 bash -c '
    vssh "$VPN_HOST" ip route show proto bgp | grep -q .
  '

# Traffic recovers once BGP withdraws the dead path (hold timer <= 30s);
# retry across the reconvergence window rather than demanding instant success.
assert "traffic continues over tunnel B within ${RECONVERGE_TIMEOUT}s" \
  retry $((RECONVERGE_TIMEOUT / 5)) 5 bash -c '
    vssh "$VPN_HOST" "ping -c 5 -W 2 -I $SRC_IP $REMOTE_TEST_IP" > /dev/null
  '

echo "Restoring tunnel A..."
vssh "$VPN_HOST" "sudo /usr/local/sbin/vpn-xfrm-up.sh && sudo swanctl --initiate --ike $TUNNEL_A_NAME --timeout 30 || true"

assert "tunnel A re-established" \
  retry 12 10 bash -c '
    vssh "$VPN_HOST" sudo swanctl --list-sas | grep -q "${TUNNEL_A_NAME}.*ESTABLISHED"
  '

# Poll until the ping log contains "packet loss" (the summary line), then read
# the result. Allow up to 135s total (120s ping window + 15s slack).
echo "Waiting for ping to finish and report loss summary..."
# shellcheck disable=SC2034
for _i in $(seq 1 27); do
  vssh "$VPN_HOST" "grep -q 'packet loss' /tmp/failover-ping.log 2>/dev/null" && break
  sleep 5
done

LOSS=$(vssh "$VPN_HOST" "grep -o '[0-9.]*% packet loss' /tmp/failover-ping.log | grep -o '^[0-9.]*'" 2>/dev/null || echo 100)
export LOSS
assert "packet loss ${LOSS}% <= ${MAX_LOSS_PCT}%" bash -c '
  awk -v l="$LOSS" -v m="$MAX_LOSS_PCT" "BEGIN{exit (l<=m) ? 0 : 1}"
'

summary
